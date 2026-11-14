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
assert(panel.rows[1].properties.text == "Slots used" and panel.rows[2].properties.text == "Requests deferred")

-- A new second of statistics arrives with each revision.
local function sample(utilization, deferred)
    fixture.tick(100)
    stats.revision = stats.revision + 1
    stats.utilization, stats.deferrals = utilization, deferred
    stats.capacity, stats.seconds = 160, 1
    diagnostics.refresh(panel)
end
local bottom = graph.y + graph.height
sample(100, 0)
assert(graph.index == 1)
assert(graph.usage[1].properties.pts[2][2] == graph.y, "full use reaches the top")
assert(graph.lines[1].properties.pts[2][2] == bottom, "no deferrals stay at the bottom")
local saved = graph.usage[1].properties.pts
diagnostics.refresh(panel)
assert(graph.index == 1 and graph.usage[1].properties.pts == saved, "unchanged statistics must not redraw")

-- At most one point a second, however fast revisions arrive.
stats.revision = stats.revision + 1
diagnostics.refresh(panel)
assert(graph.index == 1, "a point is added at most once a second")
stats.revision = stats.revision - 1

sample(0, 100)
local points = graph.usage[2].properties.pts
assert(points[1][1] == graph.x and points[2][1] == graph.x + 1, "consecutive seconds connect")
assert(points[1][2] == graph.y and points[2][2] == bottom)
points = graph.lines[2].properties.pts
assert(points[1][2] == bottom and points[2][2] == graph.y)

-- A gap in the statistics starts a new segment instead of drawing across it.
stats.revision = stats.revision + 5
fixture.tick(100)
stats.utilization, stats.deferrals = 50, 50
diagnostics.refresh(panel)
points = graph.usage[3].properties.pts
assert(points[2][1] == graph.x + 2 and points[1][2] == points[2][2], "a gap must not be bridged")

-- Out-of-range percentages stay inside the graph.
sample(250, -5)
assert(graph.usage[4].properties.pts[2][2] == graph.y and graph.lines[4].properties.pts[2][2] == bottom)

-- The sweep wraps without creating objects or connecting the right edge to the left.
for _ = 1, graph.width do
    sample(75, 0)
end
local count = #fixture.lvglMock.objects
local first = graph.lines[1]
for _ = 1, graph.width * 2 do
    sample(75, 0)
end
assert(#fixture.lvglMock.objects == count, "graph storage must stay bounded across wraps")
assert(graph.lines[1] == first, "wrap must reuse native objects")
diagnostics.update(panel, { x = 0, y = 0, w = 320, h = 180 })
assert(panel.graph.index == 0 and panel.graph.previous == nil, "resize starts a new sweep")
assert(panel.graph.lines[1] == first and first.hidden, "resize hides and reuses existing lines")
sample(25, 50)
assert(panel.graph.lines[1] == first and not first.hidden, "resized sweep reuses native objects")

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
