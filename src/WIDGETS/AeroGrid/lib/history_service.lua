-- SPDX-License-Identifier: GPL-2.0-only

--- Connected, error-bounded recordings of cumulative recording time.
local history = { RUNTIME_API = 1, CAPACITY = 6144, FLIGHT_CAPACITY = 64 }
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
    local broken = stamp & BROKEN ~= 0
    local slot = (index - 1) % history.CAPACITY
    local resumed = broken and (entry.resumeBits[slot // 32 + 1] or 0) & (1 << (slot % 32)) ~= 0
    return stamp & 0x3fffffff, value, broken, resumed
end

local function publish(entry)
    local state = entry.state
    state.last = entry.last + (entry.lastAt > entry.anchorAt and 1 or 0)
    state.count = state.last - state.first + 1
    state.plotRevision = state.plotRevision + 1
end

local function write(entry, at, value, broken, resumed)
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
    if broken then
        -- Only broken knots need a reason; one bit per ring slot stays bounded.
        local slot = (index - 1) % history.CAPACITY
        local bucket, bit = slot // 32 + 1, 1 << (slot % 32)
        local flags = entry.resumeBits[bucket] or 0
        entry.resumeBits[bucket] = resumed and flags | bit or flags & ~bit
    end
    for level, size in ipairs(SIZES) do
        local relative = (index - 1) % size
        if relative == 0 then
            entry.lows[level], entry.highs[level] = value, value
            entry.bounds[level] = 0
        end
        local bounds = entry.bounds[level]
        if value < entry.lows[level] then
            entry.lows[level], bounds = value, bounds & 0x3ff00 | relative
        end
        if value > entry.highs[level] then
            entry.highs[level], bounds = value, bounds & 0x300ff | relative << 8
        end
        if broken and index > 1 then
            bounds = bounds | 0x10000
            if not resumed then
                bounds = bounds | 0x20000
            end
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
        sessions = {},
        sessionNames = {},
        sessionViews = {},
    }, history)
end

local function sessionFor(service, armSwitch)
    local armed = assert(service.runtime.byId.armed, "history requires Armed service"):state(armSwitch)
    local session = service.sessionNames[armed.key]
    if not session then
        local state = {
            configured = armed.configured,
            available = false,
            recording = false,
            elapsed = 0,
            segment = 0,
            revision = 0,
            flightFirst = 1,
            flightLast = 0,
            flightRevision = 0,
            armFirst = 1,
            armLast = 0,
            armRevision = 0,
            resumeFirst = 1,
            resumeLast = 0,
            resumeRevision = 0,
        }
        session = {
            name = armed.key,
            state = state,
            view = service.support.snapshot(state),
            arm = armed,
            spans = {},
            spanLast = 0,
            flights = {},
            arms = {},
            armValues = {},
            resumes = {},
        }
        service.sessions[#service.sessions + 1] = session
        service.sessionNames[armed.key] = session
        service.sessionViews[session.view] = session
    end
    return session
end

function history:session(armSwitch)
    return sessionFor(self, armSwitch).view
end

--- Reset one session or recording per step, preserving subscriptions.
function history:resetSession(now, index)
    index = index or 1
    local session = self.sessions[index]
    if session then
        local state = session.state
        session.lastTime, session.attachedAt, session.armed = now, now, nil
        session.spans, session.spanLast, session.span = {}, 0, nil
        session.flights, session.openFlight = {}, nil
        session.arms, session.armValues, session.resumes = {}, {}, {}
        local flight = self.runtime.byId.flight
        session.epoch = flight and flight:state().epoch
        state.available, state.recording, state.elapsed, state.segment = false, false, 0, 0
        state.stoppedAt = nil
        state.flightFirst, state.flightLast, state.flightLost, state.flightActive = 1, 0, false, false
        state.armFirst, state.armLast, state.resumeFirst, state.resumeLast = 1, 0, 1, 0
        state.revision = state.revision + 1
        state.flightRevision = state.flightRevision + 1
        state.armRevision, state.resumeRevision = state.armRevision + 1, state.resumeRevision + 1
    else
        local entry = self.entries[index - #self.sessions]
        if not entry then
            self.flightSequence, self.flightEpoch = nil, nil
            return
        end
        local state = entry.state
        entry.chunks, entry.resumeBits, entry.blocks = {}, {}, { {}, {}, {}, {} }
        entry.lows, entry.highs, entry.bounds = {}, {}, {}
        entry.last, entry.anchorAt, entry.lastAt = 0, 0, 0
        entry.anchor, entry.endpoint, entry.low, entry.high = nil, nil, nil, nil
        entry.segment, entry.filtered, entry.sampledAt, entry.gap = nil, nil, nil, true
        state.available, state.stale, state.full = false, false, false
        state.value, state.min, state.max, state.epsilon = nil, nil, nil, nil
        state.first, state.last, state.count = 1, 0, 0
        state.window = entry.mode == "growing" and 6000 or state.window
        state.revision, state.plotRevision = state.revision + 1, state.plotRevision + 1
    end
    return index + 1
end

local function advance(session, now, flight)
    if session.lastTime == now and (not flight or not flight.epoch or session.epoch == flight.epoch) then
        return
    end
    local state = session.state
    session.attachedAt = session.attachedAt or now
    if flight and flight.epoch and flight.epoch ~= session.epoch then
        session.epoch = flight.epoch
        session.spans, session.spanLast, session.span = {}, 0, nil
        session.flights, session.openFlight = {}, nil
        state.flightFirst, state.flightLast, state.flightLost, state.flightActive = 1, 0, false, false
        state.flightRevision = state.flightRevision + 1
    end
    local lastTime = session.lastTime
    if lastTime and state.recording and now > lastTime then
        state.elapsed = state.elapsed + now - lastTime
    end
    session.lastTime = now
    local arm = session.arm
    local value, updatedAt = arm.value, arm.updatedAt
    local available = arm.fresh == true
        and type(value) == "boolean"
        and type(updatedAt) == "number"
        and now >= updatedAt
        and now - updatedAt <= 100
    local associated = flight and flight.armKey == session.name
    local recording = associated and flight.active or available and value == true or false
    if available then
        if session.armed ~= nil and session.armed ~= value and state.segment > 0 then
            state.armLast = state.armLast + 1
            state.armFirst = math.max(1, state.armLast - history.CAPACITY + 1)
            session.arms[(state.armLast - 1) % history.CAPACITY + 1] = state.elapsed
            session.armValues[(state.armLast - 1) % history.CAPACITY + 1] = value
            state.armRevision = state.armRevision + 1
        end
        session.armed = value
    end
    if associated then
        -- Wall-clock spans map delayed boundaries to the cumulative recording
        -- axis, including pauses. The ring also bounds pathological arm chatter.
        if state.recording and session.span then
            session.span.to = now
        end
        if recording and not session.span then
            session.spanLast = session.spanLast + 1
            session.span = { from = now, to = now, at = state.elapsed }
            session.spans[(session.spanLast - 1) % 128 + 1] = session.span
        elseif not recording then
            session.span = nil
        end
    elseif session.span then
        session.span.to, session.span = now, nil
    end
    if state.recording ~= recording or state.available ~= available then
        if state.recording and not recording then
            state.stoppedAt = state.elapsed
        end
        if recording and not state.recording then
            if state.segment > 0 then
                state.resumeLast = state.resumeLast + 1
                state.resumeFirst = math.max(1, state.resumeLast - history.CAPACITY + 1)
                session.resumes[(state.resumeLast - 1) % history.CAPACITY + 1] = state.elapsed
                state.resumeRevision = state.resumeRevision + 1
            end
            state.segment = state.segment + 1
            state.stoppedAt = nil
        end
        state.recording, state.available = recording, available == true
        state.revision = state.revision + 1
    end
end

local function mapped(session, stamp, clipStart)
    if type(stamp) ~= "number" then
        return nil
    end
    local clipped
    for index = session.spanLast, math.max(1, session.spanLast - 127), -1 do
        local span = session.spans[(index - 1) % 128 + 1]
        if stamp >= span.from and stamp <= span.to then
            return span.at + stamp - span.from, true
        elseif clipStart and stamp < span.from then
            clipped = span.at
        end
    end
    return clipped, false
end

local function addFlight(session, id, at, known)
    local state = session.state
    local index = state.flightLast + 1
    local interval = { id = id, start = at, startKnown = known }
    session.flights[(index - 1) % history.FLIGHT_CAPACITY + 1] = interval
    state.flightLast = index
    state.flightFirst = math.max(state.flightFirst, index - history.FLIGHT_CAPACITY + 1)
    state.flightRevision = state.flightRevision + 1
    state.flightActive = true
    session.openFlight = interval
end

--- Scalar reads keep the bounded flight ring separate from telemetry series.
function history:flight(view, index)
    local session = self.sessionViews and self.sessionViews[view]
    if not session or index < session.state.flightFirst or index > session.state.flightLast then
        return nil
    end

    local interval = session.flights[(index - 1) % history.FLIGHT_CAPACITY + 1]
    if interval.empty then
        return nil
    end
    return interval.start, interval.finish, interval.startKnown, interval.endKnown
end

function history:armBoundary(view, index)
    local session = self.sessionViews[view]
    if not session or index < session.state.armFirst or index > session.state.armLast then
        return nil
    end
    local slot = (index - 1) % history.CAPACITY + 1
    return session.arms[slot], session.armValues[slot]
end

function history:recordingBreak(view, index)
    local session = self.sessionViews[view]
    if not session or index < session.state.resumeFirst or index > session.state.resumeLast then
        return nil
    end
    return session.resumes[(index - 1) % history.CAPACITY + 1]
end

function history:boundaries()
    local service, flight = self.runtime.byId.flight, self.flightState
    if not flight or not service.boundaries or not flight.epoch or #self.sessions == 0 then
        return
    end
    local records, _, lost = service:boundaries(self.flightSequence or 0, self.flightEpoch)
    if lost then
        for _, session in ipairs(self.sessions) do
            -- An unobserved end must not turn a previous flight into a band
            -- stretching across later flights.
            if session.openFlight then
                session.openFlight.finish = session.openFlight.observed or session.state.elapsed
                session.openFlight = nil
                session.state.flightActive = false
            end
            session.state.flightLost = true
            session.state.flightRevision = session.state.flightRevision + 1
        end
    end
    self.flightEpoch = flight.epoch
    -- Drain one record per service turn, even after journal loss.
    local event = records[1]
    if event then
        self.flightSequence = event.sequence
        local session = self.sessionNames[event.armKey]
        if session and session.epoch == event.epoch then
            local at, known = mapped(session, event.at, event.kind == "start")
            if event.kind == "start" and at and event.observedAt >= session.attachedAt then
                addFlight(session, event.flightId, at, known)
            elseif event.kind == "end" then
                local interval = session.openFlight
                if interval and interval.id == event.flightId then
                    interval.finish, interval.endKnown = at or interval.observed or session.state.elapsed, at ~= nil
                    local earliest = session.spans[(math.max(1, session.spanLast - 127) - 1) % 128 + 1]
                    interval.empty = not at and earliest and event.at < earliest.from
                    session.openFlight = nil
                    session.state.flightActive = false
                    session.state.flightRevision = session.state.flightRevision + 1
                end
            end
        end
    end
    local session = #records <= 1 and flight.active and self.sessionNames[flight.armKey]
    if session then
        if not session.openFlight or session.openFlight.id ~= flight.flightId then
            local at, known = mapped(session, flight.startedAt, true)
            -- Late attachment shows only the portion this runtime recorded,
            -- never a fabricated start marker or pre-attachment samples.
            addFlight(session, flight.flightId, at or session.state.elapsed, known)
        end
        session.openFlight.observed = session.state.elapsed
    end
end

function history:advance(now)
    self.now = now
    local flight = self.runtime.byId.flight
    self.flightState = flight and flight:state()
    for _, session in ipairs(self.sessions) do
        advance(session, now, self.flightState)
    end
end

local function recordingOptions(options)
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
    return window, mode, smoothing, precision
end

local function recordingKey(name, source, window, mode, smoothing, precision)
    return name
        .. "\0"
        .. source
        .. "\0"
        .. mode
        .. "\0"
        .. window
        .. "\0"
        .. smoothing
        .. "\0"
        .. tostring(precision or "sensor")
end

--- Drafts can read compatible live recordings, but cannot create pollers,
--- sessions, subscriptions, or journal cursors.
function history:preview()
    local owner = self
    local facade = { FLIGHT_CAPACITY = history.FLIGHT_CAPACITY }
    local empty = self.support.snapshot({
        previewMissing = true,
        available = false,
        revision = 0,
        plotRevision = 0,
        count = 0,
        first = 1,
        last = 0,
    })
    local function condition(legacy)
        local modelArm = owner.runtime.byId.armed.condition
        return modelArm ~= nil and modelArm or legacy or ""
    end
    function facade:session(legacy)
        local key = condition(legacy)
        local session = owner.sessionNames[key]
        return session and session.view
            or owner.support.snapshot({
                previewMissing = true,
                configured = key ~= "",
                available = false,
                recording = false,
                elapsed = 0,
                segment = 0,
                flightFirst = 1,
                flightLast = 0,
            })
    end
    function facade:subscribe(source, options)
        options = options or {}
        local window, mode, smoothing, precision = recordingOptions(options)
        source = type(source) == "string" and source or ""
        local key = recordingKey(condition(options.armSwitch), source, window, mode, smoothing, precision)
        return owner.names[key] and owner.names[key].view or empty
    end
    function facade:point(view, index, retainedFirst)
        return owner:point(view, index, retainedFirst)
    end
    function facade:block(view, index, finish, before)
        return owner:block(view, index, finish, before)
    end
    function facade:flight(view, index)
        return owner:flight(view, index)
    end
    function facade:armBoundary(view, index)
        return owner:armBoundary(view, index)
    end
    function facade:recordingBreak(view, index)
        return owner:recordingBreak(view, index)
    end
    return facade
end

function history:subscribe(source, options)
    options = options or {}
    local window, mode, smoothing, precision = recordingOptions(options)
    local session = sessionFor(self, options.armSwitch)
    source = type(source) == "string" and source or ""
    local key = recordingKey(session.name, source, window, mode, smoothing, precision)
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
        resumeBits = {},
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
        session = session,
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
--- A staged frame may retain expired knots until the physical ring overwrites them.
function history:point(view, index, retainedFirst)
    local entry = self.views[view]
    local first = entry
        and (retainedFirst and math.max(retainedFirst, entry.last - history.CAPACITY + 1) or entry.state.first)
    if not entry or index < first or index > entry.state.last then
        return nil
    end
    if index > entry.last then
        return entry.lastAt, entry.endpoint, false, false
    end
    return read(entry, index)
end

--- Skip sealed blocks only when they fit in one screen column. These summaries
--- accelerate projection; they never replace or recompress the stored knots.
function history:block(view, index, finish, before)
    if (index - 1) % 4 ~= 0 then
        return nil
    end
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
                return last, math.min(low, high), math.max(low, high), bounds & 0x10000 ~= 0, bounds & 0x20000 == 0
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
        write(entry, at, value, true, entry.segment ~= nil and entry.segment ~= segment)
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
    local entries = self.sources and self.sources[reading.name]
    if not entries then
        return
    end
    for _, entry in ipairs(entries) do
        advance(entry.session, now, self.flightState)
        local session = entry.session.state
        if session.recording then
            local state = entry.state
            local valid = reading.fresh
                and reading.updatedAt == now
                and finite(reading.value)
                and reading.kind == "number"
            if valid then
                local value = reading.value
                if entry.segment ~= session.segment or entry.gap or not entry.filtered then
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
                record(entry, entry.filtered, session.elapsed, 0.5 * 10 ^ -precision, session.segment)
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
end

local function updateEntry(_, entry)
    local state = entry.state
    local elapsed = entry.session.state.elapsed
    if entry.mode == "growing" then
        state.window = math.max(6000, math.ceil(elapsed / 6000) * 6000)
    elseif not state.full then
        local first = state.first
        expire(entry, elapsed - state.window, 16)
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
    self:boundaries()
    self.cursor = self.support.roundRobin(self.entries, self.cursor, 1, updateEntry, self, now)
end

return history
