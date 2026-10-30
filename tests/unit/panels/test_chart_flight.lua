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
equal(#panel.flightBands, 2, "three metrics share one set of flight intervals")
local band = panel.flightBands[1].properties
local area = panel.area
equal(band.x, area.x + math.floor(100 / panel.window * area.w + 0.5))
equal(band.x + band.w, area.x + math.floor(350 / panel.window * area.w + 0.5))
equal(band.y, area.y)
equal(band.h, area.h, "flight shading must span the full plot height")
equal(band.filled, true)
equal(band.thickness, 0, "flight shading has no outline or boundary ticks")
equal(band.opacity, 32, "flight shading must leave telemetry readable")
equal(band.color, panel.theme.chartColor.green)
equal(panel.flightBands[1].parent, panel.flightRoot)
equal(panel.plotRoot.children[1], panel.flightRoot, "bands must sit behind grid and telemetry objects")
equal(panel.plotRoot.children[2], panel.gridRoot)
local active = panel.flightBands[2].properties
equal(active.x + active.w, area.x + math.floor(session.elapsed / panel.window * area.w + 0.5))
local previousWidth = active.w
session.elapsed = 1100
settle()
assert(active.w > previousWidth, "active flight shading must grow as recording continues")

session.elapsed, session.flightActive = 5000, false
session.flightRevision = 2
intervals[2] = { 500, 4000, true, true }
settings.timeRange, settings.duration = "rolling", "30s"
settle()
assert(panel.flightBands[1].hidden, "expired flights leave the rolling window")
local clipped = panel.flightBands[2].properties
equal(clipped.x, panel.area.x)
equal(clipped.x + clipped.w, panel.area.x + math.floor(2000 / 3000 * panel.area.w + 0.5))
equal(clipped.y, panel.area.y)
equal(clipped.h, panel.area.h)
chart.update(panel, { x = 0, y = 0, w = 472, h = 196 })
settle()
clipped = panel.flightBands[2].properties
equal(clipped.x + clipped.w, panel.area.x + math.floor(2000 / 3000 * panel.area.w + 0.5))
equal(clipped.h, panel.area.h, "resize reprojects every flight object")

intervals[2] = { 500, 6000, true, true }
session.flightRevision = session.flightRevision + 1
settle()
equal(clipped.x + clipped.w, panel.area.x + panel.area.w, "shading must clip at the plot's right edge")

intervals[2] = { 4999, 5000, true, true }
session.flightRevision = session.flightRevision + 1
settle()
equal(clipped.w, 1, "subpixel flights still have a visible band")
equal(clipped.x + clipped.w, panel.area.x + panel.area.w, "subpixel bands must stay inside the plot")
intervals[2] = { 5000, 6000, true, true }
session.flightRevision = session.flightRevision + 1
settle()
assert(panel.flightBands[2].hidden, "flights starting beyond the window must not spill into the legend")

session.flightLast, session.flightRevision = 0, session.flightRevision + 1
settle()
assert(panel.flightBands[1].hidden and panel.flightBands[2].hidden, "epoch reset hides all old pooled objects")
session.flightFirst, session.flightLast, session.flightRevision = 65, 66, session.flightRevision + 1
intervals[65], intervals[66] = { 2500, 3000, false, true }, { 3500, 4500, true, true }
settle()
equal(#panel.flightBands, 2, "wrapped flight identities reuse the bounded native pool")
assert(not panel.flightBands[1].hidden and not panel.flightBands[2].hidden)
equal(panel.flightBands[1].properties.x, panel.area.x + math.floor(500 / 3000 * panel.area.w + 0.5))

session.flightFirst, session.flightLast, session.flightRevision = 128, 128, session.flightRevision + 1
intervals[128] = { 2500, 3500, true, true }
settle()
assert(not panel.flightBands[64].hidden)
session.flightLast, session.flightRevision = 0, session.flightRevision + 1
chart.refresh(panel)
session.flightRevision = session.flightRevision + 1
settle()
assert(
    panel.flightBands[64].hidden and panel.flightBands[1].hidden,
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

local lightHost = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-light" })
local lightServices = lightHost.dashboardLoader.buildServices(lightHost, placement)
lightServices.history = fake
session.flightFirst, session.flightLast, session.flightRevision = 1, 2, session.flightRevision + 1
intervals[2] = { 500, 4000, true, true }
local light = chart.create(lightHost.page, { x = 0, y = 0, w = 238, h = 65 }, settings, lightServices)
for _ = 1, 150 do
    chart.refresh(light)
end
local lightBand = light.flightBands[2].properties
equal(lightBand.color, light.theme.chartColor.green, "flight shading must use the active theme's green")
equal(lightBand.opacity, 32)
equal(lightBand.y, light.area.y)
equal(lightBand.h, light.area.h)
