-- SPDX-License-Identifier: GPL-2.0-only

-- The model service as the first task migrated to the new scheduler
-- (plans/scheduler-framework.md, sections 7 and 12). The parity method of section 7
-- on one recorded trace of radio readings:
--   1. golden      per-callback hashes of every published facet, recorded from the
--                  pre-migration service (tests/fixtures/scheduler-model-golden.txt)
--   2. extraction  the legacy loop running the extracted work matches the golden run
--   3. replay      that schedule replayed into `step` alone matches it
--   4. budgeted    the real planner: exact with ample room, bounded when late or cut
-- plus the contract of `step`. The cost bound is enforced by test_scheduler_cases.lua.
-- Regenerate the golden file only for a deliberate change of what the service
-- publishes, from the code that is the reference:
--   AEROGRID_WRITE_GOLDEN=1 AEROGRID_MODEL_SERVICE=<old model_service.lua> lua <this file> .
local root = (... and ... ~= "" and ...) or "."
local hostIo = io

local parity = assert(loadfile(root .. "/tests/support/scheduler_parity.lua"))(root)
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local overhead = assert(loadfile(root .. "/tests/support/scheduler_overhead.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local INTERVAL = 100

local modelFile = root .. "/src/WIDGETS/AeroGrid/lib/model_service.lua"
local modelService = assert(loadfile(modelFile))()
local writing = os.getenv("AEROGRID_WRITE_GOLDEN")
local recordedService = modelService
if writing and os.getenv("AEROGRID_MODEL_SERVICE") then
    recordedService = assert(loadfile(os.getenv("AEROGRID_MODEL_SERVICE")))()
end

-- A recorded input: irregular callbacks, a late one now and then, and a quiet tail.
-- Every callback carries the whole state of the radio.
local CALLBACKS, TAIL = 400, 120
local LATE = 250 -- ticks of a late callback

local function recordTrace()
    local state, trace, now = 12345, {}, 0
    local function random(low, high)
        state = (state * 75 + 74) % 65537
        return low + state % (high - low + 1)
    end
    local names = { [0] = "Normal", [1] = "", [2] = "Sport", [3] = "" }
    local world
    for index = 1, CALLBACKS + TAIL do
        now = now + random(3, 7) + (index % 55 == 0 and LATE or 0)
        local seconds = now // 100
        if index <= CALLBACKS then
            local mode = (index // 40) % 4
            local volts = 7.0 + random(0, 14) / 10
            world = {
                timers = {
                    [0] = {
                        value = 15 - seconds,
                        start = 15,
                        name = "Flight",
                        persistent = 1,
                        showElapsed = (index // 100) % 2 == 1,
                    },
                    [1] = { value = seconds, start = 0, name = "", persistent = 0, showElapsed = false },
                    [2] = not (index >= 150 and index < 200)
                        and { value = 3590 + seconds, start = 0, name = "Glide", persistent = 2, showElapsed = false },
                },
                voltage = not (index < 5 or (index >= 60 and index < 70)) and volts,
                mode = not (index >= 250 and index < 270) and { mode, names[mode] },
                info = not (index >= 300 and index < 320) and {
                    name = index < 100 and "Crack Yak" or "Mini Yak",
                    bitmap = index < 100 and "yak.png" or "mini.png",
                    filename = "yak.yml",
                    labels = "fpv",
                },
                battery = (index >= 350 and index < 360) and { battMin = 8.4, battMax = 6.4 }
                    or (index < 200 and { battMin = 6.4, battMax = 8.4, battWarn = 6.6 })
                    or { battMin = 6.0, battMax = 8.2, battWarn = 6.3 },
            }
        end
        trace[index] = { now = now, index = index, kind = index % 7 == 0 and "background" or "steady", world = world }
    end
    return trace
end
local trace = recordTrace()

-- The radio: stub functions that answer from the current callback's state.
local function radio(box)
    return services.environment({
        getValue = function()
            return box.world.voltage or nil
        end,
        getFlightMode = function()
            local mode = box.world.mode
            if mode then
                return mode[1], mode[2]
            end
        end,
        getGeneralSettings = function()
            return box.world.battery
        end,
        model = {
            getInfo = function()
                return box.world.info or nil
            end,
            getTimer = function(index)
                return box.world.timers[index] or nil
            end,
        },
    })
end

-- Which facets a layout subscribes to, in the order its panels were built.
local VARIANTS = {
    seven = function(service)
        service:identity()
        service:flightMode()
        service:txVoltage()
        service:batteryRange()
        service:timer(0)
        service:timer(1)
        service:timer(2)
    end,
    five = function(service)
        service:identity()
        service:flightMode()
        service:txVoltage()
        service:batteryRange()
        service:timer(0)
    end,
    three = function(service)
        service:txVoltage()
        service:batteryRange()
        service:timer(0)
    end,
    one = function(service)
        service:identity()
    end,
}
local ORDER = { "seven", "five", "three", "one" }

local function show(value)
    if type(value) == "number" then
        return math.type(value) == "integer" and string.format("%d", value) or string.format("%.3f", value)
    end
    return tostring(value)
end

local function facetsText(service, skip)
    local parts = {}
    for position, facet in ipairs(service.facets) do
        local keys = {}
        for key in pairs(facet.state) do
            if not (skip and skip[key]) then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        parts[#parts + 1] = "[" .. position
        for _, key in ipairs(keys) do
            parts[#parts + 1] = key .. "=" .. show(facet.state[key])
        end
    end
    return table.concat(parts, " ")
end

-- A hash small enough for 32-bit integers, so the same run gives the same line anywhere.
local function digest(text)
    local hash = 5381
    for position = 1, #text do
        hash = (hash * 33 + string.byte(text, position)) % 16777213
    end
    return string.format("%06x", hash)
end

local function adapter(variant)
    return {
        id = "service:model",
        decl = modelService.decl,
        new = function()
            local box = { world = trace[1].world }
            local service = recordedService.new(radio(box), services)
            service.tickElapsed = scheduler.elapsed
            if type(service.update) ~= "function" then
                service.update = function(self, now)
                    return self:read(self.decl.stages.run.maxUnits, now)
                end
            end
            VARIANTS[variant](service)
            service.box = box
            return service
        end,
        feed = function(task, callback)
            task.box.world = callback.world
        end,
        snapshot = function(task)
            return digest(table.concat({ facetsText(task), task.revision, task.due, task.cursor, task.count }, " "))
        end,
    }
end

-- Facets as published, without anything that records when they were read.
local TIMES = { nextRead = true, updatedAt = true, age = true }
local function published(run)
    return facetsText(run.task, TIMES)
end

local goldenPath = root .. "/tests/fixtures/scheduler-model-golden.txt"
if writing then
    local lines = {}
    for _, variant in ipairs(ORDER) do
        lines[#lines + 1] = variant .. " " .. table.concat(parity.extraction(adapter(variant), trace).snapshots, " ")
    end
    local file = assert(hostIo.open(goldenPath, "w"))
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    recordedService = modelService
end
local golden = {}
do
    local file = assert(hostIo.open(goldenPath, "r"))
    for line in file:lines() do
        local name, rest = string.match(line, "^(%a+) (.*)$")
        golden[name] = { snapshots = {} }
        for hash in string.gmatch(rest, "%x+") do
            table.insert(golden[name].snapshots, hash)
        end
    end
    file:close()
end

local released = 0
for _, variant in ipairs(ORDER) do
    local a = adapter(variant)
    local expected = golden[variant]
    equal(#expected.snapshots, #trace, variant .. ": the golden file covers the trace")

    -- 2. Extraction: the legacy loop running the extracted work.
    local extraction = parity.extraction(a, trace)
    parity.assertSame(expected, extraction, variant .. " extraction")
    assert(#extraction.schedule > 20, variant .. ": the legacy run released the task")
    released = released + #extraction.schedule
    local lastLegacy = extraction.task.revision

    -- 3. Ownership flip by replay: the schedule replayed into `step`.
    parity.assertSame(expected, parity.replay(a, trace, extraction.schedule), variant .. " replay")

    -- 4. Budgeted, ample room: the planner releases exactly when the legacy loop did.
    local ample = parity.budgeted(a, trace)
    parity.assertSame(expected, ample, variant .. " budgeted, ample room")
    equal(ample.task.revision, lastLegacy, variant .. ": the same number of updates")

    -- 4. Budgeted, cut: head work leaves no room in some callbacks and room for
    -- only part of the facets in others (the planner grants fewer units).
    local tight = parity.budgeted(a, trace, {
        used = function(callback)
            local phase = callback.index % 4
            return (phase == 1 and 12598) or (phase == 2 and 13000) or 0
        end,
    })
    local timing = parity.timing(extraction, tight, trace[#trace].now)
    assert(timing.late > 0, variant .. ": the cut budget must delay some release")
    -- A release the cut budget skips just before a late callback waits for that callback.
    assert(timing.late <= LATE + 60, variant .. ": a release was more than 60 ticks late: " .. timing.late)
    assert(timing.budgetedGap <= timing.legacyGap + 60, variant .. ": the longest gap grew by more than 60 ticks")
    local regular = { schedule = {} }
    for _, call in ipairs(extraction.schedule) do
        local last = trace[math.min(call.index + 6, #trace)]
        if last.now - call.now < LATE then
            regular.schedule[#regular.schedule + 1] = call
        end
    end
    assert(#regular.schedule > 20)
    timing = parity.timing(regular, tight, trace[#trace].now)
    assert(timing.late <= 60, variant .. ": a release with no late callback near it was more than 60 ticks late")
    local cap = math.min(#a.new().facets, modelService.decl.stages.run.maxUnits)
    local partial = 0
    for _, call in ipairs(tight.schedule) do
        assert(call.grant >= 1 and call.grant <= cap, variant .. ": grant " .. call.grant .. " of " .. cap)
        partial = partial + (call.grant < cap and 1 or 0)
    end
    if cap > 2 then
        assert(partial > 0, variant .. ": the cut budget must grant fewer facets than wanted")
    end
    equal(published(tight), published(extraction), variant .. ": every facet ends as in the legacy run")
end
assert(released > 50)

-- 5. The contract of `step` (checked on a service with all seven facets).
local function service(variant, now)
    local box = { world = trace[1].world }
    local instance = modelService.new(radio(box), services)
    instance.tickElapsed = scheduler.elapsed
    VARIANTS[variant or "seven"](instance)
    instance.due = now or 100
    local reads = 0
    for _, facet in ipairs(instance.facets) do
        local read = facet.read
        facet.read = function(...)
            reads = reads + 1
            return read(...)
        end
    end
    return instance, function()
        return reads
    end
end

do
    -- The declaration is one stage with a unit per facet, at the cap of the service.
    equal(scheduler.check(modelService.decl), nil, "a usable declaration")
    equal(modelService.update, nil, "migrated services have no legacy update entry point")
    local stage = modelService.decl.stages.run
    equal(modelService.new(services.environment({}), services).interval, INTERVAL, "at most once a second")
    equal(stage.maxUnits, 4)
    assert(stage.fixed + stage.perUnit <= 4000, "the smallest step is under the maximum task size")
    equal(modelService.decl.class, "normal")
    local s = scheduler.new({ steady = 1250, background = 1130 })
    local added, reason =
        s:add({ id = "service:model", decl = modelService.decl, instance = service().tasks.run, due = 0 })
    assert(added, reason)
end

do
    -- A due release reads `grant` facets round robin, advances the due time and
    -- the revision as `services.update` does, and returns the interval.
    local instance, reads = service()
    equal(instance.tasks.run.want, 7, "the units wanted follow the subscriptions")
    equal(instance:step(2, "run", 100), INTERVAL)
    equal(reads(), 2)
    equal(instance.revision, 1)
    equal(instance.due, 100 + INTERVAL)
    equal(instance.cursor, 3)
    equal(instance:step(4, "run", 200), INTERVAL)
    equal(reads(), 6, "four more facets")
    equal(instance.cursor, 7)
    equal(instance:step(4, "run", 300), INTERVAL)
    equal(instance.cursor, 4, "the ring of seven wraps")
    equal(instance.revision, 3)

    -- Fewer facets than the grant: only the ones subscribed to.
    local small, smallReads = service("three")
    equal(small.tasks.run.want, 3)
    small:step(4, "run", 100)
    equal(smallReads(), 3)

    -- Not due: nothing is read, nothing changes, and the delay is what remains.
    local idle, idleReads = service("seven", 200)
    equal(idle:step(4, "run", 190), 10)
    equal(idle:step(4, "run", 199), 1)
    equal(idleReads(), 0)
    equal(idle.revision, 0)
    equal(idle.due, 200)
end

do
    -- The legacy registry never runs a scheduler-owned service.
    local instance, reads = service("seven", 100)
    local runtime = services.runtime({})
    runtime.order[1], runtime.byId.model = instance, instance
    equal(services.update(runtime, 100), nil)
    equal(reads(), 0)
    equal(instance.revision, 0)
    equal(instance:step(4, "run", 100), INTERVAL)
    equal(reads(), 4)
    equal(instance.revision, 1)
end

do
    -- Ticks wrap like EdgeTX's int32 clock.
    local function wrapped(tick)
        return ((tick + 0x80000000) & 0xFFFFFFFF) - 0x80000000
    end
    local due = 0x7FFFFFFC
    local instance, reads = service("seven", due)
    equal(instance:step(4, "run", wrapped(due - 3)), 3, "three ticks early, before the wrap")
    equal(reads(), 0)
    equal(instance:step(4, "run", wrapped(due + 5)), INTERVAL, "five ticks late, after the wrap")
    equal(reads(), 4)
    equal(instance.due, wrapped(due + 5) + INTERVAL)
    equal(instance:step(4, "run", wrapped(due + 10)), scheduler.elapsed(wrapped(due + 5) + INTERVAL, wrapped(due + 10)))
end

do
    -- A failing read is not swallowed: the scheduler retires the task and reports it.
    local instance = service()
    instance.facets[1].read = function()
        error("radio failure")
    end
    local s = scheduler.new({ steady = 1250, background = 1130 })
    assert(s:add({ id = "service:model", decl = modelService.decl, instance = instance.tasks.run, due = 100 }))
    s:run("steady", 100, 0)
    equal(s.byId["service:model"], nil, "retired")
    local errors = s:takeErrors()
    assert(errors and string.find(errors[1].message, "radio failure", 1, true))
    equal(instance.revision, 0, "a failed update is not counted")
    equal(instance.failed, true, "shared adapter retires the service immediately")
end

do
    -- A release that finds nothing to do costs less than the smallest stage.
    local instance = service("seven", 1000)
    local count, pause = overhead.hookCounter()
    pause(true)
    pause(false)
    local first = count()
    instance:step(4, "run", 10)
    local cost = count() - first
    debug.sethook()
    local stage = modelService.decl.stages.run
    assert(cost < (stage.fixed + stage.perUnit) / 4, "a no-work exit cost " .. cost)
end

print("Scheduler model task parity passed")
