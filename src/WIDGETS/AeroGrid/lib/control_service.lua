-- SPDX-License-Identifier: GPL-2.0-only

--- Effective trim positions and read-only global variables.
---
--- Both are resolved by EdgeTX rather than by AeroGrid. A trim is read through
--- a selectable trim source, so EdgeTX applies flight-mode trim inheritance,
--- and a global variable is read for a flight mode so EdgeTX applies global
--- variable inheritance. AeroGrid never writes either one.
---
--- Trim scaling is the awkward part. `getValue` on a trim source returns eight
--- times the stored trim, so a standard trim spans -1000 to 1000 and an
--- extended trim spans -4000 to 4000. EdgeTX does not expose the model's
--- extended-trim flag to Lua, so the `auto` scale starts standard and widens
--- permanently once a value outside the standard range is observed.

---@class AeroGridTrim
---@field name string Trim source name as configured.
---@field known boolean The radio recognizes the source name.
---@field available boolean A position has been read.
---@field raw integer Value exactly as EdgeTX reports it.
---@field value integer Stored trim units, raw divided by eight.
---@field fraction number Signed position from -1 to 1 against the active scale.
---@field scale "standard"|"extended" Range the fraction is measured against.
---@field centered boolean
---@field threePosition boolean The source behaves as a three-position switch.
---@field state "normal"|"unavailable"

---@class AeroGridGlobalVariable
---@field index integer
---@field known boolean
---@field available boolean
---@field name string Configured name, or "GV<n>" when unnamed.
---@field raw integer Stored value before precision is applied.
---@field value number Value scaled by the configured precision.
---@field min number
---@field max number
---@field precision integer
---@field unitText string
---@field flightMode integer Flight mode the value was read for.
---@field state "normal"|"unavailable"

local controlService = {}
controlService.__index = controlService

--- Ticks of 10ms between updates. Trims move under the pilot's thumb, so this
--- is the same rate a telemetry readout uses.
controlService.INTERVAL = 20

--- Subscriptions refreshed per update, served round robin.
controlService.POLL_CAP = 6

--- Ticks between attempts to resolve a trim source the radio rejects.
controlService.RESOLVE_RETRY = 500

--- `getValue` returns eight times the stored trim value.
controlService.TRIM_SCALE = 8

--- Standard and extended trim travel, already multiplied by TRIM_SCALE.
--- EdgeTX clamps a stored trim to TRIM_MAX (128) or TRIM_EXTENDED_MAX (512),
--- so the raw span is 1024 and 4096. Using the round numbers here instead
--- would make every standard trim held at its own end stop widen the scale
--- permanently and then report a quarter of its real deflection.
controlService.STANDARD_RANGE = 1024
controlService.EXTENDED_RANGE = 4096

--- EdgeTX's full stick deflection, returned by a trim configured as a
--- three-position toggle. It is also exactly a standard trim's end stop, which
--- is why one sample can never tell the two apart.
controlService.RESX = 1024

--- Create the service.
---@param env table Result of services.environment.
---@param support table The loaded lib/services.lua module.
---@return table
function controlService.new(env, support)
  return setmetatable({
    id = "control",
    interval = controlService.INTERVAL,
    revision = 0,
    count = 0,
    due = 0,
    env = env,
    support = support,
    entries = {},
    cursor = 1,
    trims = {},
    variables = {},
  }, controlService)
end

--- Register a subscription and publish its immutable view.
---@param state table
---@param read fun(self: table, entry: table, now: integer)
---@return table entry
function controlService:add(state, read)
  local entry = {
    state = state,
    read = read,
    view = self.support.snapshot(state),
    nextResolve = 0,
  }
  self.entries[#self.entries + 1] = entry
  self.count = self.count + 1
  return entry
end

--- Read one trim position.
---@param entry table
---@param now integer
function controlService:readTrim(entry, now)
  local state = entry.state

  if not state.known then
    if now < entry.nextResolve then return end
    entry.nextResolve = now + controlService.RESOLVE_RETRY

    local lookup = self.env.getFieldInfo
    local info = lookup and lookup(state.name)
    if type(info) ~= "table" or type(info.id) ~= "number" then
      state.available = false
      state.state = "unavailable"
      return
    end
    state.known = true
    entry.id = info.id
  end

  local read = self.env.getValue
  local raw = read and read(entry.id)
  if type(raw) ~= "number" then
    state.available = false
    state.state = "unavailable"
    return
  end

  local magnitude = raw < 0 and -raw or raw

  -- A three-position trim reports full deflection or nothing, and a standard
  -- trim's end stop is exactly the same number, so a single sample can never
  -- tell them apart. Claim a toggle only after seeing both a centre and a full
  -- deflection with nothing in between: a real trim moved to its stop passes
  -- through intermediate values, and one parked at the stop never reads zero.
  if magnitude == controlService.RESX then
    entry.sawExtreme = true
  elseif raw == 0 then
    entry.sawCentre = true
  else
    entry.sawOrdinary = true
  end
  state.threePosition = entry.sawExtreme == true and entry.sawCentre == true
    and not entry.sawOrdinary

  -- Auto widens once, permanently: a trim that has reached the extended range
  -- must not shrink its own scale again when it returns toward centre.
  if entry.scaleMode == "auto" and not state.threePosition
      and magnitude > controlService.STANDARD_RANGE then
    state.scale = "extended"
  end

  local range = state.scale == "extended"
    and controlService.EXTENDED_RANGE or controlService.STANDARD_RANGE
  if state.threePosition then range = controlService.RESX end

  local fraction = raw / range
  if fraction > 1 then fraction = 1 end
  if fraction < -1 then fraction = -1 end

  state.available = true
  state.state = "normal"
  state.raw = raw
  -- Integer trim units: EdgeTX stores whole trim steps and scales by eight.
  state.value = raw >= 0 and math.floor(raw / controlService.TRIM_SCALE)
    or -math.floor(-raw / controlService.TRIM_SCALE)
  state.fraction = fraction
  state.centered = raw == 0
end

--- Subscribe to one trim source.
--- The source name is persisted by the layout rather than assumed, because
--- trim naming follows the radio's stick mode and hardware description.
---@param name any EdgeTX trim source name such as "trim-ail".
---@param scale? "standard"|"extended"|"auto"
---@return AeroGridTrim
function controlService:trim(name, scale)
  if type(name) ~= "string" or name == "" then
    if not self.noneTrim then
      self.noneTrim = self.support.snapshot({
        name = "",
        known = false,
        available = false,
        raw = 0,
        value = 0,
        fraction = 0,
        scale = "standard",
        centered = true,
        threePosition = false,
        state = "unavailable",
      })
    end
    return self.noneTrim
  end

  local existing = self.trims[name]
  if existing then return existing end

  if scale ~= "standard" and scale ~= "extended" then scale = "auto" end

  local entry = self:add({
    name = name,
    known = false,
    available = false,
    raw = 0,
    value = 0,
    fraction = 0,
    scale = scale == "extended" and "extended" or "standard",
    centered = true,
    threePosition = false,
    state = "unavailable",
  }, controlService.readTrim)

  entry.scaleMode = scale
  self.trims[name] = entry.view
  return entry.view
end

--- Read one global variable for the active or a pinned flight mode.
---@param entry table
function controlService:readVariable(entry)
  local state = entry.state
  local read = self.env.getGlobalVariable
  if not read then
    state.available = false
    state.state = "unavailable"
    return
  end

  -- A pinned flight mode reads that mode's own value. Otherwise EdgeTX is
  -- asked for the active mode, so it resolves global variable inheritance.
  local flightMode = entry.pinnedMode or 0
  if not entry.pinnedMode then
    local modeReader = self.env.getFlightMode
    if modeReader then
      local index = modeReader()
      if type(index) == "number" then flightMode = index end
    end
  end

  local raw = read(state.index, flightMode)
  if type(raw) ~= "number" then
    state.available = false
    state.state = "unavailable"
    return
  end

  -- Details describe the variable rather than its value, so they are read once
  -- and only retried while they are missing.
  if not state.known then
    local details = self.env.getGlobalVariableDetails
    local info = details and details(state.index)
    if type(info) == "table" then
      state.known = true
      local name = type(info.name) == "string" and info.name or ""
      state.name = name ~= "" and name or ("GV" .. tostring(state.index + 1))
      state.precision = type(info.prec) == "number" and info.prec or 0
      state.unitText = info.unit == 1 and "%" or ""
      local divisor = state.precision > 0 and 10 or 1
      state.min = (type(info.min) == "number" and info.min or 0) / divisor
      state.max = (type(info.max) == "number" and info.max or 0) / divisor
    end
  end

  state.available = true
  state.state = "normal"
  state.raw = raw
  state.flightMode = flightMode
  state.value = state.precision > 0 and raw / 10 or raw
end

--- Subscribe to one global variable.
--- A pinned flight mode yields its own subscription, because two components
--- may legitimately show the same variable for different modes.
---@param index any Zero-based global variable index.
---@param flightMode? integer Pin to this flight mode instead of the active one.
---@return AeroGridGlobalVariable
function controlService:globalVariable(index, flightMode)
  if type(index) ~= "number" or index < 0 or index ~= math.floor(index) then
    index = 0
  end
  if type(flightMode) ~= "number" or flightMode < 0
      or flightMode ~= math.floor(flightMode) then
    flightMode = nil
  end

  local key = flightMode and (index .. ":" .. flightMode) or index
  local existing = self.variables[key]
  if existing then return existing end

  local entry = self:add({
    index = index,
    known = false,
    available = false,
    name = "GV" .. tostring(index + 1),
    raw = 0,
    value = 0,
    min = 0,
    max = 0,
    precision = 0,
    unitText = "",
    flightMode = flightMode or 0,
    state = "unavailable",
  }, controlService.readVariable)

  entry.pinnedMode = flightMode
  self.variables[key] = entry.view
  return entry.view
end

--- Refresh a bounded slice of the subscriptions.
---@param now integer
function controlService:update(now)
  local entries = self.entries
  local total = #entries
  if total == 0 then return end

  local cursor = self.cursor
  if cursor > total then cursor = 1 end

  local cap = controlService.POLL_CAP
  if cap > total then cap = total end

  for _ = 1, cap do
    local entry = entries[cursor]
    cursor = cursor % total + 1
    if entry then entry.read(self, entry, now) end
  end

  self.cursor = cursor
end

--- Round a signed percentage half away from zero.
--- Flooring a negative value plus a negative half rounds -23.4 to -24, which
--- reads as more deflection than the trim actually has.
---@param fraction number
---@return integer
local function percentOf(fraction)
  local percent = fraction * 100
  if percent < 0 then return -math.floor(-percent + 0.5) end
  return math.floor(percent + 0.5)
end

--- Describe the subscribed trims and variables as diagnostic rows.
---@param rows table Reusable row array.
---@return integer count
function controlService:describe(rows)
  local row = self.support.row
  local index = 1

  for _, entry in ipairs(self.entries) do
    local state = entry.state
    if state.name and state.fraction ~= nil then
      local text = state.available
        and string.format("%d %d%%", state.value, percentOf(state.fraction))
        or "N/A"
      if state.threePosition then text = text .. " 3P" end
      index = row(rows, index, string.upper(state.name), text)
    elseif state.index ~= nil then
      index = row(rows, index, string.upper(state.name), state.available
        and (tostring(state.value) .. state.unitText) or "N/A")
    end
  end

  return index - 1
end

return controlService
