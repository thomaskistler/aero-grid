-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local fixtures = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testCellBatteryFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "firmware", "fixture exposes firmware values")
    assertions.assertContains(fixtures.multiPanel, "type: metric", "shared layout fixture should include a metric panel")
end

local function run()
    testCellBatteryFixtureLoads()
end

run()
