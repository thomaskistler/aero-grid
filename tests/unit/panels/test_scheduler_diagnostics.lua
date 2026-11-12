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
local function sample(utilization, deferred, consumers)
    stats.revision = stats.revision + 1
    stats.utilization, stats.deferrals = utilization, deferred
    stats.consumers, stats.capacity, stats.seconds = consumers, 160, 1
    diagnostics.refresh(panel)
end
local bottom = graph.y + graph.height
sample(100, 0)
assert(graph.index == 1)
local other = graph.columns[1][6]
assert(other.properties.y == graph.y and other.properties.h == graph.height, "unattributed slots form the top layer")
assert(graph.lines[1].properties.pts[2][2] == bottom)
local saved = graph.lines[1].properties.pts
diagnostics.refresh(panel)
assert(graph.index == 1 and graph.lines[1].properties.pts == saved, "unchanged samples must not redraw")
sample(0, 100)
local points = graph.lines[2].properties.pts
assert(points[1][1] == graph.x and points[2][1] == graph.x + 1)
assert(points[1][2] == bottom and points[2][2] == graph.y)
assert(next(graph.columns[2]) == nil, "idle seconds draw no stack")

-- Consumers stack from the bottom in a stable color each.
local chart = { placement = { id = "c1", type = "chart" } }
local telemetry = { id = "telemetry" }
sample(70, 0, { [chart] = 80, [telemetry] = 16, flight = 8 })
local column = graph.columns[3]
local function boundary(percent)
    return graph.y + math.floor((100 - percent) * graph.height / 100 + 0.5)
end
assert(graph.owners[1] == chart and graph.owners[2] == telemetry and graph.owners[3] == "flight")
assert(column[1].properties.y == boundary(50) and column[1].properties.h == bottom - boundary(50))
assert(column[2].properties.y == boundary(60) and column[3].properties.y == boundary(65))
assert(column[6].properties.y == boundary(70) and column[6].properties.h == boundary(65) - boundary(70))
assert(column[1].properties.color == graph.colors[1] and column[6].properties.color == graph.colors[6])
assert(
    graph.legend >= 3 and panel.rows[2].properties.text == "80.0 c1 chart",
    "the legend shows measured slots per second"
)
assert(panel.rows[3].properties.text == "16.0 telemetry service")
for _ = 1, 10 do
    sample(70, 0, { [chart] = 8, [telemetry] = 104 })
end
assert(graph.owners[1] == chart and graph.owners[2] == telemetry, "ranking changes must not recolor consumers")
assert(panel.rows[2].properties.text == "8.0 c1 chart" and panel.rows[3].properties.text == "104.0 telemetry service")
stats.revision = stats.revision + 1
stats.utilization, stats.deferrals = 70, 0
stats.consumers, stats.capacity, stats.seconds = { [chart] = 16, [telemetry] = 30 }, 320, 2
diagnostics.refresh(panel)
assert(panel.rows[2].properties.text == "8.0 c1 chart", "rates divide by the measured interval")
local crowd = {}
for index = 1, 6 do
    crowd[{ id = "s" .. index }] = 20
end
for _ = 1, 30 do
    sample(75, 0, crowd)
end
local named = 0
for slot = 1, 5 do
    assert(crowd[graph.owners[slot]], "faded consumers give way to busier ones")
    named = named + 1
end
assert(named == 5)
column = graph.columns[graph.index]
assert(column[5].properties.y == boundary(62.5) and column[6].properties.y == boundary(75))

for _ = graph.index + 1, graph.width do
    sample(50, 25)
end
assert(graph.index == 0)
local first = graph.lines[1]
sample(25, 50)
assert(graph.lines[1] == first, "wrap must reuse native objects")
points = first.properties.pts
assert(points[1][1] == graph.x and points[2][1] == graph.x, "wrap must never connect right edge to left")
assert(graph.lines[2].hidden, "cursor must separate new samples from old data")
sample(25, 50)
for _, segment in ipairs(graph.columns[3]) do
    assert(segment.hidden, "cursor must clear the next stacked column")
end
for _ = 1, graph.width do
    sample(75, 0, crowd)
end
local count = #fixture.lvglMock.objects
for _ = 1, graph.width * 2 do
    sample(75, 0, crowd)
end
assert(#fixture.lvglMock.objects == count, "graph storage must stay bounded across wraps")
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
