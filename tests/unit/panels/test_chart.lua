-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local chartModule = fixture.module("panels/chart.lua")
local function refresh(panel)
    local interval, unfinished
    for _ = 1, 2000 do
        interval, unfinished = chartModule.refresh(panel)
        if not unfinished then
            return interval
        end
    end
    error("chart frame did not finish")
end
local chart = {}
for key, value in pairs(chartModule) do
    chart[key] = value
end
chart.refresh = refresh
chart.update = function(panel, rect)
    chartModule.update(panel, rect)
    refresh(panel)
end
local host = fixture.module("lib/panel_host.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

assert(host.validateModule(chart, "chart"))
assert(host.supportsSpan(chart, 2, 1))
assert(host.supportsSpan(chart, 2, 2))
assert(not host.supportsSpan(chart, 1, 2))
assert(not host.supportsSpan(chart, 2, 3))
assert(not host.supportsSpan(chart, 1, 1))
for _, armSwitch in ipairs({ "", "SA^", "SA-", "SAv", "L01" }) do
    equal(#chart.validateSettings({ metrics = {}, armSwitch = armSwitch }), 0)
end
for _, armSwitch in ipairs({ "sa", "ch5", "invalid", 1, true }) do
    assert(#chart.validateSettings({ metrics = {}, armSwitch = armSwitch }) > 0)
end
equal(chart.format(12.345, 2), "12.35")
equal(chart.format(nil), "--")
equal(chart.durationText(3000), "30s")
equal(chart.durationText(6000), "1m")
equal(chart.durationText(12000), "2m")
equal(chart.gridInterval(12000, 240), 6000)
equal(chart.gridInterval(60000, 240), 6000)
equal(chart.gridInterval(120000, 240), 12000)
equal(chart.gridInterval(300000, 240), 30000)
equal(chart.gridInterval(60000, 100), 30000)
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
equal(settings.duration, "1m")
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
fixture.pump(context, 120)
equal(#context.errors, 0, table.concat(context.errors, "\n"))
equal(#context.panels, 4)
local power = fixture.instanceOf(context, "power")
equal(power.axisStart, nil, "bottom axis labels must not be created")
equal(power.axisEnd, nil, "bottom axis labels must not be created")
equal(power.duration.properties.text, "1m")
local function checkDurationCorner(panel)
    local properties, area = panel.duration.properties, panel.area
    equal(properties.x + properties.w, area.x + area.w, "duration must align with the plot's right edge")
    equal(
        properties.y + panel.themeBuilder.fontAscent(TINSIZE),
        math.max(panel.rect.h - 2, panel.legendBaseline),
        "duration must use the panel's bottom text baseline or the last legend row, whichever is lower"
    )
    for _, item in ipairs(panel.series) do
        local y = panel.showExtrema and item.extrema.properties.y or item.value.properties.y
        local font = panel.showExtrema and panel.extremaFont or panel.legendFont
        assert(
            properties.y + panel.themeBuilder.fontAscent(TINSIZE) >= y + panel.themeBuilder.fontAscent(font),
            "duration must never sit higher than a legend row"
        )
    end
    assert(panel.durationBackground.properties.h > 0, "duration background must cover its lowered position")
    assert(not panel.durationBackground.hidden, "duration needs a readable plot-corner background")
end
checkDurationCorner(power)
equal(power.indicator, nil, "charts must not create a recording dot")
equal(power.series[1].feed.available, false)
equal(power.status.properties.text, "WAITING FOR ARM")
equal(#power.armMarkers.markerKeys, 0, "no arm boundary may be created before the first recording")
fixture.radio.values[300] = 1024
fixture.pump(context, 40)
assert(fixture.pumpUntil(context, function()
    return not power.framePhase and power.series[1].snapshot.available
end, 500))
equal(power.status.properties.text, "")
equal(#power.armMarkers.markerKeys, 0, "the initial arming must not draw a vertical boundary")
assert(power.session.recording)
assert(power.series[1].low < 24 and power.series[1].high > 24)
equal(power.series[1].feed.value, 24)
equal(power.series[2].feed.value, 10)
assert(power.series[1].runs[1].line)
assert(power.series[2].runs[1].line)
equal(power.series[1].runs[1].line.properties.thickness, 1)
equal(power.series[2].runs[1].line.properties.thickness, 1)
local function alignedReadouts(panel)
    for _, item in ipairs(panel.series) do
        local legendX, legendW = item.legendX or panel.area.legendX, item.legendW or panel.area.legendW
        local alignment = item.legendAlignment or 1
        equal(
            item.value.properties.x + item.value.properties.w,
            item.unit.properties.x,
            "units must sit directly beside their value"
        )
        equal(
            item.value.properties.x,
            legendX + math.floor((legendW - item.value.properties.w - item.unit.properties.w) * alignment),
            "each complete main reading must follow its metric group's alignment"
        )
        if panel.stackedLegend then
            equal(
                item.name.properties.x,
                legendX + math.floor((legendW - item.name.properties.w) * alignment),
                "metric captions must follow the same alignment as the reading"
            )
            equal(
                item.name.properties.y + panel.themeBuilder.fontHeight(panel.legendFont),
                item.value.properties.y,
                "horizontal metric groups must put the caption above the value"
            )
        else
            equal(
                item.name.properties.x + item.name.properties.w + 4,
                item.value.properties.x,
                "captions must sit a fixed distance before their value"
            )
        end
        equal(
            item.name.properties.w,
            math.min(
                panel.stackedLegend and legendW or math.max(0, item.value.properties.x - legendX - 4),
                panel.themeBuilder.measureText(panel.legendFont, item.nameText)
            ),
            "captions must hug their text instead of stretching across the legend"
        )
        equal(item.unit.properties.y, item.value.properties.y, "numbers and units must share a baseline")
        local size = math.max(4, math.floor(panel.themeBuilder.fontHeight(panel.extremaFont) / 3))
        local available = math.max(0, legendW - 2 * size - 14)
        equal(
            item.extrema.properties.w,
            math.min(
                math.floor(available / 2),
                panel.themeBuilder.measureText(panel.extremaFont, item.minimumText or "--")
            ),
            "minimum labels must hug their text"
        )
        equal(
            item.maximum.properties.w,
            math.min(
                available - math.floor(available / 2),
                panel.themeBuilder.measureText(panel.extremaFont, item.maximumText or "--")
            ),
            "maximum labels must hug their text"
        )
        local left = item.minSymbol.properties.pts[1][1]
        local right = item.maximum.properties.x + item.maximum.properties.w
        equal(
            left,
            legendX + math.floor((legendW - (right - left)) * alignment),
            "the compact extrema pair must follow the same alignment as the reading"
        )
        equal(item.extrema.properties.x, left + size + 3, "minimum arrow must stay beside its value")
        equal(
            item.maxSymbol.properties.pts[1][1] - (item.extrema.properties.x + item.extrema.properties.w),
            8,
            "minimum and maximum groups must retain a small fixed gap"
        )
        equal(
            item.maxSymbol.properties.pts[1][1] + size + 3,
            item.maximum.properties.x,
            "maximum arrow must stay beside its value"
        )
        equal(item.value.properties.text, item.valueText)
        equal(item.unit.properties.text, item.unitText)
    end
end
local function separatedReadouts(panel)
    checkDurationCorner(panel)
    local count = #panel.series
    if count == 0 then
        return
    end
    local builder = panel.themeBuilder
    if panel.topLegend then
        equal(panel.area.w, panel.area.frame.content, "top legends must leave the full plot width")
        local first = panel.series[1].name.properties.y
        for index, item in ipairs(panel.series) do
            equal(item.name.properties.y, first, "top metrics must share one horizontal row")
            assert(item.name.properties.y + builder.fontHeight(panel.legendFont) <= panel.area.y)
            assert(item.value.properties.y + builder.fontAscent(panel.legendFont) <= panel.area.y)
            if panel.showExtrema then
                assert(item.extrema.properties.y + builder.fontAscent(panel.extremaFont) <= panel.area.y)
            end
            if index > 1 then
                local previous = panel.series[index - 1]
                assert(previous.legendX + previous.legendW <= item.legendX, "metric groups must not overlap")
            end
        end
        return
    end
    local height = builder.fontHeight(panel.legendFont)
        + (panel.showExtrema and builder.fontAscent(panel.extremaFont) or 0)
    local first = panel.series[1].name.properties.y
    equal(first, panel.area.frame.labelY, "legend must stay at the title's top inset independently of the plot")
    if count < 2 then
        return
    end
    if count * height > panel.rect.h - first then
        return
    end
    local spare = panel.rect.h - first - 2 - count * height
    local preferred = math.floor(builder.fontHeight(panel.extremaFont) * 2 / 3)
    local expected = math.max(0, math.min(preferred, math.floor(spare / (count - 1))))
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
assert(fixture.pumpUntil(context, function()
    return fixed.series[1].low ~= nil
end, 500))
equal(fixed.series[1].low, 0)
equal(fixed.series[1].high, 200)
local elapsed = power.session.elapsed
fixture.radio.values[300] = 0
fixture.pump(context, 40)
assert(fixture.pumpUntil(context, function()
    return not power.framePhase and not power.session.recording
end, 500))
local paused = power.session.elapsed
assert(paused >= elapsed)
equal(#power.resumeMarkers.markerKeys, 0, "pausing must not add a band or an axis break")
equal(power.status.properties.text, "", "pausing must not print a status")
local disarmColumn = math.floor((paused - power.start) / power.window * power.area.w + 0.5) + 1
local disarmMarker = power.armMarkers.markers[-disarmColumn]
assert(disarmMarker and disarmMarker.active)
equal(disarmMarker.object.kind, "triangle")
assert(disarmMarker.object.properties.pts[3][2] > disarmMarker.object.properties.pts[1][2])
local pausedRevision = power.series[1].feed.plotRevision
chart.update(power, power.rect)
assert(
    power.armMarkers.markers[-disarmColumn] == disarmMarker
        or power.backPlot.armMarkers.markers[-disarmColumn] == disarmMarker,
    "reflow must reuse pooled markers"
)
fixture.radio.values[100] = 3
fixture.pump(context, 40)
equal(power.session.elapsed, paused)
equal(power.series[1].feed.value, 24, "the legend must freeze while disarmed")
equal(power.series[1].feed.plotRevision, pausedRevision, "showing a disarm marker must not add fake telemetry samples")
fixture.radio.values[300] = 1024
fixture.pump(context, 40)
assert(fixture.pumpUntil(context, function()
    return not power.framePhase and power.series[1].snapshot.value == 3
end, 500))
equal(power.series[1].feed.value, 3)
equal(power.series[1].feed.min, 3)
equal(power.series[1].feed.max, 24)
assert(power.series[1].runCount >= 3, "rearm adds a dotted connector between separate solid segments")
assert(power.series[1].runs[2].dotted and power.series[1].runs[2].connector)
equal(power.status.properties.text, "")
equal(#power.series[1].markerKeys, 0, "a recording pause must not add a full-height telemetry-gap marker")
local seam = power.resumeMarkers.markers[power.resumeMarkers.markerKeys[#power.resumeMarkers.markerKeys]]
assert(seam and seam.active, "resuming must mark the inserted gap")
assert(not seam.object.hidden)
equal(seam.object.properties.w, 24, "the inserted gap must retain the wider spacing")
equal(seam.object.properties.color, power.theme.color.surface, "the gap must not darken the chart")
equal(seam.object.parent, power.gapRoot, "the gap only masks flight shading, below grid and telemetry")
equal(seam.object.kind, "rectangle")
equal(seam.slashes, nil, "there must be no pause icon")
for _, size in ipairs({ { 320, 240 }, { 800, 480 }, { 480, 272 } }) do
    context.zone.w, context.zone.h = size[1], size[2]
    fixture.pump(context, 60)
    equal(#context.errors, 0, table.concat(context.errors, "\n"))
    for _, entry in ipairs(context.panels) do
        local panel = entry.instance
        chart.refresh(panel)
        assert(panel.area.w > 0 and panel.area.h > 0)
        assert(panel.topLegend or panel.area.legendX >= panel.area.x + panel.area.w)
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
                assert(
                    item.maximum.properties.x + item.maximum.properties.w
                        <= (item.legendX or panel.area.legendX) + (item.legendW or panel.area.legendW)
                )
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
assert(fixture.pumpUntil(context, function()
    return power.series[1].value.properties.text == "6.1" and power.series[2].value.properties.text == "2.0"
end, 500))
equal(power.series[1].value.properties.text, "6.1")
equal(power.series[2].value.properties.text, "2.0")
equal(power.series[1].unit.properties.text, "V")
equal(power.series[2].unit.properties.text, "A")
alignedReadouts(power)

local reading = power.series[1]
local originalUnit, originalFeed = reading.settings.unit, reading.feed
chart.render(power)
equal(chart.render(power), false, "unchanged readouts must leave the callback budget available for projection")
reading.settings.unit = "mAh"
equal(chart.render(power), true, "unit overrides must invalidate cached readouts even without a telemetry revision")
alignedReadouts(power)
equal(chart.render(power), false, "the updated unit must be cached after rendering")
reading.feed = {
    value = originalFeed.value,
    min = originalFeed.min,
    max = originalFeed.max,
    precision = originalFeed.precision,
    unitText = originalFeed.unitText,
}
reading.settings.unit = "mAh"
for _, value in ipairs({ -1234.5, 9.9, 10, 1 }) do
    reading.feed.value = value
    chart.render(power)
    alignedReadouts(power)
end
reading.feed.value = nil
chart.render(power)
equal(reading.unit.properties.w, 0, "missing readings must not leave an empty unit column")
alignedReadouts(power)
reading.settings.unit, reading.feed = originalUnit, originalFeed
chart.render(power)
alignedReadouts(power)

local function typographyPanel(count, top)
    local metrics = {}
    for index = 1, count do
        metrics[index] = { source = "Alt", label = "A", precision = 0, unit = "" }
    end
    local entry, message = context.dashboardLoader.buildPanel(context, {
        id = "typography-" .. count,
        type = "chart",
        col = 0,
        row = 0,
        colSpan = top and 2 or 4,
        rowSpan = 2,
        config = { metrics = metrics, armSwitch = "SAv" },
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
    alignedReadouts(single)
    separatedReadouts(single)
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
separatedReadouts(multiple)
local function metricGap(panel)
    return panel.series[2].name.properties.y
        - panel.series[1].name.properties.y
        - panel.themeBuilder.fontHeight(panel.legendFont)
        - panel.themeBuilder.fontAscent(panel.extremaFont)
end
equal(metricGap(multiple), 8, "roomy small-font legends must prefer two-thirds of an extrema line")
multiple.settings.label = "Recorded"
chart.update(multiple, multiple.rect)
separatedReadouts(multiple)
equal(metricGap(multiple), 8, "standard titled charts must retain the preferred gap when it fits")
equal(
    multiple.series[1].name.properties.y,
    multiple.area.frame.labelY,
    "explicit titles must share their top inset with the first metric"
)
local compact = typographyPanel(2)
compact.settings.label = "Power"
chart.update(compact, { x = 0, y = 0, w = 232, h = 64 })
separatedReadouts(compact)
assert(compact.showExtrema, "short two-metric charts must retain their extrema")
equal(compact.series[1].name.properties.y, 2, "short legends must start at the title inset")
equal(metricGap(compact), 8, "using the title row must free space between compact metric groups")
local compactTop, compactPlotTop = compact.series[1].name.properties.y, compact.area.y
compact.settings.label = ""
chart.update(compact, compact.rect)
equal(compact.series[1].name.properties.y, compactTop, "hiding the title must not move the legend")
assert(compact.area.y < compactPlotTop, "only the plot must reclaim the title row")
chart.update(multiple, { x = 0, y = 0, w = 472, h = 264 })
separatedReadouts(multiple)
equal(
    metricGap(multiple),
    math.floor(multiple.themeBuilder.fontHeight(multiple.extremaFont) * 2 / 3),
    "preferred spacing must follow the extrema font instead of stretching to fill tall panels"
)
multiple.settings.label = nil
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
    26,
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

for count = 1, 3 do
    local panel = typographyPanel(count, true)
    local feeds = {}
    for index, item in ipairs(panel.series) do
        feeds[index] = item.feed
        item.caption = ({ "ALT", "VSPD", "GSPD" })[index]
        item.settings.unit = ({ "m", "m/s", "km/h" })[index]
        item.settings.precision = 1
        item.feed = { value = 42.3, min = -1.2, max = 68.4, revision = 1 }
    end
    for _, size in ipairs({ { 232, 132 }, { 156, 112 }, { 392, 232 }, { 232, 232 } }) do
        chart.update(panel, { x = 0, y = 0, w = size[1], h = size[2] })
        assert(panel.topLegend, "square spans must use top legends even on wide radio displays")
        equal(panel.stackedLegend, count > 1)
        alignedReadouts(panel)
        separatedReadouts(panel)
        assert(panel.area.h > 0)
        if size[1] >= 232 then
            assert(panel.showExtrema, "standard square charts must retain min/max for all three metrics")
            for _, item in ipairs(panel.series) do
                assert(not item.name.hidden, "horizontal groups must retain metric names")
                equal(item.name.properties.text, item.caption)
                assert(not item.extrema.hidden and not item.maximum.hidden)
                assert(item.value.properties.w >= panel.themeBuilder.measureText(panel.legendFont, item.valueText))
            end
        end
        local first, last = panel.series[1], panel.series[count]
        if count > 1 then
            equal(first.legendX, panel.area.x, "the first group must align left")
            equal(first.name.properties.x, panel.area.x, "the left caption must start at the plot's left edge")
            equal(first.value.properties.x, panel.area.x, "the left reading must start at the plot's left edge")
            equal(
                first.minSymbol.properties.pts[1][1],
                panel.area.x,
                "the left extrema must start at the plot's left edge"
            )
            equal(last.legendX + last.legendW, panel.area.x + panel.area.w, "the last group must align right")
            equal(last.name.properties.x + last.name.properties.w, panel.area.x + panel.area.w)
            equal(last.unit.properties.x + last.unit.properties.w, panel.area.x + panel.area.w)
            equal(last.maximum.properties.x + last.maximum.properties.w, panel.area.x + panel.area.w)
        end
        if count == 3 then
            local middle = panel.series[2]
            local center = panel.area.x + panel.area.w / 2
            local extremaLeft = middle.minSymbol.properties.pts[1][1]
            local extremaRight = middle.maximum.properties.x + middle.maximum.properties.w
            assert(math.abs(middle.name.properties.x + middle.name.properties.w / 2 - center) <= 1)
            assert(
                math.abs((middle.value.properties.x + middle.unit.properties.x + middle.unit.properties.w) / 2 - center)
                    <= 1,
                "the complete middle reading must be centered, including its unit"
            )
            assert(math.abs((extremaLeft + extremaRight) / 2 - center) <= 1, "middle extrema must also be centered")
        end
    end
    panel.settings.label = "Flight"
    chart.update(panel, { x = 0, y = 0, w = 232, h = 132 })
    assert(
        panel.series[1].name.properties.y >= panel.title.properties.y + panel.themeBuilder.fontHeight(SMLSIZE),
        "top metric groups must not overlap the optional chart heading"
    )
    local width = panel.area.w
    panel.series[1].feed.value = -123456.7
    panel.series[1].feed.min = -123456.7
    panel.series[1].feed.revision = 2
    assert(chart.render(panel))
    equal(panel.area.w, width, "readout growth must never take width away from a top-layout plot")
    alignedReadouts(panel)
    separatedReadouts(panel)
    equal(chart.render(panel), false, "top readout geometry must converge without repeated reflow")
    panel.span = { colSpan = 4, rowSpan = 2 }
    chart.update(panel, { x = 0, y = 0, w = 472, h = 132 })
    assert(not panel.topLegend and not panel.stackedLegend, "wide spans must restore the existing side legend")
    alignedReadouts(panel)
    separatedReadouts(panel)
    for index, item in ipairs(panel.series) do
        item.feed = feeds[index]
    end
end

local function recordingPanel(id, range)
    local entry, errorMessage = context.dashboardLoader.buildPanel(context, {
        id = id,
        type = "chart",
        col = 0,
        row = 0,
        colSpan = 2,
        rowSpan = 2,
        config = {
            armSwitch = "SAv",
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
            and not panel.framePhase
            and item.drawnRevision == item.feed.plotRevision
            and item.drawnVersion == panel.version
            and panel.gridVersion == panel.version
        then
            return
        end
    end
    error("staged projection did not converge")
end

local gridPanel = recordingPanel("minute-grid", "rolling")
gridPanel.settings.duration = "10m"
gridPanel.session = { configured = true, available = true, recording = false, elapsed = 65000 }
for _ = 1, 24 do
    chart.refresh(gridPanel)
end
assert(gridPanel.title.hidden, "empty labels must hide the title instead of deriving one")
assert(not gridPanel.durationBackground.hidden, "titleless charts need a readable duration annotation")
equal(gridPanel.duration.properties.text, "10m")
checkDurationCorner(gridPanel)
assert(gridPanel.area.y > gridPanel.area.frame.labelY, "titleless square charts must retain only the metric header")
equal(gridPanel.area.y + gridPanel.area.h, gridPanel.rect.h - 3, "bottom labels must not reserve plot height")
equal(#gridPanel.grid, 12, "grid objects must use a bounded reusable pool")
local function checkGrid(panel)
    local visible = 0
    local previous
    for _, line in ipairs(panel.grid) do
        if line.visible then
            visible = visible + 1
            equal(line.at % panel.gridStep, 0, "grid positions must use whole armed-time intervals")
            assert(line.at > panel.start and line.at < panel.start + panel.window)
            local x = panel.area.x + math.floor((line.at - panel.start) / panel.window * panel.area.w + 0.5)
            equal(line.object.properties.x, x)
            equal(line.object.properties.y, panel.area.y)
            equal(line.object.properties.h, panel.area.h)
            equal(line.object.properties.w, 1)
            equal(line.object.properties.color, panel.theme.color.chartGrid)
            equal(line.object.properties.dashGap, nil, "minute grid must be solid, unlike gap markers")
            if previous then
                assert(x - previous >= 24, "long views must thin their grid instead of crowding it")
            end
            previous = x
        else
            assert(line.object.hidden)
        end
    end
    assert(visible > 0 and visible <= 12)
    equal(panel.gridVersion, panel.version)
    checkDurationCorner(panel)
end
checkGrid(gridPanel)
gridPanel.session.elapsed = 67500
for _ = 1, 12 do
    chart.refresh(gridPanel)
end
checkGrid(gridPanel)
chart.update(gridPanel, { x = 0, y = 0, w = 472, h = 264 })
for _ = 1, 12 do
    chart.refresh(gridPanel)
end
checkGrid(gridPanel)
gridPanel.settings.label = "Flight"
chart.update(gridPanel, gridPanel.rect)
assert(not gridPanel.title.hidden)
checkDurationCorner(gridPanel)
assert(gridPanel.area.y > gridPanel.area.frame.labelY, "explicit titles must retain a header")
gridPanel.settings.duration = "30s"
gridPanel.settings.timeRange = "growing"
for _, case in ipairs({
    { 0, 6000 },
    { 5999, 6000 },
    { 6000, 6000 },
    { 6001, 12000 },
    { 12000, 12000 },
    { 12001, 18000 },
    { 18000, 18000 },
    { 18001, 24000 },
    { 600000, 600000 },
    { 600001, 606000 },
}) do
    gridPanel.session.elapsed = case[1]
    for _ = 1, 12 do
        chart.refresh(gridPanel)
    end
    equal(gridPanel.window, case[2], "growing windows must advance by whole minutes only after a boundary is exceeded")
    equal(gridPanel.duration.properties.text, chart.durationText(case[2]))
    equal(gridPanel.start, 0, "growing mode must retain the full recording")
end
gridPanel.settings.duration = "10m"
gridPanel.session.elapsed = 0
chart.refresh(gridPanel)
equal(gridPanel.window, 6000, "legacy growing durations must not override the fixed one-minute start")
checkDurationCorner(gridPanel)
gridPanel.session.elapsed = 0
for _ = 1, 12 do
    chart.refresh(gridPanel)
end
for _, line in ipairs(gridPanel.grid) do
    assert(not line.visible and line.object.hidden, "short views must hide obsolete minute lines")
end

local dense = recordingPanel("dense-chart", "growing")
equal(
    dense.series[1].feed.window,
    6000,
    "growing subscriptions must start at one minute despite saved duration choices"
)
local history = dense.history
local now = getTime()
local arm = { fresh = true, value = true, updatedAt = now }
history.sessions[1].arm = arm
local reading = { name = "dense-chart", fresh = true, kind = "number", precision = 3, unitText = "" }
local function syntheticSample()
    arm.updatedAt = reading.updatedAt
    fixture.tick(reading.updatedAt - getTime())
    history:sample(reading, reading.updatedAt)
end
for index = 0, 6000 do
    reading.value, reading.updatedAt = index % 2 == 0 and -100 or 100, now + index * 10
    syntheticSample()
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
    syntheticSample()
end
equal(denseItem.feed.full, true)
local frozenRevision = denseItem.feed.plotRevision
reading.value, reading.updatedAt = 1000, reading.updatedAt + 10
syntheticSample()
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
    syntheticSample()
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

fixture.reset()
fixture.radio.values[300] = 1024
local light = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-light" })
fixture.pump(light, 80)
equal(#light.errors, 0, table.concat(light.errors, "\n"))
for _, entry in ipairs(light.panels) do
    local panel = entry.instance
    for _, item in ipairs(panel.series) do
        assert(item.color ~= panel.theme.color[item.settings.accent or "cyan"], "light traces need dedicated chart ink")
        equal(item.name.properties.color, item.color, "legend names must match their trace")
        for _, run in ipairs(item.runs) do
            if run.line then
                equal(run.line.properties.color, item.color)
                equal(run.line.properties.thickness, 1, "stronger colors must preserve one-pixel traces")
            end
        end
    end
end
local lightPower = fixture.instanceOf(light, "power")
for _, target in ipairs({ context, light }) do
    local recording = fixture.instanceOf(target, "recording")
    for index, accent in ipairs({ "cyan", "orange", "green" }) do
        equal(
            recording.series[index].color,
            recording.theme.chartColor[accent],
            "default traces use distinct first colors"
        )
    end
    local explicit, failure = target.dashboardLoader.buildPanel(target, {
        id = "explicit-colors",
        type = "chart",
        col = 0,
        row = 0,
        colSpan = 2,
        rowSpan = 2,
        config = {
            metrics = {
                { source = "Alt", accent = "green" },
                { source = "Curr", accent = "cyan" },
                { source = "RxBt", accent = "amber" },
            },
        },
    })
    assert(explicit, failure)
    for index, accent in ipairs({ "green", "cyan", "amber" }) do
        local item = explicit.instance.series[index]
        equal(item.color, explicit.instance.theme.chartColor[accent], "explicit colors must override the default order")
        equal(item.name.properties.color, item.color, "explicit trace colors must also identify their legend names")
    end
end
equal(lightPower.series[1].color, lightPower.theme.color.chartCyan)
equal(lightPower.series[2].color, lightPower.theme.color.chartOrange)
lightPower.settings.timeRange, lightPower.settings.duration = "rolling", "2m"
chart.update(lightPower, lightPower.rect)
for _ = 1, 24 do
    chart.refresh(lightPower)
end
checkGrid(lightPower)
equal(lightPower.baseline.properties.color, lightPower.theme.color.chartGrid, "baseline and minute grid must agree")

finishDrawing(dense)
local originalRanges, rangeUpdates = chart.ranges, 0
chartModule.ranges = function(panel)
    rangeUpdates = rangeUpdates + 1
    originalRanges(panel)
end
chart.refresh(dense)
chart.refresh(dense)
equal(rangeUpdates, 0, "unchanged recordings must reuse their vertical ranges")
denseItem.readingRevision = nil
chart.refresh(dense)
equal(rangeUpdates, 1, "a changed reading revision must recompute vertical ranges")
chartModule.ranges = originalRanges

local historyService = light.serviceRuntime.byId.history
local telemetryService = light.serviceRuntime.byId.telemetry
local controlService = light.serviceRuntime.byId.control
local subscriptions, telemetryCount, controlCount = historyService.count, telemetryService.count, controlService.count
local livePlacement = fixture.entryById(light, "power").placement
local previewConfig = {}
for key, value in pairs(livePlacement.config) do
    previewConfig[key] = value
end
previewConfig.label = "Preview label"
local compatible, previewError = light.dashboardLoader.buildPanel(light, {
    id = "chart-preview-compatible",
    type = "chart",
    col = 0,
    row = 0,
    colSpan = 2,
    rowSpan = 2,
    config = previewConfig,
}, nil, true)
assert(compatible, previewError)
equal(compatible.instance.series[1].feed, lightPower.series[1].feed, "visual edits must reuse compatible history views")
finishDrawing(compatible.instance)
equal(compatible.instance.status.properties.text, "PREVIEW")
assert(compatible.instance.series[1].runs[1].line, "a compatible chart preview must still draw recorded history")
chart.update(compatible.instance, { x = 0, y = 0, w = 472, h = 196 })
finishDrawing(compatible.instance)
assert(not compatible.instance.series[1].runs[1].line.hidden, "resizing a read-only preview preserves its traces")
local incompatible, incompatibleError = light.dashboardLoader.buildPanel(light, {
    id = "chart-preview-new",
    type = "chart",
    col = 0,
    row = 0,
    colSpan = 2,
    rowSpan = 1,
    config = { armSwitch = "L64", metrics = { { source = "draft-only-source" } } },
}, nil, true)
assert(incompatible, incompatibleError)
finishDrawing(incompatible.instance)
equal(incompatible.instance.status.properties.text, "PREVIEW: NO DATA")
equal(historyService.count, subscriptions)
equal(telemetryService.count, telemetryCount)
equal(controlService.count, controlCount, "draft-only arm changes must not subscribe to live control")
