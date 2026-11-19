-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local publisher = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/telemetry_publisher.lua"))()

local function firmware()
    local state = { allowNewSensors = false, now = 0, sensors = {}, values = {} }
    local function indexFor(id, instance)
        for index = 0, 59 do
            local sensor = state.sensors[index]
            if sensor and sensor.id == id and sensor.instance == instance then
                return index
            end
        end
        return nil
    end
    local function emptyIndex()
        for index = 0, 59 do
            if state.sensors[index] == nil then
                return index
            end
        end
        return nil
    end
    state.env = {
        getTime = function()
            return state.now
        end,
        getSensor = function(index)
            return state.sensors[index]
        end,
        getFieldInfo = function(name)
            local index = tonumber(string.sub(name, 6))
            if index and state.sensors[index - 1] then
                return { id = 1000 + index - 1 }
            end
        end,
        getSourceValue = function(source)
            return state.values[source]
        end,
        setTelemetryValue = function(id, _, instance, value, unit, precision, name)
            local index = indexFor(id, instance)
            if index ~= nil then
                state.values[1000 + index] = value / (10 ^ precision)
                return false
            end
            if not state.allowNewSensors then
                return false
            end
            index = emptyIndex()
            if index == nil then
                return false
            end
            state.sensors[index] = {
                type = 0,
                id = id,
                instance = instance,
                name = name,
                unit = unit,
                prec = precision,
            }
            return true
        end,
    }
    function state.sensor(name)
        local spec = publisher.SPECS[name]
        local index = indexFor(spec.id, 0)
        return index ~= nil and state.sensors[index] or nil
    end
    function state.value(name)
        local spec = publisher.SPECS[name]
        local index = indexFor(spec.id, 0)
        return index ~= nil and state.values[1000 + index] or nil
    end
    function state.resetTelemetry()
        state.values = {}
    end
    return state
end

local function flat(_, fromLongitude, _, toLongitude)
    return math.abs(toLongitude - fromLongitude)
end

local function testCreationNeedsDiscovery()
    local radio = firmware()
    local service = publisher.new(radio.env)
    service:publish("VCel", 3.821)
    assertions.assertEqual(radio.sensor("VCel"), nil, "only Discover new sensors creates a sensor")

    radio.allowNewSensors = true
    service:publish("VCel", 3.821)
    service:publish("Mrgn", -12.4)
    assertions.assertEqual(radio.value("VCel"), 3.82, "the creating call's value is written again")
    assertions.assertEqual(radio.sensor("VCel").prec, 2)
    assertions.assertEqual(radio.value("Mrgn"), -12)
    assertions.assertEqual(service:read("VCel"), 3.82, "a created sensor is found by its ID")

    radio.sensor("VCel").name = "Cell"
    assertions.assertEqual(publisher.new(radio.env):read("VCel"), 3.82, "renamed sensors are still found")
end

local function testDropCountsExactly()
    local radio = firmware()
    radio.allowNewSensors = true
    local service = publisher.new(radio.env)
    service:drop(0, false)
    assertions.assertEqual(radio.value("Drop"), nil, "no Drop before a link was seen")
    service:drop(10, true)
    for now = 30, 6030, 20 do
        service:drop(now, false)
        service:drop(now, false)
    end
    assertions.assertEqual(radio.value("Drop"), 60, "rounded sensor values and repeat callers do not inflate Drop")
    service:drop(6100, true)
    service:drop(6200, false)
    assertions.assertEqual(radio.value("Drop"), 61)
end

local function testTelemetryResetClearsCounters()
    local radio = firmware()
    radio.allowNewSensors = true
    local service = publisher.new(radio.env)
    service:drop(0, true)
    service:drop(500, false)
    service:track(0, 0, flat)
    service:track(0, 20, flat)
    assertions.assertEqual(radio.value("Drop"), 5)
    assertions.assertEqual(radio.value("FDst"), 20)

    radio.resetTelemetry()
    service:drop(600, false)
    assertions.assertEqual(radio.value("Drop"), nil, "after a reset Drop waits for a link again")
    service:drop(700, true)
    service:drop(800, false)
    assertions.assertEqual(radio.value("Drop"), 1)
    service:track(0, 30, flat)
    assertions.assertEqual(radio.value("FDst"), 10)

    local reloaded = publisher.new(radio.env)
    reloaded:drop(900, false)
    reloaded:drop(1000, false)
    assertions.assertEqual(radio.value("Drop"), 2, "a reloaded widget continues from the published value")
end

local function testTrackDeadband()
    local radio = firmware()
    radio.allowNewSensors = true
    local service = publisher.new(radio.env)
    service:track(0, 0, flat)
    for step = 1, 100 do
        service:track(0, step % 2 * 4, flat)
    end
    assertions.assertEqual(radio.value("FDst"), 0, "jitter under 5 m is ignored")
    for step = 1, 1000 do
        service:track(0, step * 7.3, flat)
    end
    assertions.assertEqual(radio.value("FDst"), 7300)
end

local function testOneOwnerPerType()
    local service = publisher.new(firmware().env)
    local first, second = {}, {}
    assert(service:owns("navigation", first))
    assert(not service:owns("navigation", second), "a second widget does not publish a claimed type")
    assert(service:owns("navigation", first))
    assert(service:owns("link-status", second))
    first = nil
    collectgarbage()
    assert(service:owns("navigation", second), "a destroyed widget releases its claims")
end

local function run()
    testCreationNeedsDiscovery()
    testDropCountsExactly()
    testTelemetryResetClearsCounters()
    testTrackDeadband()
    testOneOwnerPerType()
end

run()
