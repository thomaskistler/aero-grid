-- SPDX-License-Identifier: GPL-2.0-only

--- Model identity, bitmap, timers, flight mode, and transmitter voltage.
---
--- Every reading here comes from the radio itself rather than from telemetry,
--- so nothing depends on a link. What can still go wrong is a missing API: not
--- every firmware build exposes every model function, and a timer index may be
--- out of range. Each facet therefore degrades to "unavailable" instead of
--- raising, and only facets a loaded component subscribed to are ever read.

---@class AeroGridModelIdentity
---@field available boolean
---@field name string Model name, empty when unknown.
---@field bitmap string Bitmap filename recorded on the model.
---@field bitmapPath? string Conventional absolute path for the bitmap.
---@field filename string Model storage filename.
---@field labels string

---@class AeroGridModelTimer
---@field index integer
---@field available boolean
---@field name string
---@field value integer Signed seconds exactly as EdgeTX reports them.
---@field start integer Configured start value; zero means count up.
---@field countdown boolean
---@field elapsed integer Seconds elapsed since the timer started.
---@field remaining integer Seconds left, negative once a countdown expires.
---@field expired boolean A countdown has passed zero.
---@field persistent integer
---@field showElapsed boolean
---@field text string Formatted value.
---@field state "normal"|"unavailable"

---@class AeroGridFlightMode
---@field available boolean
---@field index integer
---@field name string Configured name, or "FM<index>" when unnamed.

local modelService = {}
modelService.__index = modelService

--- Ticks of 10ms between updates. Timers advance once a second, so this is
--- already far faster than anything the model can actually change.
modelService.INTERVAL = 20

--- Facets refreshed per update, served round robin.
modelService.FACET_CAP = 4

--- Ticks between model identity reads. Identity changes only when the model
--- changes, which reloads the widget anyway, so it is polled rarely.
modelService.IDENTITY_INTERVAL = 500

--- EdgeTX stores model bitmaps in this directory.
modelService.IMAGE_PATH = "/IMAGES/"

--- The source name EdgeTX uses for the transmitter battery.
modelService.TX_VOLTAGE_SOURCE = "tx-voltage"

--- Create the service.
---@param env table Result of services.environment.
---@param support table The loaded lib/services.lua module.
---@return table
function modelService.new(env, support)
  return setmetatable({
    id = "model",
    interval = modelService.INTERVAL,
    revision = 0,
    count = 0,
    due = 0,
    env = env,
    support = support,
    facets = {},
    cursor = 1,
    timers = {},
  }, modelService)
end

--- Register a facet and publish its immutable view.
---@param state table
---@param read fun(self: table, state: table, now: integer)
---@return table view
function modelService:add(state, read)
  local facet = {state = state, read = read, view = self.support.snapshot(state)}
  self.facets[#self.facets + 1] = facet
  self.count = self.count + 1
  return facet.view
end

--- Format a signed second count as a clock reading.
--- Hours appear only when they exist, so a flight timer does not waste width.
---@param seconds any
---@return string
function modelService.formatTime(seconds)
  if type(seconds) ~= "number" then return "--:--" end

  local sign = seconds < 0 and "-" or ""
  local total = math.floor(math.abs(seconds) + 0.5)
  local hours = math.floor(total / 3600)
  local minutes = math.floor(total / 60) % 60
  local secs = total % 60

  if hours > 0 then
    return string.format("%s%d:%02d:%02d", sign, hours, minutes, secs)
  end
  return string.format("%s%d:%02d", sign, minutes, secs)
end

--- Read model identity, rate limited independently of the service interval.
---@param state table
---@param now integer
function modelService:readIdentity(state, now)
  if state.available and now < (state.nextRead or 0) then return end
  state.nextRead = now + modelService.IDENTITY_INTERVAL

  local getInfo = self.env.getInfo
  local info = getInfo and getInfo()
  if type(info) ~= "table" then
    state.available = false
    return
  end

  state.available = true
  state.name = type(info.name) == "string" and info.name or ""
  state.filename = type(info.filename) == "string" and info.filename or ""
  state.labels = type(info.labels) == "string" and info.labels or ""

  local bitmap = type(info.bitmap) == "string" and info.bitmap or ""
  state.bitmap = bitmap
  -- A component still has to open the file; the service only resolves where
  -- it lives, because a missing image must fall back to the model name.
  state.bitmapPath = bitmap ~= "" and (modelService.IMAGE_PATH .. bitmap) or nil
end

--- Subscribe to model identity and bitmap metadata.
---@return AeroGridModelIdentity
function modelService:identity()
  if self.identityView then return self.identityView end

  self.identityView = self:add({
    available = false,
    name = "",
    bitmap = "",
    bitmapPath = nil,
    filename = "",
    labels = "",
    nextRead = 0,
  }, modelService.readIdentity)

  return self.identityView
end

--- Read one model timer.
---@param state table
function modelService:readTimer(state)
  local getTimer = self.env.getTimer
  local timer = getTimer and getTimer(state.index)

  if type(timer) ~= "table" or type(timer.value) ~= "number" then
    state.available = false
    state.state = "unavailable"
    state.text = "--:--"
    return
  end

  local value = timer.value
  local start = type(timer.start) == "number" and timer.start or 0

  state.available = true
  state.state = "normal"
  state.name = type(timer.name) == "string" and timer.name or ""
  state.value = value
  state.start = start
  state.persistent = type(timer.persistent) == "number" and timer.persistent or 0
  state.showElapsed = timer.showElapsed == true

  -- EdgeTX counts a configured timer down and lets it run past zero, so the
  -- elapsed and remaining views are derived rather than tracked separately.
  if start > 0 then
    state.countdown = true
    state.remaining = value
    state.elapsed = start - value
    state.expired = value < 0
  else
    state.countdown = false
    state.remaining = 0
    state.elapsed = value
    state.expired = false
  end

  state.text = modelService.formatTime(state.showElapsed and state.elapsed or value)
end

--- Subscribe to one model timer.
---@param index any Zero-based EdgeTX timer index.
---@return AeroGridModelTimer
function modelService:timer(index)
  if type(index) ~= "number" or index < 0 or index ~= math.floor(index) then
    index = 0
  end

  local existing = self.timers[index]
  if existing then return existing end

  local view = self:add({
    index = index,
    available = false,
    name = "",
    value = 0,
    start = 0,
    countdown = false,
    elapsed = 0,
    remaining = 0,
    expired = false,
    persistent = 0,
    showElapsed = false,
    text = "--:--",
    state = "unavailable",
  }, modelService.readTimer)

  self.timers[index] = view
  return view
end

--- Read the active flight mode.
---@param state table
function modelService:readFlightMode(state)
  local read = self.env.getFlightMode
  if not read then
    state.available = false
    return
  end

  local index, name = read()
  if type(index) ~= "number" then
    state.available = false
    return
  end

  state.available = true
  state.index = index
  -- An unnamed flight mode returns an empty string; show its number instead.
  if type(name) == "string" and name ~= "" then
    state.name = name
  else
    state.name = "FM" .. tostring(index)
  end
end

--- Subscribe to the active flight mode.
---@return AeroGridFlightMode
--- firmware: `MAX_FLIGHT_MODES`, `radio/src/dataconstants.h`.
modelService.FLIGHT_MODES = 9

function modelService:flightMode()
  if self.flightModeView then return self.flightModeView end

  self.flightModeView = self:add({
    available = false,
    index = 0,
    name = "",
  }, modelService.readFlightMode)

  return self.flightModeView
end

--- The widest flight mode name this model can produce.
---
--- A panel sizes its reading from the widest string it can ever print, so
--- that switching modes never resizes it. For this the widest is not a
--- constant: `LEN_FLIGHT_MODE_NAME` allows ten characters, but a model whose
--- modes are all called `NORM` and `SPORT` would be sized for ten it never
--- uses, and lose two font steps at `2 x 2` for nothing.
---
--- So the names are read once, here. `luaGetFlightMode` takes an optional
--- index and returns that mode's configured name, falling back to the active
--- mode when the index is out of range
--- (`radio/src/lua/api_general.cpp`), and `MAX_FLIGHT_MODES` is 9
--- (`radio/src/dataconstants.h`). An unnamed mode returns the empty string
--- and is drawn as `FM<n>`, so that is what is measured for it.
---
--- Read once rather than watched: a model change destroys and rebuilds every
--- widget, because `LayoutFactory::deleteCustomScreens` runs before
--- `loadModel` and `loadCustomScreens` after it, so the set of names cannot
--- change underneath a component that is still alive.
---@return string widest
function modelService:widestFlightModeName()
  if self.widestMode then return self.widestMode end

  local read = self.env.getFlightMode
  -- Seeded empty rather than with a plausible default, so that a firmware
  -- without the call and a firmware answering nothing are the same case and
  -- neither is hidden behind a name this never actually read.
  local widest = ""

  if read then
    for index = 0, modelService.FLIGHT_MODES - 1 do
      local ok, _, name = pcall(read, index)
      if not ok or type(name) ~= "string" or name == "" then
        name = "FM" .. tostring(index)
      end
      if #name > #widest then widest = name end
    end
  end

  if widest == "" then widest = "FM0" end

  self.widestMode = widest
  return widest
end

--- Read the transmitter battery voltage.
---@param state table
---@param now integer
function modelService:readTxVoltage(state, now)
  local read = self.env.getValue
  local value = read and read(modelService.TX_VOLTAGE_SOURCE)

  if type(value) ~= "number" then
    -- Keep any earlier reading rather than replacing it with nothing.
    state.fresh = false
    state.stale = state.available
    state.state = state.available and "stale" or "unavailable"
    return
  end

  state.available = true
  state.fresh = true
  state.stale = false
  state.state = "normal"
  state.value = value
  state.updatedAt = now
  state.age = 0
end

--- Read the radio's own battery meter range.
---
--- Every radio already carries this, at SYS then Hardware then Battery meter
--- range, and it is correct on any radio whose battery icon is sensible: 6.4
--- to 8.4 for a 2S LiPo, 4.6 to 6.0 for four alkaline cells. Asking a layout
--- to restate it was asking for something the radio already knows.
---
--- firmware: `luaGetGeneralSettings` (`radio/src/lua/api_general.cpp`) hands
--- these over already converted to volts:
---
---     lua_pushtablenumber(L, "battMin", (90+g_eeGeneral.vBatMin) * 0.1f);
---     lua_pushtablenumber(L, "battMax", (120+g_eeGeneral.vBatMax) * 0.1f);
---
--- so the stored fields' offsets are the firmware's business and not ours.
--- The settings screen holds them between 3.0 V and 16.0 V and will not let
--- the two cross -- `batMin`'s maximum is `vBatMax + 29 + 90` against
--- `batMax`'s displayed `vBatMax + 120`, a tenth of a volt apart
--- (`radio/src/gui/colorlcd/radio/radio_hardware.cpp`) -- so a range read
--- from the radio is always the right way round. It is validated anyway,
--- because a firmware without the call is the case that matters and it
--- returns nothing at all.
---@param state table
function modelService:readBatteryRange(state)
  local read = self.env.getGeneralSettings
  if not read then
    state.available = false
    return
  end

  local ok, general = pcall(read)
  if not ok or type(general) ~= "table" then
    state.available = false
    return
  end

  local low, high = general.battMin, general.battMax
  if type(low) ~= "number" or type(high) ~= "number" or high <= low then
    state.available = false
    return
  end

  state.available = true
  state.empty = low
  state.full = high
  -- The radio's own warning level, which is a different question from the
  -- range and is offered beside it rather than folded into it.
  state.warn = type(general.battWarn) == "number" and general.battWarn or nil
end

--- Subscribe to the radio's battery meter range.
---
--- Read on the service's own interval rather than once, because a pilot can
--- change it in radio settings while the dashboard is running and nothing
--- rebuilds a widget for that: `LayoutFactory::deleteCustomScreens` runs on a
--- model load, and radio settings is not one. Once would have meant a
--- percentage that stayed wrong until the next model change.
---@return table view
function modelService:batteryRange()
  if self.batteryRangeView then return self.batteryRangeView end

  self.batteryRangeView = self:add({
    available = false,
    empty = nil,
    full = nil,
    warn = nil,
  }, modelService.readBatteryRange)

  return self.batteryRangeView
end

--- Subscribe to the transmitter battery voltage.
--- Shaped like a telemetry reading so a component can render either without
--- special casing, even though this source never depends on the link.
---@return AeroGridReading
function modelService:txVoltage()
  if self.txVoltageView then return self.txVoltageView end

  self.txVoltageView = self:add({
    name = modelService.TX_VOLTAGE_SOURCE,
    known = true,
    telemetry = false,
    available = false,
    fresh = false,
    stale = false,
    state = "unavailable",
    value = nil,
    kind = "number",
    unit = 1,
    unitText = "V",
    precision = 1,
    updatedAt = nil,
    age = nil,
    revision = 0,
  }, modelService.readTxVoltage)

  return self.txVoltageView
end

--- Refresh a bounded slice of the subscribed facets.
---@param now integer
function modelService:update(now)
  local facets = self.facets
  local total = #facets
  if total == 0 then return end

  local cursor = self.cursor
  if cursor > total then cursor = 1 end

  local cap = modelService.FACET_CAP
  if cap > total then cap = total end

  for _ = 1, cap do
    local facet = facets[cursor]
    cursor = cursor % total + 1
    if facet then facet.read(self, facet.state, now) end
  end

  self.cursor = cursor
end

--- Describe the subscribed model facets as diagnostic rows.
---@param rows table Reusable row array.
---@return integer count
function modelService:describe(rows)
  local row = self.support.row
  local index = 1
  local identity = self.identityView
  local mode = self.flightModeView
  local voltage = self.txVoltageView

  if identity then
    index = row(rows, index, "MODEL", identity.available
      and (identity.name ~= "" and identity.name or "-") or "N/A")
    index = row(rows, index, "IMAGE",
      identity.bitmap ~= "" and identity.bitmap or "-")
  end
  if mode then
    index = row(rows, index, "MODE", mode.available and mode.name or "N/A")
  end
  if voltage then
    index = row(rows, index, "TXV", voltage.available
      and string.format("%.1fV", voltage.value) or "N/A")
  end

  for timerIndex = 0, 2 do
    local timer = self.timers[timerIndex]
    if timer then
      index = row(rows, index, "T" .. tostring(timerIndex), timer.text)
    end
  end

  return index - 1
end

return modelService
