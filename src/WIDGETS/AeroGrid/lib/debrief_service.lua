-- SPDX-License-Identifier: GPL-2.0-only

--- Records the layout's post-flight debrief: at each flight end, the flight
--- slice of every debrief series is copied from the history into chart pixel
--- columns, with its statistic, worst threshold level and per-column levels.
--- Only the latest debrief is kept, in memory.
local debrief = { RUNTIME_API = 1, UNITS_PER_SLOT = 4 }
debrief.updateCost = "variable"
debrief.updateMinCost = 1
debrief.__index = debrief

local LEVELS = { normal = 0, warning = 1, critical = 2 }
local NAMES = { [0] = "normal", "warning", "critical" }
-- Column times are flight ticks times pixels, which must stay within int32.
local TIME_LIMIT = 0x3fffffff

function debrief.new(env, support, runtime)
    return setmetatable({
        id = "debrief",
        revision = 0,
        interval = 50,
        count = 0,
        due = 0,
        handled = 0,
        env = env,
        support = support,
        runtime = runtime,
    }, debrief)
end

--- Index of the newest flight that needs no capture.
local function settled(history, session)
    local last = session.flightLast
    local start, finish = history:flight(session, last)
    return (start and not finish) and last - 1 or last
end

--- Subscribe the debrief series, at layout load and after every Save or
--- Armed rebind, so the history records them before the flight starts.
---@param section? table Validated debrief section of the layout.
---@param widths integer[] Plot width in pixels of each tile.
function debrief:configure(section, widths)
    local history = self.runtime.byId.history
    local job = self.job
    local resume = job and job.history == history and job.index
    self.job, self.tiles, self.widths, self.feeds = nil, {}, widths, {}
    self.history, self.session, self.count = history, nil, 0
    if not history or not section then
        return
    end
    for index, tile in ipairs(section.tiles) do
        local feeds = {}
        for position, series in ipairs(tile.series) do
            feeds[position] = history:subscribe(series.source, { precision = series.precision })
        end
        self.tiles[index], self.feeds[index] = tile, feeds
        self.count = self.count + #feeds
    end
    if self.count > 0 then
        self.session = history:session()
        self.handled = settled(history, self.session)
        -- A capture a Save interrupted starts over with the saved debrief.
        if resume and resume <= self.session.flightLast then
            self.handled = math.min(self.handled, resume - 1)
        end
    end
end

--- The latest debrief, or nil before the first recorded flight.
function debrief:result()
    return self.latest
end

function debrief:resetSession()
    self.latest, self.job, self.handled = nil, nil, 0
end

--- Last knot at or before `at`, or the first knot when none is.
local function search(history, feed, at)
    local low, high = feed.first, feed.last
    while low < high do
        local middle = (low + high + 1) // 2
        if history:point(feed, middle) <= at then
            low = middle
        else
            high = middle - 1
        end
    end
    return low
end

local function begin(self, index, start, finish)
    local telemetry = self.runtime.byId.telemetry
    local widest = 1
    for _, width in ipairs(self.widths) do
        widest = math.max(widest, width)
    end
    local scale = 1
    while (finish - start) // scale >= TIME_LIMIT // widest do
        scale = scale * 2
    end
    -- The previous debrief is released first to keep the peak heap down.
    self.latest = nil
    self.job = {
        history = self.history,
        index = index,
        start = start,
        finish = finish,
        scale = scale,
        window = (finish - start) // scale + 1,
        thresholds = telemetry and telemetry:thresholdMap() or {},
        level = telemetry and telemetry.level,
        tile = 1,
        position = 0,
        tiles = {},
    }
end

--- Start the next series, or return nil when every series is done.
local function nextSeries(self, job)
    local tile = self.tiles[job.tile]
    while tile do
        local position = job.position + 1
        local config = tile.series[position]
        if config then
            local feed = self.feeds[job.tile][position]
            local result = {
                config = config,
                level = "normal",
                columns = self.runtime.chartColumns.new(self.widths[job.tile], job.window, nil, { passive = true }),
                levels = {},
            }
            local tiles = job.tiles
            tiles[job.tile] = tiles[job.tile] or { config = tile, series = {} }
            tiles[job.tile].series[position] = result
            job.position = position
            job.series = {
                feed = feed,
                result = result,
                spec = job.thresholds[config.source],
                index = feed.count > 0 and search(self.history, feed, job.start) or nil,
                worst = 0,
                area = 0,
                time = 0,
                sum = 0,
                samples = 0,
            }
            return job.series
        end
        job.tile, job.position = job.tile + 1, 0
        tile = self.tiles[job.tile]
    end
end

--- Add one sample at flight time `at` (scaled ticks) to the series.
local function sample(job, series, at, value, connected)
    local store = series.result.columns
    store:sample(at, value, not connected, false, 0)
    if connected then
        local span = at - series.lastAt
        series.area = series.area + (series.lastValue + value) * 0.5 * span
        series.time = series.time + span
    elseif series.lastAt then
        store:breakAt(at)
    end
    series.first = series.first or value
    series.lastAt, series.lastValue = at, value
    series.sum, series.samples = series.sum + value, series.samples + 1
    local level = series.spec and job.level and LEVELS[job.level(series.spec, value)] or 0
    if level > 0 then
        local slot = store:bucketOf(at, 0) + 1
        local levels = series.result.levels
        levels[slot] = math.max(levels[slot] or 0, level)
        series.worst = math.max(series.worst, level)
    end
end

local function complete(series)
    local result = series.result
    local columns = result.columns
    local statistic = result.config.statistic
    if series.samples > 0 then
        if statistic == "min" then
            result.value = columns.minimum
        elseif statistic == "max" then
            result.value = columns.maximum
        elseif statistic == "avg" then
            result.value = series.time > 0 and series.area / series.time or series.sum / series.samples
        else
            result.value = series.lastValue - series.first
        end
    end
    result.level = NAMES[series.worst]
end

local function interpolate(fromAt, fromValue, toAt, toValue, at)
    return fromValue + (toValue - fromValue) * (at - fromAt) / (toAt - fromAt)
end

--- One unit of capture work: one knot read or one column sample.
--- Returns true when the series is done.
local function work(self, job, series)
    local store = series.result.columns
    local target = series.target
    if target then
        -- A straight segment gets a sample at the start of each column it
        -- crosses, so every column shows the line as a chart would.
        local column = series.column
        local at = (column * job.window + store.pixels - 1) // store.pixels
        if column < store.width and at < target then
            sample(job, series, at, interpolate(series.lastAt, series.lastValue, target, series.targetValue, at), true)
            series.column = column + 1
            return false
        end
        sample(job, series, target, series.targetValue, true)
        series.target = nil
        return series.ended == true
    end
    local index = series.index
    local at, value, broken = nil, nil, nil
    if index then
        at, value, broken = self.history:point(series.feed, index)
    end
    if at == nil then
        return true
    end
    series.index = index + 1
    local previousAt, previousValue = series.knotAt, series.knotValue
    series.knotAt, series.knotValue = at, value
    if at < job.start then
        return false
    end
    local connected = not broken and previousAt ~= nil
    if at > job.finish and not connected then
        return true
    end
    if connected and previousAt < job.start then
        sample(job, series, 0, interpolate(previousAt, previousValue, at, value, job.start), false)
    end
    local finish = math.min(at, job.finish)
    if finish < at then
        value = interpolate(previousAt, previousValue, at, value, finish)
    end
    at = (finish - job.start) // job.scale
    if connected then
        series.target, series.targetValue = at, value
        series.column = store:bucketOf(series.lastAt, 0) + 1
    else
        sample(job, series, at, value, false)
    end
    series.ended = finish == job.finish
    return series.ended and not connected
end

local function capture(self, slots)
    local job = self.job
    local units = slots * debrief.UNITS_PER_SLOT
    local used = 0
    local series = job.series or nextSeries(self, job)
    while series and used < units do
        used = used + 1
        if work(self, job, series) then
            complete(series)
            series = nextSeries(self, job)
        end
    end
    if not series then
        self.job = nil
        self.latest = { duration = job.finish - job.start, tiles = job.tiles }
    end
    return math.max(1, (used + debrief.UNITS_PER_SLOT - 1) // debrief.UNITS_PER_SLOT), self.job ~= nil
end

function debrief:update(now, slots)
    local history, session = self.history, self.session
    if not session or history ~= self.runtime.byId.history then
        return 1
    end
    local job = self.job
    if job and job.index > session.flightLast then
        self.job, job = nil, nil
    end
    if session.flightLast < self.handled then
        self.handled = session.flightLast
    end
    if not job then
        local index = self.handled + 1
        if index > session.flightLast then
            return 1
        end
        local start, finish = history:flight(session, index)
        if start and not finish then
            return 1
        end
        self.handled = index
        if not start or finish <= start then
            return 1, true
        end
        begin(self, index, start, finish)
    end
    self.due = now
    return capture(self, slots)
end

return debrief
