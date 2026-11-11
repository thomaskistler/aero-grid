-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local mipmap = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/chart_mipmap.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local points = { { 0, 0 }, { 1000, 10 }, { 1100, 20, true }, { 2000, 30 } }
local feed = { first = 1, last = #points, count = #points, plotRevision = 1 }
local history = {}
function history:point(_, index)
    return table.unpack(points[index])
end
local owner = mipmap.attach(history, feed, 60)
local callbacks = 0
while not owner:step() do
    callbacks = callbacks + 1
    assert(callbacks < 500)
end
assert(owner.complete and owner.readonly)
local low, high, gap = owner.map:column(0, 5)
equal(low, 5)
equal(high, 6)
equal(gap, false, "stored linear segments must fill intervening columns")
low, high, gap = owner.map:column(0, 10)
equal(low, 10)
equal(high, 10)
equal(gap, false)
low, high, gap = owner.map:column(0, 11)
equal(low, 20)
assert(high > low)
equal(gap, false, "a broken knot starts a new segment without connecting the gap")

local axis = { start = 0, scale = 0.018, gap = 24, breaks = { 1000 }, window = 2000 }
points[3] = { 1000, 20, true, true }
feed.plotRevision = 2
callbacks = 0
while not owner:view(axis, 1) do
    callbacks = callbacks + 1
    assert(callbacks < 500)
end
equal(owner.output.connectors[1][1], 18)
equal(owner.output.connectors[1][3], 42)
for bucket = 19, 41 do
    local _, _, hidden = owner.output:column(0, bucket)
    assert(hidden, "a recording seam must not receive solid interpolation")
end

local rolling = mipmap.new(60, 3000)
equal(rolling.lastLevel, 0)
rolling:sample(8000, 1)
local level, origin = rolling:select(8000)
equal(level, 0)
assert(origin % 15 == 0 and origin > 0)
equal(rolling.levels[0].span, 3000)
owner:destroy()

local recorder = assert(loadfile(root .. "/tests/support/mipmap_recorder.lua"))(root)
local record = recorder(1)
for at = 0, 16000, 20 do
    record.sample(at, { (at * 17) % 97 / 100 })
end
local recordedFeed = record.feeds[1]
local scalar = {}
function scalar:point(_, index, first)
    return record.history:point(recordedFeed, index, first)
end
local fast = mipmap.attach(record.history, recordedFeed, 60)
local reference = mipmap.attach(scalar, recordedFeed, 60)
for _, target in ipairs({ fast, reference }) do
    callbacks = 0
    while not target:step() do
        callbacks = callbacks + 1
        assert(callbacks < 3000)
    end
end
local selected, offset = fast.map:select(fast.map.at)
equal(selected, reference.map.level)
for bucket = offset, offset + 59 do
    local a, b, c = fast.map:column(selected, bucket)
    local x, y, z = reference.map:column(selected, bucket)
    equal(c, z, "sealed-block reconstruction must preserve scalar knot gaps")
    if not c then
        assert(
            math.abs(a - x) < 0.000001 and math.abs(b - y) < 0.000001,
            "sealed-block extrema must match the independent scalar reconstruction"
        )
    end
end
fast:destroy()
reference:destroy()

local busy = recorder(1, { timeRange = "rolling", windowSeconds = 300 })
for at = 0, 40000, 5 do
    busy.sample(at, { (at // 5) % 2 })
end
local busyFeed = busy.feeds[1]
local missing = 0
local moving = {}
function moving:point(_, index, first)
    local at, value, broken, resumed = busy.history:point(busyFeed, index, first)
    if at == nil then
        missing = missing + 1
    end
    return at, value, broken, resumed
end
function moving:observeSamples(_, target)
    busy.history:observeSamples(busyFeed, target)
end
function moving:unobserveSamples(_, target)
    busy.history:unobserveSamples(busyFeed, target)
end
local rebuilding = mipmap.attach(moving, busyFeed, 60, { window = 30000 })
local at = 40000
for _ = 1, 200 do
    at = at + 5
    busy.sample(at, { (at // 5) % 2 })
end
callbacks = 0
while not rebuilding:step(2000) do
    callbacks = callbacks + 1
    assert(callbacks < 3000, "reconstruction failed to progress while retained history advanced")
    for _ = 1, 4 do
        at = at + 5
        busy.sample(at, { (at // 5) % 2 })
    end
end
assert(missing > 0 and rebuilding.complete, "test must exercise an overwritten reconstruction prefix")
rebuilding:destroy()
print("ok - mipmap reconstructs recorded knots and rolling windows")
