-- SPDX-License-Identifier: GPL-2.0-only

-- Queued samples, editor sessions and session resets must never stall a chart's
-- prepared layer, and each turn stays bounded.
local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
local recorder = assert(loadfile(root .. "/tests/support/chart_recorder.lua"))(root)
local view = assert(loadfile(root .. "/tests/support/chart_assertions.lua"))()
fixture.reset()
local dashboard = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
local now = 0

local function create(duration)
    local record = recorder(3)
    local services = dashboard.dashboardLoader.buildServices(dashboard, { col = 0, row = 0, colSpan = 2, rowSpan = 1 })
    services.history, services.clock = record.history, function()
        return now
    end
    local panel = chart.create(dashboard.page, { x = 0, y = 0, w = 472, h = 196 }, {
        armSwitch = "L01",
        duration = duration,
        metrics = {
            { source = record.feeds[1].name },
            { source = record.feeds[2].name },
            { source = record.feeds[3].name },
        },
    }, services)
    for _ = 1, 400 do
        local _, pending = chart.refresh(panel, false, 8)
        if not pending and view.finished(panel) then
            break
        end
    end
    return panel, record
end

local function queued(panel)
    local count = 0
    for _, owner in ipairs(panel.columnConsumers) do
        count = math.max(count, #owner.pending)
    end
    return count
end

local function values(at)
    return { (at * 7) % 997, -(at % 389), (at % 600) - 300 }
end

-- A hidden dashboard keeps a full sliding chart current: samples queue while
-- the plot is full, yet the slid layer is still prepared and swapped.
local hidden, hiddenRecord = create(1)
local starts = {}
for at = 0, 24000, 10 do
    now = at
    hiddenRecord.sample(at, values(at))
    chart.background(hidden)
    if hidden.columnConsumers[1].map.start ~= (starts[#starts] or 0) then
        starts[#starts + 1] = hidden.columnConsumers[1].map.start
    end
end
assert(#starts >= 3, "a hidden full chart must keep sliding while samples queue")
assert(queued(hidden) < 10, "queued samples must drain while the chart is hidden")

-- One-slot grants with a sustained backlog still finish the slid layer.
local narrow, narrowRecord = create(1)
starts = {}
for at = 0, 24000, 10 do
    now = at
    narrowRecord.sample(at, values(at))
    local _, _, used = chart.refresh(narrow, false, 1)
    assert(used == 1, "one-slot grants must not be exceeded")
    if narrow.start ~= (starts[#starts] or 0) then
        starts[#starts + 1] = narrow.start
    end
end
assert(#starts >= 3, "a one-slot chart must keep sliding with a sustained backlog")
assert(queued(narrow) < 10, "queued samples must drain under one-slot grants")

-- A session reset retires both layers within a bounded number of hides per
-- turn, whatever timestamp the host passes.
local resetPanel, resetRecord = create(nil)
for at = 0, 9000, 25 do
    now = at
    resetRecord.sample(at, values(at))
    chart.refresh(resetPanel, false, 2)
end
local auto = resetPanel.auto
assert(auto.hidden and auto.hidden.columnRenderer, "the test needs a prepared hidden layer")
assert(next(resetPanel.columnRenderer.visible), "the test needs visible columns")
local hiddenRenderer, visibleRenderer = auto.hidden.columnRenderer, resetPanel.columnRenderer
local visibleBefore = 0
for _ in pairs(visibleRenderer.visible) do
    visibleBefore = visibleBefore + 1
end
assert(visibleBefore > 100, "the test needs many visible columns")
local step = 1
repeat
    step = resetRecord.history:resetSession(9000, step)
until not step
local hide = lvgl.hide
local hides = 0
local turns, worstHides = 0, 0
repeat
    turns = turns + 1
    hides = 0
    lvgl.hide = function(object)
        hides = hides + 1
        return hide(object)
    end
    local _, unfinished, used = chart.resetSession(resetPanel, 0x3fffffff)
    lvgl.hide = hide
    worstHides = math.max(worstHides, hides)
    assert(used >= 1 and used <= 2, "a reset turn must stay within two slots")
until not unfinished or turns > 200
assert(turns > 1 and worstHides <= 120, "a reset must hide columns in bounded batches")
assert(next(visibleRenderer.visible) == nil, "the reset must hide every visible column")
assert(auto.job == nil, "a layer prepared for the old recording must be dropped")
assert(auto.hidden.recycle, "the hidden layer must be swept before reuse")
for _, consumer in ipairs(resetPanel.columnConsumers) do
    assert(next(consumer.map.kinds) == nil and #consumer.pending == 0, "consumers must start the new recording empty")
end
local swept = false
for at = 9025, 12000, 25 do
    now = at
    resetRecord.sample(at, values(at))
    chart.refresh(resetPanel, false, 2)
    swept = swept or auto.hidden and not auto.hidden.recycle and next(hiddenRenderer.visible) == nil
end
assert(swept, "the hidden layer's old columns must be swept")
for index = 1, 3 do
    local rectangles = view.rectangles(resetPanel, index)
    assert(#rectangles > 0, "the new recording must be drawn after a reset")
end
-- Dense dropouts across a full window: every stored break gets its marker,
-- including breaks after more interruptions than the plot is wide.
local gappy, gappyRecord = create(1)
for at = 0, 5995, 5 do
    now = at
    gappyRecord.sample(at, values(at), at % 10 == 5)
    chart.refresh(gappy, false, 2)
end
for _ = 1, 400 do
    local _, pending = chart.refresh(gappy, false, 8)
    if not pending and view.finished(gappy) then
        break
    end
end
local map, item = gappy.columnConsumers[1].map, gappy.series[1]
assert(map.breakLast >= map.width - 1 and map.breakLast <= map.width + 1, "dense dropouts must fill every column")
local active = {}
for column, marker in pairs(item.markers) do
    if marker.active then
        active[column] = true
    end
end
for index = 1, map.breakLast do
    local column = math.floor(map:pixel(map.breaks[index]) + 0.5) + 1
    assert(active[column], "break " .. index .. " lost its marker")
end
print("Chart backlogs drain, dense dropouts keep their markers, and resets stay bounded across both layers")
