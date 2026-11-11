-- SPDX-License-Identifier: GPL-2.0-only

local columns = { RUNTIME_API = 1, BREAK_WIDTH = 24 }
columns.__index = columns
local consumer = {}
consumer.__index = consumer
local fields = { "kinds", "low", "high", "ends", "froms", "widths" }

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
    self.at, self.bucket, self.value, self.missing, self.last = nil, nil, nil, nil, nil
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

local function mark(self, slot)
    if not self.dirtyColumns[slot] then
        self.dirtyColumns[slot] = true
        self.dirtyList[#self.dirtyList + 1] = slot
    end
end

local function place(self, bucket, kind, value, from, width)
    local slot = bucket + 1
    self.kinds[slot], self.low[slot], self.high[slot], self.ends[slot] = kind, value, value, value
    self.froms[slot], self.widths[slot] = from, width
    mark(self, slot)
end

--- Every touched pixel column has one kind: "data" (min, max, end and the
--- incoming value it connects from), "hold" (the previous value carried across
--- skipped columns), "missing" or "pause" (a gap before resumed data).
local function append(self, bucket, value, broken, resumed)
    if bucket < 0 or bucket >= self.width then
        return
    end
    local slot = bucket + 1
    local kind = self.kinds[slot]
    if value == nil then
        if kind == nil then
            place(self, bucket, "missing", nil, nil, 1)
        end
    elseif kind == "data" then
        -- One pixel cannot show an interruption, so the column keeps its incoming value.
        self.low[slot], self.high[slot] = math.min(self.low[slot], value), math.max(self.high[slot], value)
        self.ends[slot] = value
        mark(self, slot)
    else
        local previous = self.bucket
        local from = not (broken or resumed or self.missing) and self.value or nil
        if resumed then
            local first = math.max(bucket - columns.BREAK_WIDTH, self.last and self.last + 1 or 0)
            if first < bucket then
                place(self, first, "pause", nil, nil, bucket - first)
            end
            if not self.missing and previous and self.value ~= nil then
                self.seams[#self.seams + 1] = { previous, self.value, bucket, value }
            end
        elseif from ~= nil and bucket - previous > 1 then
            place(self, previous + 1, "hold", from, nil, bucket - previous - 1)
        end
        place(self, bucket, "data", value, from, 1)
    end
    self.last = math.max(self.last or bucket, bucket)
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
    append(self, math.floor(pixel), value, broken, resumed)
    self.at = at
end

function columns:summary(bucket)
    local slot = bucket + 1
    local kind = self.kinds[slot]
    if not kind then
        return nil
    end
    return {
        kind = kind,
        min = self.low[slot],
        max = self.high[slot],
        ["end"] = self.ends[slot],
        width = self.widths[slot],
        from = self.froms[slot],
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
