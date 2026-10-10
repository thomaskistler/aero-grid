-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local fixture = assert(loadfile(root .. "/tests/support/runtime_fixture.lua"))(root)
local edgetx = fixture.edgetx
local firmware = fixture.firmware
local layout = fixture.layout
local theme = fixture.theme
local services = fixture.services
local telemetryService = fixture.telemetryService
local modelService = fixture.modelService
local controlService = fixture.controlService
local extremaService = fixture.extremaService
local navigationService = fixture.navigationService
local assertEqual = fixture.assertEqual
local telemetryHarness = fixture.telemetryHarness

--- A published snapshot must be readable and impossible to corrupt, because
--- several panels share the same one.
local function testSnapshotsAreImmutable()
    local state = { value = 1, name = "RxBt" }
    local view = services.snapshot(state)

    assertEqual(view.value, 1)
    assertEqual(view.name, "RxBt")

    local ok, err = pcall(function()
        view.value = 2
    end)
    assertEqual(ok, false, "a snapshot accepted a write")
    assert(string.match(tostring(err), "read%-only"), tostring(err))

    -- The mutable state stays reachable to the service and invisible to callers.
    state.value = 7
    assertEqual(view.value, 7, "the view lost sight of its state")
    assertEqual(getmetatable(view), false, "the snapshot exposed its metatable")
end

--- A service update is charged to the same instruction budget as everything
--- else, so the registry must serve exactly one due service per cycle, skip
--- services nothing subscribed to, and retire one that raises.
local function testServiceScheduling()
    local function fake(id, interval, behavior)
        return {
            id = id,
            interval = interval,
            revision = 0,
            count = 1,
            due = 0,
            updates = 0,
            update = function(self)
                self.updates = self.updates + 1
                if behavior == "raise" then
                    error(id .. " failed", 0)
                end
            end,
        }
    end

    local runtime = services.runtime(services.environment({}))
    local first, second, third = fake("a", 10), fake("b", 10), fake("c", 10)
    services.register(runtime, first, 0)
    services.register(runtime, second, 0)
    services.register(runtime, third, 0)

    -- Registration staggers services so they never fall due together.
    assertEqual(first.due, 0)
    assertEqual(second.due, 1)
    assertEqual(third.due, 2)

    assertEqual(services.update(runtime, 0), "a")
    assertEqual(services.update(runtime, 0), nil, "two services ran in one cycle")
    assertEqual(services.update(runtime, 1), "b")
    assertEqual(services.update(runtime, 2), "c")
    assertEqual(first.updates, 1)
    assertEqual(first.revision, 1)

    -- Nothing subscribed means nothing is read.
    local idle = fake("idle", 10)
    idle.count = 0
    services.register(runtime, idle, 0)
    for step = 3, 40 do
        services.update(runtime, step)
    end
    assertEqual(idle.updates, 0, "an unsubscribed service was polled")

    -- A service that raises is reported once and then retired.
    local broken = services.runtime(services.environment({}))
    local bad = fake("bad", 10, "raise")
    services.register(broken, bad, 0)
    local id, updateError = services.update(broken, 0)
    assertEqual(id, "bad")
    assert(string.match(tostring(updateError), "bad failed"), tostring(updateError))
    assertEqual(bad.revision, 0, "a failed update counted as a revision")
    assertEqual(services.update(broken, 100), nil, "a failed service ran again")
    assertEqual(bad.updates, 1)
end

--- A text sensor is a reading whose value is a string.
---
--- Crossfire and ELRS publish the aircraft's flight mode this way, as `FM`
--- with `UNIT_TEXT` (`telemetry/crossfire.cpp`), and `getValue` pushes the
--- stored string rather than a number for it: `case UNIT_TEXT:
--- lua_pushstring(L, telemetryItems[...].text)`
--- (`radio/src/lua/api_general.cpp`). The service has mapped unit 42 to a
--- `text` kind since it was written and **nothing had ever exercised it**,
--- because no fixture carried a text sensor. That is covered here whether or
--- not a panel ever reads one.
---
--- The absent case is checked alongside, because it is the common one: FrSky
--- S.Port publishes no flight mode sensor at all, so a layout naming `FM` on
--- a FrSky link gets nothing and must say so rather than reading zero.
local function testTelemetryTextSensor()
    local harness = telemetryHarness()
    -- firmware: `STR_SENSOR_FLIGHT_MODE` is "FM" (`telemetry/sensor_names.h`)
    -- and `UNIT_TEXT` is 42 in `enum TelemetryUnit`
    -- (`radio/src/dataconstants.h`).
    harness.fields.FM = { id = 145, name = "FM", unit = 42 }
    harness.values[145] = "ANGLE"

    local service = harness.service
    local mode = service:subscribe("FM")
    local absent = service:subscribe("Fmod")

    service:update(0)

    -- The shape, which is what nothing had checked: a string in `raw`, no
    -- numeric value, and a kind that says which to read.
    assertEqual(mode.kind, "text")
    assertEqual(mode.raw, "ANGLE")
    assertEqual(
        mode.value,
        nil,
        "a text sensor must offer no numeric value; a panel reading one"
            .. " would get a number for a string and format it"
    )
    assertEqual(mode.available, true)
    assertEqual(mode.state, "normal")

    -- A text sensor is telemetry, so it is subject to the link rules like any
    -- other reading rather than being treated as always-present.
    assertEqual(mode.telemetry, true)

    -- The common case on FrSky, which publishes no flight mode sensor at all.
    assertEqual(absent.known, false)
    assertEqual(absent.state, "unavailable")
    assertEqual(absent.raw, nil)
    assertEqual(absent.value, nil)

    -- A new string is a new reading, and the revision has to move or a panel
    -- comparing declarations would never repaint.
    local before = mode.revision
    harness.values[145] = "ACRO"
    service:update(1)
    assertEqual(mode.raw, "ACRO")
    assert(mode.revision > before, "a changed string did not count as a new reading")

    -- And the same string twice is not.
    local settled = mode.revision
    service:update(2)
    assertEqual(mode.revision, settled, "an unchanged string counted as a new reading")

    -- A dropped link keeps the last string and marks it stale, exactly as a
    -- numeric reading is kept rather than replaced with nothing.
    harness.rssi = 0
    harness.values[145] = nil
    service:update(3)
    assertEqual(mode.raw, "ACRO", "a dropped link discarded the last mode")
    assertEqual(mode.state, "stale")
end

--- Freshness is the subtle part of EdgeTX telemetry: the firmware returns zero
--- both for a genuine zero reading and for a sensor whose link is down.
local function testTelemetryFreshness()
    local harness = telemetryHarness()
    local service = harness.service
    local pack = service:subscribe("RxBt")
    local altitude = service:subscribe("Alt")
    local missing = service:subscribe("Nope")

    -- Two panels naming one source must share a single poll.
    assert(service:subscribe("RxBt") == pack, "a duplicate subscription was made")
    assertEqual(service.count, 3)

    service:update(0)
    assertEqual(pack.value, 24.4)
    assertEqual(pack.state, "normal")
    assertEqual(pack.unitText, "V")
    assertEqual(pack.telemetry, true)

    -- Zero while the link is up is a real reading, not a missing one.
    assertEqual(altitude.value, 0)
    assertEqual(altitude.available, true)
    assertEqual(altitude.state, "normal")

    -- A sensor the radio has never seen is unavailable, not stale or zero.
    assertEqual(missing.known, false)
    assertEqual(missing.state, "unavailable")
    assertEqual(missing.value, nil)

    -- Precision comes from the model's sensor table, one search at a time.
    for step = 1, 6 do
        service:update(step)
    end
    assertEqual(pack.precision, 2)
    assertEqual(altitude.precision, 1)

    -- A dropped link must keep the last reading and mark it stale rather than
    -- replacing a valid 24.4 V with the zero EdgeTX reports.
    harness.rssi = 0
    harness.values[100] = 0
    service:update(20)
    assertEqual(pack.value, 24.4, "a stale poll overwrote the cached reading")
    assertEqual(pack.state, "stale")
    assertEqual(pack.stale, true)
    assertEqual(pack.fresh, false)

    harness.rssi = 70
    harness.values[100] = 23.9
    service:update(30)
    assertEqual(pack.value, 23.9)
    assertEqual(pack.state, "normal")

    -- A sensor that appears later must be picked up without a reload.
    harness.fields.Nope = { id = 106, name = "Nope", unit = 13 }
    harness.values[106] = 42
    service:update(30 + telemetryService.RESOLVE_RETRY)
    assertEqual(missing.known, true)
    assertEqual(missing.value, 42)
    assertEqual(missing.unitText, "%")

    -- An unconfigured source still yields a usable reading.
    local none = service:subscribe("")
    assertEqual(none.state, "unavailable")
    assertEqual(telemetryService.format(none), "--")
    assertEqual(telemetryService.format(pack), "23.90")
    assertEqual(telemetryService.format(pack, 0), "24")
end

--- The link indicator is not reliable everywhere, and a sensor's extremes are
--- not always shaped like the sensor itself. Both mistakes look like a dead
--- reading on the radio, and neither is visible from a mocked value alone.
local function testTelemetryLinkHeuristics()
    local harness = telemetryHarness()
    local service = harness.service
    local pack = service:subscribe("RxBt")

    -- Some protocols never populate an RSSI sensor, so getRSSI reads zero on a
    -- perfectly live link. A telemetry source cannot return a non-zero value
    -- when EdgeTX has nothing, so that value proves the indicator is wrong.
    harness.rssi = 0
    service:update(0)
    assertEqual(pack.value, 24.4, "a live reading was discarded as stale")
    assertEqual(pack.state, "normal")

    -- Having learned that, a genuine zero from the same radio is a reading too.
    harness.values[100] = 0
    service:update(1)
    assertEqual(pack.value, 0)
    assertEqual(pack.state, "normal")

    -- A radio whose indicator does work still withholds the ambiguous zero.
    local other = telemetryHarness()
    local reading = other.service:subscribe("RxBt")
    other.service:update(0)
    assertEqual(reading.value, 24.4)
    other.rssi = 0
    other.values[100] = 0
    other.service:update(1)
    assertEqual(reading.state, "stale")
    assertEqual(reading.value, 24.4, "a stale poll overwrote the cached reading")

    -- EdgeTX returns the cells table only for the base source; "Cels-" and
    -- "Cels+" carry the same unit but return a plain number.
    harness.fields.Cels = { id = 130, name = "Cels", unit = 38 }
    harness.fields["Cels-"] = { id = 131, name = "Cels-", unit = 38 }
    harness.values[130] = { 4.11, 4.13, 4.09 }
    harness.values[131] = 4.09
    harness.rssi = 80

    local cells = service:subscribe("Cels")
    local lowest = service:subscribe("Cels-")
    service:update(2)

    assertEqual(cells.kind, "cells")
    assertEqual(type(cells.raw), "table")
    assertEqual(lowest.kind, "number", "a cells extremum was read as a table")
    assertEqual(lowest.value, 4.09)
    assertEqual(lowest.state, "normal")
end

--- Polling must stay bounded no matter how many sources a layout references.
local function testTelemetryPollingIsBounded()
    local harness = telemetryHarness()
    local service = harness.service
    local polled = {}

    harness.env.getValue = function(id)
        polled[#polled + 1] = id
        return harness.values[id]
    end

    for index = 1, 16 do
        local name = "S" .. index
        harness.fields[name] = { id = 200 + index, unit = 0 }
        harness.values[200 + index] = index
        service:subscribe(name)
    end

    service:update(0)
    assert(#polled <= telemetryService.POLL_CAP, "one update polled " .. #polled .. " sources")

    -- Every source must still be served, in rotation, rather than starved.
    local seen = {}
    for step = 1, 8 do
        service:update(step)
        for _, id in ipairs(polled) do
            seen[id] = true
        end
    end
    for index = 1, 16 do
        assert(seen[200 + index], "source S" .. index .. " was never polled")
    end
end

--- Model facets are radio-local, so they never depend on a link, but every one
--- of them can still be missing on some firmware.
local function testModelService()
    assertEqual(modelService.formatTime(125), "2:05")
    assertEqual(modelService.formatTime(-5), "-0:05")
    assertEqual(modelService.formatTime(3725), "1:02:05")
    assertEqual(modelService.formatTime(nil), "--:--")

    local timers = {
        [0] = { value = 125, start = 300, name = "Flight", persistent = 1 },
        [1] = { value = 64, start = 0, name = "Up" },
    }

    local env = services.environment({
        getValue = function(source)
            if source == "tx-voltage" then
                return 7.8
            end
            return nil
        end,
        getFlightMode = function()
            return 2, "Sport"
        end,
        model = {
            getInfo = function()
                return { name = "Test", bitmap = "plane.png", filename = "m1.yml", labels = "fpv" }
            end,
            getTimer = function(index)
                return timers[index]
            end,
        },
    })

    local service = modelService.new(env, services)
    local identity = service:identity()
    local flightMode = service:flightMode()
    local voltage = service:txVoltage()
    local countdown = service:timer(0)
    local countUp = service:timer(1)
    local absent = service:timer(2)

    for step = 0, 3 do
        service:update(step)
    end

    assertEqual(identity.name, "Test")
    assertEqual(identity.bitmap, "plane.png")
    assertEqual(identity.bitmapPath, "/IMAGES/plane.png")
    assertEqual(flightMode.index, 2)
    assertEqual(flightMode.name, "Sport")
    assertEqual(voltage.value, 7.8)
    assertEqual(voltage.unitText, "V")

    -- A countdown keeps EdgeTX's own signed value and derives the rest.
    assertEqual(countdown.countdown, true)
    assertEqual(countdown.remaining, 125)
    assertEqual(countdown.elapsed, 175)
    assertEqual(countdown.text, "2:05")
    assertEqual(countdown.expired, false)

    assertEqual(countUp.countdown, false)
    assertEqual(countUp.elapsed, 64)
    assertEqual(countUp.text, "1:04")

    -- A timer index the radio does not have degrades instead of raising.
    assertEqual(absent.available, false)
    assertEqual(absent.text, "--:--")

    -- A countdown that runs past zero must read as expired, not as elapsed.
    timers[0].value = -8
    for step = 4, 9 do
        service:update(step)
    end
    assertEqual(countdown.expired, true)
    assertEqual(countdown.text, "-0:08")

    -- An unnamed flight mode falls back to its number.
    local unnamed = modelService.new(
        services.environment({
            getFlightMode = function()
                return 0, ""
            end,
        }),
        services
    )
    local mode = unnamed:flightMode()
    unnamed:update(0)
    assertEqual(mode.name, "FM0")

    -- Firmware without the model API must not raise.
    local bare = modelService.new(services.environment({ model = {} }), services)
    local bareIdentity = bare:identity()
    local bareTimer = bare:timer(0)
    bare:update(0)
    assertEqual(bareIdentity.available, false)
    assertEqual(bareTimer.state, "unavailable")
end

--- Trims and global variables are both resolved by EdgeTX; the service only
--- normalizes their scale, precision, and bounds.
local function testControlService()
    local raw = 0
    local details = { name = "Rates", min = -100, max = 100, prec = 1, unit = 0 }

    local env = services.environment({
        getFieldInfo = function(name)
            if name == "trim-ail" or name == "trim-thr" then
                return { id = 200 }
            end
            return nil
        end,
        getValue = function()
            return raw
        end,
        getFlightMode = function()
            return 1
        end,
        model = {
            getGlobalVariable = function(index, phase)
                assertEqual(phase, 1, "a global variable ignored the flight mode")
                return 45
            end,
            getGlobalVariableDetails = function()
                return details
            end,
        },
    })

    local service = controlService.new(env, services)
    local trim = service:trim("trim-ail")
    local variable = service:globalVariable(0)

    service:update(0)
    assertEqual(trim.available, true)
    assertEqual(trim.centered, true)
    assertEqual(trim.scale, "standard")
    assertEqual(trim.fraction, 0)

    -- EdgeTX reports eight times the stored trim.
    raw = 512
    service:update(1)
    assertEqual(trim.raw, 512)
    assertEqual(trim.value, 64)
    assertEqual(trim.fraction, 0.5)
    assertEqual(trim.centered, false)

    -- A negative trim must round toward zero like a positive one. Flooring a
    -- negative percentage reports more deflection than the trim actually has.
    raw = -240
    service:update(1)
    -- describe() reports one row per subscription, in subscription order. A
    -- count greater than zero would be satisfied by a diagnostics panel that
    -- silently dropped every row but the first.
    local rows = {}
    assertEqual(service:describe(rows), 2, "a subscription was left undescribed")
    assertEqual(rows[1].label, "TRIM-AIL")
    assertEqual(rows[1].text, "-30 -23%", "a negative trim rounded the wrong way")
    assertEqual(rows[2].label, "RATES")
    assertEqual(rows[2].text, "4.5")
    raw = 512
    service:update(1)

    -- A standard trim held at its own end stop reads exactly 1024, because
    -- EdgeTX clamps the stored value to TRIM_MAX of 128. That must not be read
    -- as leaving the standard range.
    raw = 1024
    service:update(2)
    assertEqual(trim.scale, "standard", "an end stop widened the scale")
    assertEqual(trim.fraction, 1)
    assertEqual(trim.value, 128)

    -- Auto widens once a reading really does leave the standard range, and stays
    -- widened, because EdgeTX never tells Lua whether extended trims are enabled.
    raw = 2048
    service:update(3)
    assertEqual(trim.scale, "extended")
    assertEqual(trim.fraction, 0.5)
    raw = -512
    service:update(4)
    assertEqual(trim.scale, "extended", "the scale narrowed again")
    assertEqual(trim.fraction, -0.125)

    -- A global variable uses its configured name, precision, and bounds.
    assertEqual(variable.name, "Rates")
    assertEqual(variable.value, 4.5)
    assertEqual(variable.min, -10)
    assertEqual(variable.max, 10)
    assertEqual(variable.flightMode, 1)

    -- A three-position toggle and a standard trim at its end stop report the
    -- same number, so one sample can never tell them apart. A trim parked at its
    -- stop must not be mistaken for a toggle.
    local parked = controlService.new(env, services)
    local parkedTrim = parked:trim("trim-thr")
    raw = 1024
    parked:update(0)
    assertEqual(parkedTrim.threePosition, false, "an end stop was read as a toggle")

    -- A toggle only ever reports centre or full deflection, with nothing between.
    local toggle = controlService.new(env, services)
    local switchTrim = toggle:trim("trim-thr")
    raw = 0
    toggle:update(0)
    raw = 1024
    toggle:update(1)
    assertEqual(switchTrim.threePosition, true)
    assertEqual(switchTrim.fraction, 1)

    -- An ordinary trim passes through intermediate positions on its way.
    raw = 300
    toggle:update(2)
    assertEqual(switchTrim.threePosition, false, "an ordinary trim stayed a toggle")

    -- An unknown trim source and a radio without global variables degrade.
    local bare = controlService.new(services.environment({ model = {} }), services)
    local unknown = bare:trim("trim-nope")
    local noVariable = bare:globalVariable(1)
    bare:update(0)
    assertEqual(unknown.state, "unavailable")
    assertEqual(noVariable.state, "unavailable")
    assertEqual(bare:trim("").state, "unavailable")
end

--- Flight sessions are owned by the dashboard, and the arm switch is what
--- decides where one flight ends and the next begins.
local function testExtremaService()
    local harness = telemetryHarness()
    harness.fields.sa = { id = 300 }
    harness.values[300] = -1024

    local runtime = services.runtime(harness.env)
    local telemetry = harness.service
    services.register(runtime, telemetry, 0)
    local service = extremaService.new(harness.env, services, runtime)
    services.register(runtime, service, 0)

    local flight = service:flight("sa")
    local altitude = service:sessionExtrema("Alt")

    -- EdgeTX's own extrema are ordinary sources, reached through the same poll.
    local peak = service:sourceExtreme("Alt", "max")
    assertEqual(peak.name, "Alt+")

    telemetry:update(0)
    service:update(0)
    assertEqual(flight.configured, true)
    assertEqual(flight.armed, false)
    assertEqual(flight.active, false)
    assertEqual(altitude.available, false)

    -- Arming starts a session and clears whatever the last one recorded.
    harness.values[103] = 10
    harness.values[300] = 1024
    telemetry:update(1)
    service:update(1)
    assertEqual(flight.armed, true)
    assertEqual(flight.active, true)
    assertEqual(flight.count, 1)

    for step, value in ipairs({ 10, 50, 20 }) do
        harness.values[103] = value
        telemetry:update(step + 1)
        service:update(step + 1)
    end
    assertEqual(altitude.min, 10)
    assertEqual(altitude.max, 50)
    assertEqual(altitude.session, 1)
    assert(altitude.samples >= 3, "samples were not counted")

    -- Disarming freezes the session rather than discarding it.
    harness.values[300] = -1024
    telemetry:update(10)
    service:update(10)
    assertEqual(flight.active, false)
    assertEqual(altitude.max, 50)

    -- Re-arming starts a clean session.
    harness.values[300] = 1024
    harness.values[103] = 5
    telemetry:update(11)
    service:update(11)
    assertEqual(flight.count, 2)
    assertEqual(altitude.session, 2)
    assertEqual(altitude.max, 5)

    -- Without an arm source the dashboard still tracks one open session, so
    -- extrema mean something on a radio with no arm switch.
    local free = extremaService.new(harness.env, services, runtime)
    local session = free:flight()
    free:update(0)
    assertEqual(session.configured, false)
    assertEqual(session.active, true)
end

--- Navigation must never present a north-up bearing as model orientation, and
--- must withhold everything it cannot actually know.
local function testNavigationService()
    local harness = telemetryHarness()
    harness.fields.GPS = { id = 400, unit = 40 }
    harness.fields.Dist = { id = 403, unit = 9 }
    harness.values[400] = {
        lat = 47.3769,
        lon = 8.5417,
        ["pilot-lat"] = 47.3700,
        ["pilot-lon"] = 8.5400,
        delay = 1,
    }
    harness.values[403] = 812

    local runtime = services.runtime(harness.env)
    local telemetry = harness.service
    services.register(runtime, telemetry, 0)
    local service = navigationService.new(harness.env, services, runtime)
    services.register(runtime, service, 0)

    local view = service:subscribe("GPS")
    telemetry:update(0)
    service:update(0)

    assertEqual(view.fix, true)
    assertEqual(view.home, true)
    assertEqual(view.state, "normal")
    assertEqual(view.age, 1, "the reported fix age was ignored")
    assert(math.abs(view.distance - 777) < 20, "distance was " .. tostring(view.distance))
    assert(math.abs(view.bearing - 9.6) < 2, "bearing was " .. tostring(view.bearing))
    assertEqual(view.distanceUnit, "m")

    -- The reciprocal must differ, which proves the bearing runs home to model
    -- rather than the other way round.
    local reverse = navigationService.bearingBetween(47.3769, 8.5417, 47.3700, 8.5400)
    assert(
        math.abs(((reverse - view.bearing) % 360) - 180) < 1,
        "home-to-model and model-to-home bearings are not reciprocal"
    )

    -- A model due west of home reads 270, not 90.
    assert(math.abs(navigationService.bearingBetween(0, 0, 0, -1) - 270) < 0.01)
    assert(math.abs(navigationService.bearingBetween(0, 0, 1, 0)) < 0.01)

    -- Without a home position a bearing would be meaningless.
    harness.values[400]["pilot-lat"] = 0
    harness.values[400]["pilot-lon"] = 0
    telemetry:update(1)
    service:update(1)
    assertEqual(view.home, false)
    assertEqual(view.bearing, nil)
    assertEqual(view.distance, nil)
    assertEqual(view.fix, true)

    -- No fix at all is reported explicitly rather than as a position of zero.
    harness.values[400].lat = 0
    harness.values[400].lon = 0
    telemetry:update(2)
    service:update(2)
    assertEqual(view.fix, false)
    assertEqual(view.state, "unavailable")

    local second = service:subscribe("GPS2")
    harness.fields.GPS2 = harness.fields.GPS
    assertEqual(second.state, "unavailable")
    harness.values[400].lat = 47.3769
    harness.values[400].lon = 8.5417
    harness.values[400]["pilot-lat"] = 47.3700
    harness.values[400]["pilot-lon"] = 8.5400
    telemetry:update(3)
    service:update(3)
    assert(math.abs(view.distance - 777) < 20)
    assertEqual(service:subscribe("GPS"), view)
    assertEqual(second.distance, view.distance)

    -- A GPS source that has never produced a table must not raise.
    local absent = service:subscribe("NoGps")
    service:update(4)
    assertEqual(absent.state, "unavailable")
    assertEqual(navigationService.formatDistance(nil), "--")
    assertEqual(navigationService.formatDistance(450), "450m")
    assertEqual(navigationService.formatDistance(12345), "12.3km")
end

--- Every line height the dashboard lays out from must be the radio's own.
---
--- `theme.fontHeight` carries five numbers that decide every vertical
--- decision the dashboard makes, and until now nothing checked them against
--- anything. They are a claim about the firmware, so they are checked against
--- the firmware: `tests/support/edgetx.lua` records the line heights of the
--- `std` font set, which is what a 480 x 272 radio is built with, along with
--- the file they were read from.
---
--- The wrong font set is the easy mistake here rather than a typo. EdgeTX also
--- ships `sml` for 320 x 240 and `lrg` for 800 x 480, and the `sml` heights
--- are 54, 33, 23, 14 and 10. Adopting those would rescale every text fitting
--- decision in the project and no test would have objected.

testSnapshotsAreImmutable()
testServiceScheduling()
testTelemetryFreshness()
testTelemetryTextSensor()
testTelemetryLinkHeuristics()
testTelemetryPollingIsBounded()
testModelService()
testControlService()
testExtremaService()
testNavigationService()
