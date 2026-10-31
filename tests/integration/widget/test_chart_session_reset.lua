-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local yaml = fixture.module("lib/yaml.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local path = root .. "/build/test-widget-fixture/"
fixture.reset()

local layout = {
    version = 5,
    grid = { columns = 4, rows = 4 },
    panels = {},
}
for index = 1, 2 do
    layout.panels[index] = {
        id = "chart" .. index,
        type = "chart",
        col = 0,
        row = (index - 1) * 2,
        colSpan = 4,
        rowSpan = 2,
        config = {
            armSwitch = "L64",
            timeRange = index == 1 and "growing" or "rolling",
            metrics = { { source = "Alt" } },
        },
    }
end
local file = assert(hostIo.open(path .. "layouts/chart-session-reset.yaml", "w"))
file:write(assert(yaml.serialize(layout)))
file:close()
local first = definition.create({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "chart-session-reset" }, path)
local second = definition.create({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "chart-session-reset" }, path)
local function pump(count)
    for _ = 1, count or 1 do
        fixture.tick(20)
        definition.refresh(first)
        definition.background(second)
        fixture.lvglMock.settle()
    end
    equal(#first.errors, 0, table.concat(first.errors, "; "))
    equal(#second.errors, 0, table.concat(second.errors, "; "))
end
local function untilState(predicate)
    for _ = 1, 800 do
        if predicate() then
            return
        end
        pump()
    end
    error("charts-only reset did not settle")
end
local function settled()
    return not first.stage
        and not second.stage
        and not first.reloadState
        and not second.reloadState
        and not first.sessionResetPending
        and not second.sessionResetPending
end
untilState(settled)
local owner = assert(first.flightBroker)
assert(owner == second.flightBroker)
owner:setDocument({
    revision = 1,
    modelFilename = owner.filename,
    sessionReset = "L03",
})
pump(20)
assert(not owner.session, "legacy chart arming must not require a flight detector")
fixture.radio.logicalSwitches[64] = true
fixture.radio.values[fixture.radio.fields.Alt.id] = 10
pump(300)
fixture.radio.logicalSwitches[64] = false
pump(100)
local before, elapsed, pages, charts, objects = {}, {}, {}, {}, {}
for index, context in ipairs({ first, second }) do
    before[index] = context.serviceRuntime
    pages[index] = {
        root = context.root,
        page = context.page,
        canvas = context.canvas,
        canvasWrites = context.canvas.writes,
    }
    charts[index] = {}
    elapsed[index] = context.serviceRuntime.byId.history:session("L64").elapsed
    assert(elapsed[index] > 0)
    for position, entry in ipairs(context.panels) do
        assert(entry.instance.series[1].feed.available)
        local chart = entry.instance
        charts[index][position] = {
            instance = chart,
            caption = chart.series[1].name.properties.text,
            plot = chart.plotRoot,
            backPlot = chart.backPlot,
        }
    end
end
for _, object in ipairs(fixture.lvglMock.objects) do
    objects[object] = { cleared = object.cleared, invalid = object.invalid }
end
local epoch = owner.epoch
fixture.radio.values[fixture.radio.fields.Alt.id] = 50
fixture.radio.logicalSwitches[3] = true
untilState(function()
    return owner.epoch == epoch + 1 and settled()
end)
pump(100)
for index, context in ipairs({ first, second }) do
    equal(context.serviceRuntime, before[index], "reset must retain service subscriptions")
    equal(context.root, pages[index].root)
    equal(context.page, pages[index].page, "reset must not clear or rebuild the dashboard")
    equal(context.canvas, pages[index].canvas)
    equal(context.canvas.writes, pages[index].canvasWrites, "reset must not repaint the screen background")
    for position, entry in ipairs(context.panels) do
        local chart = entry.instance
        local beforeChart = charts[index][position]
        equal(chart, beforeChart.instance, "reset must retain chart objects")
        equal(chart.backPlot, beforeChart.backPlot, "reset must reuse plot buffers")
        assert(chart.plotRoot == beforeChart.plot or chart.backPlot.plotRoot == beforeChart.plot)
        equal(chart.series[1].name.properties.text, beforeChart.caption, "reset must retain chart captions")
        equal(chart.session.elapsed, 0, "a paused chart must reset its timeline")
        equal(chart.series[1].feed.count, 0, "a paused chart must discard all old samples")
        assert(not chart.series[1].feed.available)
        equal(chart.series[1].feed.min, nil)
        equal(chart.series[1].feed.max, nil)
    end
end
for object, state in pairs(objects) do
    equal(object.cleared, state.cleared, "reset must not clear LVGL objects")
    equal(object.invalid, state.invalid, "reset must not delete LVGL objects")
end
definition.refresh(second)
fixture.radio.logicalSwitches[64] = true
pump(100)
for _, context in ipairs({ first, second }) do
    for _, entry in ipairs(context.panels) do
        local chart = entry.instance
        assert(chart.session.elapsed < elapsed[1])
        equal(chart.series[1].feed.min, 50, "new recordings must not retain pre-reset extrema")
        equal(chart.series[1].feed.max, 50)
        for index = chart.series[1].feed.first, chart.series[1].feed.last do
            local _, value = chart.history:point(chart.series[1].feed, index)
            equal(value, 50, "new traces must contain only post-reset samples")
        end
    end
end

untilState(function()
    local chart = first.panels[1].instance
    return chart.framePhase == "traces" and chart.pending ~= nil
end)
local activeCharts, activeObjects = {}, {}
local objectCount = #fixture.lvglMock.objects
for _, context in ipairs({ first, second }) do
    for _, entry in ipairs(context.panels) do
        activeCharts[entry.instance] = entry.instance.backPlot
    end
    for _, object in ipairs(fixture.lvglMock.objects) do
        activeObjects[object] = { cleared = object.cleared, invalid = object.invalid }
    end
    fixture.radio.values[fixture.radio.fields.Alt.id] = 75
    owner:resetSession(getTime())
    untilState(settled)
    equal(#fixture.lvglMock.objects, objectCount, "reset must not allocate replacement display objects")
    for chart, buffer in pairs(activeCharts) do
        equal(chart.backPlot, buffer, "a mid-frame reset must retain both display buffers")
        equal(chart.framePhase, nil, "a mid-frame reset must cancel the old snapshot")
        equal(chart.pending, nil, "a mid-frame reset must discard the old projection job")
        equal(chart.series[1].feed.count, 0)
    end
    for object, state in pairs(activeObjects) do
        equal(object.cleared, state.cleared, "a mid-frame reset must not clear display objects")
        equal(object.invalid, state.invalid, "a mid-frame reset must not delete display objects")
    end
    pump(100)
    for chart in pairs(activeCharts) do
        equal(chart.series[1].feed.min, 75)
        equal(chart.series[1].feed.max, 75)
        for point = chart.series[1].feed.first, chart.series[1].feed.last do
            local _, value = chart.history:point(chart.series[1].feed, point)
            equal(value, 75, "an interrupted frame must not restore pre-reset samples")
        end
    end
end
