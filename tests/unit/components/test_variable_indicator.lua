-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testVariableIndicatorFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertEqual(type(fixture.pump), "function", "fixture should expose refresh pumping")
    assertions.assertEqual(type(fixture.panelOf), "function", "fixture should expose panel access")
end

local function run()
    testVariableIndicatorFixtureLoads()
end

run()
