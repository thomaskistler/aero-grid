-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local controlService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()

local function testTrimNamespaceExists()
    local env = services.environment({
        getFieldInfo = function(name) return { id = 42 } end,
        getValue = function() return 128 end,
    })
    local service = controlService.new(env, services)
    local trim = service:trim("trim-ail", "auto")
    assertions.assertEqual(type(trim), "table")
end

local function testStandardRangeConstantsExist()
    assertions.assertEqual(controlService.STANDARD_RANGE, 1024)
    assertions.assertEqual(controlService.EXTENDED_RANGE, 4096)
end

local function run()
    testTrimNamespaceExists()
    testStandardRangeConstantsExist()
end

run()
