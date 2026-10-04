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

local function testExtremeUnits()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/metric.lua"))()
    local context = {
        settings = { extrema = "source", extremaMode = "max", unit = "m", precision = 0 },
        feed = { unitText = "ft", precision = 1 },
        extremeFeed = { available = true, value = 180 },
    }
    assertions.assertEqual(metric.detailText(context), "MAX 180 m")
    context.settings.unit = ""
    assertions.assertEqual(metric.detailText(context), "MAX 180 ft")
    context.settings.extrema = "flight"
    context.settings.extremaMode = "min"
    context.settings.precision = 1
    context.sessionExtrema = { available = true, min = -2.5, max = 180 }
    context.feed.unitText = "m/s"
    assertions.assertEqual(metric.detailText(context), "MIN -2.5 m/s")
    context.sessionExtrema.available = false
    assertions.assertEqual(metric.detailText(context), "MIN --")
    context.sessionExtrema.available = true
    context.feed.unitText = ""
    assertions.assertEqual(metric.detailText(context), "MIN -2.5")
end

local function run()
    testMetricStates()
    testExtremeUnits()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/metric.lua"))()
    assertions.assertEqual(#metric.validateSettings({ metrics = { { source = "GAlt" } } }), 0)
    for _, entries in ipairs({
        {},
        { "GAlt" },
        { {} },
        { { source = "GAlt", precision = 4 } },
        { { source = "GAlt", unit = 1 } },
        { { source = "GAlt", typo = true } },
        { [1] = { source = "GAlt" }, [3] = { source = "VSpd" } },
        { { source = "a" }, { source = "b" }, { source = "c" }, { source = "d" } },
    }) do
        assert(#metric.validateSettings({ metrics = entries }) > 0)
    end
    local context = {
        metrics = { { source = "Alt" }, { source = "Curr", label = "CUR", unit = "", precision = 2 } },
        detailFeed = { available = true, value = 3.141, unitText = "A", precision = 1 },
        settings = {},
    }
    assertions.assertEqual(metric.detailText(context), "CUR 3.14")
    context.metrics[2].unit = nil
    assertions.assertEqual(metric.detailText(context), "CUR 3.14 A")
    context.metrics[2].precision = nil
    assertions.assertEqual(metric.detailText(context), "CUR 3.1 A")
    context.detailFeed.available = false
    assertions.assertEqual(metric.detailText(context), "CUR --")
end

run()
