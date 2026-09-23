-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testMetricStates()
    local fixture = WidgetFixture.new()
    local context = fixture.createLoaded()
    local metric = fixture.instanceOf(context, "altitude")
    assert(metric, "default layout should load the altitude metric")

    local metricModule = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/metric.lua"))()

    metricModule.setValue(metric, 240)
    assertions.assertEqual(metric.stateName, "normal")
    assertions.assertEqual(metric.value.properties.text, "240")
    assertions.assertEqual(metric.badge.properties.text, "")

    metricModule.setValue(metric, 300)
    assertions.assertEqual(metric.stateName, "warning")
    assertions.assertEqual(metric.badge.properties.text, "WARN")

    metricModule.setValue(metric, 400)
    assertions.assertEqual(metric.stateName, "critical")
    assertions.assertEqual(metric.badge.properties.text, "CRIT")

    metricModule.setValue(metric, 24.0, true)
    assertions.assertEqual(metric.stateName, "stale")
    assertions.assertEqual(metric.badge.properties.text, "STALE")

    metricModule.setValue(metric, nil)
    assertions.assertEqual(metric.stateName, "unavailable")
    assertions.assertEqual(metric.value.properties.text, "--")
    assertions.assertEqual(metric.badge.properties.text, "N/A")
end

local function run()
    testMetricStates()
end

run()
