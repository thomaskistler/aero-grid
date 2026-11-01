-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
fixture.reset()

local sources = { "ail", "ele", "thr", "rud" }
for index, source in ipairs(sources) do
    local id = 5000 + index
    fixture.radio.fields[source] = { id = id, name = source, unit = 1 }
    fixture.radio.values[id] = 0
end
fixture.radio.rssi = 80
fixture.radio.values[300] = 1024
fixture.radioMock.indexFields()

local lines = {
    "version: 3",
    "grid:",
    "  columns: 4",
    "  rows: 4",
    "panels:",
}
for chartIndex = 1, 2 do
    local firstSource = (chartIndex - 1) * 2 + 1
    lines[#lines + 1] = string.format(
        "  - id: chart%d\n    type: chart\n    col: %d\n    row: 0\n    colSpan: 2\n    rowSpan: 2\n"
            .. "    config:\n      label: Chart %d\n      armSwitch: SAv\n      scaling: independent\n      metrics:",
        chartIndex,
        (chartIndex - 1) * 2,
        chartIndex
    )
    for sourceIndex = firstSource, firstSource + 1 do
        lines[#lines + 1] = "        - source: " .. sources[sourceIndex] .. "\n          precision: 0"
    end
end
local layoutPath = root .. "/build/test-widget-fixture/layouts/chart-responsiveness.yaml"
local layout = assert(io.open(layoutPath, "w"))
layout:write(table.concat(lines, "\n") .. "\n")
layout:close()

local context = fixture.createLoaded(
    { x = 0, y = 0, w = 480, h = 272 },
    { Layout = "chart-responsiveness", Theme = "modern-dark" },
    root .. "/build/test-widget-fixture/"
)
assert(#context.panels == 2, "responsiveness fixture must contain two charts")

local charts = {}
for index, entry in ipairs(context.panels) do
    charts[index] = {
        instance = entry.instance,
        wasActive = false,
        frameStart = nil,
        frames = {},
    }
end

local callbackCount, worstInstructions = 0, 0
local traceAges, frameAges = {}, {}
local seenPlotAt, lastDrawnRevision = {}, {}
local function measureRefresh()
    fixture.lvglMock.setPropertyValidation(false)
    fixture.lvglMock.setCallCounting(false)
    fixture.lcdMock.setTextMeasurement(false)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    local ok, message = pcall(definition.refresh, context)
    debug.sethook()
    fixture.lcdMock.setTextMeasurement(true)
    fixture.lvglMock.setCallCounting(true)
    fixture.lvglMock.setPropertyValidation(true)
    assert(ok, message)
    callbackCount = callbackCount + 1
    worstInstructions = math.max(worstInstructions, instructions)
    assert(
        instructions < 15000,
        string.format("responsiveness callback %d used %d instructions", callbackCount, instructions)
    )
end

local function percentile(values, fraction)
    if #values == 0 then
        return 0
    end
    table.sort(values)
    return values[math.max(1, math.ceil(#values * fraction))]
end

local function observe(callback)
    for chartIndex, chart in ipairs(charts) do
        local instance = chart.instance
        local active = instance.framePhase ~= nil or instance.pending ~= nil
        if active and not chart.wasActive then
            chart.frameStart = callback
        elseif not active and chart.wasActive then
            local elapsed = (callback - chart.frameStart) * 50
            chart.frames[#chart.frames + 1] = elapsed
            frameAges[#frameAges + 1] = elapsed
        end
        chart.wasActive = active

        for seriesIndex, item in ipairs(instance.series) do
            local key = chartIndex .. ":" .. seriesIndex
            local plotRevision = item.feed.plotRevision
            if plotRevision ~= nil then
                local seen = seenPlotAt[key] or {}
                seenPlotAt[key] = seen
                seen[plotRevision] = seen[plotRevision] or callback
            end
            if not active and item.drawnRevision ~= lastDrawnRevision[key] then
                local sampledAt = seenPlotAt[key] and seenPlotAt[key][item.drawnRevision]
                if sampledAt then
                    traceAges[#traceAges + 1] = (callback - sampledAt) * 50
                end
                lastDrawnRevision[key] = item.drawnRevision
            end
        end
    end
end

local callbacks = 1200
for callback = 1, callbacks do
    for sourceIndex, source in ipairs(sources) do
        fixture.radio.values[5000 + sourceIndex] = ((callback * 17 + sourceIndex * 331) % 2049) - 1024
    end
    fixture.tick(5)
    measureRefresh()
    fixture.lvglMock.settle()
    observe(callback)
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
end

local dimensions = {}
for index, chart in ipairs(charts) do
    local instance = chart.instance
    assert(#chart.frames > 0, "each chart must complete a frame during the measurement")
    assert(#instance.series == 2, "each chart must measure two series")
    for _, item in ipairs(instance.series) do
        assert(item.feed.available and item.feed.plotRevision > 0, "each stick source must record live samples")
        assert(item.drawnRevision and item.drawnRevision > 0, "each stick source must reach the visible plot")
    end
    dimensions[#dimensions + 1] = string.format(
        "%s=%dx%d plot=%dpx frames=%d",
        instance.placementId or ("chart" .. index),
        instance.rect.w,
        instance.rect.h,
        instance.area.w,
        #chart.frames
    )
end
assert(#traceAges > 10, "the baseline must capture repeated sample-to-trace measurements")
print(
    string.format(
        "  chart responsiveness baseline: %d callbacks (%.1fs), %s; "
            .. "trace age p50/p95/max=%d/%d/%d ms; frame time p50/p95/max=%d/%d/%d ms; "
            .. "worst callback=%d instructions",
        callbackCount,
        callbackCount / 20,
        table.concat(dimensions, ", "),
        percentile(traceAges, 0.50),
        percentile(traceAges, 0.95),
        percentile(traceAges, 1),
        percentile(frameAges, 0.50),
        percentile(frameAges, 0.95),
        percentile(frameAges, 1),
        worstInstructions
    )
)
