-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local load = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local flight = load("lib/flight_service.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local function context()
    local writes = 0
    local c = {
        delayTolerant = true,
        settings = { smartDetection = true, minMotorPercent = 10, minFlightDuration = 30, disarmDuration = 2 },
        phase = "ground",
        feed = { available = true, precision = 0, raw = 39 },
        arm = {},
        motor = {},
        link = {},
        smart = { generation = 1, altitude = {}, speed = {} },
        control = {
            incrementFlightCount = function()
                writes = writes + 1
                return 40
            end,
        },
    }
    local function observe(now, altitude, armed, fresh, continuity)
        c.arm.value, c.arm.fresh, c.arm.updatedAt = armed, true, now
        c.motor.value, c.motor.fresh, c.motor.updatedAt = 0, true, now
        c.link.live, c.link.updatedAt = true, now
        local a = c.smart.altitude
        a.value, a.fresh, a.updatedAt, a.evidenceAt, a.confirmedAt = altitude, fresh ~= false, now, now, now
        a.sampleFresh, a.continuity = fresh ~= false, continuity or 0
        flight.advance(c, now)
    end
    return c, observe, function()
        return writes
    end
end

do
    local c, observe, writes = context()
    observe(0, 100, false)
    observe(100, 100, true)
    observe(200, 104, true)
    observe(300, 104, true)
    observe(400, 104, true)
    equal(c.reason, "smart-altitude")
    equal(writes(), 1)
    observe(500, 104, false)
    observe(600, 104, false)
    observe(700, 104, false)
    equal(c.phase, "ground")
end

-- 1 Hz Smart polls arrive up to a Flight tick late; ticks in between still use
-- the latest poll. Beyond Smart's 120-tick window the reading is stale.
for _, age in ipairs({ 104, 120, 121 }) do
    local c, _, writes = context()
    local a = c.smart.altitude
    local function poll(now, altitude)
        a.value, a.fresh, a.updatedAt, a.evidenceAt, a.confirmedAt = altitude, true, now, now, now
        a.sampleFresh, a.continuity = true, 0
    end
    local function tick(now, armed)
        c.arm.value, c.arm.fresh, c.arm.updatedAt = armed, true, now
        c.motor.value, c.motor.fresh, c.motor.updatedAt = 0, true, now
        c.link.live, c.link.updatedAt = true, now
        flight.advance(c, now)
    end
    poll(0, 100)
    tick(0, false)
    tick(age, true)
    equal(c.altitudeReference, age <= 120 and 100 or nil, "a late Smart poll keeps the arming reference")
    local now = age
    for next = 106, 742, 106 do
        while now + 20 < next do
            now = now + 20
            tick(now, true)
        end
        poll(next, 104)
        now = next
        tick(now, true)
    end
    equal(writes(), age <= 120 and 1 or 0, "late 1 Hz Smart polls keep the altitude hold")
end

for _, gap in ipairs({ 121, 250, 1000 }) do
    local c, observe, writes = context()
    observe(0, 100, false)
    observe(100, 100, true)
    observe(200, 104, true)
    observe(200 + gap, 104, true, true, 1)
    equal(writes(), 0, "a receipt discontinuity cannot invent a start")
    equal(c.altitudeReference, 100, "late Smart must retain its live arming reference")
    observe(300 + gap, 104, true, false, 1)
    observe(400 + gap, 104, true, true, 2)
    equal(writes(), 0, "missing evidence breaks the threshold window")
    observe(500 + gap, 104, true, true, 2)
    observe(600 + gap, 104, true, true, 2)
    equal(writes(), 1)
    observe(700 + gap, 104, false, true, 2)
    observe(1000 + gap, 104, false, true, 2)
    equal(c.phase, "ending", "a delayed fresh disarm is not duration evidence")
    observe(1100 + gap, 104, false, true, 2)
    observe(1200 + gap, 104, false, true, 2)
    equal(c.phase, "ground")
end

do
    local c, observe, writes = context()
    c.settings.minFlightDuration, c.settings.disarmDuration = 1, 1
    observe(100, 100, true)
    flight.advance(c, 200)
    equal(writes(), 0, "a cached local reading does not add standard-flight duration")
    observe(200, 100, true)
    equal(writes(), 1)
    observe(300, 100, false)
    flight.advance(c, 400)
    equal(c.phase, "ending", "a cached disarm does not add completion duration")
    observe(400, 100, false)
    equal(c.phase, "ground")
end

for _, speed in ipairs({ false, true }) do
    local c, observe, writes = context()
    observe(0, 100, false)
    observe(100, 100, true)
    observe(1000, 100, true, false, 1)
    for now = 1100, 1300, 100 do
        if speed then
            c.smart.speed = {
                value = 5,
                fresh = true,
                updatedAt = now,
                confirmedAt = now,
                continuity = 1,
            }
        end
        observe(now, speed and 100 or 104, true, true, 1)
        if now < 1300 then
            equal(writes(), 0, "a threshold crossing after a gap starts a new hold")
        end
    end
    equal(writes(), 1)
    equal(c.reason, speed and "smart-speed" or "smart-altitude")
end

local function fixtureLoad(relative)
    if string.sub(relative, 1, 9) == "@support/" then
        return assert(loadfile(root .. "/tests/support/" .. string.sub(relative, 10)))()
    end
    return load(relative)
end
local fixture = fixtureLoad("@support/scheduler_flight_fixture.lua")(fixtureLoad)

do
    local owner, radio, _, host = fixture("run")
    local run, smart = owner.tasks.run, owner.tasks.smart
    owner:enableScheduler(host)
    equal(#owner.schedulerTasks, 2, "activation is idempotent")
    equal(owner.facade.count, 1, "broker demand is independent of panel subscriptions")
    local stable = owner:schedulerService(host)
    equal(stable.count, 1)
    local registry = host.serviceRuntime
    host.serviceRuntime = nil
    equal(owner:schedulerService(host), stable, "loader gaps retain a stable task registration source")
    equal(stable.schedulerTasks, owner.schedulerTasks)
    equal(owner:schedulerService({}), nil, "another widget cannot enroll the stable broker service")
    host.serviceRuntime = registry
    equal(run.decl.class, "normal")
    equal(smart.decl.class, "normal")
    equal(run:step(1, "run", radio.now), 20)
    equal(owner.session.arm.updatedAt, radio.now, "the task refreshes the co-due arm poller")
    equal(owner.session.motor.updatedAt, radio.now, "the task refreshes the co-due motor poller")
    equal(smart:step(1, "run", radio.now), 100)
    local sensor = owner.smartRuntime.byId.smart
    local revision = sensor.revision
    smart:step(1, "run", radio.now + 5)
    equal(sensor.revision, revision, "registry resync cannot poll Smart faster than 1 Hz")
    assert(not pcall(owner.enableScheduler, owner, {}), "another widget must not enroll a duplicate broker")
    owner.session.altitudeReference, owner.session.wasArmed = 100, true
    owner.session.sensorGeneration = owner.session.smart.generation
    owner.output = nil
    radio.armed, radio.now = true, 1400
    for _ = 1, 16 do
        local _, _, status = owner:proposals(radio.now)
        if status == "ready" then break end
    end
    run:step(1, "run", radio.now)
    equal(owner.session.altitudeReference, 100, "late ticks do not erase the arming reference")
    owner:reset("other.yml")
    equal(owner.tasks.run, run)
    equal(owner.tasks.smart, smart)
    equal(run.stage, "run")
    equal(owner.pendingAttach, nil)
    equal(owner:schedulerService(host), stable, "model reset retains the loader registration source")
    owner:resetSession(1500)
    host.schedulerHost = { scheduler = load("lib/scheduler.lua").new({ steady = 1250 }) }
    for _, item in ipairs(owner.schedulerTasks) do
        assert(host.schedulerHost.scheduler:add({
            id = item.id,
            decl = item.instance.decl,
            instance = item.instance,
            due = 1500,
        }))
    end
    owner:disableScheduler(host)
    equal(host.schedulerHost.scheduler.byId["service:flight"], nil)
    equal(host.schedulerHost.scheduler.byId["service:smart"], nil)
    equal(run.want, 0)
    equal(smart.want, 0)
    equal(owner:schedulerService(host), nil)
    equal(stable.count, 0)
    local replacement = { flightFactory = { broker = owner } }
    replacement.serviceRuntime = { byId = { flight = { broker = owner } } }
    owner:enableScheduler(replacement)
    equal(owner.tasks.run, run)
    equal(replacement.serviceRuntime.byId.flight.count, 1)
    equal(run.want, 1)
    equal(owner:schedulerService(replacement), stable, "host transfer reuses the stable registration source")
end

do
    local support, config = load("lib/services.lua"), load("lib/flight_config.lua")
    local original = fixture("run")
    local factory = { members = {}, revision = 1 }
    local first, second =
        { flightFactory = factory, flightConfig = config }, { flightFactory = factory, flightConfig = config }
    local function facade(host)
        local runtime = support.runtime(original.env)
        runtime.host, runtime.modules = host, original.modules
        local service = flight.new(original.env, support, runtime)
        runtime.byId.flight = service
        host.serviceRuntime = runtime
        return service
    end
    local a, b = facade(first), facade(second)
    equal(a.broker, b.broker)
    a.broker:enableScheduler(first)
    equal(a.count, 1)
    equal(b.count, 0)
    equal(b.schedulerTasks, nil)
    local tasks = a.schedulerTasks
    local replacement = facade(first)
    equal(replacement.schedulerTasks, tasks, "layout replacement retains the broker's releases")
    equal(replacement.count, 1)
    equal(a.count, 0, "the replaced registry cannot retain broker demand")
    first = nil
    collectgarbage("collect")
    equal(replacement.broker:owningContext(), nil, "the broker must not retain a retired widget")
    replacement.broker:enableScheduler(second)
    equal(b.count, 1)
    equal(replacement.count, 0, "reclaiming a collected host retires its old facade")
end

do
    local owner, radio = fixture("run")
    local scheduler = load("lib/scheduler.lua").new({ steady = 1250, background = 1130 })
    local stamps = {}
    local smart = owner.smartRuntime.byId.smart
    local update = smart.update
    function smart:update(now)
        stamps[#stamps + 1] = now
        return update(self, now)
    end
    for _, item in ipairs(owner.schedulerTasks) do
        assert(scheduler:add({ id = item.id, decl = item.instance.decl, instance = item.instance, due = radio.now }))
    end
    for now = 1100, 2180, 5 do
        radio.now = now
        radio.armed = now >= 1500 and now < 2100
        radio.altitude = now >= 1600 and 105 or 100
        scheduler:run(now < 2000 and "steady" or "background", now, 0)
    end
    equal(owner.session.reason, "smart-altitude")
    equal(radio.count, 40, "Smart counting remains once-only")
    equal(#owner.events, 1, "disarm debounce has not yet completed")
    equal(radio.sticky, true, "the flight output follows qualification")
    for now = 2185, 2400, 5 do
        radio.now = now
        scheduler:run("background", now, 0)
    end
    equal(#owner.events, 2)
    equal(owner.events[1].kind, "start")
    equal(owner.events[2].kind, "end")
    equal(radio.sticky, false)
    for index = 2, #stamps do
        assert(stamps[index] - stamps[index - 1] >= 100, "Smart never runs faster than 1 Hz")
    end
    assert(scheduler:takeErrors() == nil)
end

for _, variant in ipairs({ "proposal", "conflict" }) do
    local owner = fixture(variant)
    local proposal, actualSignature, actualStatus
    for now = 1100, 30000, 20 do
        proposal, actualSignature, actualStatus = owner:proposals(now)
        if not owner.proposalScan then
            break
        end
    end
    assert(not owner.proposalScan, "bounded proposal traversal completes")
    if variant == "proposal" then
        equal(actualStatus, "ready")
        equal(proposal.armKey, "L01")
        assert(actualSignature)
    else
        equal(actualStatus, "conflict")
        equal(proposal, nil)
        local message = owner.state.configurationError
        for n = 1, 16 do
            assert(string.find(message, "Widget" .. n .. "/Armed (L" .. n .. ")", 1, true))
        end
    end
end
