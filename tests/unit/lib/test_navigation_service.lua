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

local function captureFixture(homes)
    local arm = { available = true, fresh = true, value = false, updatedAt = 0 }
    local reading = {
        known = true,
        available = true,
        fresh = true,
        stale = false,
        updatedAt = 0,
        raw = { lat = 47, lon = 8, ["pilot-lat"] = 46, ["pilot-lon"] = 7, delay = 0 },
    }
    local runtime = {
        navigationHomes = homes,
        byId = {
            telemetry = {
                subscribe = function()
                    return reading
                end,
            },
            control = {
                switch = function(_, name)
                    assertions.assertEqual(name, "SFv")
                    return arm
                end,
            },
        },
    }
    local service = navigationService.new(services.environment({}), services, runtime)
    local view = service:subscribe("GPS", "SFv")
    local function update(now, armed)
        arm.value, arm.updatedAt = armed, now
        reading.updatedAt = now
        service:update(now)
    end
    return service, view, reading, arm, update
end

local function testFirstArmHome()
    local service, view, reading, _, update = captureFixture()
    update(0, false)
    assertions.assertEqual(view.home, false)
    assertions.assertEqual(view.homeStatus, "waiting")
    update(20, true)
    assertions.assertEqual(view.home, true)
    assertions.assertEqual(view.homeStatus, "captured")
    assertions.assertEqual(view.pilotLatitude, 47)
    assertions.assertEqual(view.pilotLongitude, 8)
    assertions.assertEqual(view.distance, 0)
    assert(service:subscribe("GPS", "SFv") == view, "identical panels must share captured home")
    local edge = service:subscribe("GPS")
    reading.raw.lat = 47.001
    reading.raw["pilot-lat"] = 45
    update(40, false)
    assert(view.distance > 100 and view.distance < 120)
    update(60, true)
    assertions.assertEqual(view.pilotLatitude, 47)
    assertions.assertEqual(edge.pilotLatitude, 45)
    assert(edge ~= view, "EdgeTX and first-arm homes must remain independent")
    reading.available, reading.fresh, reading.raw = false, false, nil
    update(80, false)
    assertions.assertEqual(view.home, true)
    assertions.assertEqual(view.distance, nil)
    reading.available, reading.fresh = true, true
    reading.raw = { lat = 47.002, lon = 8, delay = 0 }
    update(100, true)
    assertions.assertEqual(view.pilotLatitude, 47)
    assert(view.distance > 200 and view.distance < 230)

    local _, restored, _, _, restoredUpdate = captureFixture(service.homes)
    restoredUpdate(120, true)
    assertions.assertEqual(restored.pilotLatitude, 47)
    assertions.assertEqual(restored.homeStatus, "captured")
    local _, fresh, _, _, freshUpdate = captureFixture()
    freshUpdate(0, false)
    assertions.assertEqual(fresh.home, false, "new sessions must not inherit home")
end

local function testInvalidFirstArmDoesNotRetry()
    for _, invalidate in ipairs({
        function(reading)
            reading.raw.lat, reading.raw.lon = 0, 0
        end,
        function(reading)
            reading.stale = true
        end,
        function(reading)
            reading.fresh = false
        end,
        function(reading)
            reading.available = false
        end,
        function(reading)
            reading.raw = nil
        end,
        function(reading)
            reading.raw.delay = 2
        end,
        function(reading)
            reading.raw.delay = -1
        end,
        function(reading)
            reading.raw.delay = 0 / 0
        end,
    }) do
        local service, view, reading, _, update = captureFixture()
        update(0, false)
        invalidate(reading)
        update(20, true)
        assertions.assertEqual(view.home, false)
        assertions.assertEqual(view.homeStatus, "missed")
        reading.raw = { lat = 48, lon = 9, delay = 0 }
        reading.available, reading.fresh, reading.stale = true, true, false
        update(40, true)
        update(60, false)
        update(80, true)
        assertions.assertEqual(view.home, false)
        assertions.assertEqual(view.homeStatus, "missed")
        local _, restored, _, _, restoredUpdate = captureFixture(service.homes)
        restoredUpdate(100, false)
        restoredUpdate(120, true)
        assertions.assertEqual(restored.homeStatus, "missed")
        assertions.assertEqual(restored.home, false)
    end
end

local function testArmObservationAndFreshness()
    local service, view, reading, arm, update = captureFixture()
    update(0, true)
    assertions.assertEqual(view.home, false, "starting armed is not an arm transition")
    update(20, false)
    arm.available = false
    update(40, true)
    assertions.assertEqual(view.homeStatus, "switch-unavailable")
    arm.available = true
    update(60, true)
    assertions.assertEqual(view.home, false, "unknown must not stand in for disarmed")
    update(80, false)
    arm.value, arm.updatedAt = true, 100
    reading.updatedAt = -1
    service:update(100)
    assertions.assertEqual(view.homeStatus, "missed", "old cached coordinates cannot be captured")

    service, view, reading, arm, update = captureFixture()
    update(0, false)
    arm.value, arm.updatedAt = true, 20
    reading.updatedAt, reading.raw.delay = 0, 1
    service:update(20)
    assertions.assertEqual(view.homeStatus, "missed", "GPS delay and cache age must be combined")

    service, view, reading, arm, update = captureFixture()
    update(0, false)
    arm.value, arm.updatedAt = true, 20
    reading.updatedAt, reading.raw.delay = 20, 1
    service:update(20)
    assertions.assertEqual(view.homeStatus, "captured", "one-second boundary is inclusive")
end

local function run()
    testPositionChecksAndDistance()
    testServiceCreatesRuntime()
    testFirstArmHome()
    testInvalidFirstArmDoesNotRetry()
    testArmObservationAndFreshness()
end

run()
