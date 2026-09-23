-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testModelIdentityFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "radioMock", "fixture should expose the radio mock")
    assertions.assertEqual(type(fixture.reset), "function", "fixture should expose reset")
end

local function run()
    testModelIdentityFixtureLoads()
end

run()
