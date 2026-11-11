-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
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
        metrics = { { source = record.feeds[1].name, precision = 3 } },
    }, services)
end
local first, second = panel(), panel()
local function settle(current, grant)
    for _ = 1, 2000 do
        local _, pending, used = chart.refresh(current, false, grant or 8)
        assert(used >= 1 and used <= (grant or 8), "chart exceeded scheduler grant")
        if not pending and view.finished(current) then
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
    error("metadata slot attempted plot work")
end
local _, metadataPending, metadataSlots = chart.refresh(first, false, 1)
assert(metadataPending and metadataSlots == 1 and first.metadataReady)
assert(first.series[1].valueText == "45.000", "one-slot metadata pass did not update its readout")
first.columnRenderer.append = draw
settle(first)
chart.refresh(first, false, 1)
local render = chart.render
chart.render = function()
    error("append slot attempted metadata work")
end
local appendCalls = 0
first.columnRenderer.append = function(self)
    appendCalls = appendCalls + 1
    draw(self)
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
assert(next(late.columnConsumers[1].map.tags) == nil, "late chart must not replay retained history")

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
assert(next(owner.map.tags) == nil, "resize must not reconstruct old telemetry")
local nativeRoot = first.columnRenderer.root
for at = 1200, 6500, 100 do
    record.sample(at, { at % 83 })
    settle(first)
end
local frozen = {}
for slot = 1, owner.map.width do
    frozen[slot] = { owner.map.low[slot], owner.map.high[slot], owner.map.ends[slot] }
end
for at = 6600, 20000, 100 do
    record.sample(at, { -at })
    settle(first)
end
assert(first.columnRenderer.root == nativeRoot and first.start == 0 and first.window == 6000)
for slot, saved in ipairs(frozen) do
    assert(owner.map.low[slot] == saved[1] and owner.map.high[slot] == saved[2] and owner.map.ends[slot] == saved[3])
end
assert(first.series[1].feed.value == -20000, "right-edge stop froze readouts")
assert(first.columnRenderer.spare == nil and owner.map.levels == nil)

local triple = recorder(3)
services.history = triple.history
local three = chart.create(dashboard.page, { x = 0, y = 0, w = 472, h = 196 }, {
    armSwitch = "L01",
    metrics = {
        { source = triple.feeds[1].name },
        { source = triple.feeds[2].name },
        { source = triple.feeds[3].name },
    },
}, services)
settle(three, 1)
chart.refresh(three, false, 1)
triple.sample(0, { -2000, 0, 2000 })
triple.sample(1, { -500, 500, -500 })
local _, triplePending, tripleSlots = chart.refresh(three, false, 1)
assert(not triplePending and tripleSlots == 1, "all three series must finish appending in one slot")
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
for slot = 1, owner.map.width do
    assert(owner.map.tags[slot] == nil or math.abs(owner.map.tags[slot]) <= owner.map.width)
end
chart.destroy(preview)
chart.destroy(late)
chart.destroy(first)
chart.destroy(first)
chart.destroy(second)
assert(record.history.views[record.feeds[1]].observers == nil)
print("Append-only charts keep fixed axes, finish each append in one slot and never reconstruct history")
