-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local extremaService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/extrema_service.lua"))()

local function testExtremaServiceCreatesFlightState()
    local env = services.environment({})
    local runtime = services.runtime(env)
    local service = extremaService.new(env, services, runtime)
    local flight = service:flight("arm")
    assertions.assertEqual(type(flight), "table")
    assertions.assertEqual(flight.configured, true)
end

local function testSessionExtremaCreatesTrack()
    local env = services.environment({})
    local runtime = services.runtime(env)
    local service = extremaService.new(env, services, runtime)
    local track = service:sessionExtrema("RxBt")
    assertions.assertEqual(type(track), "table")
    assertions.assertEqual(track.name, "RxBt")
end

local function run()
    testExtremaServiceCreatesFlightState()
    testSessionExtremaCreatesTrack()
end

run()
