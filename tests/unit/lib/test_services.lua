-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()

local function testEnvironmentAndRuntime()
    local env = services.environment({
        getValue = function()
            return 7
        end,
        getFieldInfo = function()
            return { id = 9 }
        end,
        getSourceValue = function()
            return 7
        end,
        setTelemetryValue = function()
            return false
        end,
    })
    assertions.assertEqual(type(env.getValue), "function")
    assertions.assertEqual(type(env.getFieldInfo), "function")
    assertions.assertEqual(type(env.getSourceValue), "function")
    assertions.assertEqual(type(env.setTelemetryValue), "function")
    for _, definition in ipairs(services.DEFINITIONS) do
        assert(definition.id ~= "telemetryPublisher", "publisher is runtime-owned, not a scheduled service")
    end

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
    services.step({ owner = service, registry = runtime }, 0, 1)
    assertions.assertEqual(service.revision, 1)
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

local function run()
    testEnvironmentAndRuntime()
    testRoundRobin()
    testSubscriptionOwnership()
    local runtime = services.runtime({})
    local granted
    local service = {
        id = "variable",
        interval = 10,
        due = 0,
        count = 1,
        revision = 0,
        update = function(_, _, slots)
            granted = slots
            return 2, true
        end,
    }
    local task = { owner = service, registry = runtime }
    local used, again = services.step(task, 5, 5)
    assert(used == 2 and again == true and granted == 5, "the step must pass the grant and return the update's result")
    assert(service.due == 15 and task.due == 15 and service.revision == 1 and runtime.updates == 1)
end

run()
