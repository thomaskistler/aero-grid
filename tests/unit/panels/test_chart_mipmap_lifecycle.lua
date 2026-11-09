-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
local mipmap = fixture.module("lib/chart_mipmap.lua")
local recorder = assert(loadfile(root .. "/tests/support/mipmap_recorder.lua"))(root)
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
fixture.reset()
local dashboard = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" })
fixture.pump(dashboard, 60)
local template = dashboard.panels[1].instance
local observed, baseline = recorder(1), recorder(1)
local history, feed = observed.history, observed.feeds[1]
local services = {
    theme = template.theme,
    themeBuilder = template.themeBuilder,
    primitives = template.primitives,
    history = history,
    clock = getTime,
    span = { colSpan = 4, rowSpan = 2 },
    chartMipmap = dashboard.chartMipmap,
    chartMipmapRenderer = dashboard.chartMipmapRenderer,
    state = function(name, accent)
        return template.themeBuilder.state(template.theme, name, accent)
    end,
}
assert(services.chartMipmap and services.chartMipmapRenderer, "normal runtime did not provide mipmap modules")
local host = fixture.module("lib/panel_host.lua")
local function panel(mode)
    local settings = host.resolveSettings(chart, {
        armSwitch = "L01",
        timeRange = mode or "growing",
        metrics = { { source = feed.name, precision = 3 } },
    })
    local parent = lvgl.box({ x = 0, y = 0, w = 480, h = 134 })
    local created = chart.create(parent, { x = 0, y = 0, w = 480, h = 134 }, settings, services)
    if created.mipmapSetup then
        chart.refresh(created)
    end
    return created
end
local first, sibling = panel(), panel()
local owner, other = first.mipmapConsumers[1], sibling.mipmapConsumers[1]
equal(first.series[1].feed, feed)
equal(sibling.series[1].feed, feed, "same subscription must remain shared")
assert(owner.complete and other.complete)
equal(owner.map.width, first.area.w)
local width = first.area.w
for at = 0, 100 do
    observed.sample(at, { at % 2 == 0 and 999999 or -123456 })
    baseline.sample(at, { at % 2 == 0 and 999999 or -123456 })
    chart.render(first)
    equal(first.area.w, width, "live readout/axis changes must not restart physical-width summaries")
end
equal(owner.map.at, 100)
local late = panel()
assert(not late.mipmapConsumers[1].complete, "late chart must reconstruct retained history")
local before, siblingMap, count = owner.map, other.map, feed.count
local resizeSteps, step = 0, owner.step
owner.step = function(self, ...)
    resizeSteps = resizeSteps + 1
    return step(self, ...)
end
chart.update(first, { x = 0, y = 0, w = 320, h = 134 })
equal(resizeSteps, 0, "resize must leave reconstruction to the scheduled refresh")
assert(first.mipmapRenderer == nil, "resize must not also prepare a native pool synchronously")
owner.step = step
assert(owner.map ~= before and owner.map.width == first.area.w)
assert(owner.map.at == 100 and owner.startedAt == 0)
equal(other.map, siblingMap)
equal(other.map.at, 100)
equal(feed.count, count)
local resized = owner.map
chart.update(first, { x = 5, y = 7, w = 320, h = 134 })
equal(owner.map, resized, "moving a chart must not reset its presentation")
observed.sample(110, { 0.7 })
baseline.sample(110, { 0.7 })
equal(owner.map.at, 110)
equal(other.map.at, 110)
equal(before.at, 100)
chart.destroy(first)
chart.destroy(first)
assert(first.mipmapConsumers == nil and owner.map == nil)
observed.sample(120, { 0.9 })
baseline.sample(120, { 0.9 })
equal(resized.at, 110, "destroyed chart is still observed")
equal(other.map.at, 120)
equal(feed.count, baseline.feeds[1].count)
for index = feed.first, feed.last do
    local a, b, c, d = history:point(feed, index)
    local x, y, z, w = baseline.history:point(baseline.feeds[1], index)
    assert(a == x and b == y and c == z and d == w, "chart lifecycle changed shared recording")
end
chart.destroy(late)
chart.destroy(sibling)
assert(history.views[feed].observers == nil)

services.chartMipmap = nil
assert(not pcall(panel), "missing mipmap module must fail explicitly")
services.chartMipmap = mipmap
local rendererModule = services.chartMipmapRenderer
services.chartMipmapRenderer = nil
assert(not pcall(panel), "missing renderer must fail explicitly")
services.chartMipmapRenderer = rendererModule
local rolling = panel("rolling")
assert(rolling.mipmapConsumers[1].map.lastLevel == 0, "rolling history must use one fixed-span mipmap ring")
chart.destroy(rolling)
services.preview = true
local preview = panel()
assert(preview.mipmapConsumers[1].readonly, "preview must reconstruct without observing live input")
chart.destroy(preview)

services.preview = false
local activeRecorder = recorder(1)
services.history = activeRecorder.history
local liveSession = services.history:session("L01")
services.history.flight = function()
    return 0
end
local active = panel()
local completed = 0
for at = 1, 1000 do
    activeRecorder.sample(at, { at % 17 })
    local _, pending = chart.refresh(active)
    if not pending then
        completed = completed + 1
    end
end
assert(completed > 0 and active.mipmapRenderer.published[1], "moving live input starved native publication")
-- Supply a qualified active flight through the read-only session view.
active.session = setmetatable({
    flightFirst = 1,
    flightLast = 1,
    flightRevision = 1,
    flightActive = true,
}, { __index = liveSession })
completed = 0
for at = 1001, 1300 do
    activeRecorder.sample(at, { at % 17 })
    local _, pending = chart.refresh(active)
    if not pending then
        completed = completed + 1
        assert(active.frameThrough == nil and active.mipmapDecorating == nil)
    end
end
assert(completed > 1, "an active flight must release dispatcher ownership as its clock advances")
assert(active.flightBands[1] and not active.flightBands[1].hidden)
active.mipmapDecorating, active.frameThrough = true, 1200
chart.resetSession(active)
assert(active.mipmapDecorating == nil and active.frameThrough == nil, "reset retained an old decoration pass")
chart.destroy(active)
print("Sole chart renderer owns isolated mipmaps for live, rolling, rebuilt and preview histories")
