-- SPDX-License-Identifier: GPL-2.0-only

--- Records the layout's post-flight debrief: at each flight end, the flight
--- slice of every debrief series is copied from the history into chart pixel
--- columns, with its statistic, worst threshold level and per-column levels.
--- Only the latest debrief is kept, in memory, until the model is armed with
--- no flight in progress.
local debrief = { UNITS_PER_SLOT = 1 }
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

--- The newest flight started before recording time `at`, and whether it was
--- still in progress then.
local function before(history, session, at)
    for index = session.flightLast, session.flightFirst, -1 do
        local start, finish = history:flight(session, index)
        if start and start < at then
            return index, not finish or finish >= at
        end
    end
    return session.flightFirst - 1, false
end

--- Subscribe the debrief series, at layout load and after every Save or
--- Armed rebind, so the history records them before the flight starts.
---@param section? table Validated debrief section of the layout.
---@param widths integer[] Plot width in pixels of each tile.
function debrief:configure(section, widths)
    local history = self.runtime.byId.history
    local job = self.job
    local resume = job and job.history == history and job.index
    local attached = history == self.history and self.session
    self.job, self.tiles, self.widths, self.feeds = nil, {}, widths, {}
    self.history, self.session, self.count = history, nil, 0
    if not history or not section then
        return
    end
    for index, tile in ipairs(section.tiles) do
        local feeds = {}
        for position, series in ipairs(tile.series) do
            feeds[position] = history:subscribe(series.source)
        end
        self.tiles[index], self.feeds[index] = tile, feeds
        self.count = self.count + #feeds
    end
    if self.count > 0 then
        self.support.subscribed(self)
        local session = history:session()
        -- Flights that ended before the series were recorded are skipped; a
        -- Save keeps the cursor, so a finished flight is still captured.
        if session ~= attached then
            self.handled, self.armSeen = settled(history, session), nil
        end
        self.session = session
        -- A capture a Save interrupted starts over with the saved debrief.
        if resume then
            self.handled = math.min(self.handled, resume - 1)
        end
    end
end

--- The latest debrief, or nil before the first recorded flight.
function debrief:result()
    return self.latest
end

function debrief:resetSession()
    self.latest, self.job, self.armSeen = nil, nil, nil
    -- Flights the history has not reset yet are never captured.
    self.handled = self.session and settled(self.history, self.session) or 0
end

--- Days since 1970-01-01 of a civil date, in int32-safe steps.
local function daysFromCivil(year, month, day)
    year = month <= 2 and year - 1 or year
    local era = (year >= 0 and year or year - 399) // 400
    local yoe = year - era * 400
    local doy = (153 * (month + (month > 2 and -3 or 9)) + 2) // 5 + day - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

local function civilFromDays(days)
    days = days + 719468
    local era = (days >= 0 and days or days - 146096) // 146097
    local doe = days - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local month = mp < 10 and mp + 3 or mp - 9
    local year = yoe + era * 400 + (month <= 2 and 1 or 0)
    return year, month, doy - (153 * mp + 2) // 5 + 1
end

--- The clock reading `age` seconds before `now`, a getDateTime() table.
---@return table? date year, mon, day, hour, min; nil without a clock.
function debrief.dateBefore(now, age)
    if type(now) ~= "table" or type(now.year) ~= "number" then
        return nil
    end
    local seconds = (now.hour or 0) * 3600 + (now.min or 0) * 60 + (now.sec or 0) - math.max(0, age // 1)
    local days = daysFromCivil(now.year, now.mon or 1, now.day or 1) + seconds // 86400
    seconds = seconds % 86400
    local year, month, day = civilFromDays(days)
    return { year = year, mon = month, day = day, hour = seconds // 3600, min = seconds % 3600 // 60 }
end

--- Flight number, model name and start date for the debrief header. The date
--- counts back from the radio clock by the service-clock time since the
--- flight's start, which keeps running while recording pauses.
local function header(self, now, startedAt)
    local env, flight = self.env, self.runtime.byId.flight
    local state = flight and flight.state and flight:state()
    local info = env.getInfo and env.getInfo()
    local date = env.getDateTime and env.getDateTime()
    return {
        flight = state and state.countAvailable and state.displayCount or nil,
        model = type(info) == "table" and info.name or nil,
        started = startedAt and debrief.dateBefore(date, math.max(0, now - startedAt) // 100) or nil,
    }
end

local function begin(self, index, start, finish, now, startedAt)
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
        header = header(self, now, startedAt),
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
            local spec = job.thresholds[config.source]
            local result = {
                config = config,
                unit = feed.unitText,
                -- Readings are shown as the sensor reports them; an average falls between.
                precision = config.statistic ~= "avg" and feed.precision or nil,
                -- A copy, so later threshold edits cannot restyle this debrief.
                thresholds = spec and {
                    warning = spec.warning,
                    critical = spec.critical,
                    falling = spec.falling,
                    strict = spec.strict,
                },
                level = "normal",
                columns = self.runtime.chartColumns.new(self.widths[job.tile], job.window, nil, { passive = true }),
                levels = {},
            }
            local tiles = job.tiles
            tiles[job.tile] = tiles[job.tile] or { config = tile, series = {} }
            tiles[job.tile].series[position] = result
            job.position = position
            -- The walk starts at the last knot at or before the flight start,
            -- found by a binary search over `low..high`.
            job.series = {
                feed = feed,
                result = result,
                statistic = config.statistic,
                spec = job.thresholds[config.source],
                low = feed.first,
                high = feed.count > 0 and feed.last or nil,
                worst = 0,
                time = 0,
                samples = 0,
            }
            return job.series
        end
        job.tile, job.position = job.tile + 1, 0
        tile = self.tiles[job.tile]
    end
end

--- Fold the value `value` held from flight time `at` into the statistic.
--- Means are updated in place, so no running sum can overflow.
local function accumulate(series, at, value, connected)
    local statistic, current = series.statistic, series.value
    series.samples = series.samples + 1
    series.reported = series.reported or value ~= 0
    if statistic == "min" then
        series.value = current and math.min(current, value) or value
    elseif statistic == "max" then
        series.value = current and math.max(current, value) or value
    elseif statistic == "avg" then
        if connected then
            -- Time-weighted: the previous value counts for how long it held.
            local span = at - series.knotTime
            series.time = series.time + span
            if span > 0 then
                series.mean = series.mean + (series.knotMean - series.mean) * (span / series.time)
            end
        end
        if series.time == 0 then
            -- Until the first segment, the plain mean of the samples.
            local mean = series.mean or 0.0
            series.mean = mean + (value - mean) / series.samples
        end
        series.knotMean = value
    else
        series.first = series.first or value
        series.value = value * 1.0 - series.first
    end
    series.knotTime = at
end

local function levelOf(job, spec, value)
    return spec and job.level and LEVELS[job.level(spec, value)] or 0
end

--- Add one sample at flight time `at` (scaled ticks) to the pixel columns.
local function sample(job, series, at, value, connected)
    local store = series.result.columns
    local spec, levels = series.spec, series.result.levels
    local last = series.lastAt
    store:sample(at, value, not connected, false, 0)
    if not connected and last then
        store:breakAt(at)
    end
    -- A level holds with its value, so a held value shades every column up to
    -- the next entry, not only the column where it began.
    local from = connected and last and series.lastLevel or 0
    if from > 0 then
        for slot = store:bucketOf(last, 0) + 2, store:bucketOf(at, 0) do
            levels[slot] = math.max(levels[slot] or 0, from)
        end
    end
    local level = levelOf(job, spec, value)
    series.lastAt, series.lastValue, series.lastLevel = at, value, level
    if level > 0 then
        local slot = store:bucketOf(at, 0) + 1
        levels[slot] = math.max(levels[slot] or 0, level)
        series.worst = math.max(series.worst, level)
    end
end

local function complete(series)
    local result = series.result
    if series.statistic == "avg" then
        result.value = series.mean
    else
        result.value = series.value
    end
    result.level = NAMES[series.worst]
    -- All zeros at a normal level is a sensor the aircraft does not have; a
    -- zero that reached a threshold is a reading worth showing.
    result.empty = not series.reported and series.worst == 0
end

--- Drop series that never reported anything but a normal zero, and tiles left
--- without a series: a sensor the aircraft does not have shows no chart.
local function reported(tiles)
    local shown = {}
    for _, tile in ipairs(tiles) do
        local series = {}
        for _, result in ipairs(tile.series) do
            if not result.empty then
                series[#series + 1] = result
            end
        end
        if #series > 0 then
            tile.series = series
            shown[#shown + 1] = tile
        end
    end
    return shown
end

--- One unit of capture work: one search step, one knot read or one column
--- sample. Returns true when the series is done.
local function work(self, job, series)
    local high = series.high
    if high then
        local low = series.low
        if low < high then
            local middle = (low + high + 1) // 2
            local at = self.history:point(series.feed, middle)
            if at and at > job.start then
                series.high = middle - 1
            else
                series.low = middle
            end
            return false
        end
        series.index, series.high = low, nil
        return false
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
    -- A value holds until the next entry, so the one before the flight began
    -- is the one in force at its start.
    if connected and previousAt < job.start then
        accumulate(series, job.start, previousValue, false)
        sample(job, series, 0, previousValue, false)
    end
    if at > job.finish then
        accumulate(series, job.finish, previousValue, true)
        sample(job, series, (job.finish - job.start) // job.scale, previousValue, true)
        return true
    end
    accumulate(series, at, value, connected)
    sample(job, series, (at - job.start) // job.scale, value, connected)
    return at == job.finish
end

--- Run capture work within the grant; `used` units are already spent.
--- Starting a series is a unit of its own.
local function capture(self, slots, used)
    local job = self.job
    local units = slots * debrief.UNITS_PER_SLOT
    while used < units do
        used = used + 1
        local series = job.series
        if not series then
            if not nextSeries(self, job) then
                self.job = nil
                local header = job.header
                self.latest = {
                    duration = job.finish - job.start,
                    tiles = reported(job.tiles),
                    flight = header.flight,
                    model = header.model,
                    started = header.started,
                }
                break
            end
        elseif work(self, job, series) then
            complete(series)
            job.series = nil
        end
    end
    return math.max(1, (used + debrief.UNITS_PER_SLOT - 1) // debrief.UNITS_PER_SLOT), self.job ~= nil
end

function debrief:update(now, slots)
    local history, session = self.history, self.session
    if not session or history ~= self.runtime.byId.history then
        return 1
    end
    -- Arming with no flight in progress clears the debrief and skips flights
    -- that ended before; re-arming while a flight is ending continues it.
    local seen, arms = self.armSeen, session.armLast
    if seen and arms > seen then
        for index = math.max(seen + 1, session.armFirst), arms do
            local at, value = history:armBoundary(session, index)
            if value then
                local last, flying = before(history, session, at)
                if not flying then
                    self.latest, self.job, self.handled = nil, nil, math.max(self.handled, last)
                end
            end
        end
    end
    self.armSeen = arms
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
        local start, finish, _, _, startedAt = history:flight(session, index)
        if start and not finish then
            return 1
        end
        self.handled = index
        if not start or finish <= start then
            return 1, true
        end
        begin(self, index, start, finish, now, startedAt)
        self.due = now
        return capture(self, slots, 1)
    end
    self.due = now
    return capture(self, slots, 0)
end

return debrief
