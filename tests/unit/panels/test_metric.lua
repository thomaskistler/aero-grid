-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testMetricStates()
    local fixture = WidgetFixture.new()
    local context = fixture.createLoaded()
    local metric = fixture.instanceOf(context, "altitude")
    assert(metric, "default layout should load the altitude metric")

    local metricModule = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/metric.lua"))()
    metric.settings.precision = 0
    metric.settings.warning = 300
    metric.settings.critical = 400
    metric.settings.direction = "rising"

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

local function testSupportingUnits()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/metric.lua"))()
    local context = {
        metrics = { { source = "Alt" }, { source = "Alt+", label = "MAX", unit = "m", precision = 0 } },
        detailFeed = { available = true, value = 180, unitText = "ft", precision = 1 },
    }
    assertions.assertEqual(metric.detailText(context), "MAX 180 m")
    context.metrics[2].unit = nil
    assertions.assertEqual(metric.detailText(context), "MAX 180 ft")
    context.metrics[2].unit = ""
    assertions.assertEqual(metric.detailText(context), "MAX 180")
    context.detailFeed.available = false
    assertions.assertEqual(metric.detailText(context), "MAX --")
end

local function testMetricEntrySettings()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/metric.lua"))()
    local primary = {
        source = "Alt",
        rangeMin = -50,
        rangeMax = 400,
        warning = 300,
        critical = 400,
        direction = "rising",
    }
    local supporting = {
        source = "Curr",
        rangeMin = 0,
        rangeMax = 50,
        warning = 20,
        critical = 30,
        direction = "auto",
    }
    assertions.assertEqual(#metric.validateSettings({ metrics = { primary, supporting } }), 0)
    local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
    for _, key in ipairs({ "rangeMin", "rangeMax", "warning", "critical" }) do
        for _, invalid in ipairs({ "10", true, math.huge, -math.huge, 0 / 0 }) do
            assert(#metric.validateSettings({ metrics = { { source = "Alt", [key] = invalid } } }) > 0)
        end
        local _, warnings = host.resolveSettings(metric, { metrics = { primary }, [key] = 10 })
        assert(#warnings > 0)
    end
    local _, warnings = host.resolveSettings(metric, { metrics = { primary }, direction = "rising" })
    assert(#warnings > 0)
    for _, invalid in ipairs({ "up", 1, false }) do
        assert(#metric.validateSettings({ metrics = { { source = "Alt", direction = invalid } } }) > 0)
    end

    local fixture = WidgetFixture.new()
    local dashboard = fixture.createLoaded()
    local services = {
        theme = dashboard.theme,
        primitives = dashboard.primitives,
        fonts = dashboard.themeBuilder.typography(2, 2),
        span = { colSpan = 2, rowSpan = 2 },
        telemetry = {
            subscribe = function()
                return { available = false }
            end,
        },
        state = function(name, accent)
            return dashboard.themeBuilder.state(dashboard.theme, name, accent)
        end,
        themeBuilder = dashboard.themeBuilder,
    }
    local context = metric.create(
        dashboard.page,
        { x = 0, y = 0, w = 238, h = 134 },
        { metrics = { primary, supporting }, visual = "bar" },
        services
    )
    assertions.assertEqual(context.settings.rangeMin, -50)
    assertions.assertEqual(context.settings.rangeMax, 400)
    assertions.assertEqual(metric.fraction(context.settings, 175), 0.5)
    assertions.assertEqual(metric.fraction(context.settings, -100), 0)
    assertions.assertEqual(metric.fraction(context.settings, 500), 1)
    metric.setValue(context, 100)
    assertions.assertEqual(context.stateName, "normal")
    metric.setValue(context, 300)
    assertions.assertEqual(context.stateName, "warning")
    metric.setValue(context, 400)
    assertions.assertEqual(context.stateName, "critical")

    local defaults = metric.create(
        dashboard.page,
        { x = 0, y = 0, w = 238, h = 134 },
        { metrics = { { source = "Alt" } } },
        services
    )
    assertions.assertEqual(defaults.settings.rangeMin, 0)
    assertions.assertEqual(defaults.settings.rangeMax, 100)
    assertions.assertEqual(defaults.settings.warning, nil)
    assertions.assertEqual(defaults.settings.direction, "auto")
    assertions.assertEqual(defaults.range, nil)
    assertions.assertEqual(defaults.secondary, nil)

    services.telemetry = nil
    local unavailable = metric.create(
        dashboard.page,
        { x = 0, y = 0, w = 238, h = 134 },
        { metrics = { { source = "Alt" } } },
        services
    )
    assertions.assertEqual(unavailable.stateName, "unavailable")
    assertions.assertEqual(unavailable.value.properties.text, "--")

    assert(#metric.validateSettings({}) > 0)
    local ok = pcall(metric.create, dashboard.page, { x = 0, y = 0, w = 238, h = 134 }, {}, services)
    assertions.assertEqual(ok, false, "a metric without a metrics list must not be created")
end

local function run()
    testMetricStates()
    testSupportingUnits()
    testMetricEntrySettings()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/metric.lua"))()
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
