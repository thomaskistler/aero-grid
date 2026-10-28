-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local chart = fixture.module("panels/chart.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
fixture.reset()
local host = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
local placement = { col = 0, row = 0, colSpan = 2, rowSpan = 1 }
local services = host.dashboardLoader.buildServices(host, placement)
local session = {
    configured = true,
    available = true,
    recording = true,
    elapsed = 800,
    flightFirst = 1,
    flightLast = 2,
    flightRevision = 1,
    flightActive = true,
}
local intervals = { { 100, 350, true, true }, { 500, nil, true, false } }
local fake = { FLIGHT_CAPACITY = 64 }
function fake:session()
    return session
end
function fake:subscribe()
    return { available = false, revision = 0, plotRevision = 0, count = 0 }
end
function fake:flight(_, index)
    if index < session.flightFirst or index > session.flightLast then
        return nil
    end
    local interval = intervals[index]
    return interval[1], interval[2], interval[3], interval[4]
end
services.history = fake
local settings = { armSwitch = "L01", metrics = { { source = "V" }, { source = "A" }, { source = "Alt" } } }
local panel = chart.create(host.page, { x = 0, y = 0, w = 238, h = 65 }, settings, services)
local function settle()
    for _ = 1, 150 do
        chart.refresh(panel)
    end
end
settle()
equal(#panel.flightLines, 2, "three metrics share one set of flight intervals")
local points = panel.flightLines[1].properties.pts
local area = panel.area
equal(points[1][1], area.x + math.floor(100 / panel.window * area.w + 0.5))
equal(points[3][1], area.x + math.floor(350 / panel.window * area.w + 0.5))
equal(points[1][2], area.y + 7, "confirmed start has a short boundary tick")
equal(points[2][2], area.y + 2, "flight band stays in the plot's thin upper lane")
equal(points[4][2], area.y + 7, "confirmed end has a short boundary tick")
local active = panel.flightLines[2].properties.pts
equal(active[4][2], active[3][2], "an unconfirmed end must not have a boundary tick")
equal(panel.flightLines[1].properties.color, panel.theme.chartColor.green)

session.elapsed, session.flightActive = 5000, false
session.flightRevision = 2
intervals[2] = { 500, 4000, true, true }
settings.timeRange, settings.duration = "rolling", "30s"
settle()
assert(panel.flightLines[1].hidden, "expired flights leave the rolling window")
local clipped = panel.flightLines[2].properties.pts
equal(clipped[1][1], panel.area.x)
equal(clipped[1][2], clipped[2][2], "clipping must not invent a start boundary")
equal(clipped[4][2], panel.area.y + 7)
chart.update(panel, { x = 0, y = 0, w = 472, h = 196 })
settle()
clipped = panel.flightLines[2].properties.pts
equal(clipped[3][1], panel.area.x + math.floor(2000 / 3000 * panel.area.w + 0.5))
equal(clipped[4][2], panel.area.y + 7, "resize reprojects every flight object")

session.flightLast, session.flightRevision = 0, 3
settle()
assert(panel.flightLines[1].hidden and panel.flightLines[2].hidden, "epoch reset hides all old pooled objects")
session.flightFirst, session.flightLast, session.flightRevision = 65, 66, 4
intervals[65], intervals[66] = { 2500, 3000, false, true }, { 3500, 4500, true, true }
settle()
equal(#panel.flightLines, 2, "wrapped flight identities reuse the bounded native pool")
assert(not panel.flightLines[1].hidden and not panel.flightLines[2].hidden)
equal(panel.flightLines[1].properties.pts[1][2], panel.area.y + 2, "late attachment has no false start tick")

session.flightFirst, session.flightLast, session.flightRevision = 128, 128, 5
intervals[128] = { 2500, 3500, true, true }
settle()
assert(not panel.flightLines[64].hidden)
session.flightLast, session.flightRevision = 0, 6
chart.refresh(panel)
session.flightRevision = 7
settle()
assert(
    panel.flightLines[64].hidden and panel.flightLines[1].hidden,
    "epoch changes clear sparse pools and partial passes"
)

services.preview = true
local readOnly = {
    session = function()
        return { configured = true, available = false, recording = false, elapsed = 0 }
    end,
    subscribe = function()
        return { previewMissing = true, available = false, revision = 0, plotRevision = 0, first = 1, last = 0 }
    end,
    point = function() end,
}
services.history = setmetatable({
    preview = function()
        return readOnly
    end,
}, {
    __index = function()
        error("previews must not subscribe to or consume live history")
    end,
})
local preview = chart.create(host.page, { x = 0, y = 0, w = 238, h = 65 }, settings, services)
for _ = 1, 10 do
    chart.refresh(preview)
end
equal(preview.status.properties.text, "PREVIEW: NO DATA")
equal(preview.history, readOnly)
equal(preview.session.elapsed, 0)
services.history = nil
local unavailablePreview = chart.create(host.page, { x = 0, y = 0, w = 238, h = 65 }, settings, services)
chart.refresh(unavailablePreview)
equal(unavailablePreview.status.properties.text, "HISTORY N/A", "a preview must not mask a missing history service")
