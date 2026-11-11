-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local extremaService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/extrema_service.lua"))()
local armedService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/armed_service.lua"))()

local function testExtremaServiceCreatesFlightState()
    local env = services.environment({})
    local runtime = services.runtime(env)
    runtime.byId.control = {
        switch = function()
            return { available = false }
        end,
    }
    runtime.byId.armed = armedService.new(env, services, runtime)
    local service = extremaService.new(env, services, runtime)
    local flight = service:flight("L01")
    assertions.assertEqual(type(flight), "table")
    assertions.assertEqual(flight.configured, true)
end

local function testSessionExtremaCreatesTrack()
    local env = services.environment({})
    local runtime = services.runtime(env)
    runtime.byId.armed = armedService.new(env, services, runtime)
    local service = extremaService.new(env, services, runtime)
    local track = service:sessionExtrema("RxBt")
    assertions.assertEqual(type(track), "table")
    assertions.assertEqual(track.name, "RxBt")
end

local function run()
    testExtremaServiceCreatesFlightState()
    testSessionExtremaCreatesTrack()
    local reading = { fresh = true, value = 25, updatedAt = 10 }
    local runtime = services.runtime({})
    runtime.byId.telemetry = {
        subscribe = function()
            return reading
        end,
    }
    local arm = { key = "test", configured = true, fresh = true, value = true, updatedAt = 20 }
    runtime.byId.armed = {
        state = function()
            return arm
        end,
    }
    local service = extremaService.new({}, services, runtime)
    local track = service:sessionExtrema("RQly")
    service:update(20)
    assert(track.min == 25)
    local index = 1
    repeat
        index = service:resetSession(20, index)
    until not index
    service:update(20)
    assert(not track.available, "a reset must not resample a cached pre-reset reading")
    reading.value, reading.updatedAt = 80, 21
    arm.updatedAt = 21
    service:update(21)
    assert(track.available and track.min == 80 and track.max == 80)
end

run()
