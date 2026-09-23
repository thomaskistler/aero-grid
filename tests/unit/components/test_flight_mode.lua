-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local fixtures = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testFlightModeFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "lvglMock", "fixture exposes a lvgl mock")
    assertions.assertContains(fixtures.multiPanel, "type: flight-mode", "shared layout fixture should include a flight-mode panel")
end

local function run()
    testFlightModeFixtureLoads()
end

run()
