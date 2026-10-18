-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local moduleLoader = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local primitives = moduleLoader("lib/primitives.lua")

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
    metric.settings.rangeMin, metric.settings.rangeMax = 0, 500

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
    assertions.assertEqual(metric.fraction(context.settings, 175, primitives), 0.5)
    assertions.assertEqual(metric.fraction(context.settings, -100, primitives), 0)
    assertions.assertEqual(metric.fraction(context.settings, 500, primitives), 1)
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

local function testSpeedUnitFitsPanel()
    local fixture = WidgetFixture.new()
    local dashboard = fixture.createLoaded()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/metric.lua"))()
    local services = {
        theme = dashboard.theme,
        primitives = dashboard.primitives,
        fonts = dashboard.themeBuilder.typography(2, 2),
        span = { colSpan = 2, rowSpan = 2 },
        themeBuilder = dashboard.themeBuilder,
        state = function(name, accent)
            return dashboard.themeBuilder.state(dashboard.theme, name, accent)
        end,
    }
    local rect = { x = 0, y = 0, w = 238, h = 134 }
    local panel = metric.create(dashboard.page, rect, {
        metrics = {
            { source = "GSpd", label = "speed", precision = 1, unit = "km/h" },
            { source = "GSpd+", label = "max", precision = 1, unit = "km/h" },
        },
        visual = "bar",
    }, services)
    for _, width in ipairs({ 238, 358, 238 }) do
        rect.w = width
        metric.update(panel, rect)
        metric.setValue(panel, 48)
        assert(panel.unitDrawn, "the speed unit should be visible")
        local unit = panel.unit.properties
        local right = unit.x + dashboard.themeBuilder.measureText(panel.area.unitFont, "km/h")
        assert(
            right <= panel.area.frame.pad + panel.area.frame.content,
            "the speed unit must not cross the content edge"
        )
        assert(panel.value.properties.x >= panel.area.frame.pad, "the speed reading must fit on the left")
        local left = panel.value.properties.x
        assert(
            math.abs((left + right) / 2 - panel.area.valueCentre) <= 1,
            "the number and unit must be centered together"
        )
        metric.setValue(panel, nil)
        local numberWidth = dashboard.themeBuilder.measureText(panel.area.value, "--")
        assertions.assertEqual(
            panel.value.properties.x,
            panel.area.valueCentre - math.floor(numberWidth / 2),
            "an unavailable reading must be centered without its unit"
        )
    end
end

local function testDefaultSensorUnitAfterResize()
    local fixture = WidgetFixture.new()
    local dashboard = fixture.createLoaded()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/metric.lua"))()
    assertions.assertEqual(#metric.settings[1].default, 0, "a new metric panel names no sensor")
    local feed = { available = true, value = 48, unitText = "km/h", precision = 1 }
    local services = {
        theme = dashboard.theme,
        primitives = dashboard.primitives,
        fonts = dashboard.themeBuilder.typography(1, 1),
        span = { colSpan = 1, rowSpan = 1 },
        themeBuilder = dashboard.themeBuilder,
        telemetry = {
            subscribe = function()
                return feed
            end,
        },
        state = function(name, accent)
            return dashboard.themeBuilder.state(dashboard.theme, name, accent)
        end,
    }
    local panel = metric.create(dashboard.page, { x = 0, y = 0, w = 117, h = 65 }, {
        metrics = { { source = "GSpd", label = "speed", precision = 1 } },
        visual = "none",
    }, services)
    metric.setValue(panel, 48)
    assert(not panel.unitDrawn, "the compact panel must hide its unit")
    metric.update(panel, { x = 0, y = 0, w = 238, h = 134 })
    metric.setValue(panel, 48)
    assertions.assertEqual(panel.unitText, "km/h")
    assert(panel.unitDrawn, "enlargement must reveal the inherited sensor unit")
end

--- An unconfigured panel is a captioned dash and reads nothing.
local function testUnconfiguredMetric()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/metric.lua"))()
    assertions.assertEqual(#metric.validateSettings({ metrics = {} }), 0, "no metrics is a valid panel")
    assertions.assertEqual(#metric.validateSettings({ metrics = { {} } }), 0, "a blank entry is a valid panel")
    assert(#metric.validateSettings({ metrics = { { source = 5 } } }) > 0, "a source must still be a string")

    local fixture = WidgetFixture.new()
    local dashboard = fixture.createLoaded()
    for _, metrics in ipairs({ {}, { {} }, { { source = "" } } }) do
        local subscribed = 0
        local services = {
            theme = dashboard.theme,
            primitives = dashboard.primitives,
            fonts = dashboard.themeBuilder.typography(2, 2),
            span = { colSpan = 2, rowSpan = 2 },
            themeBuilder = dashboard.themeBuilder,
            telemetry = {
                subscribe = function()
                    subscribed = subscribed + 1
                    return { available = false }
                end,
            },
            state = function(name, accent)
                return dashboard.themeBuilder.state(dashboard.theme, name, accent)
            end,
        }
        local panel = metric.create(dashboard.page, { x = 0, y = 0, w = 238, h = 134 }, {
            metrics = metrics,
            visual = "none",
        }, services)
        assertions.assertEqual(subscribed, 0, "nothing to read means nothing subscribed")
        assertions.assertEqual(panel.settings.label, "Metric")
        assertions.assertEqual(panel.text, "--")
    end
end

--- A threshold outside the range is Off, as the drawer presents it.
local function testThresholdsOutsideRangeAreOff()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/metric.lua"))()
    local settings = { rangeMin = 0, rangeMax = 400, warning = 300, critical = 450, direction = "auto" }
    assertions.assertEqual(metric.resolveState(settings, 460, false), "warning", "critical past Range max is Off")
    settings.critical, settings.warning = 380, -10
    assertions.assertEqual(metric.resolveState(settings, 390, false), "critical")
    assertions.assertEqual(metric.resolveState(settings, 0, false), "normal", "warning below Range min is Off")
    -- Off thresholds take no part in inferring direction either.
    settings = { rangeMin = 0, rangeMax = 100, warning = 30, critical = 120, direction = "auto" }
    assertions.assertEqual(metric.resolveState(settings, 50, false), "warning", "one live threshold reads as rising")
    settings = { rangeMin = 100, rangeMax = 0, warning = 30, critical = 10, direction = "auto" }
    assertions.assertEqual(metric.resolveState(settings, 5, false), "critical", "a reversed range still bounds")
end

local function run()
    testThresholdsOutsideRangeAreOff()
    testUnconfiguredMetric()
    testDefaultSensorUnitAfterResize()
    testSpeedUnitFitsPanel()
    testMetricStates()
    testSupportingUnits()
    testMetricEntrySettings()
    local metric = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/metric.lua"))()
    assertions.assertEqual(#metric.validateSettings({ metrics = { { source = "GAlt" } } }), 0)
    for _, entries in ipairs({
        { "GAlt" },
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
