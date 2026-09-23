-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testLinkStatusFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "radio", "fixture exposes radio state")
    assertions.assertIsType(fixture.radio, "table", "radio state should be a table")
end

local function run()
    testLinkStatusFixtureLoads()
end

run()
