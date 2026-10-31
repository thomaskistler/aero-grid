-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local load = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local support, detector, config =
    load("lib/services.lua"), load("lib/flight_service.lua"), load("lib/flight_config.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local modules = {
    telemetry = load("lib/telemetry_service.lua"),
    control = load("lib/control_service.lua"),
    smart = load("lib/smart_flight.lua"),
}

local function fixture(cadence)
    local radio = {
        now = 0,
        count = 39,
        arms = { false, false },
        motor = 0,
        filename = "model1.yml",
        writes = 0,
        sounds = 0,
        lines = {},
        fileAccesses = 0,
        dateReads = 0,
        sticky = false,
        commands = {},
        full = false,
        rssi = 80,
    }
    local env = {
        getTime = function()
            return radio.now
        end,
        getInfo = function()
            return { filename = radio.filename, name = "Test" }
        end,
        getFieldInfo = function(name)
            local index = tonumber(string.match(name, "^telem(%d+)$"))
            if index and radio.sensors and radio.sensors[index - 1] then
                return { id = 100 + index, unit = radio.sensors[index - 1].unit }
            end
            return name == "ch3" and { id = 1, name = name }
        end,
        getModule = function(index)
            return { Type = index == 0 and 5 or 0 }
        end,
        getSensor = function(index)
            assert(not radio.failSmart, "Smart sensor reader failed")
            return radio.sensors and radio.sensors[index]
        end,
        getSourceValue = function(id)
            local sample = radio.samples and radio.samples[id]
            if sample then
                if sample.period then
                    local packetAt = math.floor(math.min(radio.now, sample.stoppedAt or radio.now) / sample.period)
                        * sample.period
                    if packetAt < (sample.firstAt or 0) then
                        return nil
                    end
                    local age = radio.now - packetAt
                    local value = type(sample.value) == "function" and sample.value(packetAt) or sample.value
                    if radio.now == sample.unavailableAt then
                        return value, false, false
                    end
                    if type(value) == "table" then
                        value = { lat = value.lat, lon = value.lon, delay = math.floor(age / 16) }
                    end
                    return value, age < 1000, age < sample.freshTicks
                end
                return sample.value, sample.current ~= false, sample.fresh ~= false
            end
        end,
        getValue = function()
            assert(not radio.failTelemetry, "telemetry reader failed")
            return radio.motor
        end,
        getRSSI = function()
            return radio.rssi
        end,
        getSwitchIndex = function(name)
            return tonumber(string.match(name, "^L(%d+)$"))
        end,
        getSwitchValue = function(index)
            if index == 20 then
                return radio.sticky
            end
            assert(not radio.failControl, "control reader failed")
            return radio.arms[index]
        end,
        getGlobalVariable = function()
            return radio.count
        end,
        setGlobalVariable = function(_, _, value)
            radio.count, radio.writes = value, radio.writes + 1
            assert(not radio.failCount, "uncertain count persistence")
        end,
        getGlobalVariableDetails = function()
            return { min = 0, max = 999, prec = 0 }
        end,
        getDateTime = function()
            radio.dateReads = radio.dateReads + 1
            return { year = 2026, mon = 10, day = 28, hour = 1, min = 0 }
        end,
        playTone = function()
            radio.sounds = radio.sounds + 1
        end,
        playNumber = function() end,
        fileOpen = function(_, access)
            radio.fileAccesses = radio.fileAccesses + 1
            return access ~= "r" and {} or nil
        end,
        fileWrite = function(_, line)
            radio.lines[#radio.lines + 1] = line
        end,
        fileClose = function() end,
        getLogicalSwitch = function()
            return { func = 17, v1 = 0, v2 = 0, v3 = 0, ["and"] = 0, delay = 0, duration = 0 }
        end,
        setStickySwitch = function(index, value)
            if radio.full then
                return true
            end
            equal(index, 19)
            radio.commands[#radio.commands + 1] = value
            radio.sticky = value
            return false
        end,
    }
    local owner = detector.newBroker(env, support, modules, config)
    owner:reset(radio.filename)
    local settings =
        config.resolve({ minFlightDuration = 1, disarmDuration = 1, announcements = true, flightSwitch = "L20" })
    owner:setDocument({ revision = 1, flight = settings })
    local first, second = {}, {}
    radio.participants = { first, second }
    local function participant(key)
        return {
            modelFilename = radio.filename,
            layoutName = "Test",
            declarations = { { armKey = key, armIndex = tonumber(string.sub(key, 2)), source = "Armed" } },
        }
    end
    owner.members[first], owner.members[second] = participant("L01"), participant("L01")
    local function step(count)
        for _ = 1, count or 1 do
            radio.now = radio.now + (cadence or 20)
            owner:tick(radio.now)
            owner:tick(radio.now)
        end
    end
    return owner, radio, step, first, second, participant
end

do
    local owner, radio, step, first, second = fixture()
    radio.arms[3] = true
    owner:setDocument({ revision = 2, flight = owner.document.flight, sessionReset = "L03" })
    local function pump(count)
        for _ = 1, count do
            step()
            owner:pollReset(radio.now)
            owner:pollReset(radio.now)
        end
    end
    local epoch = owner.epoch
    pump(10)
    equal(owner.epoch, epoch, "booting with reset held is not an activation")
    radio.arms[1] = true
    pump(15)
    equal(radio.writes, 1)
    equal(owner.view.active, true)
    owner.session.altitudeReference, owner.session.referenceCandidate, owner.session.referencePending = 100, 99, 101
    first.dashboardLifecycle, second.dashboardLifecycle = {}, {}
    first.navigationHomes, second.navigationHomes = { saved = true }, { saved = true }
    radio.arms[3] = false
    pump(3)
    radio.arms[3], radio.full = true, true
    pump(3)
    equal(owner.epoch, epoch + 1)
    equal(owner.view.active, false)
    equal(owner.view.startedAt, nil)
    equal(owner.session.altitudeReference, nil)
    equal(owner.session.referenceCandidate, nil)
    equal(owner.session.referencePending, nil)
    equal(#owner.events, 0, "reset does not manufacture a completed flight")
    equal(radio.writes, 1, "reset must not write the durable total")
    assert(first.sessionResetPending and second.sessionResetPending, "all matching dashboards queue an in-place reset")
    equal(first.reloadState, nil, "session reset must not request a page rebuild")
    equal(second.reloadState, nil)
    assert(
        first.navigationHomes.saved and second.navigationHomes.saved,
        "home clearing is staged by each host without replacing its shared table"
    )
    assert(owner.output and not owner.output.desired, "a full output queue must retain the release request")
    radio.full = false
    owner.members[first].pending, owner.members[second].pending = false, false
    pump(20)
    equal(owner.epoch, epoch + 1, "holding reset cannot repeatedly clear data")
    equal(radio.sticky, false, "the dedicated flight output is released with retry")
    equal(radio.writes, 1, "an already armed flight cannot qualify twice")
    radio.arms[1] = false
    pump(4)
    radio.arms[1] = true
    pump(15)
    equal(radio.writes, 2, "a new arm after a fresh disarm can qualify normally")
    radio.arms[3] = false
    pump(3)
    radio.arms[3] = nil
    pump(3)
    assert(owner.view.resetError, "unavailable reset input must be reported")
    radio.arms[3] = true
    pump(3)
    equal(owner.epoch, epoch + 1, "recovery while held is not a reset edge")
    equal(owner.view.resetError, nil)
    assert(not pcall(owner.validateOutput, owner, "L03", "L01", "!L03"))
end

do
    local owner, radio, step = fixture()
    radio.arms[1] = true
    step(2)
    equal(owner.session.phase, "starting")
    owner:resetSession(radio.now)
    step(20)
    equal(radio.writes, 0, "reset cancels an unqualified start without counting it later")
end

local owner, radio, step, first, second, participant = fixture()
radio.arms[1] = true
step(15)
equal(owner.view.active, true)
equal(radio.writes, 1, "two callers/widgets have one count effect")
equal(radio.sounds, 0)
equal(radio.commands[1], true)
local start = owner:boundaries(0)
equal(#start, 1)
equal(start[1].kind, "start")
equal(start[1].armKey, "L01")
assert(start[1].at < start[1].observedAt)
assert(not pcall(function()
    start[1].at = 0
end))
owner.members[first] = nil
owner.members[second] = participant("L02")
step(5)
equal(owner.view.status, "ready", "a pending configuration does not replace the pinned flight")
equal(owner.view.active, true)
equal(radio.writes, 1)
radio.rssi = 0
step(10)
equal(owner.view.active, true, "telemetry loss cannot end a flight")
radio.arms[1] = false
step(15)
equal(owner.view.active, false)
equal(radio.commands[#radio.commands], false, "pinned old-arm completion clears the old output")
equal(radio.sounds, 0)
equal(#radio.lines, 0, "completed flights must not write CSV rows")
equal(radio.fileAccesses, 0, "flight detection must not access CSV files")
equal(radio.dateReads, 0, "flight detection must not read the wall clock for CSV timestamps")
local boundaries = owner:boundaries(0)
equal(#boundaries, 2)
equal(boundaries[2].kind, "end")
equal(boundaries[2].armKey, "L01", "completion retains the pinned arm despite changed proposals")
assert(boundaries[2].at < boundaries[2].observedAt)

owner, radio, step, first, second, participant = fixture()
owner.members[second] = participant("L02")
radio.arms[1], radio.arms[2] = true, true
step(20)
equal(owner.view.status, "conflict")
equal(radio.writes, 0)
equal(#radio.commands, 0, "cold conflicts cannot commandeer an output")
owner.members[second] = participant("L01")
step(3)
equal(radio.writes, 0, "conflict time is not qualification time")
step(15)
equal(radio.writes, 1)
owner.members[second] = participant("L02")
radio.full = true
radio.arms[1] = false
step(15)
equal(owner.view.active, false)
equal(owner.view.outputStatus, "pending")
equal(radio.sticky, true)
radio.full = false
step(5)
equal(radio.sticky, false, "a conflict cannot strand pending output cleanup")
equal(owner.view.outputStatus, "applied")
equal(radio.writes, 1)

owner, radio, step = fixture()
radio.arms[1] = true
step(3)
radio.now = radio.now + 101
owner:tick(radio.now)
step(2)
equal(radio.writes, 0)
step(15)
equal(radio.writes, 1)
radio.arms[1] = false
step(2)
radio.now = radio.now + 200
owner:tick(radio.now)
equal(owner.view.active, true, "unobserved disarm grace cannot complete")
step(15)
equal(owner.view.active, false)

owner, radio, step = fixture()
radio.arms[1] = true
step(15)
radio.filename = "model2.yml"
step()
equal(owner.view.modelFilename, "model2.yml")
equal(owner.view.active, false)
equal(#owner:boundaries(0), 0)
equal(radio.writes, 1, "old-model work cannot increment in a new model")

owner, radio, step, first, second, participant = fixture()
local dead = {}
owner.members[dead] = participant("L02")
step()
equal(owner.view.status, "conflict")
dead = nil
collectgarbage("collect")
step()
equal(owner.view.status, "ready", "dead participants must not retain configuration conflicts")
owner.members[first].pending = true
radio.arms[1] = true
step(15)
equal(radio.writes, 0, "a rebuild declaration must resolve before new qualification")
owner.members[first].pending = false
step(15)
equal(radio.writes, 1)

owner, radio, step = fixture()
radio.arms[1] = true
step(3)
radio.failTelemetry = true
step(15)
equal(radio.writes, 0, "a retired reader must not qualify from its last fresh observation")
assert(owner.view.detectionError)

owner, radio, step = fixture()
radio.arms[1] = true
step(15)
radio.arms[1] = false
step(2)
radio.failControl = true
step(15)
equal(owner.view.active, true, "failed control polling is unknown, not reliable disarm")
equal(owner.session.disarmedAt, nil)

owner, radio, step = fixture()
radio.arms[1], radio.failCount = true, true
step(15)
equal(radio.writes, 1)
assert(owner.view.countError)
step(15)
equal(radio.writes, 1, "an uncertain write must never be retried blindly")
radio.failCount = false
owner:setDocument({ revision = 2, flight = owner.document.flight })
step(15)
equal(radio.writes, 1, "acknowledging a count error must still require disarm")
radio.arms[1] = false
step(10)
radio.arms[1] = true
step(15)
equal(radio.writes, 2, "a new arm cycle can recover after explicit model Save")
equal(owner.view.countError, nil)

owner, radio, step, first, second, participant = fixture()
radio.full = true
step(15)
assert(owner.output and not owner.output.flightId)
owner.members[second] = participant("L02")
radio.full = false
step(10)
equal(#radio.commands, 0, "idle initialization cannot acquire an output during a conflict")
equal(owner.output, nil)
equal(owner.view.outputError, nil, "a canceled idle write is no longer waiting for queue capacity")

owner, radio, step = fixture()
step(3)
assert(owner.session.groundAt)
radio.now = radio.now + 200
owner:tick(radio.now)
equal(#radio.commands, 0, "an observation gap must restart idle-output disarm confirmation")
step(15)
equal(#radio.commands, 1, "continuous reliable disarm can initialize the idle output")
equal(radio.commands[1], false)

owner, radio, step = fixture()
for _ = 1, 33 do
    radio.arms[1] = true
    step(20)
    radio.arms[1] = false
    step(20)
end
local records, oldest, gap = owner:boundaries(0, owner.epoch)
equal(#records, 64)
equal(oldest, 3)
equal(gap, true, "consumers must be told when journal records were evicted")
local _, _, currentGap = owner:boundaries(oldest - 1, owner.epoch)
equal(currentGap, false)
assert(not pcall(function()
    owner.view.active = false
end))
assert(not pcall(function()
    owner:validateOutput("L20", "!L20")
end), "an inverted Armed logical switch is still the same forbidden output")

equal(
    config.key(config.resolve({ motorSource = "CH03", minFlightDuration = 1.0 })),
    config.key(config.resolve({ motorSource = "ch3", minFlightDuration = 1 })),
    "equivalent channel spelling and numeric representations must reach consensus"
)

-- A real Smart input service feeds the same shared count/output
-- path and preserves the documented candidate/observation timestamp contract.
owner, radio, step = fixture()
radio.sensors = { [12] = { type = 0, id = 9, instance = 0, unit = 9, prec = 2, name = "High" } }
radio.samples = { [113] = { value = 0 } }
local settings = config.resolve({
    smartDetection = true,
    minFlightDuration = 30,
    disarmDuration = 1,
    announcements = true,
    flightSwitch = "L20",
})
owner:setDocument({ revision = 2, flight = settings })
step(45)
equal(owner.session.smart.altitude.value, 0, "received zero is a trustworthy altitude, not missing data")
radio.arms[1] = true
step(4)
equal(owner.session.altitudeReference, 0)
local candidateAt = owner.session.startedAt
radio.samples[113].value = 4
step(20)
equal(radio.writes, 1)
equal(radio.sounds, 0)
equal(radio.commands[#radio.commands], true)
equal(owner.view.reason, "smart-altitude")
local events = owner:boundaries(0)
equal(#events, 1)
equal(events[1].reason, "smart-altitude")
equal(events[1].at, candidateAt)
equal(events[1].observedAt, owner.view.qualifiedAt)
assert(events[1].observedAt - events[1].at < 3000)
step(180)
equal(radio.writes, 1, "the later standard deadline cannot produce a second transition")
radio.arms[1] = false
step(15)
events = owner:boundaries(0)
equal(#events, 2)
equal(events[2].reason, "smart-altitude")
equal(radio.sounds, 0)
equal(#radio.lines, 0)
equal(radio.fileAccesses, 0)
equal(radio.dateReads, 0)
equal(radio.commands[#radio.commands], false)

owner, radio, step = fixture()
owner:setDocument({ revision = 2, flight = settings })
step(45)
radio.arms[1] = true
step(160)
equal(radio.writes, 1, "absent Smart sensors never block the standard OR path")
equal(owner.view.reason, "standard")

local function timedStream(path, period, freshTicks, stopped, firstAt)
    local broker, state, advance = fixture(5)
    state.sensors, state.samples = {}, {}
    local function sensor(index, id, instance, unit, value, stop)
        state.sensors[index] = { type = 0, id = id, instance = instance, unit = unit, prec = 2 }
        state.samples[101 + index] = {
            value = value,
            period = period,
            freshTicks = freshTicks,
            stoppedAt = stop,
            firstAt = firstAt,
        }
    end
    if path == "altitude" then
        sensor(12, 9, 0, 9, function(at)
            return at >= 600 and 4 or 0
        end, stopped and 700)
    else
        sensor(37, 2, 0, 40, { lat = 1, lon = 2 }, stopped == "gps" and 700)
        sensor(49, 2, 2, 8, function(at)
            return at >= 600 and 11 or 0
        end, stopped == "speed" and 700)
        sensor(59, 2, 5, 0, 8, stopped == "satellites" and 700)
    end
    broker:setDocument({ revision = 2, flight = settings })
    advance(100)
    state.arms[1] = true
    return broker, state, advance
end

for _, path in ipairs({ "altitude", "speed" }) do
    for _, period in ipairs({ 50, 100 }) do
        for _, freshTicks in ipairs({ 16, 32 }) do
            local broker, state, advance = timedStream(path, period, freshTicks)
            for _ = 1, 100 do
                advance()
                if state.writes > 0 then
                    break
                end
            end
            equal(state.writes, 1, path .. " must qualify with a healthy " .. period * 10 .. "ms stream")
            equal(broker.view.reason, "smart-" .. path)
            assert(broker.view.qualifiedAt >= 800 and broker.view.qualifiedAt <= 1000)
            if path == "altitude" then
                equal(broker.session.altitudeReference, 0, "a recent witnessed disarmed sample is a valid reference")
            end
            advance(100)
            equal(state.writes, 1)
            equal(state.sounds, 0)
            state.arms[1] = false
            advance(50)
            equal(#broker:boundaries(0), 2)
            equal(state.sounds, 0)
            equal(#state.lines, 0)
            equal(state.fileAccesses, 0)
            equal(state.commands[#state.commands], false)
        end
    end
end

for _, stopped in ipairs({ "altitude", "speed", "gps", "satellites" }) do
    local path = stopped == "altitude" and "altitude" or "speed"
    local broker, state, advance = timedStream(path, 100, 32, stopped)
    advance(62)
    equal(state.now, 810)
    equal(state.writes, 0, "a current cached " .. stopped .. " value cannot finish the two-second hold")
    advance(38)
    equal(state.now, 1000)
    equal(state.writes, 0)
    equal(broker.session.smart[path].fresh, false, "stopped data must expire before the firmware's old flag")
    advance(550)
    equal(state.writes, 1, "stopped Smart inputs cannot block independent standard qualification")
    equal(broker.view.reason, "standard")
end

do
    local broker, state, advance = timedStream("altitude", 100, 16)
    state.samples[113].value = function(at)
        return at >= 500 and 4 or 0
    end
    advance(8)
    equal(broker.session.altitudeReference, 0, "prefer the witnessed pre-arm sample over a later new reading")
    assert(broker.session.smart.altitude.sampleFresh == false, "arming need not align with the firmware fresh window")
end

do
    local broker, state, advance = timedStream("altitude", 50, 32)
    state.samples[113].unavailableAt = 715
    advance(60)
    equal(state.now, 800)
    equal(state.writes, 0)
    advance(40)
    equal(state.writes, 1)
    assert(broker.view.qualifiedAt >= 925, "an invalid poll between detector ticks must restart the hold")
end

do
    local broker, state, advance = timedStream("altitude", 100, 32, "altitude")
    advance(100)
    state.samples[113].stoppedAt = nil
    advance(39)
    equal(state.writes, 0, "recovery must start a new full two-second hold")
    advance(4)
    equal(state.writes, 1)
    equal(broker.view.reason, "smart-altitude")
end

do
    local broker, state, advance = timedStream("altitude", 100, 32, nil, 600)
    advance(100)
    equal(state.writes, 0)
    equal(broker.session.altitudeReference, nil, "first receipt after arming cannot retroactively create a reference")
end
assert(string.find(owner.view.smartStatus, "absent/unsupported", 1, true))

owner, radio, step = fixture()
radio.sensors = {
    [42] = { type = 0, id = 2, instance = 0, unit = 40, prec = 0 },
    [49] = { type = 0, id = 2, instance = 2, unit = 8, prec = 1 },
    [59] = { type = 0, id = 2, instance = 5, unit = 0, prec = 0 },
}
radio.samples = {
    [143] = { value = { lat = 37, lon = -122, delay = 0 } },
    [150] = { value = 11 },
    [160] = { value = 8 },
}
owner:setDocument({ revision = 2, flight = settings })
step(45)
radio.arms[1] = true
step(20)
equal(radio.writes, 1)
equal(owner.view.reason, "smart-speed", "GPS without barometric altitude can qualify independently")
equal(#owner:boundaries(0), 1)
equal(radio.sounds, 0)
equal(radio.commands[#radio.commands], true)

owner, radio, step = fixture()
owner:setDocument({ revision = 2, flight = settings })
radio.failSmart = true
step(45)
radio.arms[1] = true
step(160)
equal(radio.writes, 1, "failed Smart polling cannot retire the standard detector")
equal(owner.view.reason, "standard")
assert(owner.view.detectionError and string.find(owner.view.smartStatus, "reader failed", 1, true))

owner, radio, step = fixture()
radio.sensors = { [12] = { type = 0, id = 9, instance = 0, unit = 9, prec = 2 } }
radio.samples = { [113] = { value = 0 } }
owner:setDocument({ revision = 2, flight = settings })
step(45)
radio.arms[1] = true
step(4)
radio.samples[113].value = 4
step(6)
radio.now = radio.now + 101
owner:tick(radio.now)
equal(owner.session.altitudeSince, nil, "scheduling gaps reset the Smart hold")
equal(owner.session.altitudeReference, nil, "unobserved arm cycles cannot inherit an old reference")
step(20)
equal(radio.writes, 0)
step(150)
equal(radio.writes, 1)
equal(owner.view.reason, "standard")
