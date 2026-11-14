-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
assert(loadfile(root .. "/tests/support/chart_turns.lua"))().install(chart)
local recorder = assert(loadfile(root .. "/tests/support/chart_recorder.lua"))(root)
local view = assert(loadfile(root .. "/tests/support/chart_assertions.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
fixture.reset()

local low, high = chart.growRange(nil, nil, 0, 0)
assert(low < 0 and high > 0 and high - low <= 0.2, "first readings seed a tight range")
low, high = chart.growRange(-10, 10, -5, 1000)
assert(low <= -10 and high >= 1000 and high - low >= 1.25 * 1010, "growth fits the data with headroom")
low, high = chart.growRange(-10, 10, -5, 12)
assert(high - low >= 40, "spans at least double")
equal(select(1, chart.growRange(0, 10, 0, 50, 0, nil)), 0, "a configured side stays fixed")

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
local counted, worst, grant = 0, 0, 1
local phase = 0
local function callbacks(count)
    for _ = 1, count do
        now = now + 5
        phase = phase % 3 + 1
        grant = ({ 1, 2, 7 })[phase]
        counted = 0
        debug.sethook(function()
            counted = counted + 1
        end, "", 1)
        grant = chart.offered(panel, grant)
        local offered = grant
        local _, _, used = chart.refresh(panel, false, grant)
        debug.sethook()
        assert(used >= 1 and used <= offered, "range rescales must stay within the grant")
        if panel.columnRenderer and not panel.columnSetup then
            worst = math.max(worst, counted)
        end
    end
end
-- A centred stick that is pushed to full deflection after three seconds.
local jumpedAt, rescaledAt
for at = 0, 1000, 5 do
    local value = at < 300 and 0 or 1000
    if at % 10 == 0 then
        record.sample(at, { value, value / 2, -value })
    end
    callbacks(1)
    jumpedAt = jumpedAt or value > 0 and at or nil
    if jumpedAt and not rescaledAt and panel.series[1].high >= 1000 and panel.series[1].low <= -1000 then
        rescaledAt = at
    end
end
assert(rescaledAt and rescaledAt - jumpedAt <= 100, "a rescaled plot must appear within a second")
for _ = 1, 200 do
    if view.finished(panel) then
        break
    end
    callbacks(1)
end
local _, _, top, bottom = view.bounds(panel, 1)
assert(top > panel.area.y and bottom < panel.area.y + panel.area.h, "the jump must fit inside the new range")
print(string.format("Chart ranges rescale within a second; worst refresh %d Lua instructions", worst))
