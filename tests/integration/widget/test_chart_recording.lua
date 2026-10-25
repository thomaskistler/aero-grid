-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
fixture.reset()
local lines = { "version: 3", "grid:", "  columns: 4", "  rows: 4", "session:", "  armSource: sa", "panels:" }
for index = 1, 8 do
    lines[#lines + 1] = string.format(
        "  - id: chart%d\n    type: chart\n    col: %d\n    row: %d\n    colSpan: 2\n    rowSpan: 1\n"
            .. "    config:\n      scaling: independent\n      timeRange: %s\n      smoothing: medium\n      metrics:",
        index,
        (index - 1) % 2 * 2,
        math.floor((index - 1) / 2),
        index % 2 == 0 and "rolling" or "growing"
    )
    for source = 1, 3 do
        local id = (index - 1) * 3 + source
        local name = "Q" .. id
        fixture.radio.fields[name] = { id = 5000 + id, name = name, unit = 1 }
        fixture.radio.values[5000 + id] = id
        lines[#lines + 1] = "        - source: " .. name .. "\n          precision: 1"
    end
end
fixture.radioMock.indexFields()
local file = assert(hostIo.open(root .. "/build/test-widget-fixture/layouts/chart-stress.yaml", "w"))
file:write(table.concat(lines, "\n") .. "\n")
file:close()

local worst, callbacks, context = 0, 0, nil
local function measure(fn, ...)
    fixture.lvglMock.setPropertyValidation(false)
    fixture.lvglMock.setCallCounting(false)
    fixture.lcdMock.setTextMeasurement(false)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    local ok, message = pcall(fn, ...)
    debug.sethook()
    fixture.lcdMock.setTextMeasurement(true)
    fixture.lvglMock.setCallCounting(true)
    fixture.lvglMock.setPropertyValidation(true)
    assert(ok, message)
    worst, callbacks = math.max(worst, instructions), callbacks + 1
    assert(
        instructions < 15000,
        string.format("chart callback %d (%s) used %d instructions", callbacks, tostring(context.stage), instructions)
    )
end

context = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "chart-stress",
    Theme = "modern-dark",
}, root .. "/build/test-widget-fixture/")
local function pump(count, background)
    for _ = 1, count do
        fixture.tick(10)
        measure(background and definition.background or definition.refresh, context)
        fixture.lvglMock.settle()
    end
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
end
pump(200)
assert(#context.panels == 8)
for step = 1, 1000 do
    for id = 1, 24 do
        fixture.radio.values[5000 + id] = id + step % 17
    end
    pump(1, step < 500)
end
local history = context.serviceRuntime.byId.history
assert(history.count == 24)
for _, entry in ipairs(context.panels) do
    for _, series in ipairs(entry.instance.series) do
        assert(series.feed.available and series.feed.count <= 32)
        assert(series.runs[1] and series.runs[1].line)
    end
end
local elapsed = context.panels[1].instance.session.elapsed
fixture.radio.values[300] = 0
pump(30)
local paused = context.panels[1].instance.session.elapsed
assert(paused >= elapsed)
pump(100, true)
assert(context.panels[1].instance.session.elapsed == paused)

for cycle = 1, 20 do
    for _ = 1, 60 do
        fixture.radio.values[300] = 1024
        pump(6)
        fixture.radio.values[300] = 0
        pump(6)
    end
    pump(150)
    fixture.lcdMock.clearTextMeasurements()
    collectgarbage("collect")
    assert(fixture.lvglMock.replacedFontRefCount() == 0)
end
local objects = #fixture.lvglMock.objects
local memory = collectgarbage("count")
for cycle = 1, 5 do
    for _ = 1, 60 do
        fixture.radio.values[300] = 1024
        pump(6)
        fixture.radio.values[300] = 0
        pump(6)
    end
    pump(150)
    fixture.lcdMock.clearTextMeasurements()
    collectgarbage("collect")
    assert(#fixture.lvglMock.objects == objects, "chart line pools must be bounded")
    assert(collectgarbage("count") - memory < 8, "chart retained memory grew after warmup")
end
pump(1000)
for _, entry in ipairs(context.panels) do
    for _, item in ipairs(entry.instance.series) do
        assert(item.drawnRevision == item.feed.revision and not entry.instance.pending, "a chart was starved")
    end
    entry.nextRefresh = math.huge
end
local first = context.panels[1]
local refresh = first.module.refresh
first.module.refresh = function()
    return 37
end
first.nextRefresh = 0
measure(definition.refresh, context)
assert(
    first.interval == 37 and first.nextRefresh == getTime() + 37,
    "dynamic intervals must schedule from this refresh"
)
first.module.refresh = refresh
print(string.format("  chart recording: %d callbacks, 24 sources, worst %d instructions", callbacks, worst))
