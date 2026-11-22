-- SPDX-License-Identifier: GPL-2.0-only

--- Publish AeroGrid-derived values into the EdgeTX telemetry sensor table.
--- One publisher serves every AeroGrid widget, so counters advance once
--- however many panels report the same link or position.
local publisher = {}
publisher.__index = publisher

local MAX_INTEGER = 2147483647
local SENSOR_LIMIT = 60
local TRACK_DEADBAND = 5

-- radio/src/dataconstants.h, TelemetryUnit in EdgeTX v2.12.4.
local VOLTS, METERS, DECIBELS, SECONDS = 1, 9, 17, 37

local specs = {
    VCel = { id = 0xAE01, unit = VOLTS, precision = 2 },
    Mrgn = { id = 0xAE02, unit = DECIBELS, precision = 0 },
    Drop = { id = 0xAE03, unit = SECONDS, precision = 0 },
    HDst = { id = 0xAE04, unit = METERS, precision = 0 },
    FDst = { id = 0xAE05, unit = METERS, precision = 0 },
}
publisher.SPECS = specs
local namesById = {}
for name, spec in pairs(specs) do
    namesById[spec.id] = name
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function publisher.new(env)
    local self = setmetatable({ env = env, sources = {}, counters = {} }, publisher)
    -- Weak, so a destroyed widget does not keep its claims.
    self.owners = setmetatable({}, { __mode = "v" })
    self:discover()
    return self
end

--- Whether `owner` publishes for `kind`. The first owner to ask keeps it, so
--- widgets reading different sources never feed the same sensor.
function publisher:owns(kind, owner)
    local current = self.owners[kind]
    if current == nil then
        self.owners[kind] = owner
        return true
    end
    return current == owner
end

--- Find the EdgeTX source of each published sensor by its protocol ID.
--- Labels are not used: users can rename any sensor.
function publisher:discover()
    local sources = {}
    self.sources = sources
    local getSensor, getFieldInfo = self.env.getSensor, self.env.getFieldInfo
    if not getSensor or not getFieldInfo then
        return
    end
    for index = 0, SENSOR_LIMIT - 1 do
        local sensor = getSensor(index)
        local name = type(sensor) == "table" and sensor.type == 0 and sensor.instance == 0 and namesById[sensor.id]
        if name then
            local info = getFieldInfo("telem" .. (index + 1))
            sources[name] = type(info) == "table" and info.id or nil
        end
    end
end

--- The current value of a published sensor, or nil when it has none.
function publisher:read(name)
    local source, read = self.sources[name], self.env.getSourceValue
    local value = source and read and read(source)
    return finite(value) and value or nil
end

--- Write a sensor. EdgeTX only creates one while Discover new sensors runs and
--- drops the value of the creating call, so that call is repeated.
function publisher:publish(name, value)
    local spec, write = specs[name], self.env.setTelemetryValue
    if not write or not finite(value) then
        return
    end
    local scaled = math.floor(value * 10 ^ spec.precision + 0.5)
    if scaled > MAX_INTEGER or scaled < -MAX_INTEGER then
        return
    end
    if write(spec.id, 0, 0, scaled, spec.unit, spec.precision, name) == true then
        write(spec.id, 0, 0, scaled, spec.unit, spec.precision, name)
        self:discover()
    end
end

--- A counter accumulated exactly here; the sensor only mirrors it. A sensor
--- that loses its value was cleared by an EdgeTX telemetry reset.
local function counter(self, name)
    local current = self:read(name)
    local state = self.counters[name]
    local reset = false
    if not state then
        state = { value = current or 0 }
        self.counters[name] = state
    elseif current == nil and state.seen then
        state.value, reset = 0, true
    end
    state.seen = current ~= nil
    return state, reset
end

--- Accumulate seconds without a link, once a link has been seen.
function publisher:drop(now, linkLive)
    local state, reset = counter(self, "Drop")
    if reset then
        state.linkSeen, state.lastAt = false, nil
    elseif state.linkSeen == nil then
        state.linkSeen = state.seen
    end
    if linkLive then
        state.linkSeen = true
    elseif state.linkSeen and state.lastAt and now > state.lastAt then
        state.value = state.value + (now - state.lastAt) / 100
    end
    state.lastAt = now
    if state.linkSeen then
        self:publish("Drop", state.value)
    end
    return state.value
end

--- Accumulate the distance flown between positions at least 5 m apart, so GPS
--- jitter at rest does not add up.
function publisher:track(latitude, longitude, measure)
    local state = counter(self, "FDst")
    if state.latitude == nil then
        state.latitude, state.longitude = latitude, longitude
    else
        local segment = measure(state.latitude, state.longitude, latitude, longitude)
        if finite(segment) and segment >= TRACK_DEADBAND then
            state.value = state.value + segment
            state.latitude, state.longitude = latitude, longitude
        end
    end
    self:publish("FDst", state.value)
    return state.value
end

return publisher
