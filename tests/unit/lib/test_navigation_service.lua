-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local navigationService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/navigation_service.lua"))()

local function testPositionChecksAndDistance()
    assertions.assertEqual(navigationService.hasPosition(0.1, 0.2), true)
    assertions.assertEqual(navigationService.hasPosition(0, 0), false)

    local distance = navigationService.distanceBetween(0, 0, 0, 1)
    assert(distance > 0, "distance should be positive")

    local bearing = navigationService.bearingBetween(0, 0, 0, 1)
    assert(bearing >= 0 and bearing <= 360, "bearing should be in degrees")
end

local function testServiceCreatesRuntime()
    local env = services.environment({})
    local runtime = services.runtime(env)
    local service = navigationService.new(env, services, runtime)
    assert(type(service) == "table", "navigation service should construct")
end

local function run()
    testPositionChecksAndDistance()
    testServiceCreatesRuntime()
end

run()
