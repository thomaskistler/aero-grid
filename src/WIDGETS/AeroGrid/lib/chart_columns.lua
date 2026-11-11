-- SPDX-License-Identifier: GPL-2.0-only

local columns = { RUNTIME_API = 1, BREAK_WIDTH = 24 }
columns.__index = columns
local consumer = {}
consumer.__index = consumer
local fields = { "low", "high", "ends", "widths", "froms", "kinds", "gaps", "tags" }

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
    self.dirtyColumns, self.dirtyList = {}, {}
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

local function append(self, bucket, value, broken, resumed)
    if bucket < 0 or bucket >= self.width then
        return
    end
    local slot, tag = bucket + 1, bucket + 1
    if not self.dirtyColumns[slot] then
        self.dirtyList[#self.dirtyList + 1] = slot
    end
    self.dirtyColumns[slot] = true
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
            self.froms[slot] = nil
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
        self.gaps[slot] = gap
    end
    self.missing = value == nil
    if value ~= nil then
        self.bucket, self.value = bucket, value
    end
end

function columns:sample(at, value, broken, resumed, gapCount)
    assert(type(at) == "number" and at >= 0 and at % 1 == 0, "invalid column timestamp")
    assert(not self.at or at >= self.at, "column time moved backwards; reset required")
    assert(
        value == nil or type(value) == "number" and value == value and math.abs(value) < math.huge,
        "invalid reading"
    )
    self.revision = self.revision + 1
    local pixel = gapCount and at * self.width / self.window + gapCount * columns.BREAK_WIDTH or self:pixel(at)
    append(self, pixel // 1, value, broken, resumed)
    self.at = at
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

function columns.attach(history, feed, width, options)
    options = options or {}
    local self = setmetatable({
        history = history,
        feed = feed,
        window = options.window or 6000,
        startedAt = 0,
        readonly = options.preview == true or not history.observeSamples,
        map = columns.new(width, options.window, options.recording),
        pending = {},
    }, consumer)
    self.map.historyRevision = feed.plotRevision
    if not self.readonly then
        history:observeSamples(feed, self)
    end
    return self
end

function consumer:sample(at, value, broken, resumed)
    local sample = { at, value, broken, resumed, self.feed.plotRevision, self.map:gapCount(at) }
    if self.map:pixel(at) >= self.map.width then
        self.tail = sample
    else
        self.pending[#self.pending + 1] = sample
    end
end

function consumer:append()
    if self.readonly then
        self.map.historyRevision = self.feed.plotRevision
    end
    if self.tail then
        self.pending[#self.pending + 1], self.tail = self.tail, nil
    end
    for index, sample in ipairs(self.pending) do
        local at, value, broken, resumed = sample[1], sample[2], sample[3], sample[4]
        self.map:sample(at, value, broken, resumed, sample[6])
        self.map.historyRevision = sample[5]
        if broken and not resumed and value ~= nil and self.hadValue then
            self.map:breakAt(at)
        end
        self.hadValue = self.hadValue or value ~= nil
        self.pending[index] = nil
    end
end

function consumer:reset()
    self.map:reset()
    self.hadValue, self.tail, self.pending = false, nil, {}
end

function consumer:resize(width)
    self.map = columns.new(width, self.window, self.map.recording)
    self.map.historyRevision = self.feed.plotRevision
    self.hadValue, self.tail, self.pending = false, nil, {}
end

function consumer:destroy()
    if self.history and not self.readonly then
        self.history:unobserveSamples(self.feed, self)
    end
    self.history, self.feed, self.map, self.pending, self.tail = nil, nil, nil, nil, nil
end

return columns
