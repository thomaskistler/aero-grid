-- SPDX-License-Identifier: GPL-2.0-only

--- GPS fix, pilot position, distance, and north-up home-to-model bearing.
---
--- An EdgeTX GPS source returns a table carrying the model position, the pilot
--- position EdgeTX recorded when the fix was first acquired, and the age of the
--- last update. This service normalizes that into a fix state, a distance, and
--- an absolute bearing measured from the home position toward the model.
---
--- The bearing is deliberately north-up. It is not aircraft heading and not
--- transmitter orientation, neither of which EdgeTX can supply, so nothing here
--- may be presented as a model-relative direction.

---@class AeroGridNavigation
---@field source string GPS source name as configured.
---@field known boolean The radio recognizes the source.
---@field fix boolean Valid model coordinates are available.
---@field home boolean Valid pilot coordinates are available.
---@field state "normal"|"stale"|"unavailable"
---@field latitude? number Model latitude in decimal degrees.
---@field longitude? number Model longitude in decimal degrees.
---@field pilotLatitude? number
---@field pilotLongitude? number
---@field distance? number Distance from home to the model.
---@field distanceUnit string Unit label for the distance.
---@field distanceSource "computed"|"source" Where the distance came from.
---@field bearing? number Initial bearing from home to model, 0 to 359 degrees.
---@field age? number Seconds since the fix was last updated.

local navigationService = {}
navigationService.__index = navigationService

--- Ticks of 10ms between updates. Telemetry GPS rarely exceeds a few hertz.
navigationService.INTERVAL = 20

--- Subscriptions refreshed per update. A dashboard has very few GPS panels,
--- and each update costs trigonometry, so this cap stays small.
navigationService.POLL_CAP = 2

--- Mean earth radius in metres, used for the great-circle distance.
navigationService.EARTH_RADIUS = 6371000

--- Coordinates closer than this to the null island are treated as no fix.
--- EdgeTX reports zero for both axes before a sensor has produced a position.
navigationService.NULL_EPSILON = 0.0000005

--- Create the service.
---@param env table Result of services.environment.
---@param support table The loaded lib/services.lua module.
---@param runtime table Registry, used to reach the telemetry service.
---@return table
function navigationService.new(env, support, runtime)
  return setmetatable({
    id = "navigation",
    interval = navigationService.INTERVAL,
    revision = 0,
    count = 0,
    due = 0,
    env = env,
    support = support,
    runtime = runtime,
    entries = {},
    cursor = 1,
    sources = {},
  }, navigationService)
end

--- Reach the telemetry service, which owns every source poll.
---@return table?
function navigationService:telemetry()
  return self.runtime and self.runtime.byId and self.runtime.byId.telemetry or nil
end

--- Report whether a coordinate pair is a usable position.
---@param latitude any
---@param longitude any
---@return boolean
function navigationService.hasPosition(latitude, longitude)
  if type(latitude) ~= "number" or type(longitude) ~= "number" then return false end
  if latitude ~= latitude or longitude ~= longitude then return false end
  if latitude > 90 or latitude < -90 then return false end
  if longitude > 180 or longitude < -180 then return false end

  local epsilon = navigationService.NULL_EPSILON
  local zeroLatitude = latitude < epsilon and latitude > -epsilon
  local zeroLongitude = longitude < epsilon and longitude > -epsilon
  return not (zeroLatitude and zeroLongitude)
end

--- Great-circle distance between two positions, in metres.
--- The haversine form is used because it stays accurate over the short
--- distances a model flies, where the simpler law of cosines loses precision.
---@param fromLatitude number
---@param fromLongitude number
---@param toLatitude number
---@param toLongitude number
---@return number metres
function navigationService.distanceBetween(fromLatitude, fromLongitude,
    toLatitude, toLongitude)
  local rad = math.rad
  local lat1 = rad(fromLatitude)
  local lat2 = rad(toLatitude)
  local deltaLat = lat2 - lat1
  local deltaLon = rad(toLongitude - fromLongitude)

  local sinLat = math.sin(deltaLat / 2)
  local sinLon = math.sin(deltaLon / 2)
  local a = sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLon * sinLon
  if a < 0 then a = 0 end
  if a > 1 then a = 1 end

  return 2 * navigationService.EARTH_RADIUS * math.asin(math.sqrt(a))
end

--- Initial bearing from the home position toward the model, in degrees.
--- Zero is true north and the value increases clockwise, which is what a
--- north-up compass arrow needs.
---@param fromLatitude number
---@param fromLongitude number
---@param toLatitude number
---@param toLongitude number
---@return number degrees
function navigationService.bearingBetween(fromLatitude, fromLongitude,
    toLatitude, toLongitude)
  local rad = math.rad
  local lat1 = rad(fromLatitude)
  local lat2 = rad(toLatitude)
  local deltaLon = rad(toLongitude - fromLongitude)

  local y = math.sin(deltaLon) * math.cos(lat2)
  local x = math.cos(lat1) * math.sin(lat2)
    - math.sin(lat1) * math.cos(lat2) * math.cos(deltaLon)

  local bearing = math.deg(math.atan(y, x)) % 360
  return bearing
end

--- Read one GPS subscription.
---@param entry table
---@param now integer
function navigationService:poll(entry, now)
  local state = entry.state
  local reading = entry.reading

  if type(reading) ~= "table" then
    state.state = "unavailable"
    return
  end

  state.known = reading.known
  state.age = reading.age

  local position = reading.raw
  if type(position) ~= "table" or not reading.available then
    state.fix = false
    state.home = false
    state.state = "unavailable"
    state.distance = nil
    state.bearing = nil
    return
  end

  local latitude = position.lat
  local longitude = position.lon
  local pilotLatitude = position["pilot-lat"]
  local pilotLongitude = position["pilot-lon"]

  state.fix = navigationService.hasPosition(latitude, longitude)
  state.home = navigationService.hasPosition(pilotLatitude, pilotLongitude)
  state.latitude = state.fix and latitude or nil
  state.longitude = state.fix and longitude or nil
  state.pilotLatitude = state.home and pilotLatitude or nil
  state.pilotLongitude = state.home and pilotLongitude or nil

  -- EdgeTX reports the age of the position itself, which is more precise than
  -- the poll time this service could otherwise infer.
  if type(position.delay) == "number" then state.age = position.delay end

  if not state.fix then
    state.state = reading.stale and "stale" or "unavailable"
    state.distance = nil
    state.bearing = nil
    return
  end

  state.state = reading.stale and "stale" or "normal"

  -- A configured native distance sensor wins: the receiver may compute it from
  -- data this service never sees.
  local native = entry.distanceReading
  if type(native) == "table" and native.available and type(native.value) == "number" then
    state.distance = native.value
    state.distanceUnit = native.unitText ~= "" and native.unitText or "m"
    state.distanceSource = "source"
  elseif state.home then
    state.distance = navigationService.distanceBetween(
      state.pilotLatitude, state.pilotLongitude, latitude, longitude)
    state.distanceUnit = "m"
    state.distanceSource = "computed"
  else
    state.distance = nil
  end

  -- A bearing without a home position would be meaningless, so it is withheld
  -- rather than guessed.
  if state.home then
    state.bearing = navigationService.bearingBetween(
      state.pilotLatitude, state.pilotLongitude, latitude, longitude)
  else
    state.bearing = nil
  end
end

--- Subscribe to a GPS source, optionally preferring a native distance sensor.
---@param name any GPS source name.
---@param distanceSource? string Native distance sensor name.
---@return AeroGridNavigation
function navigationService:subscribe(name, distanceSource)
  if type(name) ~= "string" or name == "" then
    if not self.noneView then
      self.noneView = self.support.snapshot({
        source = "",
        known = false,
        fix = false,
        home = false,
        state = "unavailable",
        distanceUnit = "m",
        distanceSource = "computed",
      })
    end
    return self.noneView
  end

  local existing = self.sources[name]
  if existing then return existing end

  local telemetry = self:telemetry()
  local entry = {
    state = {
      source = name,
      known = false,
      fix = false,
      home = false,
      state = "unavailable",
      latitude = nil,
      longitude = nil,
      pilotLatitude = nil,
      pilotLongitude = nil,
      distance = nil,
      distanceUnit = "m",
      distanceSource = "computed",
      bearing = nil,
      age = nil,
    },
    reading = telemetry and telemetry:subscribe(name) or nil,
  }

  if type(distanceSource) == "string" and distanceSource ~= "" and telemetry then
    entry.distanceReading = telemetry:subscribe(distanceSource)
  end

  entry.view = self.support.snapshot(entry.state)
  self.sources[name] = entry.view
  self.entries[#self.entries + 1] = entry
  self.count = self.count + 1
  return entry.view
end

--- Refresh a bounded slice of the subscriptions.
---@param now integer
function navigationService:update(now)
  local entries = self.entries
  local total = #entries
  if total == 0 then return end

  local cursor = self.cursor
  if cursor > total then cursor = 1 end

  local cap = navigationService.POLL_CAP
  if cap > total then cap = total end

  for _ = 1, cap do
    local entry = entries[cursor]
    cursor = cursor % total + 1
    if entry then self:poll(entry, now) end
  end

  self.cursor = cursor
end

--- Format a distance with a sensible unit, switching to kilometres when the
--- metre reading stops being readable at a glance.
---@param metres any
---@return string
function navigationService.formatDistance(metres)
  if type(metres) ~= "number" or metres ~= metres then return "--" end
  if metres >= 10000 then return string.format("%.1fkm", metres / 1000) end
  if metres >= 1000 then return string.format("%.2fkm", metres / 1000) end
  return string.format("%.0fm", metres)
end

--- Format a distance for display, honoring where it came from.
--- A native sensor keeps its own unit, because converting a reading whose unit
--- the receiver chose would invent precision this service does not have.
---@param view AeroGridNavigation
---@return string?
function navigationService.describeDistance(view)
  if type(view.distance) ~= "number" then return nil end
  if view.distanceSource == "source" then
    return string.format("%.1f%s", view.distance, view.distanceUnit)
  end
  return navigationService.formatDistance(view.distance)
end

--- Describe the subscribed GPS sources as diagnostic rows.
---@param rows table Reusable row array.
---@param view AeroGridNavigation? Subscription to describe.
---@return integer count
function navigationService:describe(rows, view)
  if type(view) ~= "table" then return 0 end

  local row = self.support.row
  local index = row(rows, 1, "GPS", view.source ~= "" and view.source or "-")
  index = row(rows, index, "FIX", view.fix and "YES" or "NO")
  index = row(rows, index, "HOME", view.home and "YES" or "NO")
  index = row(rows, index, "LAT",
    view.latitude and string.format("%.5f", view.latitude) or "-")
  index = row(rows, index, "LON",
    view.longitude and string.format("%.5f", view.longitude) or "-")
  index = row(rows, index, "DIST", view.distance
    and (navigationService.describeDistance(view) or "-") or "-")
  index = row(rows, index, "BRG",
    view.bearing and string.format("%.0f deg", view.bearing) or "-")

  return index - 1
end

return navigationService
