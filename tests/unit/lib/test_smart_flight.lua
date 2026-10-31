-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local load = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local support, smart, detector, config =
    load("lib/services.lua"),
    load("lib/smart_flight.lua"),
    load("lib/flight_service.lua"),
    load("lib/flight_config.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local function fixture(family)
    local sensors, samples = {}, {}
    local radio = { family = family or 5, reads = 0 }
    local env = {
        getModule = function(index)
            return { Type = index == 0 and radio.family or radio.second or 0 }
        end,
        getSensor = function(index)
            radio.reads = radio.reads + 1
            return sensors[index]
        end,
        getFieldInfo = function(name)
            local index = tonumber(string.match(name, "^telem(%d+)$"))
            assert(index, "discovery must not use editable names")
            return { id = 500 + index * 3 }
        end,
        getSourceValue = function(id)
            local sample = samples[(id - 500) / 3 - 1]
            if sample then
                return sample.value, sample.current ~= false, sample.fresh ~= false
            end
        end,
    }
    local service = smart.new(env, support)
    local view = service:enable()
    local now = 0
    local function step(count)
        for _ = 1, count or 1 do
            now = now + 20
            local before = radio.reads
            service:update(now)
            assert(radio.reads - before <= 12, "discovery and revalidation remain bounded")
        end
    end
    local function sensor(index, id, instance, unit, value)
        sensors[index] = { type = 0, id = id, instance = instance, unit = unit, prec = 2, name = "EDIT" }
        if value ~= nil then
            samples[index] = { value = value }
        end
    end
    return service, view, sensor, samples, step, radio, sensors, env
end

do
    local _, view, sensor, samples, step = fixture()
    sensor(31, 9, 0, 9, 0)
    sensor(49, 2, 2, 7, 36)
    sensor(42, 2, 0, 40, { lat = 37, lon = -122, delay = 0 })
    sensor(17, 2, 5, 0, 8)
    step(8)
    equal(view.altitude.value, 0)
    equal(view.altitude.fresh, true)
    equal(view.speed.value, 10)
    equal(view.speed.fresh, true)
    samples[31] = nil
    step()
    equal(view.altitude.fresh, false, "never-received data is not zero even on a live link")
    samples[31] = { value = 123, fresh = false, current = false }
    step()
    equal(view.altitude.fresh, false, "an old nonzero value is not proof of freshness")
    samples[31] = { value = 0, current = false }
    step()
    equal(view.altitude.fresh, false)
    samples[31] = { value = math.huge }
    step()
    equal(view.altitude.fresh, false)
    samples[31] = { value = 0 / 0 }
    step()
    equal(view.altitude.fresh, false)
    for _, gps in ipairs({
        { lat = 0, lon = 0, delay = 0 },
        { lat = 91, lon = 1, delay = 0 },
        { lat = 1, lon = 1, delay = 8 },
        { lat = 1, lon = 1, delay = -1 },
        { lat = 1, lon = 1 },
        { lat = 0 / 0, lon = 1, delay = 0 },
    }) do
        samples[42].value = gps
        step()
        equal(view.speed.fresh, false, "invalid, missing or stale GPS fix cannot qualify groundspeed")
    end
    samples[42].value = { lat = 37, lon = -122, delay = 0 }
    samples[42].current = false
    step()
    equal(view.speed.fresh, false)
    samples[42].current = true
    samples[17].value = 3
    step()
    equal(view.speed.fresh, false, "CRSF GPS needs a usable satellite fix")
    samples[17].value = 8
    samples[49].value = -1
    step()
    equal(view.speed.fresh, false)
end

for _, conversion in ipairs({
    { 9, 3.25, 3.25 },
    { 10, 10, 3.048 },
    { 4, 20, 20 * 0.51444444444444 },
    { 5, 10, 10 },
    { 6, 10, 3.048 },
    { 7, 36, 10 },
    { 8, 10, 4.4704 },
}) do
    local _, view, sensor, _, step = fixture()
    local altitude = conversion[1] == 9 or conversion[1] == 10
    sensor(5, altitude and 9 or 2, altitude and 0 or 2, conversion[1], conversion[2])
    sensor(32, 2, 0, 40, { lat = 1, lon = 2, delay = 0 })
    sensor(59, 2, 5, 0, 8)
    step(8)
    local reading = altitude and view.altitude or view.speed
    assert(reading.fresh and math.abs(reading.value - conversion[3]) < 0.000000001)
end

do
    local _, view, sensor, _, step, _, sensors = fixture()
    sensor(1, 2, 4, 9, 100) -- GPS altitude is not barometric altitude.
    sensor(2, 9, 0, 9, 10)
    sensors[2].type = 1 -- Calculated altitude is not a trusted barometer.
    sensor(3, 10, 0, 9, 10) -- Unidentified distance/altitude is not enough.
    step(8)
    equal(view.altitude.fresh, false)
    assert(string.find(view.status, "absent/unsupported", 1, true))
    sensor(12, 9, 0, 9, 10)
    sensor(57, 9, 0, 9, 11)
    step(8)
    equal(view.altitude.fresh, false)
    assert(string.find(view.status, "baro ambiguous", 1, true))
    sensors[57] = nil
    step(8)
    equal(view.altitude.fresh, true)
    sensors[12] = { type = 1, unit = 9 }
    step()
    equal(view.altitude.fresh, nil, "metadata changes invalidate a previously trusted sensor immediately")
    assert(string.find(view.status, "configuration changed", 1, true))
end

for key, value in pairs({ type = 1, id = 2, instance = 1, unit = 10, prec = 1 }) do
    local _, view, sensor, _, step, _, sensors = fixture()
    sensor(12, 9, 0, 9, 10)
    step(8)
    local generation = view.generation
    sensors[12].name = "Renamed"
    step()
    assert(view.altitude.fresh and view.generation == generation, "editable names are not sensor identity")
    sensors[12][key] = value
    step()
    assert(view.generation > generation and not view.altitude.fresh, key .. " changes must invalidate immediately")
end

do
    local _, view, sensor, _, step = fixture(2)
    sensor(51, 0x0102, 0, 10, 10)
    sensor(32, 0x0831, 0, 4, 20)
    sensor(7, 0x0801, 0, 40, { lat = 1, lon = 2, delay = 0 })
    step(8)
    assert(view.altitude.fresh and view.speed.fresh)
    equal(view.altitude.value, 3.048)
end

do
    local _, view, sensor, _, step, _, sensors = fixture(2)
    sensor(51, 0x0102, 0, 9, 0)
    sensor(32, 0x0831, 1, 8, 15)
    sensor(7, 0x0801, 2, 40, { lat = 1, lon = 2, delay = 0 })
    step(8)
    equal(view.speed.fresh, false, "different S.Port GPS instances cannot be paired")
    sensors[7].instance = 1
    step(9)
    equal(view.speed.fresh, true)
    sensor(58, 0x0802, 1, 40, { lat = 1, lon = 2, delay = 0 })
    step(8)
    equal(view.speed.fresh, false)
    equal(view.altitude.fresh, true, "GPS ambiguity must not disable independent barometric input")
    assert(string.find(view.status, "GPS speed ambiguous", 1, true))
end

for _, mode in ipairs({ "api", "protocol", "modules" }) do
    local _, view, sensor, _, step, radio, _, env = fixture()
    sensor(12, 9, 0, 9, 10)
    if mode == "api" then
        env.getSourceValue = nil
    elseif mode == "protocol" then
        radio.family = 6 -- Unknown MULTI subprotocol is not assumed to be FrSky.
    else
        radio.second = 2
    end
    step(8)
    equal(view.altitude.fresh, nil)
    assert(string.find(view.status, "standard only", 1, true))
end

do
    local _, view, sensor, samples, step = fixture()
    sensor(12, 9, 0, 9, 0)
    step(8)
    local evidence = view.altitude.evidenceAt
    samples[12].fresh = false
    step(3)
    assert(view.altitude.fresh and not view.altitude.sampleFresh, "healthy current inter-sample gaps remain usable")
    equal(view.altitude.evidenceAt, evidence, "polling a cached value must not renew receipt evidence")
    assert(string.find(view.status, "baro current", 1, true))
    step(4)
    assert(not view.altitude.fresh, "a stopped stream expires even while isCurrent remains true")
    step(4)
    assert(not view.altitude.fresh, "current alone cannot revive expired or never-witnessed data")
    samples[12].fresh = true
    step()
    assert(view.altitude.fresh and view.altitude.continuity == 1)
end

local function detectorFixture(options, engine)
    local writes = 0
    local context = {
        phase = "ground",
        settings = config.resolve(options or { smartDetection = true }),
        feed = { available = true, precision = 0, raw = 0 },
        arm = { available = true, fresh = true, value = false },
        motor = { available = true, fresh = true, value = 0 },
        link = { live = true },
        smart = { generation = 1, altitude = {}, speed = {} },
        control = {
            incrementFlightCount = function()
                writes = writes + 1
                return writes
            end,
        },
    }
    local function step(at, altitude, speed)
        for _, reading in ipairs({ context.arm, context.motor, context.link }) do
            reading.updatedAt = at
        end
        for key, value in pairs({ altitude = altitude, speed = speed }) do
            context.smart[key] = {
                available = true,
                fresh = true,
                sampleFresh = true,
                value = value,
                updatedAt = at,
                evidenceAt = at,
                confirmedAt = at,
            }
        end
        (engine or detector).advance(context, at)
    end
    return context, step, function()
        return writes
    end
end

do
    local c, step = detectorFixture()
    step(0, 0)
    c.arm.value = true
    step(20, 0)
    step(40, 3)
    step(240, 3)
    equal(c.phase, "starting", "exactly +3m does not qualify")
    step(260, 3.01)
    step(459, 3.01)
    equal(c.phase, "starting", "199 ticks is not two seconds")
    step(460, 3.01)
    equal(c.phase, "active")
    equal(c.reason, "smart-altitude")
    equal(c.startedAt, 20)
end

do
    local c, step = detectorFixture()
    c.arm.value = true
    step(0, 100, 4.4704)
    step(200, 104, 4.4704)
    equal(c.altitudeReference, nil, "startup while armed cannot fabricate an arming reference")
    equal(c.phase, "starting", "exactly 10mph does not qualify")
    step(220, 104, 4.4705)
    step(419, 104, 4.4705)
    equal(c.phase, "starting")
    step(420, 104, 4.4705)
    equal(c.reason, "smart-speed", "speed is an OR path without any altitude reference")
end

do
    local c, step = detectorFixture()
    step(0)
    c.arm.value = true
    step(20)
    step(40, 100)
    step(240, 104)
    equal(c.altitudeReference, nil, "late in-flight altitude never becomes a baseline")
    equal(c.phase, "starting")
    step(3020)
    equal(c.reason, "standard", "missing/late altitude never gates standard qualification")
end

do
    local c, step = detectorFixture()
    step(0, 20)
    c.arm.value = true
    step(20, 20)
    step(40, 24)
    c.motor.value = -1024
    step(140, 24)
    equal(c.altitudeSince, nil)
    equal(c.altitudeReference, 20, "motor interruptions preserve the arming reference")
    c.motor.value = 0
    step(160, 24)
    step(359, 24)
    equal(c.phase, "starting")
    step(360, 24)
    equal(c.reason, "smart-altitude")
end

for _, failure in ipairs({ "stale", "unavailable", "age", "unknown-arm", "link", "motor-threshold", "generation" }) do
    local c, step = detectorFixture()
    step(0, 0, 5)
    c.arm.value = true
    step(20, 0, 5)
    step(40, 4, 5)
    if failure == "unknown-arm" then
        c.arm.fresh = false
    elseif failure == "link" then
        c.link.live = false
    elseif failure == "motor-threshold" then
        c.motor.value = -512 -- Exactly 25%.
    elseif failure == "generation" then
        c.smart.generation = 2
    else
        for _, reading in pairs({ c.smart.altitude, c.smart.speed }) do
            reading.fresh = failure ~= "stale"
            reading.available = failure ~= "unavailable"
            reading.updatedAt = failure == "age" and -1000 or 40
        end
    end
    step(100)
    equal(c.altitudeSince, nil, failure .. " must reset altitude hold")
    if failure ~= "generation" then
        equal(c.speedSince, nil, failure .. " must reset speed hold")
    end
    c.arm.fresh, c.link.live, c.motor.value = true, true, 0
    step(120, 4, 5)
    step(319, 4, 5)
    if failure ~= "generation" then
        equal(c.phase, "starting", failure .. " must require a new full two-second hold")
    end
end

do
    local c, step = detectorFixture({ smartDetection = false })
    step(0, 0, 5)
    c.arm.value = true
    step(20, 0, 5)
    step(40, 4, 5)
    step(240, 4, 5)
    equal(c.phase, "starting", "Smart remains opt-in")
    step(3020, 4, 5)
    equal(c.reason, "standard")
end

do
    local c, step = detectorFixture({ smartDetection = true, disarmDuration = 1 })
    step(0, 0)
    c.arm.value = true
    step(20, 0)
    step(40, 4)
    step(240, 4)
    equal(c.phase, "active")
    c.arm.value = false
    step(260, 100)
    step(360, 100)
    equal(c.phase, "ground")
    c.arm.value = true
    step(380, 100)
    equal(c.altitudeReference, 100, "immediate rearm after confirmed completion must use a new reference")
    step(580, 100)
    equal(c.phase, "starting", "completed flight altitude cannot trigger the next flight")
end

do
    local packsize = string.packsize
    string.packsize = function()
        return 4
    end
    local floatDetector = load("lib/flight_service.lua")
    string.packsize = packsize
    local function f32(value)
        return string.unpack("f", string.pack("f", value))
    end
    local baseline = f32(f32(1000) * f32(0.3048))
    local exactRise = f32(f32(1000 + 3 / 0.3048) * f32(0.3048))
    local exactSpeed = f32(f32(16.09344) * f32(1 / 3.6))
    local c, step = detectorFixture({ smartDetection = true }, floatDetector)
    step(0, baseline)
    c.arm.value = true
    step(20, baseline)
    step(40, exactRise, exactSpeed)
    step(240, exactRise, exactSpeed)
    equal(c.phase, "starting", "float32 conversion noise at +3m/10mph must not qualify")
    step(260, exactRise + 0.01, exactSpeed + 0.01)
    step(460, exactRise + 0.01, exactSpeed + 0.01)
    equal(c.phase, "active")
end

do
    local c, step = detectorFixture()
    step(0, 0, 0)
    c.arm.value = true
    step(20, 0, 0)
    local exactFeet = (3 / 0.3048) * 0.3048
    local exactKph = 16.09344 * (1 / 3.6)
    step(40, exactFeet, exactKph)
    step(240, exactFeet, exactKph)
    equal(c.phase, "starting", "conversion roundoff must not turn exact physical thresholds into shortcuts")
    step(260, 3.001, 4.471)
    step(360, 3.001, 4.471)
    equal(c.phase, "starting", "two one-second-spaced samples do not prove a two-second hold")
    step(460, 3.001, 4.471)
    equal(c.phase, "active")
end

do
    local c, step = detectorFixture()
    step(0, 10)
    c.arm.value = true
    step(20, 10)
    step(40, 14)
    step(100, 13)
    equal(c.altitudeSince, nil, "returning to exactly +3m resets the continuous hold")
    step(120, 14)
    c.arm.fresh = false
    step(180, 14)
    equal(c.altitudeReference, 10, "unknown arm is not a new disarm/rearm reference")
    c.arm.fresh = true
    step(200, 15)
    equal(c.altitudeReference, 10, "recovery must not rebase late in flight")
    step(399, 15)
    equal(c.phase, "starting")
    step(400, 15)
    equal(c.reason, "smart-altitude")
end

do
    local c, step = detectorFixture()
    step(0, 10)
    c.arm.value = true
    step(20, 10)
    step(40, 14)
    c.smart.altitude.fresh = false
    step(140)
    equal(c.startedAt, 20, "sensor loss does not reset the independent standard timer")
    step(3020)
    equal(c.reason, "standard")
end
