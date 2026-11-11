-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local diagnostics = fixture.module("panels/host-diagnostics.lua")
local dashboard = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
local services = dashboard.dashboardLoader.buildServices(dashboard, { col = 0, row = 0, colSpan = 2, rowSpan = 2 })
local panel = diagnostics.create(dashboard.page, { x = 0, y = 0, w = 238, h = 132 }, {
    section = "scheduler",
    accent = "cyan",
}, services)
assert(panel.refreshCost == 0 and dashboard.schedulerStats)
local stats, graph = dashboard.schedulerStats, panel.graph
assert(graph.cursor.properties.w == 1, "native vertical line width is its stroke thickness")
for _, object in ipairs(fixture.lvglMock.objects) do
    if object.kind == "hline" then
        assert(object.properties.h == 1, "native horizontal line height is its stroke thickness")
    end
end
local function sample(utilization, deferred)
    stats.revision = stats.revision + 1
    stats.utilization, stats.deferrals = utilization, deferred
    diagnostics.refresh(panel)
end
sample(100, 0)
assert(graph.index == 1)
assert(graph.lines[1][1].properties.pts[2][2] == graph.y)
assert(graph.lines[2][1].properties.pts[2][2] == graph.y + graph.height)
local saved = graph.lines[1][1].properties.pts
diagnostics.refresh(panel)
assert(graph.index == 1 and graph.lines[1][1].properties.pts == saved, "unchanged samples must not redraw")
sample(0, 100)
local points = graph.lines[1][2].properties.pts
assert(points[1][1] == graph.x and points[2][1] == graph.x + 1)
assert(points[1][2] == graph.y and points[2][2] == graph.y + graph.height)
for _ = 3, graph.width do
    sample(50, 25)
end
assert(graph.index == 0)
local first = graph.lines[1][1]
sample(25, 50)
assert(graph.lines[1][1] == first, "wrap must reuse native objects")
points = first.properties.pts
assert(points[1][1] == graph.x and points[2][1] == graph.x, "wrap must never connect right edge to left")
assert(graph.lines[1][2].hidden, "cursor must separate new samples from old data")
local count = #fixture.lvglMock.objects
for _ = 1, graph.width * 2 do
    sample(50, 0)
end
assert(#fixture.lvglMock.objects == count, "sparkline storage must stay bounded across wraps")
diagnostics.update(panel, { x = 0, y = 0, w = 320, h = 180 })
assert(panel.graph.index == 0 and panel.graph.previous == nil, "resize starts a new sweep")
assert(panel.graph.lines[1][1] == first and first.hidden, "resize hides and reuses existing lines")
sample(25, 50)
assert(panel.graph.lines[1][1] == first and not first.hidden, "resized sweep reuses native objects")
diagnostics.destroy(panel)
assert(dashboard.schedulerStats == nil)
services.preview = true
local preview = diagnostics.create(dashboard.page, { x = 0, y = 0, w = 238, h = 132 }, {
    section = "scheduler",
    accent = "cyan",
}, services)
diagnostics.refresh(preview)
assert(dashboard.schedulerStats == nil, "previews must not enable measurement")
preview.preview = false
diagnostics.refresh(preview)
assert(dashboard.schedulerStats, "saving a preview must enable live measurement")
diagnostics.destroy(preview)
assert(dashboard.schedulerStats == nil)
