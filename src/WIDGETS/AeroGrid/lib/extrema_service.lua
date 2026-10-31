-- SPDX-License-Identifier: GPL-2.0-only

--- EdgeTX telemetry extrema and dashboard flight sessions.
---
--- Two kinds of extrema exist and they are not interchangeable. EdgeTX keeps
--- its own minimum and maximum for every telemetry sensor, exposed as the
--- sources "<name>-" and "<name>+", and resets them on its own schedule. A
--- flight session extremum is owned by AeroGrid: it starts when the configured
--- arm switch goes active and covers exactly that flight.
---
--- Both are read through `telemetryService`, so a sensor displayed as a value
--- and tracked for extrema is still polled once.

---@class AeroGridFlightSession
---@field armed boolean The configured arm source is currently active.
---@field active boolean A session is running.
---@field configured boolean An arm source was configured.
---@field count integer Sessions started since the dashboard loaded.
---@field startedAt? integer Tick the current session started.
---@field duration number Seconds the current or last session ran.
---@field state "normal"|"unavailable"

---@class AeroGridSessionExtrema
---@field name string Source the extrema track.
---@field available boolean At least one sample was taken this session.
---@field min? number
---@field max? number
---@field samples integer
---@field session integer Session number the values belong to.

local extremaService = { RUNTIME_API = 1 }
extremaService.__index = extremaService

--- Ticks of 10ms between updates. Extrema only move when a reading moves, and
--- the reading itself is rate limited by the telemetry service.
local INTERVAL = 20

--- Session trackers refreshed per update, served round robin.
local TRACK_CAP = 6

--- Create the service.
---@param env table Result of services.environment.
---@param support table The loaded lib/services.lua module.
---@param runtime table Registry, used to reach the telemetry service.
---@return table
function extremaService.new(env, support, runtime)
    return setmetatable({
        id = "extrema",
        interval = INTERVAL,
        revision = 0,
        count = 0,
        due = 0,
        env = env,
        support = support,
        runtime = runtime,
        tracks = {},
        cursor = 1,
        sessions = {},
        sessionOrder = {},
    }, extremaService)
end

--- Reach the telemetry service, which owns every source poll.
---@return table?
function extremaService:telemetry()
    return self.runtime and self.runtime.byId and self.runtime.byId.telemetry or nil
end

--- Subscribe to EdgeTX's own minimum or maximum for a sensor.
--- These are ordinary sources, so they carry the same freshness and unit
--- normalization as any other reading.
---@param name any Base sensor name.
---@param mode? "min"|"max"
---@return AeroGridReading?
function extremaService:sourceExtreme(name, mode)
    local telemetry = self:telemetry()
    if not telemetry or type(name) ~= "string" or name == "" then
        return telemetry and telemetry:subscribe(nil) or nil
    end

    return telemetry:subscribe(name .. (mode == "min" and "-" or "+"))
end

--- Subscribe to the effective widget/legacy arm condition's session.
---@param armSource? string Retained legacy switch condition.
---@return AeroGridFlightSession
function extremaService:flight(armSource)
    local arm = assert(self.runtime.byId.armed, "extrema requires Armed service"):state(armSource)
    local session = self.sessions[arm.key]
    if not session then
        local state = {
            armed = false,
            active = false,
            configured = arm.configured,
            count = 0,
            startedAt = nil,
            duration = 0,
            state = "unavailable",
        }
        session = { state = state, arm = arm, tracks = {}, view = self.support.snapshot(state) }
        self.sessions[arm.key] = session
        self.sessionOrder[#self.sessionOrder + 1] = session
        self.count = self.count + 1
    end
    return session.view
end

--- Subscribe to flight-session extrema for one source.
---@param name any Source name whose extremes should be tracked.
---@return AeroGridSessionExtrema
function extremaService:sessionExtrema(name, armSource)
    if type(name) ~= "string" or name == "" then
        if not self.noneTrack then
            self.noneTrack = self.support.snapshot({
                name = "",
                available = false,
                min = nil,
                max = nil,
                samples = 0,
                session = 0,
            })
        end
        return self.noneTrack
    end

    local flight = self:flight(armSource)
    local arm = self.runtime.byId.armed:state(armSource)
    local session = self.sessions[arm.key]
    local key = arm.key .. "\0" .. name
    local existing = self.tracks[key]
    if existing then
        return existing.view
    end

    local telemetry = self:telemetry()
    local track = {
        state = {
            name = name,
            available = false,
            min = nil,
            max = nil,
            samples = 0,
            session = flight.count,
        },
        reading = telemetry and telemetry:subscribe(name) or nil,
        flight = flight,
        session = session,
    }
    self.trackOrder = self.trackOrder or {}
    self.support.addSubscription(self, self.trackOrder, track)
    self.tracks[key] = track
    session.tracks[#session.tracks + 1] = track
    return track.view
end

--- Discard every tracked extremum and start a new session number.
--- This is the manual reset policy, and it is also what an arm transition
--- calls, so both policies leave the service in exactly the same state.
---@param now? integer
local function resetSession(session, now)
    local flight = session.state
    flight.count = flight.count + 1
    for _, track in ipairs(session.tracks) do
        local state = track.state
        state.min = nil
        state.max = nil
        state.samples = 0
        state.available = false
        state.session = flight.count
    end

    flight.startedAt = now
    flight.duration = 0
    flight.active = true
    flight.state = "normal"
end

function extremaService:reset(now)
    for _, session in ipairs(self.sessionOrder) do
        resetSession(session, now)
    end
end

function extremaService:resetSession(_, index)
    index = index or 1
    local session = self.sessionOrder[index]
    if session then
        local state = session.state
        state.armed, state.active, state.count = false, false, 0
        state.startedAt, state.duration, state.state = nil, 0, "unavailable"
    else
        local track = (self.trackOrder or {})[index - #self.sessionOrder]
        if not track then
            return
        end
        local state = track.state
        state.min, state.max, state.samples, state.available, state.session = nil, nil, 0, false, 0
    end
    return index + 1
end

--- Fold one reading into its tracked extrema.
---@param track table
local function sample(track)
    local reading = track.reading
    if type(reading) ~= "table" or not reading.fresh then
        return
    end

    local value = reading.value
    if type(value) ~= "number" or value ~= value then
        return
    end

    local state = track.state
    if not state.available then
        state.min = value
        state.max = value
        state.available = true
    else
        if value < state.min then
            state.min = value
        end
        if value > state.max then
            state.max = value
        end
    end
    state.samples = state.samples + 1
end

local function advanceSession(service, session, now)
    local flight, arm = session.state, session.arm
    if flight.configured then
        local live = arm.fresh and now >= arm.updatedAt and now - arm.updatedAt <= 100
        if not live then
            flight.active = false
            flight.state = "unavailable"
            return
        end
        if arm.value and not flight.armed then
            resetSession(session, now)
        end
        flight.armed, flight.active = arm.value, arm.value
        flight.state = "normal"
    elseif not flight.active then
        resetSession(session, now)
    end
    if flight.active and flight.startedAt then
        flight.duration = service.support.age(now, flight.startedAt) or 0
    end
end

local function sampleEntry(service, track, now)
    -- A track may be visited before its session's round-robin turn.
    advanceSession(service, track.session, now)
    if track.flight.active then
        sample(track)
    end
end

--- Advance a bounded slice of sessions and trackers.
function extremaService:update(now)
    self.sessionCursor =
        self.support.roundRobin(self.sessionOrder, self.sessionCursor or 1, TRACK_CAP, advanceSession, self, now)
    local order = self.trackOrder or {}
    if #order == 0 then
        return
    end

    self.cursor = self.support.roundRobin(order, self.cursor, TRACK_CAP, sampleEntry, self, now)
end

--- Describe the session and tracked extrema as diagnostic rows.
---@param rows table Reusable row array.
---@return integer count
function extremaService:describe(rows)
    local row = self.support.row
    local index = 1
    for _, session in ipairs(self.sessionOrder) do
        local flight = session.state
        index = row(
            rows,
            index,
            "FLIGHT",
            flight.active and string.format("#%d %.0fs", flight.count, flight.duration) or "IDLE"
        )
        index = row(rows, index, "ARM", flight.configured and (flight.armed and "ARMED" or "SAFE") or "NONE")
    end

    for _, track in ipairs(self.trackOrder or {}) do
        local state = track.state
        index = row(
            rows,
            index,
            string.upper(state.name),
            state.available and string.format("%.1f / %.1f", state.min, state.max) or "N/A"
        )
    end

    return index - 1
end

return extremaService
