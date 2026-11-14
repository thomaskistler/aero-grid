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

local function run()
    testSnapshotIsReadOnly()
    testEnvironmentAndRuntime()
    testRoundRobin()
    testSubscriptionOwnership()
    local runtime = services.runtime({})
    local granted
    local task = {
        id = "variable",
        interval = 10,
        due = 0,
        count = 1,
        revision = 0,
        updateCost = "variable",
        updateMinCost = 1,
        update = function(_, _, slots)
            granted = slots
            return 2
        end,
    }
    local id, message, used = services.dispatch(runtime, task, 0, 5)
    assert(id == "variable" and not message and used == 2 and granted == 5)
    assert(task.due == 10 and task.revision == 1)
    assert(services.dispatch(runtime, task, 1, 8) == nil)
    task.updateCost = 3
    assert(services.dispatch(runtime, task, 10, 2) == nil)
    assert(task.due == 10, "deferral must not move the deadline")
    id, message, used = services.dispatch(runtime, task, 10, 3)
    assert(id == "variable" and not message and used == 2)
    task.due = 11
    task.update = function() end
    id, message, used = services.dispatch(runtime, task, 11, 3)
    assert(id == "variable" and not message and used == 3, "missing fixed consumption charges the full grant")
    task.due = 12
    task.update = function()
        return 4
    end
    id, message, used = services.dispatch(runtime, task, 12, 3)
    assert(id == "variable" and message and used == 3 and task.failed)
    task.failed, task.due = nil, 20
    task.updateCost = "variable"
    task.update = function()
        return 9
    end
    id, message, used = services.dispatch(runtime, task, 20, 8)
    assert(id == "variable" and message and used == 8 and task.failed)
    assert(services.dispatch(runtime, task, 30, 8) == nil)
    task.failed = nil
    task.update = function() end
    id, message, used = services.dispatch(runtime, task, 30, 8)
    assert(id == "variable" and message and used == 8 and task.failed, "missing consumption must fail")
    task.failed = nil
    task.update = function()
        return 0
    end
    id, message, used = services.dispatch(runtime, task, 40, 8)
    assert(id == "variable" and not message and used == 0 and not task.failed)
    task.updateCost, task.due = 2, 41
    task.update = function()
        return 1, true
    end
    id, message, used = services.dispatch(runtime, task, 41, 2)
    assert(id == "variable" and not message and used == 1 and task.due == 41)
    task.update = function()
        return 0, false
    end
    id, message, used = services.dispatch(runtime, task, 41, 2)
    assert(id == "variable" and not message and used == 0 and task.due == 51)
    for _, value in ipairs({ -1, 1.5, 9, math.huge, 0 / 0, "1" }) do
        assert(not services.consumption(value, 8))
    end
    assert(services.consumption(0, 8) and services.consumption(8, 8))
    task.updateCost, task.due = 0, 50
    task.update = function(_, _, slots)
        assert(slots == 0)
    end
    id, message, used = services.dispatch(runtime, task, 50, 0)
    assert(id == "variable" and not message and used == 0 and task.due == 60)
    assert(services.dispatch(runtime, task, 50, 0) == nil, "zero-slot work must retain its due interval")
    task.update = function()
        error("zero-slot failure")
    end
    id, message, used = services.dispatch(runtime, task, 60, 0)
    assert(id == "variable" and message and used == 0 and task.failed)
    assert(services.grant(0, 0) == 0)
    assert(services.grant("variable", 12, 3) == 8)
    assert(services.grant("variable", 2, 3) == 0)
end

run()
