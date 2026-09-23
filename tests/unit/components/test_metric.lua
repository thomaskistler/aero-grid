-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local fixtures = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testPresetResolution()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "firmware", "fixture exposes firmware data")
end

local function testMetricFixtureLoads()
    local fixture = WidgetFixture.new()
    assertions.assertContains(fixtures.singleMetric, "type: metric", "metric fixture should define a metric panel")
end

local function run()
    testPresetResolution()
    testMetricFixtureLoads()
end

run()
