-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local admission = assert(loadfile(root .. "/tests/support/scheduler_admission.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local declared = assert(loadfile(root .. "/tests/fixtures/scheduler-bounds.lua"))()
local equal = assertions.assertEqual

local TRACES = { "chart-full", "flight-smart", "metric-16", "session-reset", "stress" }

-- Every traced task cost must stay at or below its declared bound.
local function testRecordedTracesStayWithinTheDeclaredBounds()
    local checked, units = 0, 0
    for _, name in ipairs(TRACES) do
        local file = assert(io.open(root .. "/tests/fixtures/scheduler-traces/" .. name .. ".txt", "r"))
        for line in file:lines() do
            local tasks = select(5, string.match(line, "^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$"))
            for label, cost, count in string.gmatch(tasks, "([^,=]+)=(%d+)/?(%d*)") do
                local bound = declared.bounds[label]
                if bound then
                    local grant = count ~= "" and tonumber(count) or bound.maxUnits
                    local limit = bound.fixed + grant * bound.perUnit
                    assert(tonumber(cost) <= limit, name .. ": " .. label .. " cost " .. cost .. " is above " .. limit)
                    checked = checked + 1
                    units = units + (count ~= "" and 1 or 0)
                else
                    assert(declared.unbounded[label], name .. ": " .. label .. " has no declared bound")
                end
            end
        end
        file:close()
    end
    assert(checked > 1000, "the traces should exercise many task costs, got " .. checked)
    assert(units > 100, "telemetry and control traces carry units")
end

local function testDeclaredBoundsAreUsableDeclarations()
    for label, bound in pairs(declared.bounds) do
        local decl = { class = "normal", stages = { run = bound } }
        equal(scheduler.check(decl), nil, label)
    end
end

-- Invariant 14: every declared piece and smallest step fits the maximum task size,
-- except the ones the specification lists for splitting during their migration.
local function testBoundsRespectTheMaximumTaskSize()
    for label, bound in pairs(declared.bounds) do
        local smallest = bound.fixed + bound.perUnit
        if declared.splitBeforeMigration[label] then
            assert(smallest > admission.MAX_SIZE, label .. " no longer needs a split")
        else
            assert(
                smallest <= admission.MAX_SIZE,
                label .. " is above the maximum task size and not listed for a split"
            )
        end
        for label, bound in pairs(declared.tasks) do
            local stage = { fixed = bound.fixed, perUnit = bound.perUnit, maxUnits = bound.maxUnits }
            equal(scheduler.check({ class = bound.class, stages = { run = stage } }), nil, label)
            assert(
                bound.fixed + bound.perUnit <= admission.MAX_SIZE,
                label .. " has a smallest step above the maximum task size"
            )
        end
    end
end

testRecordedTracesStayWithinTheDeclaredBounds()
testDeclaredBoundsAreUsableDeclarations()
testBoundsRespectTheMaximumTaskSize()

print("Scheduler trace replay passed")
