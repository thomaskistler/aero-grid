-- SPDX-License-Identifier: GPL-2.0-only

--- Publish AeroGrid-derived values into the EdgeTX telemetry sensor table.
local publisher = { RUNTIME_API = 1 }
publisher.__index = publisher

local MAX_INTEGER = 2147483647
local SENSOR_LIMIT = 60

-- radio/src/dataconstants.h, TelemetryUnit in EdgeTX v2.12.4.
publisher.UNITS = {
    VOLTS = 1,
    METERS = 9,
    DECIBELS = 17,
    SECONDS = 37,
}
local units = publisher.UNITS

local specs = {
    VCel = { id = 0xAE01, name = "VCel", unit = units.VOLTS, precision = 2 },
    Mrgn = { id = 0xAE02, name = "Mrgn", unit = units.DECIBELS, precision = 0 },
    Drop = { id = 0xAE03, name = "Drop", unit = units.SECONDS, precision = 0 },
    HDst = { id = 0xAE04, name = "HDst", unit = units.METERS, precision = 0 },
    FDst = { id = 0xAE05, name = "FDst", unit = units.METERS, precision = 0 },
}
publisher.SPECS = specs
local specsById = {}
for name, spec in pairs(specs) do
    specsById[spec.id] = { name = name, instance = 0 }
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function rounded(value)
    return value >= 0 and math.floor(value + 0.5) or math.ceil(value - 0.5)
end

function publisher.new(env, runtime)
    local self = setmetatable({
        env = env,
        runtime = runtime,
        sensors = {},
        counters = {},
        owners = nil,
        resolveAfter = 0,
    }, publisher)
    self:discover()
    return self
end

local function sensorState(self, name)
    local state = self.sensors[name]
    if not state then
        state = {}
        self.sensors[name] = state
    end
    return state
end

function publisher:discover(force)
    local now = self.env.getTime and self.env.getTime() or 0
    if not force and now < self.resolveAfter then
        return
    end
    self.resolveAfter = now + 200

    local getSensor = self.env.getSensor
    local getFieldInfo = self.env.getFieldInfo
    if not getSensor or not getFieldInfo then
        return
    end
    for index = 0, SENSOR_LIMIT - 1 do
        local sensor = getSensor(index)
        local definition = type(sensor) == "table" and sensor.type == 0 and specsById[sensor.id] or nil
        if definition and sensor.instance == definition.instance then
            local info = getFieldInfo("telem" .. (index + 1))
            if type(info) == "table" and type(info.id) == "number" then
                local state = sensorState(self, definition.name)
                if state.source == nil then
                    state.source = info.id
                end
            end
        end
    end
end

--- Resolve a Lua sensor by its protocol ID and remember the EdgeTX source.
--- Label matches are deliberately avoided: users can rename any sensor.
function publisher:resolve(name, force)
    local state = sensorState(self, name)
    if state.source == nil then
        self:discover(force)
    end
    return state.source
end

--- Read one published value by its resolved EdgeTX source.
function publisher:read(name)
    local source = self:resolve(name)
    local read = source ~= nil and self.env.getSourceValue or nil
    if not read then
        return nil
    end
    local value = read(source)
    return finite(value) and value or nil
end

--- Write a named sensor. EdgeTX ignores the creation call's value, so repeat
--- only a call that created a sensor.
function publisher:publish(name, value)
    local spec = specs[name]
    local write = self.env.setTelemetryValue
    if not spec or not write or not finite(value) then
        return false
    end

    local scaled = rounded(value * (10 ^ spec.precision))
    if scaled > MAX_INTEGER or scaled < -MAX_INTEGER then
        return false
    end

    local created = write(spec.id, 0, 0, scaled, spec.unit, spec.precision, spec.name)
    if created == true then
        write(spec.id, 0, 0, scaled, spec.unit, spec.precision, spec.name)
        self:resolve(name, true)
    else
        self:resolve(name)
    end
    return true
end

--- Whether one live panel is the first of its type in layout order.
function publisher:refreshOwners()
    local host = self.runtime and self.runtime.host
    local panels = host and host.panels
    local revision = host and host.panelOrderRevision
    if self.owners ~= nil and self.ownerRevision == revision then
        return
    end
    local owners = {}
    self.owners = owners
    self.ownerRevision = revision
    if type(panels) ~= "table" then
        return
    end
    for _, entry in ipairs(panels) do
        if entry and not entry.failed and not entry.preview and entry.placement then
            owners[entry.placement.type] = owners[entry.placement.type] or entry.placement.id
        end
    end
end

function publisher:owns(placementId, panelType)
    local owners = self.owners
    if not owners then
        self:refreshOwners()
        owners = self.owners
    end
    return owners[panelType] == placementId
end

function publisher:publishes(panelType)
    return panelType == "rx-battery" or panelType == "link-status" or panelType == "navigation"
end

local function counterState(self, name)
    local state = self.counters[name]
    if not state then
        local current = self:read(name)
        state = {
            value = current or 0,
            seen = current ~= nil,
            observed = current,
            lastAt = nil,
        }
        if name == "Drop" then
            state.linkSeen = current ~= nil
        end
        self.counters[name] = state
    end
    return state
end

local function mergeCounter(self, name, delta)
    local state = counterState(self, name)
    local current = self:read(name)
    local reset = current == nil and state.seen
    local republishedReset = current ~= nil and state.observed ~= nil and current < state.observed
    if reset or republishedReset then
        state.value = 0
        state.seen = current ~= nil
        state.lastAt = nil
        if name == "Drop" then
            state.linkSeen = false
        end
        delta = republishedReset and 0 or delta
    elseif current ~= nil then
        state.seen = true
    end
    delta = finite(delta) and delta > 0 and delta or 0
    state.value = math.min(MAX_INTEGER, math.max(state.value + delta, current or 0))
    state.observed = current
    return state
end

--- Advance Drop only after a link has been observed since the last reset.
function publisher:drop(now, linkLive)
    local state = counterState(self, "Drop")
    local current = self:read("Drop")
    local reset = current == nil and state.seen
    local republishedReset = current ~= nil and state.observed ~= nil and current < state.observed
    if reset or republishedReset then
        state.value = 0
        state.seen = current ~= nil
        state.lastAt = nil
        state.linkSeen = current ~= nil
    elseif current ~= nil then
        state.seen = true
        state.linkSeen = true
    end

    if linkLive == true then
        state.linkSeen = true
    end
    local increment = 0
    if
        not republishedReset
        and state.linkSeen
        and not linkLive
        and type(state.lastAt) == "number"
        and now >= state.lastAt
    then
        increment = (now - state.lastAt) / 100
    end
    increment = finite(increment) and increment > 0 and increment or 0
    state.value = math.min(MAX_INTEGER, math.max(state.value + increment, current or 0))
    state.lastAt = now

    if state.linkSeen then
        self:publish("Drop", state.value)
        state.seen = self:read("Drop") ~= nil
    end
    state.observed = self:read("Drop")
    return state.value
end

function publisher:distance(delta)
    local state = mergeCounter(self, "FDst", delta)
    self:publish("FDst", state.value)
    state.observed = self:read("FDst")
    state.seen = state.observed ~= nil
    return state.value
end

return publisher
