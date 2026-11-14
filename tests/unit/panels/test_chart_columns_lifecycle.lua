-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
assert(loadfile(root .. "/tests/support/chart_turns.lua"))().install(chart)
local recorder = assert(loadfile(root .. "/tests/support/chart_recorder.lua"))(root)
local view = assert(loadfile(root .. "/tests/support/chart_assertions.lua"))()
fixture.reset()
local dashboard = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
local services = dashboard.dashboardLoader.buildServices(dashboard, { col = 0, row = 0, colSpan = 2, rowSpan = 1 })
local record = recorder(1)
services.history = record.history
local function panel()
    return chart.create(dashboard.page, { x = 0, y = 0, w = 238, h = 100 }, {
        armSwitch = "L01",
        duration = 1,
        metrics = { { source = record.feeds[1].name, precision = 3, rangeMin = -1000, rangeMax = 1000 } },
    }, services)
end
local first, second = panel(), panel()
local function queued(current)
    for _, consumer in ipairs(current.columnConsumers or {}) do
        if #consumer.pending > 0 or consumer.tail then
            return true
        end
    end
    return false
end
-- One callback of the chart's two tasks: the refresh is offered `grant` slots,
-- and the finishing task, when pending, gets at least its declared minimum.
local function settle(current, grant)
    for _ = 1, 2000 do
        local pending, used
        local offered = chart.offered(current, grant)
        if chart.finishPending(current) then
            _, pending, used = chart.finish(current, false, offered)
        else
            _, pending, used = chart.refresh(current, false, offered)
        end
        assert(used >= 1 and used <= offered, "chart exceeded scheduler grant")
        if not pending and not queued(current) and view.finished(current) then
            return
        end
    end
    error("fixed chart failed to settle")
end
settle(first, 1)
settle(second, 2)
local owner, sibling = first.columnConsumers[1], second.columnConsumers[1]
local originalWidth = owner.map.width
for at = 0, 1000, 20 do
    record.sample(at, { at % 97 })
    settle(first)
    settle(second)
end
assert(first.series[1].low == -1000 and first.series[1].high == 1000)
assert(first.window == 6000 and first.start == 0 and owner.map.width == originalWidth)
assert(first.columnRenderer.root ~= second.columnRenderer.root)
record.sample(1020, { 45 })
first.metadataReady = nil
local draw = first.columnRenderer.append
first.columnRenderer.append = function()
    error("readout pass attempted plot work")
end
assert(chart.finishPending(first) and first.finishMinCost == 2, "readouts must declare a two-slot minimum")
local _, metadataPending, metadataSlots = chart.finish(first, false, 2)
assert(not metadataPending and metadataSlots == 2 and first.metadataReady)
assert(first.series[1].valueText == "45.000", "the readout pass did not update its readout")
first.columnRenderer.append = draw
settle(first)
local render = chart.render
chart.render = function()
    error("append slot attempted metadata work")
end
local appendCalls = 0
first.columnRenderer.append = function(self, ...)
    appendCalls = appendCalls + 1
    return draw(self, ...)
end
record.sample(1040, { 46 })
local _, appendPending, appendSlots = chart.refresh(first, false, 1)
assert(appendSlots == 1 and not appendPending, "the entire append must finish in one slot")
assert(appendCalls == 1)
assert(first.columnRenderer.published[1].revision == owner.map.revision)
assert(first.series[1].drawnRevision == first.series[1].feed.plotRevision)
assert(#owner.map.dirtyList == 0 and #owner.pending == 0)
chart.render, first.columnRenderer.append = render, draw
settle(first)
local late = panel()
settle(late)
assert(next(late.columnConsumers[1].map.kinds) == nil, "late chart must not replay retained history")

local ranges = { first.series[1].low, first.series[1].high }
record.sample(1100, { 100000 })
settle(first)
assert(first.series[1].low == ranges[1] and first.series[1].high == ranges[2], "live extrema changed fixed bounds")
assert(first.series[1].feed.max == 100000, "clipping changed recorded extrema")

local before, other = owner.map, sibling.map
chart.update(first, { x = 0, y = 0, w = 320, h = 134 })
assert(owner.map ~= before and sibling.map == other)
settle(first, 2)
assert(first.start == 0 and first.window == 6000)
assert(next(owner.map.kinds) == nil, "resize must not reconstruct old telemetry")
for at = 1200, 5900, 100 do
    record.sample(at, { at % 83 })
    settle(first)
end
assert(first.start == 0, "a fixed window must not slide before it is full")
for at = 6000, 20000, 100 do
    record.sample(at, { -at })
    settle(first)
end
assert(first.start == 18000 and first.window == 6000, "fixed windows slide by a minute")
local slid = owner.map
for at = 18000, 20000, 100 do
    local slot = slid:bucketOf(at, slid:gapCount(at)) + 1
    assert(slid.low[slot] == -at and slid.high[slot] == -at and slid.ends[slot] == -at, "slid columns lost samples")
end
assert(first.series[1].feed.value == -20000, "sliding froze readouts")
assert(first.columnRenderer.spare == nil and owner.map.levels == nil)

-- A chart attached or resized after the window filled starts where sliding
-- would have put it and draws new samples at once.
local function drawsNewest(current, at, message)
    local map = current.columnConsumers[1].map
    assert(#current.columnConsumers[1].pending == 0, message .. ": samples stayed queued")
    assert(current.start <= at and at < current.start + current.window, message .. ": window misses the newest sample")
    local slot = map:bucketOf(at, map:gapCount(at)) + 1
    assert(map.kinds[slot] == "data" and map.ends[slot] == -at, message .. ": newest sample missing")
    assert(#view.rectangles(current, 1) > 0, message .. ": nothing drawn")
end
local attached = panel()
settle(attached)
assert(attached.start == 18000, "a late fixed window starts where sliding would have put it")
for at = 20100, 21000, 100 do
    record.sample(at, { -at })
    settle(first)
    settle(attached, 1)
end
drawsNewest(attached, 21000, "late attachment")
assert(attached.start == first.start, "late and continuous charts show the same window")
chart.update(attached, { x = 0, y = 0, w = 320, h = 134 })
settle(attached, 1)
for at = 21100, 22000, 100 do
    record.sample(at, { -at })
    settle(first)
    settle(attached, 1)
end
drawsNewest(attached, 22000, "resize after overflow")
for at = 22100, 26000, 100 do
    record.sample(at, { -at })
    settle(first)
    settle(attached, 1)
end
assert(attached.start > 18000, "a late fixed window keeps sliding")
drawsNewest(attached, 26000, "late window after sliding")
chart.destroy(attached)

local triple = recorder(3)
services.history = triple.history
local three = chart.create(dashboard.page, { x = 0, y = 0, w = 472, h = 196 }, {
    armSwitch = "L01",
    duration = 1,
    metrics = {
        { source = triple.feeds[1].name },
        { source = triple.feeds[2].name },
        { source = triple.feeds[3].name },
    },
}, services)
settle(three, 1)
triple.sample(0, { -2000, 0, 2000 })
triple.sample(1, { -500, 500, -500 })
-- Two samples for each of three series cost about 3,200 instructions.
local _, triplePending, tripleSlots = chart.refresh(three, false, 3)
assert(not triplePending and tripleSlots <= 3, "all three series must finish appending in three slots")
for index, consumer in ipairs(three.columnConsumers) do
    assert(#consumer.pending == 0 and #consumer.map.dirtyList == 0)
    assert(three.series[index].drawnRevision == triple.feeds[index].plotRevision)
end
chart.destroy(three)
services.history = record.history
services.preview = true
local preview = panel()
settle(preview)
assert(preview.columnConsumers[1].readonly)
for slot in pairs(owner.map.kinds) do
    assert(slot >= 1 and slot <= owner.map.width)
end
chart.destroy(preview)
chart.destroy(late)
chart.destroy(first)
chart.destroy(first)
chart.destroy(second)
assert(record.history.views[record.feeds[1]].observers == nil)
print(
    "Fixed charts slide, start late or resized windows in place, finish each append in one slot and never reconstruct history"
)
