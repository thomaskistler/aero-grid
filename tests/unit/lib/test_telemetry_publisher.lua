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
    function state.rename(name, renamed)
        state.sensor(name).name = renamed
    end
    return state
end

local function runtime()
    return { host = { panels = {} } }
end

local function testUnitsAndDiscovery()
    assertions.assertEqual(publisher.UNITS.VOLTS, 1)
    assertions.assertEqual(publisher.UNITS.METERS, 9)
    assertions.assertEqual(publisher.UNITS.DECIBELS, 17)
    assertions.assertEqual(publisher.UNITS.SECONDS, 37)

    local radio = firmware()
    local service = publisher.new(radio.env, runtime())
    service:publish("VCel", 3.817)
    assertions.assertEqual(radio.sensor("VCel"), nil, "Discover new sensors controls creation")

    radio.allowNewSensors = true
    service:publish("VCel", 3.817)
    assertions.assertEqual(radio.sensor("VCel").unit, publisher.UNITS.VOLTS)
    assertions.assertEqual(radio.sensor("VCel").prec, 2)
    assertions.assertEqual(radio.value("VCel"), 3.82)
    service:publish("Mrgn", -12)
    assertions.assertEqual(radio.sensor("Mrgn").unit, publisher.UNITS.DECIBELS)
    assertions.assertEqual(radio.value("Mrgn"), -12)
    service:publish("Drop", 0)
    service:publish("HDst", 0)
    service:publish("FDst", 0)
    assertions.assertEqual(radio.sensor("Drop").unit, publisher.UNITS.SECONDS)
    assertions.assertEqual(radio.sensor("HDst").unit, publisher.UNITS.METERS)
    assertions.assertEqual(radio.sensor("FDst").unit, publisher.UNITS.METERS)
end

local function testIdResolutionSurvivesRename()
    local radio = firmware()
    radio.allowNewSensors = true
    local service = publisher.new(radio.env, runtime())
    service:publish("Drop", 0)
    radio.rename("Drop", "Dwn")
    radio.resetTelemetry()

    local value = { current = nil }
    local original = radio.env.getSourceValue
    radio.env.getSourceValue = function(source)
        value.current = source
        return original(source)
    end
    service:drop(0, true)
    service:drop(100, false)
    service:publish("Drop", 1)
    assertions.assertEqual(value.current, 1000, "the resolved EdgeTX source is used, not the renamed label")
end

local function testConcurrentCountersAndDropGate()
    local radio = firmware()
    radio.allowNewSensors = true
    local first = publisher.new(radio.env, runtime())
    local second = publisher.new(radio.env, runtime())

    radio.now = 0
    first:drop(0, false)
    second:drop(0, false)
    assertions.assertEqual(radio.value("Drop"), nil, "waiting receivers do not create or advance Drop")
    radio.now = 100
    first:drop(100, true)
    second:drop(100, true)
    radio.now = 6100
    first:drop(6100, false)
    second:drop(6100, false)
    assertions.assertEqual(radio.value("Drop"), 60, "concurrent publishers merge rather than double count")
    radio.now = 6200
    assertions.assertEqual(first:drop(6200, false), 61)
    assertions.assertEqual(second:drop(6200, false), 61)

    radio.resetTelemetry()
    assertions.assertEqual(radio.value("Drop"), nil)
    radio.now = 6300
    assertions.assertEqual(first:drop(6300, false), 0, "the first missing read resets Drop")
    assertions.assertEqual(second:drop(6300, false), 0)
    radio.now = 6400
    first:drop(6400, true)
    second:drop(6400, true)
    radio.now = 6500
    first:drop(6500, false)
    assertions.assertEqual(second:drop(6500, false), 1, "counting restarts only after another live link")

    first:distance(0)
    second:distance(0)
    first:distance(25)
    second:distance(25)
    assertions.assertEqual(radio.value("FDst"), 25, "concurrent distance publishers merge")
    radio.resetTelemetry()
    assertions.assertEqual(first:distance(10), 10)
    assertions.assertEqual(second:distance(10), 10)
end

local function testDynamicOwnership()
    local context = runtime()
    local service = publisher.new(firmware().env, context)
    local first = {
        placement = { id = "first", type = "link-status" },
    }
    local second = {
        placement = { id = "second", type = "link-status" },
    }
    context.host.panels = { first, second }
    context.host.panelOrderRevision = 1
    service:refreshOwners()
    assert(service:owns("first", "link-status"))
    assert(not service:owns("second", "link-status"))

    context.host.panels = { second, first }
    context.host.panelOrderRevision = 2
    service:refreshOwners()
    assert(service:owns("second", "link-status"), "App-mode rebuild order is queried live")
    first.failed = true
    context.host.panelOrderRevision = 3
    service:refreshOwners()
    assert(service:owns("second", "link-status"))
    first.failed = nil
    first.preview = true
    context.host.panelOrderRevision = 4
    service:refreshOwners()
    assert(service:owns("second", "link-status"), "editor previews do not own publication")
    context.host.panels = { second }
    context.host.panelOrderRevision = 5
    service:refreshOwners()
    assert(service:owns("second", "link-status"), "deleting the first panel transfers ownership")
end

local function run()
    testUnitsAndDiscovery()
    testIdResolutionSurvivesRename()
    testConcurrentCountersAndDropGate()
    testDynamicOwnership()
end

run()
