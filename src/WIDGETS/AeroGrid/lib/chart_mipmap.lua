-- SPDX-License-Identifier: GPL-2.0-only

local mipmap = { RUNTIME_API = 1, LAST_LEVEL = 10 }
mipmap.__index = mipmap
local consumer = {}
consumer.__index = consumer
local huge = math.huge

function mipmap.new(width, window)
    assert(type(width) == "number" and width >= 1 and width % 1 == 0, "mipmap requires an integer column count")
    assert(window == nil or type(window) == "number" and window > 0, "invalid mipmap window")
    local self = setmetatable({ width = width, window = window, lastLevel = window and 0 or mipmap.LAST_LEVEL }, mipmap)
    self:reset()
    return self
end

function mipmap:reset()
    self.levels = {}
    self.breaks, self.breakFirst, self.breakLast, self.historyRevision = {}, 1, 0, nil
    for level = 0, self.lastLevel do
        self.levels[level] = { span = self.window or (6000 * (4 / 3) ^ level), low = {}, high = {}, tags = {} }
    end
    self.level, self.at = 0, nil
    self.revision = (self.revision or 0) + 1
end

function mipmap:breakAt(at)
    self.breakLast = self.breakLast + 1
    self.breakFirst = math.max(1, self.breakLast - self.width + 1)
    self.breaks[(self.breakLast - 1) % self.width + 1] = at
end

--- Each event touches one column per retained level, regardless of elapsed time.
--- A nil value marks missing telemetry. Never interpolate unsampled columns.
function mipmap:sample(at, value, broken)
    assert(type(at) == "number" and at >= 0 and at % 1 == 0, "invalid mipmap timestamp")
    assert(not self.at or at >= self.at, "mipmap time moved backwards; reset required")
    assert(
        value == nil or type(value) == "number" and value == value and value ~= huge and value ~= -huge,
        "invalid mipmap reading"
    )
    local width = self.width
    local position = at * width
    for index = self.level, self.lastLevel do
        local level = self.levels[index]
        local bucket = (position / level.span) // 1
        local slot, tag = bucket % width + 1, bucket + 1
        local lows, highs, tags = level.low, level.high, level.tags
        local previous = tags[slot]
        if previous ~= tag and previous ~= -tag then
            lows[slot], highs[slot] = value, value
            tags[slot] = value == nil and -tag or tag
        elseif value == nil or broken or previous == -tag then
            local endpoint = value or highs[slot]
            lows[slot], highs[slot], tags[slot] = endpoint, endpoint, -tag
        else
            if value < lows[slot] then
                lows[slot] = value
            end
            if value > highs[slot] then
                highs[slot] = value
            end
        end
    end
    self.at, self.revision = at, self.revision + 1
end

--- Selection only: no summary writes, raw-history reads or rebucketing.
function mipmap:select(at)
    if self.snapshotLevel then
        return self.snapshotLevel, self.snapshotOrigin
    end
    local level = self.level
    while level < self.lastLevel and at >= self.levels[level].span do
        level = level + 1
    end
    local selected, origin = self.levels[level], 0
    if not self.pinned and level == self.lastLevel and at >= selected.span then
        local quarter = selected.span / 4
        origin = ((((at - selected.span) / quarter) // 1 + 1) * self.width / 4) // 1
    end
    return level, origin
end

--- Chart-local summaries: call only after publishing the replacement view.
function mipmap:releaseBelow(level)
    assert(
        type(level) == "number" and level % 1 == 0 and level >= self.level and level <= self.lastLevel,
        "invalid mipmap retirement"
    )
    for index = self.level, level - 1 do
        self.levels[index] = nil
    end
    self.level = level
end

function mipmap:column(levelIndex, bucket)
    local level, width = assert(self.levels[levelIndex], "mipmap level was retired"), self.width
    local slot = bucket % width + 1
    local tag = level.tags[slot]
    if tag == bucket + 1 or tag == -(bucket + 1) then
        return level.low[slot], level.high[slot], tag < 0
    end
    return nil, nil, true
end

local function merge(map, levelIndex, bucket, low, high, broken)
    local level = map.levels[levelIndex]
    local slot, tag = bucket % map.width + 1, bucket + 1
    local previous = level.tags[slot]
    if previous and math.abs(previous) > tag then
        return
    end
    if previous ~= tag and previous ~= -tag then
        level.low[slot], level.high[slot] = low, high
        level.tags[slot] = broken and -tag or tag
    elseif previous == -tag or broken then
        level.tags[slot] = -tag
    else
        level.low[slot] = math.min(level.low[slot], low)
        level.high[slot] = math.max(level.high[slot], high)
    end
end

local function position(job, at, before, level)
    if job.axis then
        local axis, count = job.axis, 0
        for _, stamp in ipairs(axis.breaks) do
            if stamp < at or stamp == at and not before then
                count = count + 1
            end
        end
        return (at - axis.start) * axis.scale + count * axis.gap
    end
    return at * job.map.width / job.map.levels[level].span
end

local function rebuild(history, feed, map, axis)
    local first, last = feed.first or 1, feed.last or 0
    local at, value, broken, resumed
    if last >= first then
        at, value, broken, resumed = history:point(feed, last)
        assert(at ~= nil, "history tail unavailable while rebuilding mipmap")
    end
    map.at = at
    if at then
        local level, origin = map:select(map.pinned and 0 or at)
        map:releaseBelow(level)
        if map.rebuildOnly then
            map.snapshotLevel, map.snapshotOrigin = level, origin
        end
    end
    if map.rebuildOnly then
        for level = map.level + 1, map.lastLevel do
            map.levels[level] = nil
        end
        map.lastLevel = map.level
    end
    map.connectors = {}
    return {
        history = history,
        feed = feed,
        map = map,
        axis = axis,
        first = first,
        index = first,
        last = last,
        revision = feed.plotRevision,
        level = map.level,
        tailAt = at,
        tailValue = value,
        tailBroken = broken,
        tailResumed = resumed,
    }
end

local function rebuildStep(job, quota)
    for _ = 1, quota or 24 do
        if not job.current then
            if job.index > job.last then
                job.level = job.level + 1
                if job.level > job.map.lastLevel or job.last < job.first then
                    job.map.revision = job.map.revision + 1
                    job.map.historyRevision = math.max(job.map.historyRevision or 0, job.revision or 0)
                    return true
                end
                job.index, job.previous = job.first, nil
            end
            local at, value, broken, resumed
            if job.index == job.last then
                at, value, broken, resumed = job.tailAt, job.tailValue, job.tailBroken, job.tailResumed
            else
                at, value, broken, resumed = job.history:point(job.feed, job.index, job.first)
            end
            if at == nil and job.index < job.feed.first then
                -- A live ring may overwrite a snapshot prefix between callbacks.
                -- Resume at retained data without bridging the discarded knots.
                job.first = math.min(job.last, job.feed.first)
                job.index, job.previous = job.first, nil
                if job.index == job.last then
                    at, value, broken, resumed = job.tailAt, job.tailValue, job.tailBroken, job.tailResumed
                else
                    at, value, broken, resumed = job.history:point(job.feed, job.index, job.first)
                end
            end
            assert(at ~= nil and type(value) == "number", "recorded knot unavailable while rebuilding mipmap")
            job.current = { at = at, value = value, broken = broken, resumed = resumed }
            if job.level == job.map.level and job.axis and resumed and job.previous then
                local left, right = position(job, job.previous.at, true, 0), position(job, at, false, 0)
                if left >= 0 and right <= job.map.width then
                    job.map.connectors[#job.map.connectors + 1] = { left, job.previous.value, right, value }
                end
            elseif job.level == job.map.level and broken and not resumed and job.previous then
                job.map:breakAt(at)
            end
        end
        local current, previous, level = job.current, job.previous, job.level
        local right = position(job, current.at, not current.resumed, level)
        local left = previous and not current.broken and position(job, previous.at, false, level) or right
        if not job.bucket then
            local latest = job.axis and job.map.width - 1
                or ((job.map.at or 0) * job.map.width / job.map.levels[level].span) // 1
            job.bucket = math.max(0, latest - job.map.width + 1, left // 1)
            job.finish = math.min(latest, right // 1)
        end
        local bucket = job.bucket
        if bucket <= job.finish then
            local low, high = current.value, current.value
            if previous and not current.broken and right > left then
                local a = math.max(left, bucket)
                local b = math.min(right, bucket + 1)
                local delta = (current.value - previous.value) / (right - left)
                local firstValue = previous.value + (a - left) * delta
                local lastValue = previous.value + (b - left) * delta
                low, high = math.min(firstValue, lastValue), math.max(firstValue, lastValue)
            end
            local gap = current.broken
                and previous
                and not current.resumed
                and position(job, previous.at, false, level) // 1 == bucket
            merge(job.map, level, bucket, low, high, gap)
            job.bucket = bucket + 1
        else
            -- Sealed history blocks entirely inside one column need only their
            -- extrema and endpoint; unsealed or interrupted blocks stay scalar.
            local blockLast, lowIndex, highIndex, interrupted
            if job.history.block and not current.broken and not job.axis then
                local before = (right // 1 + 1) * job.map.levels[level].span / job.map.width
                blockLast, lowIndex, highIndex, interrupted =
                    job.history:block(job.feed, job.index, job.last - 1, before)
            end
            if blockLast and not interrupted and blockLast > job.index then
                local _, low = job.history:point(job.feed, lowIndex, job.first)
                local _, high = job.history:point(job.feed, highIndex, job.first)
                local at, value = job.history:point(job.feed, blockLast, job.first)
                assert(at and low and high, "sealed recorded block unavailable while rebuilding mipmap")
                merge(job.map, level, right // 1, math.min(low, high), math.max(low, high), false)
                current = { at = at, value = value }
                job.index = blockLast
            end
            job.bucket, job.previous, job.current = nil, current, nil
            job.index = job.index + 1
        end
    end
    return false
end

--- Reconstructed envelopes follow stored knots within recording precision.
function mipmap.attach(history, feed, width, options)
    options = options or {}
    local self = setmetatable({
        history = history,
        feed = feed,
        window = options.window,
        readonly = options.preview == true or not history.observeSamples,
        map = mipmap.new(width, options.window),
        startedAt = 0,
        complete = (feed.count or math.max(0, (feed.last or 0) - (feed.first or 1) + 1)) == 0,
    }, consumer)
    self.hadValue = not self.complete
    self.map.rebuildOnly = self.readonly
    if not self.complete then
        self.rebuildJob = rebuild(history, feed, self.map)
    end
    if not self.readonly then
        history:observeSamples(feed, self)
    end
    return self
end

function consumer:sample(at, value, broken)
    self.map:sample(at - self.startedAt, value, broken)
    self.map.historyRevision = self.feed.plotRevision
    if broken and value ~= nil and self.hadValue then
        self.map:breakAt(at)
    end
    self.hadValue = self.hadValue or value ~= nil
end

function consumer:reset()
    self.startedAt, self.complete = 0, true
    self.hadValue = false
    self.rebuildJob, self.output, self.viewJob, self.viewVersion, self.viewRevision = nil, nil, nil, nil, nil
    self.map:reset()
end

function consumer:step(quota)
    if self.rebuildJob then
        if not rebuildStep(self.rebuildJob, quota) then
            return false
        end
        self.complete, self.builtRevision, self.rebuildJob = true, self.rebuildJob.revision, nil
    end

    return true
end

function consumer:prepareView(axis, version)
    if not axis and not self.readonly then
        self.output = nil
        return true
    end
    if
        not axis
        and not self.output
        and not self.viewJob
        and self.builtRevision == self.feed.plotRevision
        and (not self.viewWindow or self.viewWindow == self.map.levels[self.map.level].span)
        and (not self.viewOrigin or self.viewOrigin == (self.map.snapshotOrigin or 0))
    then
        self.output, self.viewVersion, self.viewRevision = self.map, version, self.builtRevision
        return true
    end
    if not self.viewJob and (self.viewVersion ~= version or self.viewRevision ~= self.feed.plotRevision) then
        local map = mipmap.new(self.map.width, axis and axis.window or self.viewWindow or self.window)
        map.pinned = axis ~= nil
        map.rebuildOnly = true
        self.viewJob = rebuild(self.history, self.feed, map, axis)
        if not axis and self.viewOrigin then
            map.snapshotLevel, map.snapshotOrigin = 0, self.viewOrigin
        end
        self.viewJob.version = version
    end
end

function consumer:view(axis, version, quota)
    if not self.viewJob then
        self:prepareView(axis, version)
    end
    if self.viewJob then
        if not rebuildStep(self.viewJob, quota) then
            return false
        end
        self.output, self.viewVersion, self.viewRevision = self.viewJob.map, self.viewJob.version, self.viewJob.revision
        self.viewJob = nil
    end
    return true
end

--- Configuration-time restart affects this presentation, never its recording.
function consumer:restart(width, at)
    assert(self.history, "mipmap consumer was destroyed")
    assert(type(at) == "number" and at >= 0 and at % 1 == 0, "invalid mipmap restart timestamp")
    local map = mipmap.new(width, self.window)
    map.rebuildOnly = self.readonly
    self.map, self.startedAt, self.complete = map, 0, false
    self.output, self.viewJob, self.viewVersion, self.viewRevision = nil, nil, nil, nil
    self.rebuildJob = rebuild(self.history, self.feed, map)
end

function consumer:destroy()
    if self.history then
        if not self.readonly then
            self.history:unobserveSamples(self.feed, self)
        end
        self.history, self.feed, self.map = nil, nil, nil
        self.rebuildJob, self.viewJob, self.output = nil, nil, nil
    end
end

return mipmap
