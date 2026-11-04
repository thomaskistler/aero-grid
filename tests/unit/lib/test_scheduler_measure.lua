-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local measure = assert(loadfile(root .. "/tests/support/scheduler_measure.lua"))()
local overhead = assert(loadfile(root .. "/tests/support/scheduler_overhead.lua"))()
local equal = assertions.assertEqual

local function near(actual, expected, tolerance, message)
    assert(
        math.abs(actual - expected) <= tolerance,
        (message or "value") .. ": expected " .. expected .. ", got " .. actual
    )
end

local function testFitHoldsAtEveryMeasuredPoint()
    local grants = { [1] = 1000, [2] = 1500, [4] = 2600 }
    local fixed, perUnit = measure.fit(grants)
    near(perUnit, 1600 / 3, 0.01, "the steepest slope from one unit")
    for grant, cost in pairs(grants) do
        assert(fixed + grant * perUnit >= cost - 1e-9, "bound below the measurement at " .. grant)
    end
    local fixedOnly, perUnitOnly = measure.fit({ [1] = 940 })
    equal(fixedOnly, 0)
    equal(perUnitOnly, 940)
    local flat, tiny = measure.fit({ [1] = 500, [3] = 500 })
    equal(tiny, 1, "a unit always costs something")
    equal(flat, 499)
end

local function testDeclaredBoundsFollowTheMarginRule()
    local indivisible = measure.declare("critical", 0, 940, 1)
    equal(indivisible.perUnit, 1280, "1.25 * 940 + 100, rounded up to ten")
    equal(indivisible.fixed, 0)
    equal(indivisible.maxUnits, 1)
    local divisible = measure.declare("normal", 200, 770, 9)
    equal(divisible.fixed, 270, "1.10 * 200 + 50")
    equal(divisible.perUnit, 850, "1.10 * 770, with no constant")
    equal(divisible.maxUnits, 9)
    equal(measure.declare("normal", 0, 770, 9).fixed, 0, "no fixed part stays zero")
    equal(measure.declare("critical", 0, 1180, 1).perUnit, 1580)
    equal(scheduler.check({ class = "normal", stages = { run = divisible } }), nil)
end

local function testFindingsWarnAndFail()
    local decl = { class = "normal", stages = { run = { fixed = 100, perUnit = 1000, maxUnits = 4 } } }
    local findings = measure.check(decl, { run = { [1] = 1100, [2] = 2200, [3] = 1500, [4] = 4000 } })
    equal(#findings, 4)
    equal(findings[1].level, "high", "a cost above 90% of its bound")
    equal(findings[1].grant, 1)
    equal(findings[2].level, "exceeds", "a cost above its bound")
    equal(findings[2].grant, 2)
    equal(findings[3].level, "loose", "a cost below 60% of its bound")
    equal(findings[3].grant, 3)
    equal(findings[4].level, "high")
    equal(#measure.check(decl, { run = { [1] = 800 } }), 0)
end

local function testMeasuringARealStep()
    local case = assert(loadfile(root .. "/tests/fixtures/scheduler-cases/stub.lua"))()
    local seeds = 0
    for _, item in ipairs(case.cases) do
        local setup = item.setup
        item.setup = function(seed)
            seeds = seeds + 1
            return setup(seed)
        end
    end
    local count, pause = overhead.hookCounter()
    local report = measure.report(case, count, pause)
    debug.sethook()
    equal(seeds, #case.cases * measure.SEEDS, "every case runs at several clock phases or seeds")
    local one, eight = report.worst.run[1], report.worst.run[8]
    near(eight - one, 7 * 10 * 2, 20, "two instructions per unit of work")
    local proposed = report.proposed.run
    equal(proposed.maxUnits, 8)
    assert(proposed.perUnit >= 20, "the proposed bound covers the slope")
    assert(proposed.fixed + 8 * proposed.perUnit >= eight, "the proposed bound covers the worst case")
    for _, finding in ipairs(measure.check({ class = "normal", stages = report.proposed }, report.worst)) do
        assert(finding.level ~= "exceeds", "a proposed bound must hold for what it was fitted on")
    end
    equal(#report.findings > 0, true, "the loose hand-written declaration is reported")
end

local function testOverheadVerdict()
    local results = {
        idle = { [32] = 40 },
        run = { [32] = { [1] = 70, [12] = 400 } },
        unfit = { [32] = 136 },
        worst = { [32] = 450 },
    }
    local verdict = overhead.verdict(results, scheduler)
    equal(verdict.F0, 40)
    equal(verdict.c1, 6, "the cost of an examined task that does not fit")
    equal(verdict.o, 30, "the worst added cost per task run")
    equal(verdict.total, 40 + 16 * 6 + 12 * 30)
    equal(verdict.go, true)
    results.run[32][12] = 460
    equal(overhead.verdict(results, scheduler).go, false)
end

local function testFrameworkCostIsMeasurable()
    local count, pause = overhead.hookCounter()
    local results = overhead.measure(scheduler, count, pause)
    debug.sethook()
    for _, tasks in ipairs(overhead.TASK_COUNTS) do
        assert(results.idle[tasks] > 0)
        assert(results.run[tasks][4] > results.run[tasks][1], "more tasks run, more instructions")
    end
    assert(results.run[32][12] > results.run[32][8])
    assert(results.unfit[32] > results.idle[32])
    assert(results.heap.kib > 0 and results.heap.tasks == scheduler.MAX_TASKS)
    local verdict = overhead.verdict(results, scheduler)
    -- A regression guard on the planner's own cost; the go/no-go figure of the
    -- specification is reported by the native measurement.
    assert(results.worst[32] < 2500, "the worst callback costs " .. results.worst[32] .. " instructions")
    print(
        string.format(
            "scheduler framework (offline count, 32 tasks): F0 %d, c1 %.0f, o %.0f, worst callback %d, heap %.0f KiB at %d tasks",
            verdict.F0,
            verdict.c1,
            verdict.o,
            verdict.direct,
            results.heap.kib,
            results.heap.tasks
        )
    )
end

testFitHoldsAtEveryMeasuredPoint()
testDeclaredBoundsFollowTheMarginRule()
testFindingsWarnAndFail()
testMeasuringARealStep()
testOverheadVerdict()
testFrameworkCostIsMeasurable()

print("Scheduler measurement passed")
