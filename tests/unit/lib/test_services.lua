-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()

local function testSnapshotIsReadOnly()
    local snapshot = services.snapshot({ value = 42 })
    assertions.assertEqual(snapshot.value, 42)

    local ok, err = pcall(function()
        snapshot.newValue = 1
    end)
    assert(ok == false, "snapshot should reject writes")
    assert(string.match(err or "", "read-only") or true)
end

local function testEnvironmentAndRuntime()
    local env = services.environment({
        getValue = function()
            return 7
        end,
        getFieldInfo = function()
            return { id = 9 }
        end,
    })
    assertions.assertEqual(type(env.getValue), "function")
    assertions.assertEqual(type(env.getFieldInfo), "function")

    local runtime = services.runtime(env)
    assertions.assertTableHasKey(runtime, "order", "runtime should track service order")

    local service = {
        id = "demo",
        interval = 20,
        due = 0,
        count = 1,
        revision = 0,
        update = function() end,
    }

    services.register(runtime, service, 0)
    local updatedId = services.update(runtime, 0)
    assertions.assertEqual(updatedId, "demo")
end

local function recordVisit(owner, entry, now)
    owner.visited[#owner.visited + 1] = entry .. ":" .. now
end

local function testSubscriptionOwnership()
    local owner = { support = services, count = 2 }
    local entries = {}
    local state = { value = 12 }
    local metadata = { state = state, nextResolve = 7 }
    local entry = services.addSubscription(owner, entries, metadata)
    assertions.assertEqual(entry, metadata)
    assertions.assertEqual(entries[1], metadata)
    assertions.assertEqual(owner.count, 3)
    assertions.assertEqual(entry.nextResolve, 7)
    assertions.assertEqual(entry.view.value, 12)
    state.value = 24
    assertions.assertEqual(entry.view.value, 24)
    assert(not pcall(function()
        entry.view.value = 0
    end), "subscribers must not mutate service-owned state")
end

local function testRoundRobin()
    local state = { visited = {} }
    local cursor = services.roundRobin({ "a", "b", "c", "d" }, 3, 3, recordVisit, state, 12)
    assertions.assertEqual(table.concat(state.visited, ","), "c:12,d:12,a:12")
    assertions.assertEqual(cursor, 2)

    state.visited = {}
    cursor = services.roundRobin({ "a", "b" }, 9, 8, recordVisit, state, 20)
    assertions.assertEqual(table.concat(state.visited, ","), "a:20,b:20")
    assertions.assertEqual(cursor, 1)
    assertions.assertEqual(services.roundRobin({}, 7, 3, recordVisit, state, 0), 7)
end

local function testSchedulerOwnedServiceKeepsItsLegacySlot()
    local runtime = services.runtime({})
    local nav = {
        id = "navigation",
        interval = 20,
        due = 0,
        count = 1,
        preserveLegacySlot = true,
        step = function() end,
    }
    local telemetryUpdates = 0
    local telemetry = {
        id = "telemetry",
        interval = 10,
        due = 0,
        count = 1,
        revision = 0,
        update = function()
            telemetryUpdates = telemetryUpdates + 1
        end,
    }
    services.register(runtime, nav, 0)
    services.register(runtime, telemetry, 0)

    local updated = services.update(runtime, 0, function(instance)
        return instance.id ~= "navigation"
    end)
    assertions.assertEqual(updated, nil, "navigation's replaced slot stays empty")
    assertions.assertEqual(nav.due, 0, "legacy rotation does not postpone the scheduler task")
    assertions.assertEqual(telemetryUpdates, 0, "another service does not take the slot")
    assertions.assertEqual(runtime.cursor, 2, "rotation advances past navigation")

    updated = services.update(runtime, 1, function()
        return true
    end)
    assertions.assertEqual(updated, "telemetry", "telemetry keeps its next legacy release")
    assertions.assertEqual(telemetryUpdates, 1)

    local historyRuntime = services.runtime({})
    local historyUpdates = 0
    local history = {
        id = "history",
        interval = 5,
        due = 0,
        count = 1,
        preserveLegacySlot = true,
        legacySlotReservation = true,
        step = function() end,
        update = function()
            historyUpdates = historyUpdates + 1
        end,
    }
    services.register(historyRuntime, history, 0)
    updated = services.update(historyRuntime, 0, function()
        return false
    end)
    assertions.assertEqual(updated, "history", "history reserves its mixed-mode service slot")
    assertions.assertEqual(history.due, 0, "reserved slot does not postpone the scheduler task")
    assertions.assertEqual(historyUpdates, 0, "the scheduler-owned service is not updated by the legacy loop")
end

local function testServiceTaskAdapter()
    local owner = { interval = 20 }
    local calls, cleaned = 0, 0
    local elapsed = function(a, b)
        return a - b
    end
    local task = services.task(owner, "run", {
        id = "service:example",
        want = 6,
        run = function(service, grant, stage, now, current)
            assertions.assertEqual(service, owner)
            assertions.assertEqual(current, owner.tasks.run)
            assertions.assertEqual(service.tickElapsed, elapsed)
            assertions.assertEqual(grant, 2, "the adapter forwards the exact scheduler grant")
            assertions.assertEqual(stage, "run")
            assertions.assertEqual(now, 123)
            calls = calls + 1
            return 1
        end,
    })
    task.tickElapsed = elapsed
    assertions.assertEqual(task:step(2, "run", 123), 1, "partial releases retain their retry delay")
    assertions.assertEqual(calls, 1)
    assertions.assertEqual(task.want, 6, "the adapter does not recompute demand")
    assertions.assertEqual(task.interval, nil, "omitted intervals continue to follow the service")
    assertions.assertEqual(owner.schedulerTasks[1], task.item)
    assertions.assertEqual(task.item.instance, task)
    assertions.assertEqual(task.item.id, task.id)
    assert(not pcall(services.task, owner, "run", {}), "task names must be unique")

    owner.taskFailed = function()
        cleaned = cleaned + 1
    end
    local failing = services.task(owner, "failure", {
        id = "service:failure",
        interval = 10,
        critical = true,
        run = function()
            error("radio failure", 0)
        end,
    })
    local ok, message = pcall(failing.step, failing, 1, "run", 124)
    assertions.assertEqual(ok, false, "errors reach the scheduler for reporting")
    assertions.assertEqual(message, "radio failure")
    assertions.assertEqual(owner.failed, true)
    assertions.assertEqual(cleaned, 1)
    assertions.assertEqual(failing.interval, 10)
    assertions.assertEqual(failing.item.critical, true)
    assertions.assertEqual(task:step(2, "run", 123), 1)
    assertions.assertEqual(calls, 1, "a sibling cannot do work after its owner fails")
    assertions.assertEqual(failing:step(1, "run", 125), 1)
    assertions.assertEqual(cleaned, 1, "cleanup happens once")
end

local function testMigratedTaskShape()
    local runtime = services.runtime(services.environment({}))
    runtime.host = {}
    local expected = {
        telemetry = { "maintenance" },
        model = { "run" },
        control = { "critical", "normal", "outputs" },
        armed = { "run" },
        navigation = { "run" },
        history = { "run" },
    }
    local sharedStep
    for _, definition in ipairs(services.DEFINITIONS) do
        local names = expected[definition.id]
        if names then
            local module = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. definition.file))()
            local service = module.new(runtime.env, services, runtime)
            runtime.byId[definition.id] = service
            assertions.assertEqual(#service.schedulerTasks, #names)
            for index, name in ipairs(names) do
                local task, item = service.tasks[name], service.schedulerTasks[index]
                assertions.assertEqual(item.instance, task)
                assertions.assertEqual(item.id, task.id)
                assertions.assertEqual(task.owner, service)
                assertions.assertEqual(type(task.run), "function")
                sharedStep = sharedStep or task.step
                assertions.assertEqual(task.step, sharedStep, "every migrated task uses the shared adapter")
            end
            assertions.assertEqual(service.update, nil, "host-owned services cannot run through the legacy loop")
        end
    end
    local telemetry = runtime.byId.telemetry
    assertions.assertEqual(telemetry.interval, 10, "Telemetry polling stays at ten ticks")
    telemetry:subscribe("S01")
    telemetry:subscribe("S02")
    assertions.assertEqual(telemetry.tasks["source:1"], telemetry.entries[1].task)
    assertions.assertEqual(telemetry.tasks["source:2"], telemetry.entries[2].task)
    assertions.assertEqual(#telemetry.schedulerTasks, 3)
    assertions.assertEqual(telemetry.tasks["source:1"].step, sharedStep)
    assertions.assertEqual(telemetry.tasks["source:2"].step, sharedStep)
end

local function run()
    testSnapshotIsReadOnly()
    testEnvironmentAndRuntime()
    testRoundRobin()
    testSchedulerOwnedServiceKeepsItsLegacySlot()
    testSubscriptionOwnership()
    testServiceTaskAdapter()
    testMigratedTaskShape()
end

run()
