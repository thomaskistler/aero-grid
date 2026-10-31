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
equal(band.opacity, 48, "flight shading must be visible without obscuring telemetry")
equal(band.color, lcd.RGB(0xFFFFFF), "dark themes lighten the panel background without an accent tint")
equal(panel.flightBands[1].parent, panel.flightRoot)
equal(panel.plotRoot.children[1], panel.flightRoot, "bands must sit behind grid and telemetry objects")
equal(panel.plotRoot.children[2], panel.gapRoot)
equal(panel.plotRoot.children[3], panel.gridRoot, "flight shading and gap masks must stay behind the grid")
local active = panel.flightBands[2].properties
equal(active.x + active.w, area.x + math.floor(session.elapsed / panel.window * area.w + 0.5))
local previousWidth = active.w
session.elapsed = 1100
settle()
active = panel.flightBands[2].properties
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
clipped = panel.flightBands[2].properties
equal(clipped.x + clipped.w, panel.area.x + panel.area.w, "shading must clip at the plot's right edge")

intervals[2] = { 4999, 5000, true, true }
session.flightRevision = session.flightRevision + 1
settle()
clipped = panel.flightBands[2].properties
equal(clipped.w, 1, "subpixel flights still have a visible band")
equal(clipped.x + clipped.w, panel.area.x + panel.area.w, "subpixel bands must stay inside the plot")
intervals[2] = { 5000, 6000, true, true }
session.flightRevision = session.flightRevision + 1
settle()
assert(panel.flightBands[2].hidden, "flights starting beyond the window must not spill into the legend")

for _, interval in ipairs({ { 3500, 3500 }, { 1000, 2000 }, { 3501, 3500 } }) do
    intervals[2] = interval
    session.flightRevision = session.flightRevision + 1
    settle()
    assert(panel.flightBands[2].hidden, "empty and fully clipped intervals must not leave a one-pixel sliver")
end

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
equal(lightBand.color, lcd.RGB(0x000000), "light themes darken the panel background without an accent tint")
equal(lightBand.opacity, 48, "light and dark themes must use the same flight shading contrast")
equal(lightBand.y, light.area.y)
equal(lightBand.h, light.area.h)

-- Keep the previous complete plot on screen while the next three traces are
-- projected, even if both telemetry and the live flight clock keep changing.
local samples = {}
for index = 1, 160 do
    samples[index] = { index * 10, index % 17 }
end
local feed = {
    available = true,
    revision = 1,
    plotRevision = 1,
    first = 1,
    last = #samples,
    min = 0,
    max = 16,
    value = samples[#samples][2],
    precision = 0,
    unitText = "",
}
local live = {
    configured = true,
    available = true,
    recording = true,
    elapsed = 1700,
    flightFirst = 1,
    flightLast = 1,
    flightActive = true,
    flightRevision = 1,
    armFirst = 1,
    armLast = 1,
    armRevision = 1,
}
local history = { FLIGHT_CAPACITY = 64 }
local confirmedEnd
function history:session()
    return live
end
function history:subscribe()
    return feed
end
function history:point(_, index)
    if samples[index] then
        return samples[index][1], samples[index][2], false
    end
end
function history:block() end
function history:flight(_, index)
    if index == 1 then
        return 100, confirmedEnd
    end
end
function history:armBoundary(_, index)
    if index == 1 then
        return 1200, false
    end
end
function history:recordingBreak() end
services.preview, services.history = false, history
local consistent = chart.create(host.page, { x = 0, y = 0, w = 472, h = 196 }, settings, services)
local previous = consistent.plotRoot
local _, unfinished = chart.refresh(consistent)
assert(unfinished and consistent.plotRoot.hidden and not previous.hidden)
local captured = consistent.series[1].tailAt
local committed = false
for step = 1, 200 do
    live.elapsed = live.elapsed + 10
    samples[#samples + 1] = { live.elapsed, step % 17 }
    feed.last, feed.revision, feed.plotRevision = #samples, feed.revision + 1, feed.plotRevision + 1
    _, unfinished = chart.refresh(consistent)
    if not unfinished then
        committed = true
        break
    end
    assert(not previous.hidden and consistent.plotRoot.hidden, "partial plots must never become visible")
end
assert(committed, "a moving flight clock must not restart or starve a chart transaction")
assert(previous.hidden and not consistent.plotRoot.hidden)
equal(consistent.plotRoot.parent, consistent.plotHost, "both plot buffers must stay behind the labels")
for _, item in ipairs(consistent.series) do
    equal(item.job.tailAt, captured, "all traces must project the same captured frame")
end
local endX = consistent.area.x + math.floor(captured / consistent.window * consistent.area.w + 0.5)
local frameBand = consistent.flightBands[1].properties
equal(frameBand.x + frameBand.w, endX, "the live band must stop at recorded telemetry, not race ahead")
local arm = consistent.armMarkers
equal(#arm.markerKeys, 1, "an arm transition must be visible while the flight is still active")
assert(arm.markers[arm.markerKeys[1]].active)
equal(arm.markers[arm.markerKeys[1]].object.properties.dashGap, nil)
feed.stale, feed.revision = true, feed.revision + 1
live.elapsed = live.elapsed + 1000
for _ = 1, 200 do
    local _, pending = chart.refresh(consistent)
    if not pending then
        break
    end
end
frameBand = consistent.flightBands[1].properties
equal(
    frameBand.x + frameBand.w,
    consistent.area.x + math.floor((live.elapsed - consistent.start) / consistent.window * consistent.area.w + 0.5),
    "real telemetry loss must not make an active flight look completed"
)

local function finishFrame(target)
    for _ = 1, 200 do
        local _, pending = chart.refresh(target)
        if not pending then
            return
        end
    end
    error("chart frame did not finish")
end
settings.timeRange = "growing"
live.elapsed, live.segment = 1200, 1
feed.last, feed.stale = 120, false
feed.revision, feed.plotRevision = feed.revision + 1, feed.plotRevision + 1
local confirmation = chart.create(host.page, { x = 0, y = 0, w = 472, h = 196 }, settings, services)
finishFrame(confirmation)
local function checkDisarmBoundary()
    local count = 0
    for _, object in ipairs(confirmation.plotRoot.children) do
        if not object.hidden and object.kind == "triangle" and object.parent == confirmation.plotRoot then
            count = count + 1
            equal(
                object.properties.pts[3][1],
                confirmation.area.x + math.floor(1200 / confirmation.window * confirmation.area.w + 0.5),
                "the disarm triangle must stay at the actual disarm time"
            )
        end
    end
    equal(count, 1, "flight confirmation must not add an event")
end
checkDisarmBoundary()
live.elapsed = live.elapsed + 1000
live.recording, live.flightActive = false, false
live.stoppedAt = live.elapsed
live.flightRevision = live.flightRevision + 1
confirmedEnd = 1200
finishFrame(confirmation)
checkDisarmBoundary()
equal(confirmation.status.properties.text, "")
equal(#confirmation.resumeMarkers.markerKeys, 0, "recording stop must not add any decoration")
local completedBand = confirmation.flightBands[1].properties
equal(
    completedBand.x + completedBand.w,
    confirmation.area.x + math.floor(1200 / confirmation.window * confirmation.area.w + 0.5),
    "confirmation must close the flight band at disarm, not ten seconds later"
)

do
    local points = { { 0, 3, false }, { 1000, 5, false } }
    local resumes, arms = {}, {}
    local recording = {
        configured = true,
        available = true,
        recording = true,
        elapsed = 1000,
        segment = 1,
        armFirst = 1,
        armLast = 0,
        armRevision = 0,
        resumeFirst = 1,
        resumeLast = 0,
        resumeRevision = 0,
    }
    local data = {
        available = true,
        first = 1,
        last = 2,
        min = 3,
        max = 11,
        value = 5,
        revision = 1,
        plotRevision = 1,
        precision = 0,
        unitText = "",
    }
    local pausedHistory = {}
    function pausedHistory:session()
        return recording
    end
    function pausedHistory:subscribe()
        return data
    end
    function pausedHistory:point(_, index)
        return table.unpack(points[index])
    end
    function pausedHistory:block() end
    function pausedHistory:armBoundary(_, index)
        if arms[index] then
            return table.unpack(arms[index])
        end
    end
    function pausedHistory:recordingBreak(_, index)
        if index >= recording.resumeFirst and index <= recording.resumeLast then
            return resumes[index]
        end
    end
    function pausedHistory:preview()
        return self
    end
    services.history = pausedHistory
    local pauseSettings = { label = "Recorded", metrics = { { source = "V" }, { source = "A" } } }
    local pausedPanel = chart.create(host.page, { x = 0, y = 0, w = 472, h = 196 }, pauseSettings, services)
    finishFrame(pausedPanel)
    equal(#pausedPanel.resumeMarkers.markerKeys, 0)
    recording.recording, recording.elapsed = false, 1000
    recording.stoppedAt = 1000
    recording.armLast, recording.armRevision, arms[1] = 1, 1, { 1000, false }
    finishFrame(pausedPanel)
    equal(pausedPanel.status.properties.text, "")
    equal(#pausedPanel.resumeMarkers.markerKeys, 0, "a pause alone must not add anything")
    equal(#pausedPanel.armMarkers.markerKeys, 1, "disarm remains a distinct axis event")
    local disarmed = pausedPanel.armMarkers.markers[pausedPanel.armMarkers.markerKeys[1]]
    equal(disarmed.object.kind, "triangle")
    assert(disarmed.object.properties.pts[3][2] > disarmed.object.properties.pts[1][2])
    local firstRun = pausedPanel.series[1].runs[1]
    equal(
        firstRun.pts[firstRun.size][1],
        pausedPanel.area.x + math.floor(1000 / pausedPanel.window * pausedPanel.area.w + 0.5),
        "paused traces end at the last real sample, without extending to recording stop"
    )
    equal(data.plotRevision, 1, "pause presentation must not add synthetic samples")

    recording.recording, recording.segment = true, 2
    recording.stoppedAt = nil
    recording.resumeLast, recording.resumeRevision, resumes[1] = 1, 1, 1000
    recording.armLast, recording.armRevision, arms[2] = 2, 2, { 1000, true }
    finishFrame(pausedPanel)
    equal(pausedPanel.status.properties.text, "")
    local column = math.floor(1000 * pausedPanel.axis.scale + 0.5) + 1
    local seam = pausedPanel.resumeMarkers.markers[column]
    assert(seam and seam.active, "resume is visible even before another telemetry sample arrives")
    assert(not seam.object.hidden)
    equal(seam.object.parent, pausedPanel.gapRoot, "gap backgrounds must belong to the staged plot")
    equal(seam.object.properties.x, pausedPanel.area.x + column - 1)
    equal(seam.object.properties.w, 24)
    equal(seam.object.properties.color, pausedPanel.theme.color.surface)
    equal(seam.object.kind, "rectangle")
    equal(seam.slashes, nil, "recording pauses must not add an axis icon")
    equal(#pausedPanel.resumeMarkers.markerKeys, 1, "all metrics share one recording seam")
    local beforeSample = pausedPanel.series[1].runs[1]
    equal(
        beforeSample.pts[beforeSample.size][1],
        seam.object.properties.x,
        "a sample at the exact stop timestamp must stay to the left until a resumed sample exists"
    )
    local up = pausedPanel.armMarkers.markers[column + 24]
    local down = pausedPanel.armMarkers.markers[-column]
    assert(up.active and down.active, "the gap must retain both coincident arm and disarm events")
    assert(up.object.properties.pts[3][2] < up.object.properties.pts[1][2])
    assert(down.object.properties.pts[3][2] > down.object.properties.pts[1][2])
    equal(
        up.object.properties.pts[3][1] - down.object.properties.pts[3][1],
        24,
        "the wider gap keeps the arm and disarm icons separated"
    )

    points[3], points[4] = { 1000, 9, true, true }, { 1500, 10, false }
    data.last, data.revision, data.plotRevision = 4, 2, 2
    recording.elapsed = 1500
    recording.armLast, recording.armRevision, arms[3] = 3, 3, { 1300, false }
    finishFrame(pausedPanel)
    local otherColumn = math.floor(1300 * pausedPanel.axis.scale + 0.5) + 25
    assert(pausedPanel.armMarkers.markers[-otherColumn].active, "other disarm triangles remain visible")
    for _, item in ipairs(pausedPanel.series) do
        equal(item.runCount, 3, "resuming adds a dotted connector between solid runs")
        local connector = item.runs[2]
        assert(connector.dotted and connector.connector and not connector.connector.hidden)
        equal(connector.pts[2][1] - connector.pts[1][1], 24, "equal recording timestamps must be separated by the gap")
        equal(connector.pts[1][1], seam.object.properties.x)
        equal(connector.pts[2][1], seam.object.properties.x + seam.object.properties.w)
        assert(#connector.dots > 2, "dotted connectors need separated native dots, not a solid line")
        for index = 1, connector.dotCount do
            equal(connector.dots[index].properties.color, item.color)
            equal(connector.dots[index].properties.w, 1)
        end
        equal(#item.markerKeys, 0, "a resume must not also draw a full-height dashed gap line")
    end
    points[5], points[6] = { 1800, 8, true }, { 2000, 7, false }
    data.last, data.revision, data.plotRevision = 6, 3, 3
    recording.elapsed = 2000
    finishFrame(pausedPanel)
    equal(#pausedPanel.resumeMarkers.markerKeys, 1, "telemetry gaps must not create recording seams")
    for _, item in ipairs(pausedPanel.series) do
        equal(item.runCount, 4)
        local gap = item.markers[item.markerKeys[1]]
        assert(gap.active)
        equal(gap.object.properties.dashGap, 3, "ordinary telemetry gap styling is unchanged")
    end

    recording.resumeLast, recording.resumeRevision = 3, 3
    resumes[2], resumes[3] = 2200, 2200
    recording.elapsed = 2400
    points[7], points[8] = { 2300, 11, true, true }, { 2400, 10, false }
    data.last, data.revision, data.plotRevision = 8, 4, 4
    finishFrame(pausedPanel)
    local function activeSeams(target)
        local result = {}
        for _, marker in pairs(target.resumeMarkers.markers) do
            if marker.active then
                result[#result + 1] = marker
            end
        end
        return result
    end
    equal(#activeSeams(pausedPanel), 2, "identical resume timestamps share one gap")
    recording.resumeFirst, recording.resumeRevision = 2, 4
    finishFrame(pausedPanel)
    equal(#activeSeams(pausedPanel), 1, "expired journal boundaries must be hidden")
    pauseSettings.timeRange, pauseSettings.duration = "rolling", "30s"
    recording.elapsed = 7000
    finishFrame(pausedPanel)
    for _, marker in pairs(pausedPanel.resumeMarkers.markers) do
        assert(not marker.active, "recording seams must leave the rolling window")
        assert(marker.object.hidden, "expired gap backgrounds must disappear")
    end
    recording.elapsed = 3500
    finishFrame(pausedPanel)
    chart.update(pausedPanel, { x = 0, y = 0, w = 238, h = 65 })
    finishFrame(pausedPanel)
    local active = 0
    for _, marker in pairs(pausedPanel.resumeMarkers.markers) do
        if marker.active then
            active = active + 1
            local geometry = marker.object.properties
            assert(geometry.x >= pausedPanel.area.x)
            assert(geometry.x + geometry.w <= pausedPanel.area.x + pausedPanel.area.w)
            equal(geometry.y, pausedPanel.area.y)
            equal(geometry.h, pausedPanel.area.h)
            assert(geometry.y + geometry.h <= pausedPanel.rect.h)
        end
    end
    equal(active, 1, "resize must reproject and reuse the retained seam")
    recording.recording = false
    lightServices.history = pausedHistory
    local lightPause = chart.create(lightHost.page, { x = 0, y = 0, w = 238, h = 65 }, pauseSettings, lightServices)
    finishFrame(lightPause)
    equal(lightPause.status.properties.text, "")
    for _, marker in pairs(lightPause.resumeMarkers.markers) do
        equal(marker.object.properties.color, lightPause.theme.color.surface, "gaps match either theme")
        equal(marker.slashes, nil)
    end
    lightServices.preview = true
    local pausePreview = chart.create(lightHost.page, { x = 0, y = 0, w = 238, h = 65 }, pauseSettings, lightServices)
    finishFrame(pausePreview)
    equal(pausePreview.status.properties.text, "PREVIEW", "preview status must remain distinct from live pause status")
    local previewSeams = 0
    for _, marker in pairs(pausePreview.resumeMarkers.markers) do
        if marker.active then
            previewSeams = previewSeams + 1
        end
    end
    equal(previewSeams, 1, "previews show retained recording seams")

    recording.resumeLast, recording.resumeRevision, resumes[4] = 4, 5, 3499
    finishFrame(pausedPanel)
    local edgeColumn = math.floor((3499 - pausedPanel.start) * pausedPanel.axis.scale + 24 + 0.5) + 1
    local edge = pausedPanel.resumeMarkers.markers[edgeColumn]
    assert(edge and edge.active, "a seam at the current recording edge must remain visible")
    assert(edge.object.properties.x + edge.object.properties.w <= pausedPanel.area.x + pausedPanel.area.w)
    equal(edge.object.parent, pausedPanel.gapRoot, "a gap at the edge must not add a foreground icon")
    for index = 5, 65 do
        resumes[index] = 3499 + index
    end
    recording.resumeLast, recording.resumeRevision, recording.elapsed = 65, 6, resumes[65]
    finishFrame(pausedPanel)
    local crowded = activeSeams(pausedPanel)
    assert(#crowded > 0 and #crowded <= pausedPanel.area.w // 48)
    assert(
        pausedPanel.axis.start > pausedPanel.start,
        "crowded breaks must evict old data rather than collapse the gaps"
    )
    table.sort(crowded, function(a, b)
        return a.object.properties.x < b.object.properties.x
    end)
    for index, marker in ipairs(crowded) do
        equal(marker.object.properties.w, 24, "crowded breaks retain their full gap width")
        if index > 1 then
            assert(crowded[index - 1].object.properties.x + 24 <= marker.object.properties.x)
        end
    end
    chart.update(pausedPanel, { x = 0, y = 0, w = 40, h = 30 })
    finishFrame(pausedPanel)
    equal(pausedPanel.area.w, 1)
    equal(pausedPanel.axis.gap, 0, "an unusably narrow plot must not divide by zero or create zero-width glyphs")
    equal(#activeSeams(pausedPanel), 0)
end

local scheduler = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
local turns = {}
local function scheduled(id, kind)
    return {
        placement = { id = id, type = kind },
        instance = {},
        interval = 1,
        module = {
            id = kind,
            refresh = function()
                turns[id] = (turns[id] or 0) + 1
                return 1, kind == "chart" and turns[id] < 3
            end,
        },
    }
end
scheduler.panels = { scheduled("first", "chart"), scheduled("second", "chart"), scheduled("reading", "metric") }
fixture.pump(scheduler, 2)
equal(turns.first, 2)
equal(turns.second, nil, "another chart must wait for the current chart's complete frame")
equal(turns.reading, 2, "staged charts must not starve ordinary panels")
fixture.pump(scheduler, 1)
equal(turns.first, 3)
equal(turns.second, 1, "the next chart starts once the preceding frame is complete")
