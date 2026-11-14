-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
assert(loadfile(root .. "/tests/support/chart_turns.lua"))().install(chart)
local Columns = fixture.module("lib/chart_columns.lua")
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
    duration = 2,
    metrics = {
        { source = record.feeds[1].name },
        { source = record.feeds[2].name },
        { source = record.feeds[3].name },
    },
}, services)
local worst, counted, grant = 0, 0, 1
local phase = 0
local depth, inside, backgroundCount = 0, nil, 0
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
            worstByGrant[grant] = math.max(worstByGrant[grant] or 0, backgroundCount)
            inside = nil
        end
        depth = depth - 1
    end
end
-- 50 ms callbacks on a busy dashboard: 1, 2 and 7 slots offered in turn, as measured.
local function callbacks(count)
    for _ = 1, count do
        now = now + 5
        counted, depth, inside = 0, 0, nil
        debug.sethook(hook, "cr", 1)
        phase = phase % 3 + 1
        grant = ({ 1, 2, 7 })[phase]
        grant = chart.offered(panel, grant)
        local offered = grant
        local _, _, used = chart.refresh(panel, false, grant)
        debug.sethook()
        worst = math.max(worst, counted)
        assert(used >= 1 and used <= offered, "sliding must stay within the grant")
    end
end
-- Every sample each series receives, replayed below into a directly sampled map.
local received = {}
local function capture()
    for index, owner in ipairs(panel.columnConsumers or {}) do
        if not received[index] then
            received[index] = {}
            local sample = owner.sample
            owner.sample = function(self, at, value, broken, resumed)
                local list = received[index]
                list[#list + 1] = { at, value, broken, resumed }
                return sample(self, at, value, broken, resumed)
            end
        end
    end
end
local starts, overflowAt, lateness = {}, nil, 0
for at = 0, 21000, 5 do
    -- One-second pauses before the first slide and after it.
    local paused = at >= 4000 and at < 4100 or at >= 15000 and at < 15100
    if at % 10 == 0 then
        record.sample(at, { (at * 7) % 997, -(at % 389), (at % 600) - 300 }, false, not paused)
    end
    capture()
    callbacks(1)
    local first = panel.columnConsumers and panel.columnConsumers[1]
    if not overflowAt and first and first.map.overflowed then
        overflowAt = at
    end
    if panel.start ~= (starts[#starts] or 0) then
        starts[#starts + 1] = panel.start
        lateness = math.max(lateness, at - (overflowAt or at))
        overflowAt = nil
        assert(panel.window == 12000, "a fixed window keeps its length while sliding")
    end
end
assert(#starts == 2, "a two-minute window must slide twice in 210 seconds")
assert(lateness <= 100, "the slid window must appear within a second of overflow")
equal(panel.duration.properties.text, "2m")
local function drained()
    for _, owner in ipairs(panel.columnConsumers) do
        if #owner.pending > 0 then
            return false
        end
    end
    return view.finished(panel)
end
for _ = 1, 400 do
    if drained() then
        break
    end
    callbacks(1)
end
assert(drained(), "the slid layer must keep drawing")

-- The slid columns are an exact shift: they equal a map sampled directly at the
-- final offset.
for index, owner in ipairs(panel.columnConsumers) do
    local map = owner.map
    local direct = Columns.new(map.width, map.window, map.recording, {
        breakWidth = map.breakWidth,
        offset = map.offset,
        start = map.start,
    })
    local hadValue = false
    for _, sample in ipairs(received[index]) do
        local at, value, broken, resumed = sample[1], sample[2], sample[3], sample[4]
        direct:sample(at, value, broken, resumed, direct:gapCount(at))
        if broken and not resumed and value ~= nil and hadValue then
            direct:breakAt(at)
        end
        hadValue = hadValue or value ~= nil
    end
    equal(map.start, starts[#starts])
    for slot = 1, map.width do
        local same = map.kinds[slot] == direct.kinds[slot]
            and map.low[slot] == direct.low[slot]
            and map.high[slot] == direct.high[slot]
            and map.ends[slot] == direct.ends[slot]
        assert(
            same,
            string.format(
                "series %d column %d differs: %s %s %s / %s %s %s",
                index,
                slot,
                tostring(map.kinds[slot]),
                tostring(map.low[slot]),
                tostring(map.high[slot]),
                tostring(direct.kinds[slot]),
                tostring(direct.low[slot]),
                tostring(direct.high[slot])
            )
        )
    end
end
-- Preparation uses what is left of the ordinary slot plus at most one extra slot.
assert((worstByGrant[1] or 0) < 2400, "one-slot turns must keep preparation within the slot")
assert((worstByGrant[2] or 0) < 4000, "preparation must not exceed one extra slot")
print(
    string.format(
        "Fixed chart windows slide by a minute within a second; worst refresh %d, worst preparation %d/%d instructions",
        worst,
        worstByGrant[1] or 0,
        worstByGrant[2] or 0
    )
)
