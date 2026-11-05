-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local measure = assert(loadfile(root .. "/tests/support/scheduler_measure.lua"))()
local overhead = assert(loadfile(root .. "/tests/support/scheduler_overhead.lua"))()
local mixes = assert(loadfile(root .. "/tests/support/scheduler_mixes.lua"))()
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

local function testOverheadVerdictComparesMeasuredWithCharged()
    local function row(name, measured, charged, examined, ran)
        return {
            name = name,
            measured = measured,
            charged = charged,
            examined = examined,
            ran = ran,
            slack = charged - measured,
        }
    end
    local results = {
        rows = {
            row("idle (8 tasks)", 90, 100, 0, 0),
            row("none fits (8 tasks)", 330, 480, 7, 0),
            row("run 4, delay 1 (8 tasks)", 800, 1000, 4, 4),
        },
    }
    local verdict = overhead.verdict(results)
    equal(verdict.ok, true)
    equal(verdict.fixed, 90)
    near(verdict.examine, 240 / 7, 0.01)
    near(verdict.perRun, 177.5, 0.01)
    equal(verdict.slack, 10)
    equal(verdict.tightest.name, "idle (8 tasks)")
    results.rows[3].measured = 1001
    verdict = overhead.verdict(results)
    equal(verdict.ok, false, "a callback that cost more than was charged fails")
    equal(verdict.failures[1].name, "run 4, delay 1 (8 tasks)")
end

-- Native counts equal these offline counts (checked on Companion 2.12), so this
-- is the check that the charged constants stay conservative: every scenario,
-- every task count and every mix measured no more than the planner charged.
local function testChargedCostsAreConservative()
    local count, pause = overhead.hookCounter()
    local results = overhead.measure(scheduler, count, pause, mixes)
    debug.sethook()
    local verdict = overhead.verdict(results)
    for _, item in ipairs(verdict.failures) do
        print("over budget: " .. item.name .. " measured " .. item.measured .. " charged " .. item.charged)
    end
    equal(verdict.ok, true, "the planner cost more than it charged")
    assert(#results.rows > 55, "scenarios at every task count and every mix were measured")
    local names = {}
    for _, item in ipairs(results.rows) do
        names[#names + 1] = item.name
    end
    local text = table.concat(names, "\n")
    for _, want in ipairs({
        "none fits (128 tasks)",
        "all skipped, the last one runs (128 tasks)",
        "stages, shared costs",
        "mix D, 2 per task",
    }) do
        assert(string.find(text, want, 1, true), "no scenario " .. want)
    end
    assert(verdict.slack >= 0)
    -- The charges are not the exact worst cases: a different luac point release or
    -- one more instruction must not flip the invariant.
    assert(verdict.headroom >= 1.04, "headroom " .. verdict.headroom .. " on " .. verdict.tightestRatio.name)
    assert(verdict.fixed <= scheduler.FIXED_COST and verdict.examine <= scheduler.EXAMINE_COST)
    assert(verdict.perRun <= scheduler.EXAMINE_COST + scheduler.RUN_COST)
    assert(results.heap.kib > 0 and results.heap.tasks == scheduler.MAX_TASKS)
    print(
        string.format(
            "scheduler framework (offline count): idle %d, examine %.0f, run %.0f (examine included), least slack %d on %s, least headroom %.3f, heap %.0f KiB at %d tasks",
            verdict.fixed,
            verdict.examine,
            verdict.perRun,
            verdict.slack,
            verdict.tightest.name,
            verdict.headroom,
            results.heap.kib,
            results.heap.tasks
        )
    )
end

testFitHoldsAtEveryMeasuredPoint()
testDeclaredBoundsFollowTheMarginRule()
testFindingsWarnAndFail()
testMeasuringARealStep()
testOverheadVerdictComparesMeasuredWithCharged()
testChargedCostsAreConservative()

print("Scheduler measurement passed")
