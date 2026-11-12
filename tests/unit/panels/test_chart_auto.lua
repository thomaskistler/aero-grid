-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
local recorder = assert(loadfile(root .. "/tests/support/chart_recorder.lua"))(root)
local view = assert(loadfile(root .. "/tests/support/chart_assertions.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
fixture.reset()
local dashboard = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
local services = dashboard.dashboardLoader.buildServices(dashboard, { col = 0, row = 0, colSpan = 2, rowSpan = 1 })
local record = recorder(3)
local now = 0
services.history, services.clock = record.history, function()
    return now
end
local panel = chart.create(dashboard.page, { x = 0, y = 0, w = 472, h = 196 }, {
    armSwitch = "L01",
    metrics = {
        { source = record.feeds[1].name },
        { source = record.feeds[2].name },
        { source = record.feeds[3].name },
    },
}, services)
local worst, counted, grant = 0, 0, 1
local depth, inside, worstBackground, backgroundCount = 0, nil, 0, 0
local worstByGrant = {}
local function hook(event)
    if event == "count" then
        counted = counted + 1
        if inside then
            backgroundCount = backgroundCount + 1
        end
    elseif event == "call" then
        depth = depth + 1
        if not inside and debug.getinfo(2, "n").name == "background" then
            inside, backgroundCount = depth, 0
        end
    elseif event == "return" then
        if inside == depth then
            worstBackground, inside = math.max(worstBackground, backgroundCount), nil
            worstByGrant[grant] = math.max(worstByGrant[grant] or 0, backgroundCount)
        end
        depth = depth - 1
    end
end
-- Simulate 50 ms callbacks on a shared dashboard: one or two granted slots in turn.
local function callbacks(count)
    for _ = 1, count do
        now = now + 5
        counted = 0
        depth, inside = 0, nil
        debug.sethook(hook, "cr", 1)
        grant = 3 - grant
        local _, _, used = chart.refresh(panel, false, grant)
        debug.sethook()
        worst = math.max(worst, counted)
        assert(used >= 1 and used <= grant, "auto preparation must stay within the grant")
    end
end
-- One sample per series and one chart refresh per simulated 50 ms callback.
local swappedAt, overflowAt
local function activeResumes()
    local count = 0
    for _, marker in pairs(panel.resumeMarkers.markers) do
        count = count + (marker.active and 1 or 0)
    end
    return count
end
for at = 0, 9000, 5 do
    -- A one-second pause at 40 s, after the next window is already prepared.
    record.sample(at, { (at * 7) % 997, -(at % 389), (at % 600) - 300 }, false, not (at >= 4000 and at < 4100))
    if at == 1000 then
        -- A flight that is still open when the window swaps.
        for _, session in ipairs(record.history.sessions) do
            local interval = { id = 1, start = 1000, startKnown = true }
            session.flights[1], session.openFlight = interval, interval
            local state = session.state
            state.flightFirst, state.flightLast, state.flightActive = 1, 1, true
            state.flightRevision = state.flightRevision + 1
        end
    end
    callbacks(1)
    local first = panel.columnConsumers and panel.columnConsumers[1]
    if not overflowAt and first and first.map.overflowed then
        overflowAt = at
    end
    if not swappedAt and panel.window == 12000 then
        -- The swap can land in the same callback in which the plot fills.
        swappedAt, overflowAt = at, overflowAt or at
        equal(activeResumes(), 1, "the swapped layer must already show pauses recorded before the swap")
        local band, area = panel.flightBands[1].properties, panel.area
        -- One pause gap lies before the current time.
        local reach = area.x
            + math.floor(record.session.elapsed / panel.window * area.w + 0.5)
            + panel.columnConsumers[1].map.breakWidth
        assert(
            not panel.flightBands[1].hidden and math.abs(band.x + band.w - reach) <= 1,
            "the swapped layer's open flight band must reach the current time"
        )
        for _, item in ipairs(panel.series) do
            assert(item.connectors[1] and item.connectors[1].key, "pause connectors must be drawn before the swap")
        end
    end
end
assert(
    overflowAt and swappedAt and swappedAt - overflowAt <= 100,
    "the next window must appear within a second of overflow"
)
callbacks(400)
equal(panel.window, 12000, "a full one-minute plot must swap to two minutes")
equal(panel.duration.properties.text, "2m")
local owner = panel.columnConsumers[1]
equal(owner.map.window, 12000)
for _ = 1, 200 do
    if view.finished(panel) then
        break
    end
    callbacks(1)
end
assert(view.finished(panel), "the swapped layer must keep drawing")
local left, right = view.bounds(panel, 1)
assert(left <= panel.area.x + 1, "earlier data must stay visible after the swap")
assert(right >= panel.area.x + math.floor(panel.area.w * 0.7), "the swap must keep the newest data")
-- Preparation uses what is left of the ordinary slot plus at most one extra slot
-- (nominally 2,000 instructions each).
assert((worstByGrant[1] or 0) < 2400, "one-slot turns must keep preparation within the slot")
assert((worstByGrant[2] or 0) < 4000, "preparation must not exceed one extra slot")
print(
    string.format(
        "Auto chart windows swap within one extra slot; worst refresh %d, worst preparation %d Lua instructions",
        worst,
        worstBackground
    )
)
