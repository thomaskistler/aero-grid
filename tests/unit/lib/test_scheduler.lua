-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local equal = assertions.assertEqual

local OVERHEAD = { steady = 1000, background = 800 }
local FIXED, EXAMINE, RUN = scheduler.FIXED_COST, scheduler.EXAMINE_COST, scheduler.RUN_COST
local CHARGE = EXAMINE + RUN
local ROOM = scheduler.CEILING - scheduler.MARGIN - OVERHEAD.steady - FIXED

local function single(class, cost, extra)
    local decl = { class = class, stages = { run = { fixed = 0, perUnit = cost, maxUnits = 1 } } }
    for key, value in pairs(extra or {}) do
        decl[key] = value
    end
    return decl
end

-- A task that logs its calls into `log` and returns `delay`.
local function task(log, name, delay)
    local instance = { name = name }
    function instance.step(self, grant, stage, now)
        log[#log + 1] = name .. ":" .. stage .. ":" .. grant
        return type(delay) == "function" and delay(self, now) or delay or 10
    end
    return instance
end

local function add(s, id, decl, instance, due)
    local ok, message = s:add({ id = id, decl = decl, instance = instance, due = due or 0 })
    assert(ok, message)
end

local function testRemovingAnIdleListedTaskUnlistsIt()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    add(s, "a", single("critical", 100), task(log, "a"), 500)
    add(s, "b", single("normal", 100), task(log, "b"), 500)
    equal(s:remove("a"), true)
    equal(s:remove("b"), true)
    equal(#s.lists[1] + #s.lists[2], 0, "nothing stays listed")
    equal(s:run("steady", 1000), 0)
    equal(#log, 0, "a removed task never runs")
    equal(s.count, 0)
    add(s, "a", single("critical", 100), task(log, "a"), 0)
    equal(s:run("steady", 1000), 1, "its id can return")
end

local function testReschedulingPreservesIdentityAndOrder()
    for _, class in ipairs({ "critical", "normal" }) do
        local log, s = {}, scheduler.new(OVERHEAD)
        local decl = single(class, 100, { shared = { sample = 50 } })
        for index = 1, 4 do
            add(s, index, decl, task(log, index), index * 100)
        end
        local record, seq, refs = s.byId[4], s.seq, s.sharedRefs.sample
        assert(s:reschedule(4, 50))
        equal(record.list[1], record)
        assert(s:reschedule(4, 500))
        equal(record.list[4], record)
        assert(s:reschedule(4, 100))
        equal(record.list[1].id, 1, "equal releases retain original tie-breaking order")
        equal(record.list[2], record)
        equal(s.byId[4], record)
        equal(s.count, 4)
        equal(s.seq, seq)
        equal(s.sharedRefs.sample, refs)
        equal(s:run("steady", 100), 2)
        equal(table.concat(log, ","), "1:run:1,4:run:1")
        equal(s:dueOf(2), 200, "unrelated releases are untouched")
        equal(s:dueOf(3), 300)
        equal(s:dueOf(4), 110)
    end
end

local function testReschedulingWrapsAndRejectsInvalidReleases()
    for _, base in ipairs({ 0x7ffffff0, 0xfffffff0 }) do
        local log, s = {}, scheduler.new(OVERHEAD)
        add(s, "first", single("normal", 100), task(log, "first"), base + 10)
        add(s, "last", single("normal", 100), task(log, "last"), base + 20)
        assert(s:reschedule("last", base - 10))
        equal(s.lists[2][1].id, "last")
        equal(s:run("steady", base), 1)
        equal(log[1], "last:run:1")
        assert(s:reschedule("first", base + 30))
        equal(s.lists[2][2].id, "first")
    end
    local s = scheduler.new(OVERHEAD)
    add(s, "a", single("normal", 100), task({}, "a"), 50)
    for _, due in ipairs({ false, "10", 1.5, 0 / 0, math.huge }) do
        local ok, reason = s:reschedule("a", due)
        equal(ok, false)
        equal(reason, "due must be a whole number of ticks")
        equal(s:dueOf("a"), 50)
    end
    local ok, reason = s:reschedule("missing", 0)
    equal(ok, false)
    equal(reason, "task is not registered")
    local callback = {
        step = function()
            for _, id in ipairs({ "a", "b" }) do
                local accepted, message = s:reschedule(id, 100)
                equal(accepted, false, "running and already planned releases are rejected")
                equal(message, "task is already planned")
            end
            return 10
        end,
    }
    s:remove("a")
    add(s, "a", single("normal", 100), callback, 0)
    add(s, "b", single("normal", 100), task({}, "b"), 0)
    equal(s:run("steady", 0), 2)
    equal(s:dueOf("a"), 10)
    equal(s:dueOf("b"), 10)
end

local function testInvalidStagesRetireWithoutRunning()
    local s = scheduler.new({ steady = 0 })
    for index = 1, 3 do
        local instance = task({}, index)
        instance.stage = "missing"
        add(s, index, single("normal", 100), instance, 0)
    end
    equal(s:run("steady", 1), 0, "nothing runs")
    equal(s.lastPlan.ran, 3, "a retired task counts as run")
    equal(s.lastPlan.examined, 3)
    equal(#s:takeErrors(), 3)
end

local function testKindsAreCheckedWithReasons()
    local s = scheduler.new({ steady = 1000, background = 800 })
    local decl = function(kinds)
        return single("normal", 100, { kinds = kinds })
    end
    local function refused(kinds, text)
        local ok, reason = s:add({ id = text, decl = decl(kinds), instance = task({}, text), due = 0 })
        equal(ok, false, text)
        assert(
            string.find(reason, text == "empty" and "no callback" or "kind", 1, true),
            text .. ": " .. tostring(reason)
        )
    end
    refused({ stedy = true }, "unknown name")
    refused({ steady = true, stedy = true }, "unknown name beside a known one")
    refused({ steady = false }, "all false")
    refused({ steady = false, background = false }, "all false, two kinds")
    refused({ steady = "yes" }, "non-boolean value")
    refused({ steady = true, background = 1 }, "non-boolean beside a boolean")
    refused({}, "empty")
    add(s, "ok1", decl({ steady = true }), task({}, "x"), 0)
    add(s, "ok2", decl({ steady = false, background = true }), task({}, "x"), 0)
    equal(s:run("steady", 1), 1, "only the steady task ran in a steady callback")
    equal(
        scheduler.new({ modal = 0 }):add({ id = "m", decl = single("normal", 10), instance = task({}, "m"), due = 0 }),
        false
    )
end

local function testDeclarationsAreReadOnceAndCostsBounded()
    local decl = single("normal", 100)
    local s = scheduler.new({ steady = 0 })
    local log = {}
    add(s, "a", decl, task(log, "a"), 0)
    decl.stages.run.perUnit = 0
    decl.stages.run.maxUnits = 1 << 40
    decl.kinds = { nowhere = true }
    add(s, "b", decl, task(log, "b"), 0)
    local ok = pcall(s.run, s, "steady", 1)
    equal(ok, true, "changing a declaration after the first add cannot make run raise")
    equal(#log, 2)
    for _, bad in ipairs({
        single("normal", math.maxinteger - 100),
        single("normal", scheduler.CEILING + 1),
        { class = "normal", stages = { run = { fixed = scheduler.CEILING + 1, perUnit = 1, maxUnits = 1 } } },
        { class = "normal", stages = { run = { fixed = 0, perUnit = 1, maxUnits = scheduler.CEILING + 1 } } },
        single("normal", 10, { shared = { x = math.maxinteger } }),
        single("normal", 10, { shared = { x = scheduler.CEILING + 1 } }),
        single("normal", 10, { shared = "link" }),
        single("normal", 10, { shared = 5 }),
    }) do
        local fresh = scheduler.new({ steady = 0 })
        local added, reason = fresh:add({ id = "x", decl = bad, instance = task({}, "x"), due = 0 })
        equal(added, false)
        assert(type(reason) == "string")
    end
end

local function testSharedNamesAreFreedWithTheirLastTask()
    local s = scheduler.new({ steady = 0 })
    local a = single("normal", 10, { shared = { link = 100 } })
    local b = single("normal", 10, { shared = { link = 200 } })
    add(s, "a1", a, task({}, "a1"), 0)
    add(s, "a2", a, task({}, "a2"), 0)
    equal(s:add({ id = "b", decl = b, instance = task({}, "b"), due = 0 }), false, "one name, one cost")
    s:remove("a1")
    equal(s:add({ id = "b", decl = b, instance = task({}, "b"), due = 0 }), false, "still used by a2")
    s:remove("a2")
    equal(next(s.sharedCost), nil, "the last user frees the name")
    equal(next(s.sharedRefs), nil)
    add(s, "b", b, task({}, "b"), 0)
    equal(s.sharedCost.link, 200)
    local retiring = task({}, "r")
    retiring.stage = "missing"
    add(s, "r", single("normal", 10, { shared = { gone = 5 } }), retiring, 0)
    s:run("steady", 1)
    equal(s.sharedCost.gone, nil, "a retired task frees its names")
    -- A name freed by one declaration can be taken by another with a new cost,
    -- and the first declaration is checked again at every add.
    s:remove("b")
    add(s, "a3", a, task({}, "a3"), 0)
    equal(s:add({ id = "b2", decl = b, instance = task({}, "b2"), due = 0 }), false)
end

local function testDueIsRequiredAndStaggerGivesIntegers()
    local s = scheduler.new(OVERHEAD)
    local ok, reason = s:add({ id = "a", decl = single("normal", 10), instance = task({}, "a") })
    equal(ok, false)
    assert(string.find(reason, "due", 1, true))
    equal(math.type(scheduler.stagger(3, 25.0)), "integer")
    equal(math.type(scheduler.stagger(3.0, 25)), "integer")
    equal(scheduler.stagger(3, 25.0), 15)
end

local function testRunRaisesOnlyForAWrongCall()
    local s = scheduler.new(OVERHEAD)
    add(s, "a", single("normal", 10), task({}, "a"), 0)
    for _, call in ipairs({
        { "nowhere", 1 },
        { "steady", "1" },
        { "steady", 1.5 },
        { "steady", 1, {} },
        { "steady", 1, "5" },
    }) do
        local called = pcall(s.run, s, call[1], call[2], call[3])
        equal(called, false, "call " .. tostring(call[1]) .. " " .. tostring(call[2]) .. " " .. tostring(call[3]))
    end
    equal(pcall(s.run, s, "steady", 5, 100), true)
end

local function testNegativeRoomDefersTasksWithoutAnError()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    add(s, "a", single("normal", 10), task(log, "a"), 0)
    equal(s:run("steady", 1, scheduler.CEILING), 0)
    equal(#log, 0, "no task runs without room")
    equal(s:dueOf("a"), 0, "a deferred task keeps its release")
    equal(s:takeErrors(), nil, "lack of room is not a task error")
end

local function testDeclarationChecks()
    local good = single("normal", 100)
    equal(scheduler.check(good), nil)
    local bad = {
        { class = "high", stages = good.stages },
        { class = "normal" },
        { class = "normal", stages = {} },
        { class = "normal", stages = good.stages, first = "begin" },
        { class = "normal", stages = { run = { fixed = -1, perUnit = 1, maxUnits = 1 } } },
        { class = "normal", stages = { run = { fixed = 0, perUnit = 0, maxUnits = 1 } } },
        { class = "normal", stages = { run = { fixed = 0, perUnit = 1.5, maxUnits = 1 } } },
        { class = "normal", stages = { run = { fixed = 0, perUnit = 1, maxUnits = 0 } } },
        { class = "normal", stages = good.stages, shared = { link = -5 } },
        { class = "normal", stages = good.stages, kinds = true },
        { class = "normal", stages = good.stages, shared = { a = 1, b = 1, c = 1 } },
    }
    for index, decl in ipairs(bad) do
        assert(scheduler.check(decl), "declaration " .. index .. " should be rejected")
    end
    local s = scheduler.new(OVERHEAD)
    local ok = s:add({ due = 0, id = "x", decl = bad[1], instance = task({}, "x") })
    equal(ok, false)
    ok = s:add({ due = 0, id = "x", decl = good, instance = {} })
    equal(ok, false, "an instance needs a step")
    equal(s:add({ due = 0, id = "x", decl = good, instance = task({}, "x") }), true)
    equal(s:add({ due = 0, id = "x", decl = good, instance = task({}, "x") }), false, "ids are unique")
    equal(s:remove("x"), true)
    equal(s:remove("x"), false)
    equal(s:add({ due = 0, id = "x", decl = good, instance = task({}, "x") }), true, "a removed id can return")
end

local function testTaskLimit()
    local s = scheduler.new(OVERHEAD)
    local decl = single("normal", 10)
    for index = 1, scheduler.MAX_TASKS do
        add(s, index, decl, task({}, index))
    end
    equal(s:add({ due = 0, id = "extra", decl = decl, instance = task({}, "extra") }), false)
end

local function testStagger()
    equal(scheduler.stagger(0, 25), 0)
    equal(scheduler.stagger(4, 25), 20)
    equal(scheduler.stagger(5, 25), 0)
    equal(scheduler.stagger(7, 25), 10)
    equal(scheduler.stagger(3, 5), 0)
    equal(scheduler.stagger(4, 12), 5, "an interval is rounded up to whole slots")
end

local function testOldestFirstAndClassOrder()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    add(s, "n-late", single("normal", 100), task(log, "n-late"), 5)
    add(s, "n-early", single("normal", 100), task(log, "n-early"), 1)
    add(s, "c-late", single("critical", 100), task(log, "c-late"), 5)
    add(s, "c-early", single("critical", 100), task(log, "c-early"), 2)
    add(s, "c-tie", single("critical", 100), task(log, "c-tie"), 5)
    equal(s:run("steady", 10), 5)
    equal(table.concat(log, " "), "c-early:run:1 c-late:run:1 c-tie:run:1 n-early:run:1 n-late:run:1")
end

local function testNotReadyTasksWait()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    add(s, "a", single("critical", 100), task(log, "a", 10), 20)
    equal(s:run("steady", 19), 0)
    equal(s:run("steady", 20), 1)
    equal(s:dueOf("a"), 30, "due is the callback time plus the delay")
    equal(s:run("steady", 29), 0)
    equal(s:run("steady", 100), 1, "a late release runs once, with no catch-up")
    equal(s:dueOf("a"), 110)
end

local function testPlanStaysUnderTheBudget()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    for index = 1, 8 do
        add(s, index, single("normal", 2000), task(log, index), 0)
    end
    s:run("steady", 1, 500)
    local limit = scheduler.CEILING - scheduler.MARGIN
    equal(s.lastPlan.kind, "steady")
    local expected = (limit - OVERHEAD.steady - FIXED - 500) // (2000 + CHARGE)
    equal(#log, expected, "as many as fit, no more")
    equal(s.lastPlan.examined, expected, "the scan stops when nothing more fits")
    equal(select("#", s:run("background", 2)), 1)
    equal(s.lastPlan.kind, "background")
end

local function testSkipAndContinueKeepsTheWaiterFirst()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    local room = ROOM
    add(s, "big", single("normal", room - 3 * CHARGE - 100), task(log, "big", 1), 0)
    add(s, "huge", single("normal", room - CHARGE), task(log, "huge", 1), 1)
    add(s, "small", single("normal", 50), task(log, "small", 1), 2)
    equal(s:run("steady", 5), 2, "big and small fit together, huge never fits")
    equal(table.concat(log, " "), "big:run:1 small:run:1")
    equal(s:dueOf("huge"), 1, "a task that did not fit keeps its release")
    assert(s.lists[2][1] == s.byId.huge, "the waiter is still first")
    log[1], log[2] = nil, nil
    s:run("steady", 6)
    equal(log[1], "huge:run:1", "the oldest waiter goes first as soon as it fits")
end

local function testCriticalIsNeverDroppedAndKeepsItsPlace()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    local critical = ROOM - scheduler.NORMAL_RESERVE - CHARGE + 1
    add(s, "c", single("critical", critical), task(log, "c"), 0)
    add(s, "n", single("normal", 100), task(log, "n"), 0)
    s:run("steady", 1)
    equal(table.concat(log, " "), "n:run:1", "a critical task above the reserved limit waits")
    equal(s:dueOf("c"), 0)
    s:run("steady", 2, 0)
    equal(s:dueOf("c"), 0, "and is not dropped")
    log = {}
    s = scheduler.new({ steady = OVERHEAD.steady - 1 })
    add(s, "c", single("critical", critical), task(log, "c"), 0)
    s:run("steady", 1)
    equal(#log, 1, "it runs as soon as it fits")
end

local function testNormalReserve()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    local limit = ROOM - scheduler.NORMAL_RESERVE - 2 * CHARGE
    local half = limit // 2
    add(s, "c1", single("critical", half), task(log, "c1"), 0)
    add(s, "c2", single("critical", limit - half + 1), task(log, "c2"), 0)
    add(s, "n", single("normal", scheduler.NORMAL_RESERVE), task(log, "n"), 0)
    s:run("steady", 1)
    equal(table.concat(log, " "), "c1:run:1 n:run:1", "critical stops at the reserve and normal gets it")
end

local function testGrantsInUnits()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    local decl = { class = "normal", stages = { run = { fixed = 200, perUnit = 1000, maxUnits = 9 } } }
    local instance = task(log, "chart")
    add(s, "chart", decl, instance, 0)
    s:run("steady", 1)
    equal(log[1], "chart:run:9", "no want means the cap")
    instance.want = 4
    s:run("steady", 100)
    equal(log[2], "chart:run:4")
    instance.want = 400
    s:run("steady", 200)
    equal(log[3], "chart:run:9", "want is capped by maxUnits")
    instance.want = 2.5
    s:run("steady", 300)
    equal(log[4], "chart:run:2", "a fractional want rounds down")
    instance.want = 0
    s:run("steady", 400)
    equal(log[5], "chart:run:1", "a task that runs gets at least one unit")
    instance.want = "many"
    s:run("steady", 500)
    equal(log[6], "chart:run:9")
    local tight = scheduler.new({ steady = scheduler.CEILING - scheduler.MARGIN - FIXED - CHARGE - 200 - 3 * 1000 - 5 })
    local log2 = {}
    add(tight, "chart", decl, task(log2, "chart"), 0)
    tight:run("steady", 1)
    equal(log2[1], "chart:run:3", "the grant is what fits")
end

local function testExclusiveAndKinds()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    local chart = single("normal", 300, { exclusive = true, kinds = { steady = true } })
    add(s, "chart1", chart, task(log, "chart1"), 0)
    add(s, "chart2", chart, task(log, "chart2"), 1)
    add(s, "plain", single("normal", 300), task(log, "plain"), 2)
    s:run("steady", 10)
    equal(table.concat(log, " "), "chart1:run:1 plain:run:1", "one exclusive task per callback")
    log[1], log[2] = nil, nil
    s:run("steady", 100)
    equal(table.concat(log, " "), "chart2:run:1 plain:run:1", "the waiting chart goes first")
    log[1], log[2] = nil, nil
    s:run("background", 200)
    equal(table.concat(log, " "), "plain:run:1", "steady-only tasks do not run in a background callback")
    log[1] = nil
    local critical = single("critical", 300, { exclusive = true })
    add(s, "c-excl", critical, task(log, "c-excl"), 0)
    add(s, "chart3", chart, task(log, "chart3"), 0)
    for _, id in ipairs({ "c-excl", "chart1", "chart2", "chart3" }) do
        assert(s:reschedule(id, 300))
    end
    log[1] = nil
    s:run("steady", 300)
    equal(log[1], "c-excl:run:1")
    for index = 2, #log do
        assert(not string.find(log[index], "chart", 1, true), "a second exclusive task ran")
    end
end

local function testSharedCostIsChargedOncePerPlan()
    local log = {}
    local decl = single("critical", 1000, { shared = { link = 560 } })
    local limit = ROOM - scheduler.NORMAL_RESERVE
    local s = scheduler.new(OVERHEAD)
    for index = 1, 12 do
        add(s, index, decl, task(log, index), 0)
    end
    s:run("steady", 1)
    local fits = (limit - 560) // (1000 + CHARGE)
    equal(#log, fits)
    local before = #log
    s:run("steady", 100)
    local second = #log - before
    equal(second, fits, "shared work is reserved again in the next callback")
end

local function testReadyTasksHaveNoCountCap()
    local log = {}
    local s = scheduler.new({ steady = 0 })
    for index = 1, 20 do
        add(s, "c" .. index, single("critical", 10), task(log, "c" .. index), index)
    end
    for index = 1, 20 do
        add(s, "n" .. index, single("normal", 10), task(log, "n" .. index), 100 + index)
    end
    equal(s:run("steady", 1000), 40, "every ready task that fits runs, with no count cap")
    for index = 1, 20 do
        equal(log[index], "c" .. index .. ":run:1")
        equal(log[20 + index], "n" .. index .. ":run:1")
    end

    local crowd = scheduler.new({ steady = 0 })
    for index = 1, scheduler.MAX_TASKS do
        add(crowd, index, single("normal", 10), task({}, index), 0)
    end
    local room = scheduler.CEILING - scheduler.MARGIN - FIXED
    local ran = crowd:run("steady", 1)
    equal(ran, room // (10 + CHARGE), "the budget, not a cap, ends the scan")
    equal(crowd.lastPlan.examined, ran)

    local refused = scheduler.new({ steady = 0 })
    for index = 1, scheduler.MAX_TASKS - 1 do
        add(refused, index, single("normal", 12000), task({}, index), 0)
    end
    add(refused, "tiny", single("normal", 1), task({}, "tiny"), 10 ^ 9)
    equal(refused:run("steady", 1, 6000), 0, "none fits beside the 6000 already used")
    equal(refused.lastPlan.examined, scheduler.MAX_TASKS - 1, "tasks that do not fit are charged, all of them")
end

local function testSkippedTasksDoNotHideLaterOnes()
    local log = {}
    local s = scheduler.new({ steady = 0, background = 0 })
    local steadyOnly = single("normal", 100, { kinds = { steady = true } })
    for index = 1, 20 do
        add(s, "chart" .. index, steadyOnly, task(log, "chart" .. index), index)
    end
    add(s, "service", single("normal", 100), task(log, "service"), 50)
    equal(s:run("background", 100), 1)
    equal(log[1], "service:run:1", "a background task behind twenty steady-only ones still runs")
    equal(s.lastPlan.examined, 21)
end

local function testOlderCriticalReleasePrecedesTheNormalBacklog()
    local log = {}
    local s = scheduler.new({ steady = 0 })
    for index = 1, 100 do
        add(s, "n" .. index, single("normal", 14000), task(log, "n" .. index), 0)
    end
    add(s, "c", single("critical", 100), task(log, "c"), 0)
    equal(s:run("steady", 1000), 1)
    equal(log[1], "c:run:1")
end

local function testStagesAreConsistent()
    local log = {}
    local decl = {
        class = "normal",
        first = "begin",
        stages = {
            begin = { fixed = 0, perUnit = 100, maxUnits = 1 },
            project = { fixed = 10, perUnit = 50, maxUnits = 9 },
        },
    }
    local s = scheduler.new(OVERHEAD)
    local instance = task(log, "chart")
    add(s, "chart", decl, instance, 0)
    s:run("steady", 1)
    equal(log[1], "chart:begin:1", "the first stage is the declared one")
    instance.stage = "project"
    s:run("steady", 100)
    equal(log[2], "chart:project:9")
    instance.stage = "missing"
    s:run("steady", 200)
    equal(#log, 2, "an unknown stage never runs")
    local errors = s:takeErrors()
    equal(errors[1].id, "chart")
    assert(string.find(errors[1].message, "unknown stage", 1, true))
    equal(s.byId.chart, nil)
    equal(s:takeErrors(), nil, "an error is reported once")
end

local function testFailuresRetireOnlyTheTask()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    local function bad(value)
        local instance = {}
        function instance.step()
            return value
        end
        return instance
    end
    local raising = {}
    function raising.step()
        error("boom")
    end
    local values = { zero = 0, fraction = 1.5, text = "5", none = nil, negative = -3, nan = 0 / 0, huge = math.huge }
    local names = { "zero", "fraction", "text", "negative", "nan", "huge", "none" }
    for index, name in ipairs(names) do
        add(s, name, single(name == "huge" and "critical" or "normal", 10), bad(values[name]), index)
    end
    add(s, "raises", single("critical", 10), raising, 0)
    add(s, "healthy", single("critical", 10), task(log, "healthy", 5), 0)
    s:run("steady", 100)
    local errors = s:takeErrors()
    equal(#errors, 8)
    equal(s.count, 1)
    equal(s.byId.healthy ~= nil, true)
    equal(#log, 1, "the healthy task ran in the same callback")
    s:run("steady", 200)
    equal(#log, 2)
    equal(s:takeErrors(), nil)
end

local function testDelaysAreWholeTicks()
    local s = scheduler.new(OVERHEAD)
    local log = {}
    add(s, "a", single("normal", 10), task(log, "a", 1), 0)
    s:run("steady", 7)
    equal(s:dueOf("a"), 8, "a delay of 1 is ready at the first callback a tick later")
    s:run("steady", 7)
    equal(#log, 1, "and not again in the same tick")
end

local function testAddAndRemoveDuringARun()
    local log = {}
    local s = scheduler.new(OVERHEAD)
    local decl = single("normal", 10)
    local second = task(log, "second", 5)
    local first = {}
    function first.step()
        s:remove("second")
        if not s.byId.third then
            add(s, "third", decl, task(log, "third", 5), 0)
        end
        return 5
    end
    add(s, "first", decl, first, 0)
    add(s, "second", decl, second, 1)
    s:run("steady", 10)
    equal(#log, 0, "a task removed earlier in the same plan does not run")
    equal(s:dueOf("third"), 0, "an added task is first planned in the next callback")
    s:run("steady", 11)
    equal(log[1], "third:run:1")
    local selfRemoving = {}
    function selfRemoving.step()
        s:remove("me")
        return 5
    end
    add(s, "me", decl, selfRemoving, 0)
    s:run("steady", 100)
    equal(s.byId.me, nil)
    for _, list in pairs(s.lists) do
        for _, record in ipairs(list) do
            assert(record.id ~= "me" and record.id ~= "second")
        end
    end
    equal(s.count, 2)
    local leaving = {}
    function leaving.step()
        s:remove("leaving")
        error("removed and failed")
    end
    add(s, "leaving", decl, leaving, 0)
    s:run("steady", 200)
    equal(s.count, 2, "a task that removes itself is counted once")
    equal(s:takeErrors(), nil, "and its failure is not reported")
end

local function testOnePendingReleasePerTask()
    local s = scheduler.new(OVERHEAD)
    local log = {}
    add(s, "a", single("normal", 10), task(log, "a", 10), 0)
    s:run("steady", 1000)
    equal(#log, 1)
    equal(#s.lists[2], 1)
    equal(s:dueOf("a"), 1010)
end

local function testListsStayOrdered()
    local s = scheduler.new(OVERHEAD)
    local log = {}
    local delays = { 3, 50, 7, 21, 4, 99, 1, 13 }
    for index, delay in ipairs(delays) do
        add(s, index, single(index % 2 == 0 and "critical" or "normal", 10), task(log, index, delay), index)
    end
    for now = 1, 400, 3 do
        s:run("steady", now)
        for _, list in pairs(s.lists) do
            for index = 2, #list do
                local a, b = list[index - 1], list[index]
                assert(a.due < b.due or (a.due == b.due and a.seq < b.seq), "list out of order")
            end
        end
    end
end

local function testUnknownKindFails()
    local s = scheduler.new(OVERHEAD)
    local ok = pcall(s.run, s, "modal", 1)
    equal(ok, false)
end

local function testDeterminism()
    local function trace()
        local log = {}
        local s = scheduler.new(OVERHEAD)
        local delays = { 3, 50, 7, 21, 4, 99, 1, 13 }
        for index, delay in ipairs(delays) do
            add(
                s,
                index,
                single(index % 3 == 0 and "critical" or "normal", 300 * index, { shared = { link = 50 } }),
                task(log, index, delay),
                index
            )
        end
        for now = 1, 600, 4 do
            s:run(now % 8 == 0 and "background" or "steady", now, now % 5 * 100)
        end
        return table.concat(log, ",")
    end
    equal(trace(), trace())
end

testDeclarationChecks()
testRemovingAnIdleListedTaskUnlistsIt()
testReschedulingPreservesIdentityAndOrder()
testReschedulingWrapsAndRejectsInvalidReleases()
testInvalidStagesRetireWithoutRunning()
testKindsAreCheckedWithReasons()
testDeclarationsAreReadOnceAndCostsBounded()
testSharedNamesAreFreedWithTheirLastTask()
testDueIsRequiredAndStaggerGivesIntegers()
testRunRaisesOnlyForAWrongCall()
testNegativeRoomDefersTasksWithoutAnError()
testTaskLimit()
testStagger()
testOldestFirstAndClassOrder()
testNotReadyTasksWait()
testPlanStaysUnderTheBudget()
testSkipAndContinueKeepsTheWaiterFirst()
testCriticalIsNeverDroppedAndKeepsItsPlace()
testNormalReserve()
testGrantsInUnits()
testExclusiveAndKinds()
testSharedCostIsChargedOncePerPlan()
testReadyTasksHaveNoCountCap()
testSkippedTasksDoNotHideLaterOnes()
testOlderCriticalReleasePrecedesTheNormalBacklog()
testStagesAreConsistent()
testFailuresRetireOnlyTheTask()
testDelaysAreWholeTicks()
testAddAndRemoveDuringARun()
testOnePendingReleasePerTask()
testListsStayOrdered()
testUnknownKindFails()
testDeterminism()

print("Scheduler library passed")
