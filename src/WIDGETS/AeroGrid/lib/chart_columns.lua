-- SPDX-License-Identifier: GPL-2.0-only

local columns = { RUNTIME_API = 1, BREAK_WIDTH = 24 }
columns.__index = columns
local consumer = {}
consumer.__index = consumer
local fields = { "kinds", "low", "high", "ends", "froms", "widths", "starts", "counts" }

--- Auto windows in minutes: 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, ...
function columns.autoMinutes(step)
    if step <= 4 then
        return step
    end
    return (step % 2 == 1 and 3 or 4) << ((step - 3) // 2)
end

--- Fine columns at level k last 2^k minutes divided by the plot width, so every
--- auto window is a whole number (1 to 4) of fine columns per plot column.
function columns.autoLevel(step)
    return step <= 4 and 0 or (step - 3) // 2
end

--- Pause gaps narrow as the auto window grows.
function columns.autoGap(step)
    return math.max(4, columns.BREAK_WIDTH // columns.autoMinutes(step))
end

--- Smallest auto step whose window still has room after `elapsed` ticks.
function columns.autoStep(elapsed)
    local step = 1
    while columns.autoMinutes(step) * 6000 <= (elapsed or 0) + 100 do
        step = step + 1
    end
    return step
end

---@param options? { breakWidth?: integer, pixels?: integer, passive?: boolean }
function columns.new(width, window, recording, options)
    assert(type(width) == "number" and width >= 1 and width % 1 == 0, "columns require an integer width")
    assert(window == nil or type(window) == "number" and window > 0, "invalid column window")
    options = options or {}
    local self = setmetatable({
        width = width,
        window = window or 6000,
        recording = recording,
        pixels = options.pixels or width,
        breakWidth = options.breakWidth or columns.BREAK_WIDTH,
        passive = options.passive == true,
    }, columns)
    self:reset()
    return self
end

--- Off-screen store for auto windows: fine columns at `level`, four plot widths
--- long plus room for pause columns, without native paint tracking.
function columns.fine(width, level, recording)
    local store = columns.new(width * 4 + width // 4 + 8, 6000 << level, recording, {
        breakWidth = 1,
        pixels = width,
        passive = true,
    })
    store.level = level
    return store
end

function columns:reset()
    for _, field in ipairs(fields) do
        self[field] = {}
    end
    self.seams, self.breaks = {}, {}
    self.dirtyColumns, self.dirtyList = {}, {}
    self.breakFirst, self.breakLast = 1, 0
    self.at, self.bucket, self.value, self.missing, self.last = nil, nil, nil, nil, nil
    self.cursor, self.breakSource, self.overflowed = nil, nil, nil
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
    return at * self.pixels / self.window + self:gapCount(at, before) * self.breakWidth
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
    if not self.passive and not self.dirtyColumns[slot] then
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
--- `low == nil` records a missing reading; `start` is the first resumed value.
local function put(self, bucket, low, high, finish, connected, start, gaps)
    if bucket < 0 or bucket >= self.width then
        return
    end
    local slot = bucket + 1
    local kind = self.kinds[slot]
    if low == nil then
        if kind == nil then
            place(self, bucket, "missing", nil, nil, 1)
            self.counts[slot] = gaps
        end
    elseif kind == "data" then
        -- One pixel cannot show an interruption, so the column keeps its incoming value.
        self.low[slot], self.high[slot] = math.min(self.low[slot], low), math.max(self.high[slot], high)
        self.ends[slot] = finish
        mark(self, slot)
    else
        local previous = self.bucket
        local from = connected and not self.missing and self.value or nil
        if start ~= nil then
            local first = math.max(bucket - self.breakWidth, self.last and self.last + 1 or 0)
            if first < bucket then
                place(self, first, "pause", nil, nil, bucket - first)
            end
            -- Narrow auto gaps fit more pauses; keep the fixed-gap connector bound.
            if not self.missing and previous and self.value ~= nil and #self.seams < self.width // 48 then
                self.seams[#self.seams + 1] = { previous, self.value, bucket, start }
            end
        elseif from ~= nil and bucket - previous > 1 then
            place(self, previous + 1, "hold", from, nil, bucket - previous - 1)
        end
        place(self, bucket, "data", low, from, 1)
        self.high[slot], self.ends[slot] = high, finish
        self.starts[slot], self.counts[slot] = start, gaps
    end
    self.last = math.max(self.last or bucket, bucket)
    self.missing = low == nil
    if low ~= nil then
        self.bucket, self.value = bucket, finish
    end
end

function columns:sample(at, value, broken, resumed, gapCount)
    assert(type(at) == "number" and at >= 0 and at % 1 == 0, "invalid column timestamp")
    assert(not self.at or at >= self.at, "column time moved backwards; reset required")
    assert(
        value == nil or type(value) == "number" and value == value and math.abs(value) < math.huge,
        "invalid reading"
    )
    self:record(at, value, broken, resumed, gapCount or self:gapCount(at))
end

--- Sample already validated by `columns:sample` (the fine store mirrors the plot).
function columns:record(at, value, broken, resumed, gaps)
    self.revision = self.revision + 1
    -- Integer division keeps fine and plot columns aligned on float32 radios.
    local bucket = ((math.tointeger(at) or at) * self.pixels) // self.window + gaps * self.breakWidth
    if bucket >= self.width then
        self.overflowed = true
    end
    put(self, bucket, value, value, value, not (broken or resumed), resumed and value or nil, gaps)
    self.at = at
end

--- Merge source columns up to `through` (0-based), `factor` source columns per
--- column. Source columns must be complete; pause and hold columns are rebuilt.
function columns:absorb(source, factor, through, allowance)
    local cursor, used = self.cursor or 0, 0
    while cursor <= through and used < allowance do
        local slot = cursor + 1
        local kind = source.kinds[slot]
        if kind == "data" or kind == "missing" then
            local gaps = source.counts[slot]
            local bucket = (cursor - gaps * source.breakWidth) // factor + gaps * self.breakWidth
            if bucket >= self.width then
                self.overflowed = true
            end
            if kind == "data" then
                put(
                    self,
                    bucket,
                    source.low[slot],
                    source.high[slot],
                    source.ends[slot],
                    source.froms[slot] ~= nil,
                    source.starts[slot],
                    gaps
                )
            else
                put(self, bucket, nil, nil, nil, false, nil, gaps)
            end
            used = used + 100
        else
            used = used + 8
        end
        cursor = cursor + 1
    end
    self.cursor = cursor
    local index = self.breakSource or source.breakFirst
    while index <= source.breakLast do
        self:breakAt(source.breaks[index])
        index, used = index + 1, used + 40
    end
    self.breakSource = index
    if cursor > through then
        self.at = source.at
    end
    return cursor > through, used
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

--- Live column consumer. With `options.auto` it starts at the auto step that
--- fits `options.elapsed` and also records a fine store for later steps.
function columns.attach(history, feed, width, options)
    options = options or {}
    local readonly = options.preview == true or not history.observeSamples
    local self = setmetatable({
        history = history,
        feed = feed,
        width = width,
        window = options.window or 6000,
        breakWidth = options.breakWidth,
        recording = options.recording,
        auto = options.auto == true and not readonly,
        startedAt = 0,
        readonly = readonly,
        resets = 0,
    }, consumer)
    self:restart(options.elapsed)
    if not self.readonly then
        history:observeSamples(feed, self)
    end
    return self
end

function consumer:restart(elapsed)
    if self.auto then
        self.step = columns.autoStep(elapsed)
        self.window, self.breakWidth = columns.autoMinutes(self.step) * 6000, columns.autoGap(self.step)
        self.fine = columns.fine(self.width, columns.autoLevel(self.step), self.recording)
    end
    self.map = columns.new(self.width, self.window, self.recording, { breakWidth = self.breakWidth })
    self.map.historyRevision = self.feed.plotRevision
    self.hadValue, self.tail, self.pending = false, nil, {}
    self.resets = self.resets + 1
end

--- Show a prepared map for the next auto step; live samples continue in it.
function consumer:adopt(map, step)
    map.historyRevision = self.map.historyRevision
    self.map, self.step, self.window, self.breakWidth = map, step, map.window, map.breakWidth
end

function consumer:sample(at, value, broken, resumed)
    local sample = { at, value, broken, resumed, self.feed.plotRevision, self.map:gapCount(at) }
    if not self.auto and self.map:pixel(at) >= self.map.width then
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
    local fine = self.fine
    for index, sample in ipairs(self.pending) do
        local at, value, broken, resumed = sample[1], sample[2], sample[3], sample[4]
        self.map:sample(at, value, broken, resumed, sample[6])
        if fine then
            fine:record(at, value, broken, resumed, sample[6])
        end
        self.map.historyRevision = sample[5]
        if broken and not resumed and value ~= nil and self.hadValue then
            self.map:breakAt(at)
            if fine then
                fine:breakAt(at)
            end
        end
        self.hadValue = self.hadValue or value ~= nil
        self.pending[index] = nil
    end
end

function consumer:reset()
    if self.auto then
        self:restart(0)
    else
        self.map:reset()
        self.hadValue, self.tail, self.pending = false, nil, {}
    end
end

function consumer:resize(width)
    self.width = width
    self:restart(self.recording and self.recording.session and self.recording.session.elapsed)
end

function consumer:destroy()
    if self.history and not self.readonly then
        self.history:unobserveSamples(self.feed, self)
    end
    self.history, self.feed, self.map, self.fine, self.pending, self.tail = nil, nil, nil, nil, nil, nil
end

return columns
