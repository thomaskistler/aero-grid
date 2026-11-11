-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local Columns = fixture.module("lib/chart_columns.lua")
local Renderer = fixture.module("lib/chart_columns_renderer.lua")
local recorder = assert(loadfile(root .. "/tests/support/chart_recorder.lua"))(root)
local Oracle = assert(loadfile(root .. "/tests/support/chart_column_oracle.lua"))()
fixture.reset()

for _, width in ipairs({ 60, 226, 397, 800 }) do
    local map, oracle = Columns.new(width), Oracle.new()
    for at = 0, 5999, 5 do
        local value = at % 71
        if at % 113 == 0 then
            value = nil
        end
        map:sample(at, value)
        oracle:sample(at, value)
    end
    for bucket = 0, width - 1 do
        local expected, actual = oracle:summary(width, bucket), map:summary(bucket)
        assert(not expected == not actual)
        if expected then
            assert(actual.kind == expected.kind and actual.min == expected.min and actual.max == expected.max)
            assert(actual["end"] == expected.finish and actual.width == expected.width and actual.from == expected.from)
        end
    end
    local geometry = {
        area = { x = 4, y = 10, w = width, h = 90 },
        rect = { w = width + 20, h = 120 },
        geometryVersion = 1,
        version = 1,
        session = { elapsed = 5999 },
        plotRoot = lvgl.box({ x = 0, y = 0, w = width + 20, h = 120 }),
        series = { { color = lcd.RGB(255, 0, 0), low = 10, high = 50 } },
        columnConsumers = { { map = map } },
    }
    local projected = Renderer.new(geometry)
    while not projected:prepare(2000) do
    end
    for turn = 1, 2000 do
        if projected:step(2000) then
            break
        end
        assert(turn < 2000, "fixed geometry did not converge")
    end
    for bucket = 0, width - 1 do
        local expected = oracle:summary(width, bucket)
        local populated = expected and expected.kind ~= "missing"
        assert(not not projected.visible[bucket + 1] == not not populated)
        if populated then
            local actual = projected.objects[bucket + 1].properties
            local top = math.max(10, math.min(100, math.floor(100 - (expected.max - 10) * 90 / 40 + 0.5)))
            local bottom = math.max(10, math.min(100, math.floor(100 - (expected.min - 10) * 90 / 40 + 0.5)))
            assert(actual.x == 4 + bucket and actual.y == top and actual.h == bottom - top + 1)
            local points = oracle:connection(width, bucket, geometry.area, 10, 50)
            assert(not not projected.connected[bucket + 1] == not not points)
            if points then
                local actualPoints = projected.connections[bucket + 1].properties.pts
                for index = 1, 2 do
                    assert(actualPoints[index][1] == points[index][1] and actualPoints[index][2] == points[index][2])
                end
            end
        end
    end
    projected:destroy()
    local saved = {}
    for slot = 1, width do
        saved[slot] = { map.low[slot], map.high[slot], map.ends[slot], map.tags[slot] }
    end

    do
        local points, feed = {}, { count = 20, first = 1, last = 20, plotRevision = 1 }
        local history = {}
        function history:point(_, index)
            local point = points[index]
            return point[1], point[2]
        end
        function history:observeSamples(_, observer)
            self.observer = observer
        end
        function history:unobserveSamples()
            self.observer = nil
        end
        local baseline = Columns.new(120)
        for index = 1, 20 do
            points[index] = { index * 10, index % 7 }
            baseline:sample(points[index][1], points[index][2])
        end
        local live = Columns.attach(history, feed, 120)
        for turn = 1, 300 do
            local at, value = 200 + turn * 10, turn % 11
            history.observer:sample(at, value)
            baseline:sample(at, value)
            local complete, used = live:step(1400)
            assert(used <= 1400)
            if complete then
                break
            end
        end
        assert(live.complete, "incoming samples starved historical reconstruction")
        for bucket = 0, 119 do
            local expected, actual = baseline:summary(bucket), live.map:summary(bucket)
            assert(not expected == not actual)
            if expected then
                assert(expected.min == actual.min and expected.max == actual.max and expected["end"] == actual["end"])
                assert(expected.width == actual.width and expected.from == actual.from)
            end
        end
        live:destroy()
        assert(history.observer == nil)
    end
    for at = 6000, 50000, 50 do
        map:sample(at, -at)
    end
    for slot, previous in ipairs(saved) do
        assert(map.low[slot] == previous[1] and map.high[slot] == previous[2])
        assert(map.ends[slot] == previous[3] and map.tags[slot] == previous[4], "full chart overwrote old columns")
    end
    assert(map.levels == nil and map.lastLevel == nil and map.tags[width + 1] == nil)
end

local record = recorder(1)
local owner = Columns.attach(record.history, record.feeds[1], 120, {
    recording = { history = record.history, session = record.session },
})
local points = { { 0, 10 }, { 100, 30 }, { 200, 20 }, { 300, 40 } }
for _, point in ipairs(points) do
    record.sample(point[1], { point[2] })
end
local rebuilt = Columns.attach(record.history, record.feeds[1], 120, {
    recording = { history = record.history, session = record.session },
    preview = true,
})
for _ = 1, 100 do
    local complete, used = rebuilt:step(1400)
    assert(used <= 1400)
    if complete then
        break
    end
end
assert(rebuilt.complete)
for slot = 1, 120 do
    assert(owner.map.low[slot] == rebuilt.map.low[slot] and owner.map.high[slot] == rebuilt.map.high[slot])
    assert(owner.map.ends[slot] == rebuilt.map.ends[slot] and owner.map.widths[slot] == rebuilt.map.widths[slot])
end

local context = {
    area = { x = 4, y = 10, w = 120, h = 90 },
    rect = { w = 160, h = 120 },
    geometryVersion = 1,
    session = record.session,
    plotRoot = lvgl.box({ x = 0, y = 0, w = 160, h = 120 }),
    series = { { color = lcd.RGB(255, 0, 0), low = 0, high = 100 } },
    columnConsumers = { owner },
    version = 1,
}
local renderer = Renderer.new(context)
while not renderer:prepare(2000) do
end
local function settle()
    for _ = 1, 1000 do
        local complete, used = renderer:step(2000)
        assert(used <= 2000)
        if complete then
            return
        end
    end
    error("fixed-column projection did not converge")
end
settle()
local rootObject, first = renderer.root, renderer.objects[1]
local original = { x = first.properties.x, y = first.properties.y, h = first.properties.h }
local calls, set = 0, first.set
first.set = function(self, values)
    if self == first then
        calls = calls + 1
    end
    return set(self, values)
end
record.sample(400, { 50 })
settle()
assert(calls == 0, "append redrew a prefix column")
assert(renderer.root == rootObject and renderer.spare == nil)
assert(first.properties.x == original.x and first.properties.y == original.y and first.properties.h == original.h)
assert(#renderer.objects == 120 and #renderer.connections == 120)
local incoming = renderer.connections[9].properties.pts
assert(incoming[1][1] == 10 and incoming[2][1] == 12, "connection must span from the previous endpoint")
assert(incoming[1][2] == 64 and incoming[2][2] == 55)

record.sample(500, { 0 }, false, false)
record.sample(600, { 60 }, false, true)
settle()
assert(#owner.map.seams == 1, "resume must retain its dotted connector")
local resumed = owner.map:summary(owner.map:pixel(owner.map.at) // 1)
assert(resumed.kind == "break" and resumed.width == 24 and resumed.from == nil)
record.sample(700, { 60 }, true)
record.sample(800, { 70 })
settle()
assert(owner.map:summary(owner.map:pixel(owner.map.at) // 1).from == nil, "missing data reconnected a trace")
assert(#owner.map.seams == 1)
owner:reset()
renderer:reset()
settle()
assert(next(owner.map.tags) == nil)
renderer:destroy()
owner:destroy()
rebuilt:destroy()
print("Fixed pixel columns preserve summaries, geometry, gaps, prefix appends and right-edge data")
