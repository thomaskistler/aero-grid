-- SPDX-License-Identifier: GPL-2.0-only

local columns = { RUNTIME_API = 1, BREAK_WIDTH = 24 }
columns.__index = columns
local consumer = {}
consumer.__index = consumer
local fields = { "low", "high", "ends", "widths", "froms", "kinds", "gaps", "tags", "cutoffs" }

function columns.new(width, window, recording)
    assert(type(width) == "number" and width >= 1 and width % 1 == 0, "columns require an integer width")
    assert(window == nil or type(window) == "number" and window > 0, "invalid column window")
    local self = setmetatable({ width = width, window = window or 6000, recording = recording }, columns)
    self:reset()
    return self
end

function columns:reset()
    for _, field in ipairs(fields) do
        self[field] = {}
    end
    self.seams, self.breaks = {}, {}
    self.breakFirst, self.breakLast = 1, 0
    self.at, self.bucket, self.value, self.missing = nil, nil, nil, nil
    self.gapAt, self.gapRevision = nil, nil
    self.revision = (self.revision or 0) + 1
    self.historyRevision = nil
end

function columns:gapCount(at, before)
    if not self.recording then
        return 0
    end
    local session = self.recording.session
    before = before == true
    if self.gapAt == at and self.gapBefore == before and self.gapRevision == session.resumeRevision then
        return self.gapValue
    end
    local low, high = session.resumeFirst or 1, session.resumeLast or 0
    while low <= high do
        local middle = (low + high) // 2
        local stamp = self.recording.history:recordingBreak(session, middle)
        assert(stamp ~= nil, "recording seam unavailable")
        if stamp < at or stamp == at and not before then
            low = middle + 1
        else
            high = middle - 1
        end
    end
    self.gapAt, self.gapBefore, self.gapRevision, self.gapValue = at, before, session.resumeRevision, high
    return high
end

function columns:pixel(at, before)
    return at * self.width / self.window + self:gapCount(at, before) * columns.BREAK_WIDTH
end

function columns:seamConnectors()
    return self.seams
end

function columns:breakAt(at)
    if self:pixel(at) >= self.width then
        return
    end
    self.breakLast = self.breakLast + 1
    self.breaks[self.breakLast] = at
end

local function append(self, at, bucket, value, broken, resumed)
    if bucket < 0 or bucket >= self.width then
        return
    end
    local slot, tag = bucket + 1, bucket + 1
    local previous = self.tags[slot]
    local interrupted = broken or resumed or self.missing
    local width = self.bucket and math.max(0, bucket - self.bucket)
        or (value == nil or self.missing) and math.max(0, bucket)
        or 0
    local gap = resumed
            and {
                kind = "break",
                min = value,
                max = value,
                ["end"] = value,
                width = columns.BREAK_WIDTH,
            }
        or interrupted and (self.bucket or self.missing) and { kind = "missing", width = width }
        or nil
    if resumed and not self.missing and value ~= nil and self.bucket and self.value ~= nil then
        self.seams[#self.seams + 1] = { self.bucket, self.value, bucket, value }
    end
    local same = previous == tag or previous == -tag
    if value == nil then
        if not same or previous == -tag then
            self.low[slot], self.high[slot], self.ends[slot] = nil, nil, nil
            self.tags[slot], self.kinds[slot], self.widths[slot] = -tag, "missing", width
            self.froms[slot], self.cutoffs[slot] = nil, nil
        end
        self.gaps[slot] = gap
    elseif same and previous == tag and not interrupted then
        if self.kinds[slot] == "break" then
            self.kinds[slot], self.widths[slot] = "data", 0
        end
        self.low[slot], self.high[slot] = math.min(self.low[slot], value), math.max(self.high[slot], value)
        self.ends[slot] = value
    else
        self.low[slot], self.high[slot], self.ends[slot] = value, value, value
        self.tags[slot], self.kinds[slot] = tag, resumed and "break" or "data"
        self.widths[slot] = resumed and columns.BREAK_WIDTH or width
        self.froms[slot] = not interrupted and self.value or nil
        self.gaps[slot], self.cutoffs[slot] = gap, interrupted and at or nil
    end
    self.missing = value == nil
    if value ~= nil then
        self.bucket, self.value = bucket, value
    end
end

function columns:sample(at, value, broken, resumed)
    assert(type(at) == "number" and at >= 0 and at % 1 == 0, "invalid column timestamp")
    assert(not self.at or at >= self.at, "column time moved backwards; reset required")
    assert(
        value == nil or type(value) == "number" and value == value and math.abs(value) < math.huge,
        "invalid reading"
    )
    append(self, at, self:pixel(at) // 1, value, broken, resumed)
    self.at, self.revision = at, self.revision + 1
end

function columns:summary(bucket)
    local slot = bucket + 1
    if not self.tags[slot] then
        return nil
    end
    return {
        kind = self.kinds[slot],
        min = self.low[slot],
        max = self.high[slot],
        ["end"] = self.ends[slot],
        width = self.widths[slot],
        from = self.froms[slot],
        gap = self.gaps[slot],
    }
end

local function rebuilding(self)
    local feed = self.feed
    local first, last = feed.first or 1, feed.last or 0
    local at, value, broken, resumed
    if last >= first then
        at, value, broken, resumed = self.history:point(feed, last)
        assert(at ~= nil, "history tail unavailable while rebuilding columns")
    end
    local snapshot = self.map
    snapshot.at = at
    self.rebuildJob = {
        map = snapshot,
        index = first,
        last = last,
        revision = feed.plotRevision,
        tailAt = at,
        tailValue = value,
        tailBroken = broken,
        tailResumed = resumed,
    }
    if not self.readonly then
        self.map = columns.new(snapshot.width, self.window, snapshot.recording)
        self.map.at, self.map.value = at, value
        self.map.bucket = at and snapshot:pixel(at, not resumed) // 1
    end
end

local function rebuildStep(self, work, allowance)
    local used = 0
    while work.index <= work.last and allowance - used >= 700 do
        local at, value, broken, resumed
        if work.index == work.last then
            at, value, broken, resumed = work.tailAt, work.tailValue, work.tailBroken, work.tailResumed
        else
            at, value, broken, resumed = self.history:point(self.feed, work.index)
        end
        assert(at ~= nil and type(value) == "number", "recorded knot unavailable while rebuilding columns")
        local afterResume = resumed or work.previousAt == at and work.afterResume
        local bucket = work.map:pixel(at, not afterResume) // 1
        append(work.map, at, bucket, value, broken, resumed)
        if broken and not resumed and work.previousAt then
            work.map:breakAt(at)
        end
        work.previousAt, work.afterResume = at, afterResume
        work.index, used = work.index + 1, used + 700
        if bucket >= work.map.width then
            work.index = work.last + 1
        end
    end
    return work.index > work.last, used
end

-- Merge a frozen historical prefix into the separately collected live tail.
local function mergeStep(work, target, allowance)
    local used, source = 0, work.source
    while work.slot <= target.width and allowance - used >= 500 do
        local slot = work.slot
        local a, b = source.tags[slot], target.tags[slot]
        if a and (not b or a == -b and a > 0) then
            local gap = b and a == -b and target.gaps[slot]
            for _, field in ipairs(fields) do
                target[field][slot] = source[field][slot]
            end
            target.gaps[slot] = gap or target.gaps[slot]
        elseif a and a == b and a > 0 and not target.cutoffs[slot] then
            target.low[slot], target.high[slot] =
                math.min(source.low[slot], target.low[slot]), math.max(source.high[slot], target.high[slot])
            target.froms[slot] = source.froms[slot]
            target.widths[slot] = source.kinds[slot] == "break" and 0 or source.widths[slot]
            target.gaps[slot], target.cutoffs[slot] = source.gaps[slot], source.cutoffs[slot]
        end
        work.slot, used = slot + 1, used + 500
    end
    if work.slot <= target.width then
        return false, used
    end
    work.seam = work.seam or #source.seams
    while work.seam > 0 and allowance - used >= 200 do
        table.insert(target.seams, 1, source.seams[work.seam])
        work.seam, used = work.seam - 1, used + 200
    end
    work.boundary = work.boundary or source.breakLast
    while work.seam == 0 and work.boundary > 0 and allowance - used >= 200 do
        table.insert(target.breaks, 1, source.breaks[work.boundary])
        target.breakLast = target.breakLast + 1
        work.boundary, used = work.boundary - 1, used + 200
    end
    if work.seam > 0 or work.boundary > 0 then
        return false, used
    end
    target.revision = target.revision + 1
    target.historyRevision = math.max(target.historyRevision or 0, source.historyRevision or 0)
    return true, used
end

function columns.attach(history, feed, width, options)
    options = options or {}
    local self = setmetatable({
        history = history,
        feed = feed,
        window = options.window or 6000,
        startedAt = 0,
        readonly = options.preview == true or not history.observeSamples,
        map = columns.new(width, options.window, options.recording),
        complete = (feed.count or math.max(0, (feed.last or 0) - (feed.first or 1) + 1)) == 0,
    }, consumer)
    self.hadValue = not self.complete
    if not self.complete then
        rebuilding(self)
    end
    if not self.readonly then
        history:observeSamples(feed, self)
    end
    return self
end

function consumer:sample(at, value, broken, resumed)
    self.map:sample(at, value, broken, resumed)
    self.map.historyRevision = self.feed.plotRevision
    if broken and not resumed and value ~= nil and self.hadValue then
        self.map:breakAt(at)
    end
    self.hadValue = self.hadValue or value ~= nil
end

function consumer:step(allowance)
    allowance = allowance or 6000
    local used = 0
    if self.rebuildJob then
        local complete
        complete, used = rebuildStep(self, self.rebuildJob, allowance)
        if not complete then
            return false, used
        end
        local work = self.rebuildJob
        self.builtRevision, work.map.historyRevision = work.revision, work.revision
        if not self.readonly then
            self.mergeJob = { source = work.map, slot = 1 }
        end
        self.rebuildJob = nil
    end
    if self.mergeJob then
        local complete, cost = mergeStep(self.mergeJob, self.map, allowance - used)
        used = used + cost
        if not complete then
            return false, used
        end
        self.mergeJob = nil
    end
    self.complete = true
    return true, used
end

function consumer:reset()
    self.map:reset()
    self.complete, self.hadValue, self.builtRevision = true, false, nil
    self.rebuildJob, self.mergeJob = nil, nil
end

function consumer:restart(width)
    self.map = columns.new(width, self.window, self.map.recording)
    self.complete, self.mergeJob = false, nil
    rebuilding(self)
end

function consumer:destroy()
    if self.history and not self.readonly then
        self.history:unobserveSamples(self.feed, self)
    end
    self.history, self.feed, self.map, self.rebuildJob, self.mergeJob = nil, nil, nil, nil, nil
end

return columns
