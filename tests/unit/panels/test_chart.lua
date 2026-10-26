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
equal(#chart.validateSettings({ metrics = { { rangeMin = 200 } } }), 0)
equal(#chart.validateSettings({ metrics = { { rangeMax = -200 } } }), 0)
assert(#chart.validateSettings({ metrics = { { rangeMin = 100 }, { rangeMax = 0 } } }) > 0)
equal(#chart.validateSettings({
    scaling = "independent",
    metrics = { { rangeMin = 100 }, { rangeMax = 0 } },
}), 0)
assert(#chart.validateSettings({ metrics = { { unknown = 1 } } }) > 0)
assert(#chart.validateSettings({ metrics = { {}, {}, {}, {} } }) > 0)
assert(#chart.validateSettings({ metrics = { [2] = {} } }) > 0)
local settings, warnings = host.resolveSettings(chart, {})
equal(#warnings, 0)
equal(settings.duration, "30s")
equal(settings.smoothing, "off")
equal(#settings.metrics, 0)
settings, warnings = host.resolveSettings(chart, { range = "fixed", metrics = { { rangeMin = 200 } } })
equal(#warnings, 0, "earlier preview layouts must remain loadable")
equal(settings.metrics[1].rangeMin, 200)
equal(settings.metrics[1].rangeMax, nil)
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
scales.settings.range = "auto"
chart.ranges(scales)
equal(scales.series[2].low, -10, "explicit bounds take precedence over the legacy range selector")
equal(scales.series[2].high, 50)

local function expectBounds(config, rawLow, rawHigh, low, high)
    local item = { settings = config, feed = { available = rawLow ~= nil, min = rawLow, max = rawHigh } }
    chart.ranges({ settings = { scaling = "independent" }, series = { item } })
    assert(math.abs(item.low - low) < 1e-8, string.format("expected lower bound %g, got %g", low, item.low))
    assert(math.abs(item.high - high) < 1e-8, string.format("expected upper bound %g, got %g", high, item.high))
    assert(item.high > item.low, "one-sided bounds must always leave a usable range")
end

expectBounds({}, 100, 300, 80, 320)
expectBounds({}, 0, 100, -10, 110)
expectBounds({ rangeMin = 0 }, 100, 300, 0, 320)
expectBounds({ rangeMax = 400 }, 100, 300, 80, 400)
expectBounds({ rangeMin = 0, rangeMax = 200 }, 100, 300, 0, 200)
expectBounds({ rangeMin = -50, rangeMax = -10 }, 100, 300, -50, -10)
expectBounds({ rangeMin = 500 }, 100, 300, 500, 510)
expectBounds({ rangeMax = 0 }, 100, 300, -0.1, 0)
expectBounds({ rangeMin = 100 }, nil, nil, 100, 102)
expectBounds({ rangeMax = -100 }, nil, nil, -102, -100)
expectBounds({}, 0, 0, -0.01, 0.01)

scales.settings.scaling = "shared"
scales.series[1].settings = { rangeMin = 0 }
scales.series[2].settings = { rangeMax = 30 }
chart.ranges(scales)
equal(scales.series[1].low, 0)
equal(scales.series[1].high, 30, "shared ranges use explicit bounds from any metric")
equal(scales.series[2].high, 30)
scales.series[1].settings = { rangeMin = 10, rangeMax = 20 }
scales.series[2].settings = { rangeMin = 0, rangeMax = 30 }
chart.ranges(scales)
equal(scales.series[1].low, 0, "shared ranges use the outermost configured bounds")
equal(scales.series[1].high, 30)
scales.settings.scaling = "independent"
chart.ranges(scales)
equal(scales.series[1].low, 10)
equal(scales.series[1].high, 20)
equal(scales.series[2].low, 0)
equal(scales.series[2].high, 30)

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
assert(power.series[1].low < 24 and power.series[1].high > 24)
equal(power.series[1].feed.value, 24)
equal(power.series[2].feed.value, 10)
assert(power.series[1].runs[1].line)
assert(power.series[2].runs[1].line)
equal(power.series[1].runs[1].line.properties.thickness, 1)
equal(power.series[2].runs[1].line.properties.thickness, 1)
local function alignedReadouts(panel)
    local first = panel.series[1]
    for _, item in ipairs(panel.series) do
        equal(
            item.value.properties.x + item.value.properties.w,
            first.value.properties.x + first.value.properties.w,
            "numeric readings must share a right edge independently of units"
        )
        equal(item.unit.properties.x, first.unit.properties.x, "units must share their own column")
        equal(item.name.properties.w, first.name.properties.w, "captions must share their own column")
        equal(item.unit.properties.y, item.value.properties.y, "numbers and units must share a baseline")
        equal(item.maximum.properties.x, first.maximum.properties.x, "maxima must share their own column")
        equal(item.value.properties.text, item.valueText)
        equal(item.unit.properties.text, item.unitText)
    end
end
local function separatedReadouts(panel)
    local count = #panel.series
    if count < 2 then
        return
    end
    local builder = panel.themeBuilder
    local height = builder.fontHeight(panel.legendFont)
        + (panel.showExtrema and builder.fontAscent(panel.extremaFont) or 0)
    local spare = panel.rect.h - 2 - count * height
    if spare < 0 then
        return
    end
    local expected = math.min(6, math.floor(spare / (count - 1)))
    for index = 2, count do
        equal(
            panel.series[index].name.properties.y - panel.series[index - 1].name.properties.y - height,
            expected,
            "metric groups must use spare height for a bounded gap"
        )
    end
    assert(panel.series[count].name.properties.y + height <= panel.rect.h)
end
alignedReadouts(power)
separatedReadouts(power)
assert(power.series[1].name.properties.x > power.area.x + power.area.w)
assert(power.series[1].extrema.properties.y > power.series[1].value.properties.y)
assert(power.showExtrema, "two sources must retain their extrema in a standard short panel")
assert(fixture.instanceOf(context, "recording").showExtrema, "a tall panel must fit three enlarged legend entries")
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
assert(#power.series[1].markerKeys > 0, "rearm boundary must be marked")
for _, size in ipairs({ { 320, 240 }, { 800, 480 }, { 480, 272 } }) do
    context.zone.w, context.zone.h = size[1], size[2]
    fixture.pump(context, 60)
    equal(#context.errors, 0, table.concat(context.errors, "\n"))
    for _, entry in ipairs(context.panels) do
        local panel = entry.instance
        assert(panel.area.w > 0 and panel.area.h > 0)
        assert(panel.area.legendX >= panel.area.x + panel.area.w)
        for _, item in ipairs(panel.series) do
            equal(item.name.properties.font(), panel.legendFont, "metric names must follow the legend font")
            equal(item.value.properties.font(), panel.legendFont, "recorded values must follow the legend font")
            equal(item.unit.properties.font(), panel.legendFont, "units must follow the reading font")
            equal(item.extrema.properties.font(), panel.extremaFont, "minimum must use the smaller extrema font")
            equal(item.maximum.properties.font(), panel.extremaFont, "maximum must use the smaller extrema font")
            assert(panel.themeBuilder.fontHeight(panel.extremaFont) < panel.themeBuilder.fontHeight(panel.legendFont))
            equal(item.extrema.properties.text, item.minimumText)
            equal(item.maximum.properties.text, item.maximumText)
            equal(item.minSymbol.kind, "triangle")
            equal(item.maxSymbol.kind, "triangle")
            assert(item.minSymbol.properties.pts[1][2] < item.minSymbol.properties.pts[3][2])
            assert(item.maxSymbol.properties.pts[1][2] > item.maxSymbol.properties.pts[3][2])
            assert(panel.themeBuilder.fontHeight(panel.legendFont) >= panel.themeBuilder.fontHeight(SMLSIZE))
            if panel.showExtrema then
                assert(
                    item.extrema.properties.y
                        >= item.value.properties.y + panel.themeBuilder.fontHeight(panel.legendFont)
                )
                assert(item.extrema.properties.y + panel.themeBuilder.fontAscent(panel.extremaFont) <= panel.rect.h)
                assert(item.maximum.properties.x + item.maximum.properties.w <= panel.area.legendX + panel.area.legendW)
            end
            alignedReadouts(panel)
            separatedReadouts(panel)
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

fixture.radio.values[getFieldInfo("RxBt").id] = 6.1
fixture.radio.values[getFieldInfo("Curr").id] = 2.0
fixture.pump(context, 60)
equal(power.series[1].value.properties.text, "6.1")
equal(power.series[2].value.properties.text, "2.0")
equal(power.series[1].unit.properties.text, "V")
equal(power.series[2].unit.properties.text, "A")
alignedReadouts(power)

local function typographyPanel(count)
    local metrics = {}
    for index = 1, count do
        metrics[index] = { source = "Alt", label = "A", precision = 0, unit = "" }
    end
    local entry, message = context.dashboardLoader.buildPanel(context, {
        id = "typography-" .. count,
        type = "chart",
        col = 0,
        row = 0,
        colSpan = 2,
        rowSpan = 2,
        config = { metrics = metrics },
    })
    assert(entry, message)
    return entry.instance
end

local single, multiple = typographyPanel(1), typographyPanel(3)
local feed = single.series[1].feed
local previousHeight = 0
local heights = {}
for _, size in ipairs({ { 232, 64 }, { 232, 132 }, { 472, 132 }, { 472, 264 } }) do
    chart.update(single, { x = 0, y = 0, w = size[1], h = size[2] })
    local builder = single.themeBuilder
    local height = builder.fontHeight(single.legendFont)
    assert(height >= previousHeight, "adding space must not make identical readouts smaller")
    assert(
        height <= math.max(builder.fontHeight(SMLSIZE), math.floor(size[2] / 6)),
        "legend must not dominate the plot"
    )
    assert(height <= builder.fontHeight(MIDSIZE), "chart legends must not use primary-reading fonts")
    if height > builder.fontHeight(SMLSIZE) then
        assert(single.area.w >= math.floor(single.area.frame.content / 2) - 6, "larger fonts must preserve plot space")
    end
    local expectedExtrema = single.legendFont == MIDSIZE and 0 or single.legendFont == 0 and SMLSIZE or TINSIZE
    equal(single.extremaFont, expectedExtrema, "extrema must be exactly one font step smaller")
    assert(single.showExtrema, "larger fonts must not hide extrema that fit at the readability floor")
    equal(single.series[1].feed, feed, "typography reflow must retain history subscriptions")
    previousHeight = height
    heights[#heights + 1] = height
end
assert(previousHeight > single.themeBuilder.fontHeight(SMLSIZE), "large widgets must use a larger font")
equal(heights[1], single.themeBuilder.fontHeight(SMLSIZE), "short panels must keep compact legends")
equal(heights[2], single.themeBuilder.fontHeight(0), "standard panels must not inflate single-metric legends")
equal(heights[3], heights[2], "spare width alone must not enlarge the legend")
equal(heights[4], single.themeBuilder.fontHeight(MIDSIZE), "tall panels may use medium text")
chart.update(single, { x = 0, y = 0, w = 472, h = 132 })
chart.update(multiple, { x = 0, y = 0, w = 472, h = 132 })
assert(
    single.themeBuilder.fontHeight(single.legendFont) > multiple.themeBuilder.fontHeight(multiple.legendFont),
    "fewer metrics must allow larger text when height is the limiting factor"
)
chart.update(multiple, { x = 0, y = 0, w = 472, h = 100 })
equal(multiple.legendFont, SMLSIZE, "keep all extrema instead of increasing the font and hiding them")
assert(multiple.showExtrema)
separatedReadouts(multiple)
chart.update(multiple, { x = 0, y = 0, w = 232, h = 84 })
assert(multiple.showExtrema, "extra group spacing must yield before hiding extrema")
separatedReadouts(multiple)
equal(
    multiple.series[2].name.properties.y - multiple.series[1].name.properties.y,
    28,
    "tight layouts must shrink the gap instead of dropping information"
)
chart.update(single, { x = 0, y = 0, w = 232, h = 64 })
chart.update(multiple, { x = 0, y = 0, w = 232, h = 64 })
equal(multiple.legendFont, SMLSIZE, "crowded short panels must keep the readable minimum")
assert(not multiple.showExtrema, "extrema may hide only when they cannot fit at the minimum font")
separatedReadouts(multiple)
chart.update(single, { x = 0, y = 0, w = 472, h = 132 })
local initialFontHeight = single.themeBuilder.fontHeight(single.legendFont)
local altitudeId = getFieldInfo("Alt").id
local altitude = fixture.radio.values[altitudeId]
fixture.radio.values[altitudeId] = 123456789012345678901234
fixture.pump(context, 60)
chart.refresh(single)
assert(
    single.themeBuilder.fontHeight(single.legendFont) < initialFontHeight,
    "longer readouts must reduce the font to fit"
)
assert(
    single.area.legendW >= single.themeBuilder.measureText(single.legendFont, single.series[1].readout),
    "the resized legend must fit the full recorded value"
)
equal(single.series[1].name.properties.font(), single.legendFont)
equal(single.series[1].value.properties.font(), single.legendFont)
equal(single.series[1].unit.properties.font(), single.legendFont)
equal(single.series[1].extrema.properties.font(), single.extremaFont)
equal(single.series[1].maximum.properties.font(), single.extremaFont)
fixture.radio.values[altitudeId] = altitude
assert(fixture.lvglMock.replacedFontRefCount() == 0, "font resizing must reuse native callbacks")

local function recordingPanel(id, range)
    local entry, errorMessage = context.dashboardLoader.buildPanel(context, {
        id = id,
        type = "chart",
        col = 0,
        row = 0,
        colSpan = 2,
        rowSpan = 2,
        config = {
            timeRange = range,
            duration = range == "rolling" and "30s" or "10m",
            metrics = { { source = id, precision = 3, rangeMin = -100, rangeMax = 100 } },
        },
    })
    assert(entry, errorMessage)
    return entry.instance
end

local function finishDrawing(panel)
    for _ = 1, 2000 do
        chart.refresh(panel)
        local item = panel.series[1]
        if
            not panel.pending
            and item.drawnRevision == item.feed.plotRevision
            and item.drawnVersion == panel.version
        then
            return
        end
    end
    error("staged projection did not converge")
end

local dense = recordingPanel("dense-chart", "growing")
local history = dense.history
local now = getTime()
local reading = { name = "dense-chart", fresh = true, kind = "number", precision = 3, unitText = "" }
for index = 0, 6000 do
    reading.value, reading.updatedAt = index % 2 == 0 and -100 or 100, now + index * 10
    history:sample(reading, reading.updatedAt)
end
local denseItem = dense.series[1]
equal(denseItem.feed.count, 6001)
equal(denseItem.feed.full, false)
equal(denseItem.feed.epsilon, 0.0005, "metric precision must reach the compressor")
finishDrawing(dense)
local run = denseItem.runs[1]
assert(run.size <= 4 * (dense.area.w + 1), "dense histories must project to bounded screen-column points")
local top, bottom = false, false
for _, point in ipairs(run.pts) do
    top, bottom = top or point[2] == dense.area.y, bottom or point[2] == dense.area.y + dense.area.h
end
assert(top and bottom, "display reduction must retain spikes in both directions")
for index = 6001, 6144 do
    reading.value, reading.updatedAt = index % 2 == 0 and -100 or 100, now + index * 10
    history:sample(reading, reading.updatedAt)
end
equal(denseItem.feed.full, true)
local frozenRevision = denseItem.feed.plotRevision
reading.value, reading.updatedAt = 1000, reading.updatedAt + 10
history:sample(reading, reading.updatedAt)
equal(denseItem.feed.value, 1000)
equal(denseItem.feed.max, 1000)
equal(denseItem.feed.plotRevision, frozenRevision)
chart.refresh(dense)
chart.update(dense, { x = 0, y = 0, w = 472, h = 264 })
finishDrawing(dense)
equal(dense.status.properties.text, "HISTORY FULL")
assert(denseItem.runs[1].line and not denseItem.runs[1].line.hidden, "full history must remain drawable after resize")
history.failed = true
chart.refresh(dense)
equal(dense.status.properties.text, "HISTORY N/A", "full status must not mask service failure")
history.failed = nil

local clipped = recordingPanel("clipped-chart", "rolling")
reading.name, now = "clipped-chart", reading.updatedAt + 10
for index = 0, 60 do
    reading.value, reading.updatedAt = index, now + index * 100
    history:sample(reading, reading.updatedAt)
end
finishDrawing(clipped)
local clippedRun = clipped.series[1].runs[1]
local first = clippedRun.pts[1]
equal(first[1], clipped.area.x, "rolling ramps must interpolate at the left boundary")
local expectedY = clipped.area.y + math.floor((1 - (30 + 100) / 200) * clipped.area.h + 0.5)
equal(first[2], expectedY, "window clipping must interpolate the retained bracketing segment")

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
