-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testTrimPanelFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "firmware", "fixture should expose firmware constants")
    assertions.assertEqual(type(fixture.entryById), "function", "fixture should expose entry lookup")
end

local function run()
    testTrimPanelFixtureLoads()
end

run()
