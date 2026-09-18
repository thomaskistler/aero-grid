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

local extremaService = {}
extremaService.__index = extremaService

--- Ticks of 10ms between updates. Extrema only move when a reading moves, and
--- the reading itself is rate limited by the telemetry service.
extremaService.INTERVAL = 20

--- Session trackers refreshed per update, served round robin.
extremaService.TRACK_CAP = 6

--- Create the service.
---@param env table Result of services.environment.
---@param support table The loaded lib/services.lua module.
---@param runtime table Registry, used to reach the telemetry service.
---@return table
function extremaService.new(env, support, runtime)
  return setmetatable({
    id = "extrema",
    interval = extremaService.INTERVAL,
    revision = 0,
    count = 0,
    due = 0,
    env = env,
    support = support,
    runtime = runtime,
    tracks = {},
    cursor = 1,
    session = 0,
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

--- Configure the arm source and subscribe to the flight session.
--- One dashboard has one flight, so the source comes from the layout's
--- `session` block rather than from a component. It used to be a per-component
--- setting, which let two components name two switches and left the second one
--- silently ignored by the first-caller-wins rule below.
---@param armSource? string Switch or source name that marks the model armed.
---@return AeroGridFlightSession
function extremaService:flight(armSource)
  if not self.flightView then
    self.flightState = {
      armed = false,
      active = false,
      configured = false,
      count = 0,
      startedAt = nil,
      duration = 0,
      state = "unavailable",
    }
    self.flightView = self.support.snapshot(self.flightState)
    self.count = self.count + 1
  end

  if type(armSource) == "string" and armSource ~= "" and not self.armSource then
    self.armSource = armSource
    self.flightState.configured = true
    local telemetry = self:telemetry()
    if telemetry then self.armReading = telemetry:subscribe(armSource) end
  end

  return self.flightView
end

--- Subscribe to flight-session extrema for one source.
---@param name any Source name whose extremes should be tracked.
---@return AeroGridSessionExtrema
function extremaService:sessionExtrema(name)
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

  local existing = self.tracks[name]
  if existing then return existing.view end

  local telemetry = self:telemetry()
  local track = {
    state = {
      name = name,
      available = false,
      min = nil,
      max = nil,
      samples = 0,
      session = self.session,
    },
    reading = telemetry and telemetry:subscribe(name) or nil,
  }
  track.view = self.support.snapshot(track.state)

  self.tracks[name] = track
  self.trackOrder = self.trackOrder or {}
  self.trackOrder[#self.trackOrder + 1] = track
  self.count = self.count + 1
  return track.view
end

--- Discard every tracked extremum and start a new session number.
--- This is the manual reset policy, and it is also what an arm transition
--- calls, so both policies leave the service in exactly the same state.
---@param now? integer
function extremaService:reset(now)
  self.session = self.session + 1

  for _, track in ipairs(self.trackOrder or {}) do
    local state = track.state
    state.min = nil
    state.max = nil
    state.samples = 0
    state.available = false
    state.session = self.session
  end

  local flight = self.flightState
  if flight then
    flight.count = self.session
    flight.startedAt = now
    flight.duration = 0
    flight.active = true
    flight.state = "normal"
  end
end

--- Fold one reading into its tracked extrema.
---@param track table
local function sample(track)
  local reading = track.reading
  if type(reading) ~= "table" or not reading.fresh then return end

  local value = reading.value
  if type(value) ~= "number" or value ~= value then return end

  local state = track.state
  if not state.available then
    state.min = value
    state.max = value
    state.available = true
  else
    if value < state.min then state.min = value end
    if value > state.max then state.max = value end
  end
  state.samples = state.samples + 1
end

--- Advance the flight session and a bounded slice of the trackers.
---@param now integer
function extremaService:update(now)
  local flight = self.flightState

  if flight then
    if self.armReading then
      -- Switch sources report full deflection, so any positive value is armed.
      local value = self.armReading.value
      local armed = type(value) == "number" and value > 0
      if armed ~= flight.armed then
        flight.armed = armed
        if armed then
          self:reset(now)
        else
          flight.active = false
        end
      end
    elseif not flight.configured and not flight.active then
      -- Without an arm source the dashboard tracks one open-ended session, so
      -- extrema still mean something on a radio with no arm switch.
      self:reset(now)
    end

    if flight.active and flight.startedAt then
      flight.duration = self.support.age(now, flight.startedAt) or 0
    end
  end

  local order = self.trackOrder
  local total = order and #order or 0
  if total == 0 then return end

  -- Flight extrema belong to a flight. Sampling while the model is disarmed
  -- would fold ground handling into the numbers the pilot reads afterwards.
  if flight and not flight.active then return end

  local cursor = self.cursor
  if cursor > total then cursor = 1 end

  local cap = extremaService.TRACK_CAP
  if cap > total then cap = total end

  for _ = 1, cap do
    local track = order[cursor]
    cursor = cursor % total + 1
    if track then sample(track) end
  end

  self.cursor = cursor
end

--- Describe the session and tracked extrema as diagnostic rows.
---@param rows table Reusable row array.
---@return integer count
function extremaService:describe(rows)
  local row = self.support.row
  local index = 1
  local flight = self.flightState

  if flight then
    index = row(rows, index, "FLIGHT", flight.active
      and string.format("#%d %.0fs", flight.count, flight.duration) or "IDLE")
    index = row(rows, index, "ARM", flight.configured
      and (flight.armed and "ARMED" or "SAFE") or "NONE")
  end

  for _, track in ipairs(self.trackOrder or {}) do
    local state = track.state
    index = row(rows, index, string.upper(state.name), state.available
      and string.format("%.1f / %.1f", state.min, state.max) or "N/A")
  end

  return index - 1
end

return extremaService
