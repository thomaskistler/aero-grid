-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local load = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local support, detector, config =
    load("lib/services.lua"), load("lib/flight_service.lua"), load("lib/flight_config.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local modules = {
    telemetry = load("lib/telemetry_service.lua"),
    control = load("lib/control_service.lua"),
    model = load("lib/model_service.lua"),
}

local function fixture()
    local radio = {
        now = 0,
        count = 39,
        arms = { false, false },
        motor = 0,
        filename = "model1.yml",
        writes = 0,
        sounds = 0,
        lines = {},
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
            return name == "ch3" and { id = 1, name = name }
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
            return { year = 2026, mon = 10, day = 28, hour = 1, min = 0 }
        end,
        playTone = function()
            radio.sounds = radio.sounds + 1
        end,
        playNumber = function() end,
        fileOpen = function(_, access)
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
            radio.now = radio.now + 20
            owner:tick(radio.now)
            owner:tick(radio.now)
        end
    end
    return owner, radio, step, first, second, participant
end

local owner, radio, step, first, second, participant = fixture()
radio.arms[1] = true
step(15)
equal(owner.view.active, true)
equal(radio.writes, 1, "two callers/widgets have one count effect")
equal(radio.sounds, 1)
equal(radio.commands[1], true)
local start = owner:boundaries(0)
equal(#start, 1)
equal(start[1].kind, "start")
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
equal(radio.sounds, 2)
equal(#radio.lines, 2, "one header and one flight row")
local boundaries = owner:boundaries(0)
equal(#boundaries, 2)
equal(boundaries[2].kind, "end")
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
