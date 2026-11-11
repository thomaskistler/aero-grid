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
local worst, counted = 0, 0
local depth, inside, worstBackground, backgroundCount = 0, nil, 0, 0
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
        end
        depth = depth - 1
    end
end
-- Simulate 50 ms callbacks with two granted slots: one ordinary, one extra.
local function callbacks(count)
    for _ = 1, count do
        now = now + 5
        counted = 0
        depth, inside = 0, nil
        debug.sethook(hook, "cr", 1)
        local _, _, used = chart.refresh(panel, false, 2)
        debug.sethook()
        worst = math.max(worst, counted)
        assert(used >= 1 and used <= 2, "auto preparation must stay within one extra slot")
    end
end
-- One sample per series and one chart refresh per simulated 50 ms callback.
local swappedAt
for at = 0, 9000, 5 do
    record.sample(at, { (at * 7) % 997, -(at % 389), (at % 600) - 300 })
    callbacks(1)
    swappedAt = swappedAt or panel.window == 12000 and at or nil
end
assert(swappedAt and swappedAt >= 6000 and swappedAt <= 6100, "the next window must appear within a second of overflow")
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
assert(worstBackground < 2600, "rescale preparation must stay near one extra slot")
print(
    string.format(
        "Auto chart windows swap within one extra slot; worst refresh %d, worst preparation %d Lua instructions",
        worst,
        worstBackground
    )
)
