-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local chart = fixture.module("panels/chart.lua")
local host = fixture.module("lib/panel_host.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

assert(host.validateModule(chart, "chart"))
assert(host.supportsSpan(chart, 2, 1))
assert(host.supportsSpan(chart, 2, 2))
assert(not host.supportsSpan(chart, 1, 2))
assert(not host.supportsSpan(chart, 2, 3))
assert(not host.supportsSpan(chart, 1, 1))
equal(chart.format(12.345, 2), "12.35")
equal(chart.format(nil), "--")
equal(#chart.validateSettings({ metrics = { { source = "RxBt" }, {} } }), 0)
for _, value in ipairs({ "invalid", false, math.huge, 0 / 0 }) do
    assert(#chart.validateSettings({ metrics = { { rangeMin = value } } }) > 0)
end
assert(#chart.validateSettings({ metrics = { { precision = 4 } } }) > 0)
assert(#chart.validateSettings({ metrics = { { rangeMin = 10, rangeMax = 10 } } }) > 0)
assert(#chart.validateSettings({ metrics = { { unknown = 1 } } }) > 0)
assert(#chart.validateSettings({ metrics = { {}, {}, {}, {} } }) > 0)
assert(#chart.validateSettings({ metrics = { [2] = {} } }) > 0)
local settings, warnings = host.resolveSettings(chart, {})
equal(#warnings, 0)
equal(settings.duration, "30s")
equal(settings.smoothing, "off")
equal(#settings.metrics, 0)
assert(chart.intervalFor(12000, 200, 1) > chart.intervalFor(3000, 200, 1))
assert(chart.intervalFor(12000, 100, 1) > chart.intervalFor(12000, 200, 1))
local scales = {
    settings = { scaling = "shared", range = "auto" },
    series = {
        { settings = {}, feed = { available = true, min = 24, max = 25 } },
        { settings = {}, feed = { available = false } },
    },
}
chart.ranges(scales)
assert(scales.series[1].low > 0, "missing series must not pull a shared range down to zero")
equal(scales.series[1].low, scales.series[2].low)
scales.settings.scaling = "independent"
chart.ranges(scales)
equal(scales.series[2].low, 0)
scales.settings.scaling, scales.settings.range = "shared", "fixed"
scales.series[1].settings.rangeMin, scales.series[1].settings.rangeMax = -10, 50
chart.ranges(scales)
equal(scales.series[2].low, -10)
equal(scales.series[2].high, 50)

fixture.reset()
fixture.radio.values[300] = 0
local context = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" })
fixture.pump(context, 40)
equal(#context.errors, 0, table.concat(context.errors, "\n"))
equal(#context.panels, 4)
local power = fixture.instanceOf(context, "power")
equal(power.indicator, nil, "charts must not create a recording dot")
equal(power.series[1].feed.available, false)
equal(power.status.properties.text, "WAITING FOR ARM")
fixture.radio.values[300] = 1024
fixture.pump(context, 40)
equal(power.status.properties.text, "")
assert(power.session.recording)
equal(power.series[1].feed.value, 24)
equal(power.series[2].feed.value, 10)
assert(power.series[1].runs[1].line)
assert(power.series[2].runs[1].line)
assert(power.series[1].name.properties.x > power.area.x + power.area.w)
assert(power.series[1].extrema.properties.y > power.series[1].value.properties.y)
equal(power.series[1].runs[1].line.kind, power.series[2].runs[1].line.kind)
local fixed = fixture.instanceOf(context, "fixed")
equal(fixed.series[1].low, 0)
equal(fixed.series[1].high, 200)
local elapsed = power.session.elapsed
fixture.radio.values[300] = 0
fixture.pump(context, 40)
local paused = power.session.elapsed
assert(paused >= elapsed)
fixture.radio.values[100] = 3
fixture.pump(context, 40)
equal(power.session.elapsed, paused)
equal(power.series[1].feed.value, 24, "the legend must freeze while disarmed")
fixture.radio.values[300] = 1024
fixture.pump(context, 40)
equal(power.series[1].feed.value, 3)
equal(power.series[1].feed.min, 3)
equal(power.series[1].feed.max, 24)
assert(power.series[1].runCount >= 2, "rearm must not connect separate recording segments")
assert(power.series[1].runs[2].marker, "rearm boundary must be marked")
for _, size in ipairs({ { 320, 240 }, { 800, 480 }, { 480, 272 } }) do
    context.zone.w, context.zone.h = size[1], size[2]
    fixture.pump(context, 60)
    equal(#context.errors, 0, table.concat(context.errors, "\n"))
    for _, entry in ipairs(context.panels) do
        local panel = entry.instance
        assert(panel.area.w > 0 and panel.area.h > 0)
        assert(panel.area.legendX >= panel.area.x + panel.area.w)
        for _, item in ipairs(panel.series) do
            for _, run in ipairs(item.runs) do
                if run.line and not run.line.hidden then
                    for _, point in ipairs(run.pts) do
                        assert(point[1] >= panel.area.x and point[1] <= panel.area.x + panel.area.w)
                        assert(point[2] >= panel.area.y and point[2] <= panel.area.y + panel.area.h)
                    end
                end
            end
        end
    end
end
assert(fixture.lvglMock.replacedFontRefCount() == 0, "chart reflow must reuse font callbacks")

local empty = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
local built, message = empty.dashboardLoader.buildPanel(empty, {
    id = "unconfigured",
    type = "chart",
    col = 0,
    row = 0,
    colSpan = 2,
    rowSpan = 1,
    config = {},
})
assert(built, message)
equal(built.instance.status.properties.text, "SET ARM SOURCE")
