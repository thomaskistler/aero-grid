-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local Columns = fixture.module("lib/chart_columns.lua")
local Renderer = fixture.module("lib/chart_columns_renderer.lua")
local recorder = assert(loadfile(root .. "/tests/support/chart_recorder.lua"))(root)
local Oracle = assert(loadfile(root .. "/tests/support/chart_column_oracle.lua"))()
fixture.reset()

local holds = 0
for run = 1, 8 do
    local width, stride = ({ 60, 226, 397, 800 })[(run - 1) % 4 + 1], run <= 4 and 5 or 37
    local history = {}
    function history:point()
        error("appends must never read recorded history")
    end
    function history:observeSamples(_, observer)
        self.observer = observer
    end
    function history:unobserveSamples()
        self.observer = nil
    end
    local feed = { count = 5000, first = 1, last = 5000, plotRevision = 0 }
    local owner, oracle = Columns.attach(history, feed, width), Oracle.new()
    assert(next(owner.map.kinds) == nil and #owner.pending == 0, "attachment replayed old history")
    local context = {
        area = { x = 4, y = 10, w = width, h = 90 },
        rect = { w = width + 20, h = 120 },
        geometryVersion = 1,
        version = 1,
        plotRoot = lvgl.box({ x = 0, y = 0, w = width + 20, h = 120 }),
        series = { { color = lcd.RGB(255, 0, 0), low = 10, high = 50 } },
        columnConsumers = { owner },
    }
    local renderer = Renderer.new(context)
    assert(next(renderer.objects) == nil, "empty charts must not allocate a full column pool")
    for at = 0, 5999, stride do
        local value = at % 71
        if at % 113 == 0 then
            value = nil
        end
        feed.plotRevision = feed.plotRevision + 1
        history.observer:sample(at, value)
        oracle:sample(at, value)
        if at % (stride * 4) == 0 then
            renderer:append()
            assert(#owner.pending == 0 and #owner.map.dirtyList == 0, "append left unfinished work")
        end
    end
    renderer:append()
    local map = owner.map
    for bucket = 0, width - 1 do
        local expected, actual = oracle:summary(width, bucket), map:summary(bucket)
        assert(not expected == not actual)
        holds = holds + (expected and expected.kind == "hold" and 1 or 0)
        if expected then
            assert(actual.kind == expected.kind and actual.min == expected.min and actual.max == expected.max)
            assert(actual["end"] == expected.finish and actual.width == expected.width and actual.from == expected.from)
        end
        local rectangle = oracle:rectangle(width, bucket, context.area, 10, 50)
        assert(not not renderer.visible[bucket + 1] == not not rectangle)
        if rectangle then
            local properties = renderer.objects[bucket + 1].properties
            for _, key in ipairs({ "x", "y", "w", "h" }) do
                assert(
                    properties[key] == rectangle[key],
                    "column " .. bucket .. " " .. key .. " differs from the oracle"
                )
            end
        end
    end
    local saved = {}
    for slot = 1, width do
        saved[slot] = { map.low[slot], map.high[slot], map.ends[slot], map.kinds[slot], map.froms[slot] }
    end
    for at = 6000, 50000, 50 do
        history.observer:sample(at, -at)
    end
    assert(#owner.pending == 0 and owner.tail, "offscreen input accumulated an unnecessary backlog")
    renderer:append()
    for slot, previous in ipairs(saved) do
        assert(map.low[slot] == previous[1] and map.high[slot] == previous[2])
        assert(map.ends[slot] == previous[3] and map.kinds[slot] == previous[4], "full chart overwrote old columns")
        assert(map.froms[slot] == previous[5], "full chart overwrote old columns")
    end
    owner:resize(width)
    assert(next(owner.map.kinds) == nil and #owner.pending == 0, "resize replayed history")
    renderer:destroy()
    owner:destroy()
    assert(history.observer == nil)
end
assert(holds > 100, "sparse input must exercise held columns")

local record = recorder(3)
local context = {
    area = { x = 4, y = 10, w = 120, h = 90 },
    rect = { w = 160, h = 120 },
    geometryVersion = 1,
    session = record.session,
    plotRoot = lvgl.box({ x = 0, y = 0, w = 160, h = 120 }),
    series = {},
    columnConsumers = {},
    version = 1,
}
for series = 1, 3 do
    context.series[series] = { color = lcd.RGB(255, 0, 0), low = 0, high = 100 }
    context.columnConsumers[series] = Columns.attach(record.history, record.feeds[series], 120, {
        recording = { history = record.history, session = record.session },
    })
end
local renderer = Renderer.new(context)
record.sample(0, { 10, 20, 30 })
assert(next(context.columnConsumers[1].map.kinds) == nil, "telemetry callback created columns before append")
renderer:append()
local first, set = renderer.objects[1], renderer.objects[1].set
local calls = {}
first.set = function(self, values)
    calls[self] = (calls[self] or 0) + 1
    return set(self, values)
end
for at = 100, 103 do
    record.sample(at, { at - 90, at - 80, at - 70 })
end
renderer:append()
assert(calls[first] == nil, "append redrew a prefix column")
for series, owner in ipairs(context.columnConsumers) do
    local summary = owner.map:summary(2)
    assert(summary.min == series * 10 and summary.max == series * 10 + 3 and summary["end"] == series * 10 + 3)
    assert(#owner.pending == 0 and #owner.map.dirtyList == 0)
    assert(context.series[series].drawnRevision == record.feeds[series].plotRevision)
end
local second = renderer.objects[3]
second.set = first.set
calls = {}
record.sample(104, { 14, 24, 34 })
record.sample(105, { 15, 25, 35 })
renderer:append()
assert(calls[second] == 1, "same-column readings must be summarized before one native draw")
calls = {}
record.sample(4000, { 50, 60, 70 })
renderer:append()
assert(calls[second] == nil, "sparse input redrew previous columns")
for index in pairs(renderer.objects) do
    local bucket = (index - 1) % 120
    assert(bucket <= 3 or bucket == 80, "append allocated empty columns across a time gap")
end
for series, owner in ipairs(context.columnConsumers) do
    local hold = owner.map:summary(3)
    assert(hold.kind == "hold" and hold.width == 77 and hold.min == series * 10 + 5, "skipped columns must hold")
    local jump = owner.map:summary(80)
    assert(jump.kind == "data" and jump.from == series * 10 + 5 and jump.min == series * 10 + 40)
    local rectangle = renderer.objects[(series - 1) * 120 + 4].properties
    assert(rectangle.x == 7 and rectangle.w == 77 and rectangle.h == 1, "a hold must be one rectangle")
end

record.sample(4100, { 0, 0, 0 }, false, false)
record.sample(4200, { 60, 60, 60 }, false, true)
renderer:append()
for _, owner in ipairs(context.columnConsumers) do
    local map = owner.map
    assert(#map.seams == 1)
    local bucket = map:pixel(map.at) // 1
    local resumed, pause = map:summary(bucket), map:summary(bucket - 24)
    assert(resumed.kind == "data" and resumed.width == 1 and resumed.from == nil)
    assert(pause.kind == "pause" and pause.width == 24, "a pause must be one 24-pixel column")
    assert(map:summary(bucket - 1) == nil and not renderer.visible[bucket - 23], "a pause must draw nothing")
end
record.sample(4300, { 0, 0, 0 }, true)
record.sample(4400, { 70, 70, 70 })
renderer:append()
for _, owner in ipairs(context.columnConsumers) do
    assert(owner.map:summary(owner.map:pixel(owner.map.at) // 1).from == nil, "missing data reconnected a trace")
    owner:reset()
end
renderer:sweep(math.huge)
renderer:append()
assert(next(renderer.visible) == nil)
for _, owner in ipairs(context.columnConsumers) do
    assert(next(owner.map.kinds) == nil)
    owner:destroy()
end
renderer:destroy()

local queuedSession = { resumeFirst = 1, resumeLast = 0, resumeRevision = 0 }
local queuedHistory = {}
function queuedHistory:observeSamples() end
function queuedHistory:unobserveSamples() end
function queuedHistory:recordingBreak()
    return 1000
end
local queued = Columns.attach(queuedHistory, { plotRevision = 1 }, 120, {
    recording = { history = queuedHistory, session = queuedSession },
})
queued:sample(0, 10)
queued:sample(1000, 30)
queuedSession.resumeLast, queuedSession.resumeRevision = 1, 1
queued:sample(1000, 50, true, true)
assert(next(queued.map.kinds) == nil)
queued:append()
assert(queued.map:summary(20)["end"] == 30, "queued pre-resume data shifted across the pause gap")
assert(queued.map:summary(44).kind == "data" and queued.map:summary(44).from == nil)
assert(queued.map:summary(21).kind == "pause" and queued.map:summary(21).width == 23, "a pause must follow its prefix")
assert(queued.map.seams[1][1] == 20 and queued.map.seams[1][3] == 44)
queued:destroy()

-- Auto windows: every step is a whole number of fine columns per plot column,
-- and merging fine columns (including halving) equals sampling the window directly.
assert(Columns.autoMinutes(4) == 4 and Columns.autoMinutes(5) == 6 and Columns.autoMinutes(6) == 8)
assert(Columns.autoMinutes(7) == 12 and Columns.autoMinutes(10) == 32)
for step = 1, 12 do
    local factor = Columns.autoMinutes(step) / (1 << Columns.autoLevel(step))
    assert(factor % 1 == 0 and factor >= 1 and factor <= 4)
end
assert(Columns.autoGap(1) == 24 and Columns.autoGap(3) == 8 and Columns.autoGap(8) == 4)
assert(Columns.autoStep(0) == 1 and Columns.autoStep(6000) == 2 and Columns.autoStep(30000) == 5)
for _, step in ipairs({ 2, 3, 4, 5, 6, 7, 8, 10 }) do
    local width, minutes, level = 97, Columns.autoMinutes(step), Columns.autoLevel(step)
    local fine, direct = Columns.fine(width, 0), Columns.new(width, minutes * 6000)
    for at = 0, minutes * 6000 - 1, 37 + step do
        local value = (at * 7) % 113
        if at % 13 == 0 then
            value = nil
        end
        while fine.level < level and (at * width) // fine.window >= width * 3 do
            local coarser = Columns.fine(width, fine.level + 1)
            coarser:absorb(fine, 2, fine.last, math.huge)
            fine = coarser
        end
        fine:sample(at, value)
        direct:sample(at, value)
    end
    while fine.level < level do
        local coarser = Columns.fine(width, fine.level + 1)
        coarser:absorb(fine, 2, fine.last, math.huge)
        fine = coarser
    end
    local merged = Columns.new(width, minutes * 6000)
    merged:absorb(fine, minutes >> level, fine.last, math.huge)
    for bucket = 0, width - 1 do
        local expected, actual = direct:summary(bucket), merged:summary(bucket)
        assert(not expected == not actual, "step " .. step .. " column " .. bucket .. " presence differs")
        if expected then
            for _, key in ipairs({ "kind", "min", "max", "end", "width", "from" }) do
                assert(
                    expected[key] == actual[key],
                    "step " .. step .. " column " .. bucket .. " " .. key .. " differs"
                )
            end
        end
    end
end
-- Dense dropouts keep at most one break per column, in time order, so marker
-- passes read them directly; copying them is staged within the allowance.
do
    local width = 40
    local dense = Columns.new(width, 6000)
    for at = 0, 5990, 10 do
        dense:sample(at, at % 7)
        dense:breakAt(at)
    end
    assert(dense.breakLast <= width + 1 and dense.breakLast >= width, "breaks must be bounded by the plot width")
    for index = 2, dense.breakLast do
        local previous, current = dense.breaks[index - 1], dense.breaks[index]
        assert(current > previous, "breaks must stay in time order")
        assert(math.floor(dense:pixel(current) + 0.5) > math.floor(dense:pixel(previous) + 0.5), "one break per column")
    end
    assert(dense:pixel(dense.breaks[dense.breakLast]) >= width - 1, "the newest break must be kept")
    local target = Columns.new(width, 12000)
    local done, used = target:absorb(dense, 2, -1, 0)
    assert(not done and used == 0 and target.breakLast == 0, "a zero allowance must copy nothing")
    done, used = target:absorb(dense, 2, -1, 40)
    assert(not done and used == 40 and target.breakLast == 1, "one break fits a one-break allowance")
    local turns = 1
    while not done do
        local stage
        done, stage = target:absorb(dense, 2, -1, 200)
        assert(stage <= 200, "break copying must stay within the allowance")
        turns = turns + 1
    end
    assert(turns > 2 and target.breakSource == dense.breakLast + 1, "every break must be copied across turns")
    local last = target.breaks[target.breakLast]
    assert(
        target.breakLast <= width // 2 + 1 and target:pixel(last) >= width // 2 - 1,
        "coarser columns keep one break each"
    )
end
print("Append-only typed columns consume new telemetry, summarize once, hold skipped columns and never replay history")
