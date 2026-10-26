-- SPDX-License-Identifier: GPL-2.0-only

--- Connected, error-bounded recordings of cumulative armed time.
local history = { RUNTIME_API = 1, CAPACITY = 6144 }
history.__index = history

local TAU = { off = 0, light = 50, medium = 100, strong = 200 }
local NUMBER_FORMAT, INTEGER_FORMAT, CHUNK = "<I4n", "<I4j", 64
local SIZES = { 256, 64, 16, 4 }
local BROKEN, INTEGER = 0x80000000, 0x40000000
local BYTES = math.max(string.packsize(NUMBER_FORMAT), string.packsize(INTEGER_FORMAT))
NUMBER_FORMAT = NUMBER_FORMAT .. string.rep("x", BYTES - string.packsize(NUMBER_FORMAT))
INTEGER_FORMAT = INTEGER_FORMAT .. string.rep("x", BYTES - string.packsize(INTEGER_FORMAT))
local ROUNDING = (string.packsize("n") == 4 and 2 ^ -23 or 2 ^ -52) * 32
history.BYTES_PER_POINT = BYTES

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function location(index)
    local slot = (index - 1) % history.CAPACITY
    return math.floor(slot / CHUNK) + 1, slot % CHUNK * BYTES + 1
end

local function read(entry, index)
    local chunk, offset = location(index)
    local stamp = string.unpack("<I4", entry.chunks[chunk], offset)
    local format = stamp & INTEGER ~= 0 and INTEGER_FORMAT or NUMBER_FORMAT
    local _, value = string.unpack(format, entry.chunks[chunk], offset)
    return stamp & 0x3fffffff, value, stamp & BROKEN ~= 0
end

local function publish(entry)
    local state = entry.state
    state.last = entry.last + (entry.lastAt > entry.anchorAt and 1 or 0)
    state.count = state.last - state.first + 1
    state.plotRevision = state.plotRevision + 1
end

local function write(entry, at, value, broken)
    local index = entry.last + 1
    local chunk, offset = location(index)
    -- Preserve native integers too: float32 cannot represent every int32.
    -- Never round a synthesized endpoint again when committing it.
    local integer = math.type(value) == "integer"
    local stamp = (broken and at | BROKEN or at) | (integer and INTEGER or 0)
    local packed = string.pack(integer and INTEGER_FORMAT or NUMBER_FORMAT, stamp, value)
    local previous = entry.chunks[chunk] or ""
    entry.chunks[chunk] = string.sub(previous, 1, offset - 1) .. packed .. string.sub(previous, offset + BYTES)
    entry.last = index
    for level, size in ipairs(SIZES) do
        local relative = (index - 1) % size
        if relative == 0 then
            entry.lows[level], entry.highs[level] = value, value
            entry.bounds[level] = 0
        end
        local bounds = entry.bounds[level]
        if value < entry.lows[level] then
            entry.lows[level], bounds = value, bounds & 0x1ff00 | relative
        end
        if value > entry.highs[level] then
            entry.highs[level], bounds = value, bounds & 0x100ff | relative << 8
        end
        if broken then
            bounds = bounds | 0x10000
        end
        entry.bounds[level] = bounds
        local block = math.floor(((index - 1) % history.CAPACITY) / size) + 1
        entry.blocks[level][block] = bounds
    end
end

local function seal(entry)
    if entry.lastAt > entry.anchorAt then
        write(entry, entry.lastAt, entry.endpoint, false)
        entry.anchorAt, entry.anchor = entry.lastAt, entry.endpoint
    end
    entry.low, entry.high = -math.huge, math.huge
end

local function expire(entry, cutoff, limit)
    local state = entry.state
    for _ = 1, limit do
        if state.first >= entry.last then
            break
        end
        local at = read(entry, state.first + 1)
        if at > cutoff then
            break
        end
        -- Keep the knot immediately before the window for exact edge clipping.
        state.first = state.first + 1
    end
end

function history.new(env, support, runtime)
    local state = { configured = false, available = false, recording = false, elapsed = 0, segment = 0, revision = 0 }
    return setmetatable({
        id = "history",
        revision = 0,
        interval = 5,
        count = 0,
        due = 0,
        env = env,
        support = support,
        runtime = runtime,
        entries = {},
        names = {},
        views = {},
        cursor = 1,
        state = state,
        view = support.snapshot(state),
    }, history)
end

function history:session(armSource)
    if type(armSource) == "string" and armSource ~= "" and not self.armSource then
        self.armSource = armSource
        self.state.configured = true
        local telemetry = self.runtime.byId.telemetry
        self.arm = telemetry and telemetry:subscribe(armSource) or nil
    end
    return self.view
end

function history:advance(now)
    local state = self.state
    if self.lastTime and state.recording then
        state.elapsed = state.elapsed + math.max(0, now - self.lastTime)
    end
    self.lastTime = now
    local arm = self.arm
    local available = arm ~= nil and arm.fresh == true and finite(arm.value)
    local recording = arm ~= nil and available and arm.value > 0 or false
    if state.recording ~= recording or state.available ~= available then
        if recording and not state.recording then
            state.segment = state.segment + 1
        end
        state.recording, state.available = recording, available == true
        state.revision = state.revision + 1
    end
end

function history:subscribe(source, options)
    options = options or {}
    local window = options.windowSeconds or 60
    local mode = options.timeRange or "growing"
    local smoothing, precision = options.smoothing or "off", options.precision
    assert(finite(window) and window >= 30 and window <= 600, "history window must be 30 to 600 seconds")
    assert(mode == "growing" or mode == "rolling", "invalid history time range")
    assert(TAU[smoothing], "invalid history smoothing")
    assert(
        precision == nil or finite(precision) and precision >= 0 and precision <= 3 and precision % 1 == 0,
        "invalid history precision"
    )
    if mode == "growing" then
        window = 60
    end
    source = type(source) == "string" and source or ""
    local key = source .. "\0" .. mode .. "\0" .. window .. "\0" .. smoothing .. "\0" .. tostring(precision or "sensor")
    if self.names[key] then
        return self.names[key].view
    end
    local state = {
        name = source,
        available = false,
        stale = false,
        unitText = "",
        precision = 0,
        revision = 0,
        plotRevision = 0,
        count = 0,
        first = 1,
        last = 0,
        full = false,
        window = window * 100,
    }
    local entry = {
        state = state,
        view = self.support.snapshot(state),
        chunks = {},
        blocks = { {}, {}, {}, {} },
        lows = {},
        highs = {},
        bounds = {},
        last = 0,
        anchorAt = 0,
        lastAt = 0,
        mode = mode,
        precision = precision,
        tau = TAU[smoothing],
        gap = true,
    }
    self.entries[#self.entries + 1] = entry
    self.names[key], self.views[entry.view] = entry, entry
    self.sources = self.sources or {}
    local tracks = self.sources[source] or {}
    self.sources[source] = tracks
    tracks[#tracks + 1] = entry
    self.count = self.count + 1
    local telemetry = self.runtime.byId.telemetry
    if telemetry then
        telemetry:subscribe(source)
        if not self.observing then
            telemetry:observe(self)
            self.observing = true
        end
    end
    return entry.view
end

--- Absolute sequence numbers remain stable as a rolling history expires.
function history:point(view, index)
    local entry = self.views[view]
    if not entry or index < entry.state.first or index > entry.state.last then
        return nil
    end
    if index > entry.last then
        return entry.lastAt, entry.endpoint, false
    end
    return read(entry, index)
end

--- Skip sealed blocks only when they fit in one screen column. These summaries
--- accelerate projection; they never replace or recompress the stored knots.
function history:block(view, index, finish, before)
    local entry = self.views[view]
    if not entry or index < entry.state.first then
        return nil
    end
    for level, size in ipairs(SIZES) do
        local last = index + size - 1
        if (index - 1) % size == 0 and last <= entry.last and last <= finish then
            local bounds = entry.blocks[level][math.floor(((index - 1) % history.CAPACITY) / size) + 1]
            if read(entry, last) < before then
                local low, high = index + (bounds & 0xff), index + (bounds >> 8 & 0xff)
                return last, math.min(low, high), math.max(low, high), bounds & 0x10000 ~= 0
            end
        end
    end
end

local function record(entry, value, at, epsilon, segment)
    local state = entry.state
    if state.full then
        return
    end
    if entry.mode == "rolling" then
        expire(entry, at - state.window, 2)
    end
    local broken = entry.gap or entry.segment ~= segment or at <= entry.lastAt
    if broken or state.epsilon ~= epsilon then
        seal(entry)
    end
    state.epsilon = epsilon
    if at > 0x3fffffff or entry.last - state.first + 1 >= history.CAPACITY then
        state.full = true
        publish(entry)
        return
    end
    if broken then
        write(entry, at, value, true)
        entry.anchorAt, entry.anchor = at, value
        entry.lastAt, entry.endpoint = at, value
        entry.low, entry.high = -math.huge, math.huge
    else
        for attempt = 1, 2 do
            local elapsed = at - entry.anchorAt
            local tolerance = epsilon - math.max(math.abs(value), math.abs(entry.anchor), epsilon) * ROUNDING
            local low = math.max(entry.low, (value - entry.anchor - tolerance) / elapsed)
            local high = math.min(entry.high, (value - entry.anchor + tolerance) / elapsed)
            local endpoint = entry.anchor + (low / 2 + high / 2) * elapsed
            local slope = (endpoint - entry.anchor) / elapsed
            if tolerance > 0 and finite(endpoint) and low <= slope and slope <= high then
                entry.low, entry.high = low, high
                entry.lastAt, entry.endpoint = at, endpoint
                break
            end
            -- The previous endpoint was feasible for EVERY previous sample.
            -- Sharing it avoids the error from blindly committing a raw sample.
            seal(entry)
            if entry.last - state.first + 1 >= history.CAPACITY then
                state.full = true
                break
            end
            if attempt == 2 or tolerance <= 0 then
                write(entry, at, value, false)
                entry.anchorAt, entry.anchor = at, value
                entry.lastAt, entry.endpoint = at, value
                break
            end
        end
    end
    entry.segment, entry.gap = segment, false
    publish(entry)
end

function history:sample(reading, now)
    self:advance(now)
    if not self.state.recording then
        return
    end
    local entries = self.sources[reading.name]
    if not entries then
        return
    end
    for _, entry in ipairs(entries) do
        local state = entry.state
        local valid = reading.fresh and reading.updatedAt == now and finite(reading.value) and reading.kind == "number"
        if valid then
            local value = reading.value
            if entry.segment ~= self.state.segment or entry.gap or not entry.filtered then
                entry.filtered = value
                entry.gap = true
            elseif entry.tau > 0 then
                local alpha = 1 - math.exp(-math.max(0, now - entry.sampledAt) / entry.tau)
                entry.filtered = entry.filtered * (1 - alpha) + value * alpha
            else
                entry.filtered = value
            end
            entry.sampledAt = now
            state.value = value
            state.min = state.min and math.min(state.min, value) or value
            state.max = state.max and math.max(state.max, value) or value
            state.unitText, state.precision = reading.unitText, reading.precision
            state.available, state.stale = true, false
            local precision = entry.precision or (reading.precisionKnown == false and 3 or reading.precision or 0)
            precision = math.min(3, math.max(0, precision))
            record(entry, entry.filtered, self.state.elapsed, 0.5 * 10 ^ -precision, self.state.segment)
            state.revision = state.revision + 1
        else
            entry.gap = true
            if not state.stale then
                state.stale = state.available
                state.revision = state.revision + 1
            end
        end
    end
end

local function updateEntry(service, entry)
    local state = entry.state
    if entry.mode == "growing" then
        state.window = math.max(6000, math.ceil(service.state.elapsed / 6000) * 6000)
    elseif not state.full then
        local first = state.first
        expire(entry, service.state.elapsed - state.window, 16)
        if state.first ~= first then
            publish(entry)
        end
    end
end

function history:update(now)
    if self.failure then
        error(self.failure)
    end
    self:advance(now)
    self.cursor = self.support.roundRobin(self.entries, self.cursor, 1, updateEntry, self, now)
end

return history
