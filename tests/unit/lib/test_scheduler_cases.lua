-- SPDX-License-Identifier: GPL-2.0-only

-- Every task case file in tests/fixtures/scheduler-cases (plans/scheduler-framework.md,
-- section 6) is measured offline with the exact instruction counter. The counts equal
-- the native ones (checked on Companion 2.12), so this is the CI enforcement of the
-- declared bounds: a migrated task's measured cost must stay within its declaration,
-- below the 90% that asks for a re-declaration, and the planner's cost of releasing
-- it within what the planner charges. A declaration must also fit the maximum task
-- size. The native job (`audit-scheduler.py --framework`) repeats this on hardware.
local root = (... and ... ~= "" and ...) or "."
local hostIo = io

local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local measure = assert(loadfile(root .. "/tests/support/scheduler_measure.lua"))()
local overhead = assert(loadfile(root .. "/tests/support/scheduler_overhead.lua"))()
local admission = assert(loadfile(root .. "/tests/support/scheduler_admission.lua"))()

assert(loadfile(root .. "/tests/support/edgetx.lua"))().constants()

local function load(relative, ...)
    local path = string.sub(relative, 1, 9) == "@support/" and root .. "/tests/support/" .. string.sub(relative, 10)
        or root .. "/src/WIDGETS/AeroGrid/" .. relative
    return assert(loadfile(path))(...)
end

-- The stub case only exercises the measurement itself (test_scheduler_measure.lua).
local listing = root .. "/build/scheduler-case-files.txt"
os.execute("ls '" .. root .. "/tests/fixtures/scheduler-cases' > '" .. listing .. "'")
local names = {}
local file = assert(hostIo.open(listing, "r"))
for name in file:lines() do
    local case = string.match(name, "^(.+)%.lua$")
    if case and case ~= "stub" then
        names[#names + 1] = case
    end
end
file:close()
os.remove(listing)
assert(#names >= 1, "the migrated tasks have case files")

for _, name in ipairs(names) do
    local case = measure.open(assert(loadfile(root .. "/tests/fixtures/scheduler-cases/" .. name .. ".lua"))(), load)
    assert(scheduler.check(case.decl) == nil, name .. ": the declaration is usable")
    local count, pause = overhead.hookCounter()
    local report = measure.report(case, count, pause, scheduler)
    debug.sethook()

    for _, finding in ipairs(report.findings) do
        assert(
            finding.level == "loose",
            string.format(
                "%s.%s at grant %d: %s (%.0f%% of its bound); re-declare it from the measurement: %s",
                name,
                finding.stage,
                finding.grant,
                finding.level,
                finding.ratio * 100,
                tostring(report.proposed[finding.stage].perUnit)
            )
        )
    end
    for stage, declared in pairs(case.decl.stages) do
        assert(report.worst[stage], name .. ": stage " .. stage .. " is not measured")
        assert(
            declared.fixed + declared.perUnit <= admission.MAX_SIZE,
            name .. "." .. stage .. ": the smallest step is above the maximum task size"
        )
        for grant = 1, declared.maxUnits do
            assert(report.worst[stage][grant], name .. "." .. stage .. ": grant " .. grant .. " is not measured")
        end
    end
    assert(
        report.planner.measured <= report.planner.charged,
        name
            .. ": releasing the task cost "
            .. report.planner.measured
            .. ", the planner charged "
            .. report.planner.charged
    )

    local worst = {}
    for stage, grants in pairs(report.worst) do
        local costs = {}
        for grant = 1, case.decl.stages[stage].maxUnits do
            costs[#costs + 1] = grant .. "=" .. grants[grant]
        end
        worst[#worst + 1] = stage .. " " .. table.concat(costs, " ")
    end
    print(
        string.format(
            "scheduler task %s (offline count): %s; planner %d of %d charged",
            case.id,
            table.concat(worst, "; "),
            report.planner.measured,
            report.planner.charged
        )
    )
end

print("Scheduler task bounds passed")
