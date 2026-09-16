-- SPDX-License-Identifier: GPL-2.0-only

--- Cached telemetry readings with units, precision, and freshness.
---
--- Components subscribe by EdgeTX source name and hold the returned immutable
--- reading for their lifetime. Two components naming the same sensor share one
--- subscription, so the dashboard reads each source once per poll no matter how
--- many panels display it.
---
--- Freshness deserves its own note, because EdgeTX makes it subtle. `getValue`
--- returns integer zero for a telemetry source whenever telemetry is not
--- streaming *or* the sensor has never been received, and that is
--- indistinguishable from a genuine zero reading.
---
--- Only a zero is ambiguous, so only a zero is judged. A non-zero value is
--- proof of life whatever the link indicator says, and is always stored. A
--- zero is stored only while the link is believed up; otherwise the last live
--- value is kept and marked stale. Non-telemetry sources such as the
--- transmitter voltage, timers, trims, and global variables do not depend on
--- the link and are always live once resolved.
---
--- The link indicator is `getRSSI() > 0`, which is the only liveness signal
--- the Lua API offers, and it is not reliable everywhere: a protocol that
--- never populates an RSSI sensor reads zero on a perfectly live link. The
--- service detects that case and stops trusting the indicator, because a
--- telemetry source cannot return a non-zero value when EdgeTX has nothing.
---
--- What remains unsolvable from Lua: a sensor that is configured but has never
--- been received reads as a valid zero while the link is up, because EdgeTX
--- exposes no per-sensor availability. GPS is the exception; it carries its
--- own age, which `navigationService` uses.

---@class AeroGridReading
---@field name string Source name as configured in the layout.
---@field id? integer Resolved EdgeTX source id.
---@field known boolean The radio recognizes the source name.
---@field telemetry boolean The source is a telemetry sensor subject to the link.
---@field available boolean A live reading has been seen at least once.
---@field fresh boolean The most recent poll produced a live reading.
---@field stale boolean A reading exists but is no longer live.
---@field state "normal"|"stale"|"unavailable" Name accepted by theme.state.
---@field value? number Last live numeric reading.
---@field raw any Last live reading in its original shape, including tables.
---@field kind "number"|"cells"|"gps"|"datetime"|"text" Value shape.
---@field unit integer EdgeTX unit code.
---@field unitText string Short ASCII unit label, empty when the unit is raw.
---@field precision integer Decimal places configured on the sensor.
---@field updatedAt? integer Tick of the last live reading.
---@field age? number Seconds since the last live reading.
---@field revision integer Incremented whenever the reading changes.

local telemetryService = {}
telemetryService.__index = telemetryService

--- Ticks of 10ms between polls. Faster than any component's refresh so a
--- component never renders a reading older than its own interval.
telemetryService.INTERVAL = 10

--- Subscriptions refreshed per update, served round robin. Sixteen sources
--- split across two updates still give every source 5 Hz at the interval above.
telemetryService.POLL_CAP = 8

--- Ticks between attempts to resolve a source the radio does not yet know.
--- Sensors appear when telemetry first arrives, so an unresolved name must be
--- retried, but retrying every poll wastes the budget on a missing sensor.
telemetryService.RESOLVE_RETRY = 200

--- Telemetry sensors inspected per update while looking up precision, and the
--- largest sensor table any supported radio provides. Only one subscription
--- scans at a time, so this is the whole cost of the search per update.
telemetryService.SCAN_CAP = 8
telemetryService.SENSOR_LIMIT = 60

--- Short ASCII labels for EdgeTX unit codes, from `TelemetryUnit` in
--- `radio/src/dataconstants.h`. Deliberately ASCII: the radio's fonts and this
--- repository both stay within it.
local UNIT_TEXT = {
  [0] = "",
  "V", "A", "mA", "kts", "m/s", "ft/s", "km/h", "mph", "m", "ft",
  "C", "F", "%", "mAh", "W", "mW", "dB", "rpm", "g", "deg",
  "rad", "ml", "floz", "ml/m", "Hz", "ms", "us", "km", "dBm",
}
UNIT_TEXT[35] = "h"
UNIT_TEXT[36] = "min"
UNIT_TEXT[37] = "s"

--- Unit codes whose value is not a plain number.
local UNIT_KIND = {
  [38] = "cells",
  [39] = "datetime",
  [40] = "gps",
  [42] = "text",
}

--- Create the service.
---@param env table Result of services.environment.
---@param support table The loaded lib/services.lua module.
---@return table
function telemetryService.new(env, support)
  return setmetatable({
    id = "telemetry",
    interval = telemetryService.INTERVAL,
    revision = 0,
    count = 0,
    due = 0,
    env = env,
    support = support,
    names = {},
    entries = {},
    cursor = 1,
    scanCursor = 1,
    linkLive = false,
    rssi = 0,
  }, telemetryService)
end

--- Build the mutable state behind a subscription.
---@param name string
---@return table entry
local function newEntry(name)
  -- EdgeTX exposes a sensor's minimum and maximum as "<name>-" and "<name>+".
  -- Precision is configured on the base sensor, so remember the stem.
  local base = string.gsub(name, "[%+%-]$", "")

  local state = {
    name = name,
    id = nil,
    known = false,
    telemetry = false,
    available = false,
    fresh = false,
    stale = false,
    state = "unavailable",
    value = nil,
    raw = nil,
    kind = "number",
    unit = 0,
    unitText = "",
    precision = 0,
    updatedAt = nil,
    age = nil,
    revision = 0,
  }

  return {state = state, base = base, nextResolve = 0, scanIndex = nil}
end

--- Subscribe to an EdgeTX source by name.
--- An absent or empty name yields a permanently unavailable reading rather
--- than nil, so a component can render an unconfigured source without
--- branching and without ever indexing nil.
---@param name any
---@return AeroGridReading
function telemetryService:subscribe(name)
  if type(name) ~= "string" or name == "" then
    if not self.noneView then
      self.noneView = self.support.snapshot(newEntry("").state)
    end
    return self.noneView
  end

  local entry = self.names[name]
  if not entry then
    entry = newEntry(name)
    entry.view = self.support.snapshot(entry.state)
    self.names[name] = entry
    self.entries[#self.entries + 1] = entry
    self.count = self.count + 1
  end

  return entry.view
end

--- Look up an existing subscription without creating one.
---@param name any
---@return AeroGridReading?
function telemetryService:reading(name)
  local entry = type(name) == "string" and self.names[name] or nil
  return entry and entry.view or nil
end

--- Resolve a source name to its EdgeTX id, unit, and value shape.
---@param entry table
---@param now integer
---@return boolean resolved
function telemetryService:resolve(entry, now)
  local lookup = self.env.getFieldInfo
  if not lookup then
    entry.nextResolve = now + telemetryService.RESOLVE_RETRY
    return false
  end

  local info = lookup(entry.state.name)
  if type(info) ~= "table" or type(info.id) ~= "number" then
    -- The sensor may simply not have been received yet; try again later.
    entry.nextResolve = now + telemetryService.RESOLVE_RETRY
    return false
  end

  local state = entry.state
  state.id = info.id
  state.known = true

  -- EdgeTX reports a unit only for telemetry sensors, which is also how this
  -- service tells link-dependent sources from radio-local ones.
  if type(info.unit) == "number" then
    state.telemetry = true
    state.unit = info.unit
    state.unitText = UNIT_TEXT[info.unit] or ""
    state.kind = UNIT_KIND[info.unit] or "number"
    -- EdgeTX returns the cells table only for the base source. "Cels-" and
    -- "Cels+" carry the same unit but return a plain number, so the lowest
    -- and highest cell would otherwise never be readable.
    if state.kind == "cells" and entry.base ~= state.name then
      state.kind = "number"
    end
    entry.scanIndex = 0
  else
    state.telemetry = false
    state.unit = 0
    state.unitText = ""
    state.kind = "number"
  end

  return true
end

--- Advance the bounded search for a sensor's configured precision.
--- EdgeTX does not report precision through `getFieldInfo`, so the sensor
--- table is searched by name. Only one subscription searches per update and
--- only a fixed number of sensors are inspected, so the cost is flat.
---@param entry table
function telemetryService:scanPrecision(entry)
  local getSensor = self.env.getSensor
  if not getSensor then
    entry.scanIndex = nil
    return
  end

  local index = entry.scanIndex
  local limit = index + telemetryService.SCAN_CAP
  if limit > telemetryService.SENSOR_LIMIT then
    limit = telemetryService.SENSOR_LIMIT
  end

  while index < limit do
    local sensor = getSensor(index)
    if type(sensor) == "table" and sensor.name == entry.base then
      entry.state.precision = type(sensor.prec) == "number" and sensor.prec or 0
      entry.state.sensorIndex = index
      entry.scanIndex = nil
      return
    end
    index = index + 1
  end

  -- Give up at the end of the table; precision stays at zero.
  entry.scanIndex = index < telemetryService.SENSOR_LIMIT and index or nil
end

--- Apply one poll result to a subscription.
---@param entry table
---@param now integer
function telemetryService:poll(entry, now)
  local state = entry.state

  if not state.known then
    if now < entry.nextResolve then return end
    if not self:resolve(entry, now) then
      state.fresh = false
      -- A cached reading from a previous session stays stale, not unavailable.
      state.state = state.available and "stale" or "unavailable"
      state.stale = state.available
      return
    end
  end

  local read = self.env.getValue
  local raw = read and read(state.id)

  local kind = state.kind
  local value

  if kind == "number" then
    value = type(raw) == "number" and raw or nil
  elseif kind == "cells" then
    -- EdgeTX returns integer zero rather than a table when no cells are known.
    value = type(raw) == "table" and raw or nil
  elseif kind == "gps" then
    value = type(raw) == "table" and raw or nil
  else
    value = raw ~= nil and raw or nil
  end

  -- A telemetry source returns exactly integer zero when EdgeTX has nothing
  -- for it, so a non-zero value proves the link is alive no matter what the
  -- indicator says. Learn that once and stop trusting a broken indicator.
  if state.telemetry and value ~= nil and value ~= 0 and not self.linkLive then
    self.linkTrusted = false
    self.linkLive = true
  end

  -- Only the ambiguous case is withheld: a zero read while the link is down is
  -- not a reading, so the last live value is kept and marked stale.
  if value == nil or (state.telemetry and value == 0 and not self.linkLive) then
    state.fresh = false
    state.stale = state.available
    state.state = state.available and "stale" or "unavailable"
    if state.updatedAt then
      state.age = self.support.age(now, state.updatedAt)
    end
    return
  end

  local changed = state.raw ~= value
  state.raw = value
  state.value = kind == "number" and value or nil
  state.available = true
  state.fresh = true
  state.stale = false
  state.state = "normal"
  state.updatedAt = now
  state.age = 0
  if changed then state.revision = state.revision + 1 end
end

--- Poll a bounded slice of the subscriptions.
---@param now integer
function telemetryService:update(now)
  local read = self.env.getRSSI
  local rssi = read and read() or 0
  if type(rssi) ~= "number" then rssi = 0 end

  -- EdgeTX reports zero RSSI whenever telemetry is not streaming, which is the
  -- only link-liveness signal the Lua API offers.
  self.rssi = rssi
  self.linkLive = rssi > 0 or self.linkTrusted == false

  local entries = self.entries
  local total = #entries
  if total == 0 then return end

  local cursor = self.cursor
  if cursor > total then cursor = 1 end

  local polled = 0
  local cap = telemetryService.POLL_CAP
  if cap > total then cap = total end

  while polled < cap do
    local entry = entries[cursor]
    cursor = cursor % total + 1
    polled = polled + 1
    if entry then self:poll(entry, now) end
  end
  self.cursor = cursor

  -- Advance at most one precision search per update, in rotation, so a
  -- dashboard of sixteen sources never pays sixteen table scans at once.
  local scan = self.scanCursor
  if scan > total then scan = 1 end
  for _ = 1, total do
    local entry = entries[scan]
    scan = scan % total + 1
    if entry and entry.scanIndex then
      self:scanPrecision(entry)
      break
    end
  end
  self.scanCursor = scan
end

--- Format a reading for display, honoring its precision.
--- Provided as a module function rather than a snapshot field so formatting is
--- paid only by the components that actually render text.
---@param reading AeroGridReading?
---@param precision? integer Overrides the sensor's own precision.
---@return string
function telemetryService.format(reading, precision)
  if type(reading) ~= "table" then return "--" end

  local value = reading.value
  if type(value) ~= "number" or value ~= value then
    if reading.kind == "text" and type(reading.raw) == "string" then
      return reading.raw
    end
    return "--"
  end

  local digits = precision
  if type(digits) ~= "number" or digits < 0 then digits = reading.precision end
  digits = math.floor(tonumber(digits) or 0)
  if digits < 0 then digits = 0 end
  if digits > 3 then digits = 3 end

  return string.format("%." .. digits .. "f", value)
end

--- Describe a reading as diagnostic rows.
--- The rows exist so a diagnostic view can prove normalized output without
--- depending on any production component's presentation.
---@param rows table Reusable row array of {label = , text = } tables.
---@param reading AeroGridReading? Subscription to describe.
---@return integer count
function telemetryService:describe(rows, reading)
  if type(reading) ~= "table" then return 0 end

  local row = self.support.row
  local index = row(rows, 1, "SRC", reading.name ~= "" and reading.name or "-")
  index = row(rows, index, "STATE", string.upper(reading.state))
  index = row(rows, index, "VALUE", telemetryService.format(reading))
  index = row(rows, index, "UNIT",
    reading.unitText ~= "" and reading.unitText or "-")
  index = row(rows, index, "PREC", tostring(reading.precision))
  index = row(rows, index, "AGE",
    reading.age and string.format("%.1fs", reading.age) or "-")
  index = row(rows, index, "LINK", self.linkLive and "UP" or "DOWN")

  return index - 1
end

return telemetryService
