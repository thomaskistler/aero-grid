-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testNavigationFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "radio", "fixture should include radio state")
    assertions.assertEqual(type(fixture.entryById), "function", "fixture should include lookup helpers")
end

local function run()
    testNavigationFixtureLoads()
end

run()
