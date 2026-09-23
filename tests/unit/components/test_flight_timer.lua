-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testFlightTimerFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "lvglMock", "fixture should expose lvgl scaffolding")
    assertions.assertEqual(type(fixture.tick), "function", "fixture should expose the radio tick")
end

local function run()
    testFlightTimerFixtureLoads()
end

run()
