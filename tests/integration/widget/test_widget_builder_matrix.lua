-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local fixtures = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testSharedBuilderContract()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "firmware", "builder fixture should provide radio constants")
    assertions.assertTableHasKey(fixture, "radio", "builder fixture should provide radio state")
    assertions.assertContains(fixtures.multiPanel, "type: metric", "shared multi-panel layout should exercise the metric builder")
    assertions.assertContains(fixtures.multiPanel, "type: flight-mode", "shared multi-panel layout should exercise the flight-mode builder")
end

local function testRepresentativeLayoutLoads()
    local fixture = WidgetFixture.new()
    assertions.assertEqual(type(fixture.createLoaded), "function", "widget fixture should expose createLoaded")
    assertions.assertEqual(type(fixture.pump), "function", "widget fixture should expose pump")
    assertions.assertEqual(type(fixture.entryById), "function", "widget fixture should expose entry lookup")
end

local function run()
    testSharedBuilderContract()
    testRepresentativeLayoutLoads()
end

run()
