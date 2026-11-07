-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local controlService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()

local function testTrimNamespaceExists()
    local env = services.environment({
        getFieldInfo = function(name)
            return { id = 42 }
        end,
        getValue = function()
            return 128
        end,
    })
    local service = controlService.new(env, services)
    local trim = service:trim("trim-ail", "auto")
    assertions.assertEqual(type(trim), "table")
end

local function testStandardRangeConstantsExist()
    assertions.assertEqual(controlService.STANDARD_RANGE, 1024)
    assertions.assertEqual(controlService.EXTENDED_RANGE, 4096)
end

local function testBoundedDescription()
    local create = assert(loadfile(root .. "/tests/support/scheduler_probe_fixture.lua"))()(function(relative)
        return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. relative))()
    end)
    local service = create("control", 2)
    local expected, actual = {}, {}
    local count = service:describe(expected)
    local nextRow, cursor = 1, 1
    for index = 1, #service.entries do
        nextRow, cursor = service:describeStep(actual, nextRow, index)
        assertions.assertEqual(cursor, index < #service.entries and index + 1 or nil)
        if index <= 128 then
            assertions.assertEqual(nextRow, 1)
            assertions.assertEqual(#actual, 0)
        end
    end
    assertions.assertEqual(nextRow - 1, count)
    assertions.assertEqual(count, 12)
    for index = 1, count do
        assertions.assertEqual(actual[index].label, expected[index].label)
        assertions.assertEqual(actual[index].text, expected[index].text)
    end
    local absent, finished = service:describeStep(actual, nextRow, #service.entries + 1)
    assertions.assertEqual(absent, nextRow)
    assertions.assertEqual(finished, nil)
end

local function testCriticalGrantOwnership()
    for grant = 1, 6 do
        local reads = {}
        local service = controlService.new(services.environment({
            getSwitchIndex = function() error("captured switch indices must be reused") end,
            getSwitchValue = function(index)
                reads[#reads + 1] = index
                return true
            end,
        }), services)
        local views = {}
        for index = 1, 6 do
            views[index] = service:switch("condition-" .. index, index, "critical")
        end
        local task = service.tasks.critical
        local delay = task:step(grant, "run", 20)
        assertions.assertEqual(#reads, grant)
        assertions.assertEqual(delay, grant < 6 and 1 or 20)
        for index = 1, 6 do
            assertions.assertEqual(views[index].available, index <= grant)
            if index <= grant then assertions.assertEqual(reads[index], index) end
        end
        if grant < 6 then
            task:step(6 - grant, "run", 21)
            assertions.assertEqual(#reads, 6)
            for index = 1, 6 do assertions.assertEqual(views[index].available, true) end
        end
        assertions.assertEqual(service.criticalRemaining, nil)
        assertions.assertEqual(service.criticalCursor, 1)
    end
end

local function run()
    testTrimNamespaceExists()
    testStandardRangeConstantsExist()
    testBoundedDescription()
    testCriticalGrantOwnership()
end

run()
