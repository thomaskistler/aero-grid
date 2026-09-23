-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testTxBatteryFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertEqual(type(fixture.createLoaded), "function", "fixture should support widget creation")
    assertions.assertEqual(type(fixture.panelOf), "function", "fixture should expose panel accessors")
end

local function run()
    testTxBatteryFixtureLoads()
end

run()
