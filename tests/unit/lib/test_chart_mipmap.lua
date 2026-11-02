-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local mipmap = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/chart_mipmap.lua"))()
local recorder = assert(loadfile(root .. "/tests/support/mipmap_recorder.lua"))(root)
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local function attach(record, width)
    local map = mipmap.new(width)
    record.history:observeSamples(record.feeds[1], map)
    return map
end

-- Reference uses incoming readings, not a reconstruction of compressed knots.
for _, width in ipairs({ 600, 800 }) do
    local record = recorder(1)
    local map = attach(record, width)
    local samples = {}
    for index = 0, 1200 do
        local at, value = index * 5, (index * 37) % 103 / 100
        record.sample(at, { value })
        samples[#samples + 1] = { at, value }
    end
    for level = 0, 10 do
        local summary, expected = map.levels[level], {}
        for _, reading in ipairs(samples) do
            local bucket = (reading[1] * width / summary.span) // 1
            local bounds = expected[bucket]
            if bounds then
                bounds[1], bounds[2] = math.min(bounds[1], reading[2]), math.max(bounds[2], reading[2])
            else
                expected[bucket] = { reading[2], reading[2] }
            end
        end
        local finish = (6000 * width / summary.span) // 1
        for bucket = math.max(0, finish - width + 1), finish do
            local low, high, gap = map:column(level, bucket)
            local bounds = expected[bucket]
            equal(gap, bounds == nil)
            if bounds then
                equal(low, bounds[1])
                equal(high, bounds[2])
            end
        end
        local entries = 0
        for _ in pairs(summary.tags) do
            entries = entries + 1
        end
        assert(entries <= width, "level exceeded its column count")
    end
    local prepared, count = map.levels[1], record.feeds[1].count
    equal(map:select(6000), 1)
    map:releaseBelow(1)
    equal(map.levels[0], nil)
    equal(map.levels[1], prepared)
    equal(record.feeds[1].count, count)
end

-- New values only extend observed extrema: no provisional-line replacements.
local record, map = recorder(1)
map = attach(record, 600)
record.sample(0, { 0 })
record.sample(1, { 0.1 })
record.sample(2, { 0.2 })
local low, high = map:column(0, 0)
equal(low, 0)
equal(high, 0.2)
record.sample(3, { 0.15 })
equal(select(2, map:column(0, 0)), 0.2, "recording finalization must not retract a reading maximum")
record.sample(10, { 0.05 })
equal(select(2, map:column(0, 0)), 0.2, "sealed column changed")
equal(select(1, map:column(0, 1)), 0.05)

-- A long recorder segment and its finalization touch only eleven new columns.
record, map = recorder(1), nil
map = attach(record, 800)
record.sample(0, { 0 })
record.sample(1000000, { 1 })
record.sample(1000001, { -1 })
for level = 0, 10 do
    local summary = map.levels[level]
    local occupied = 0
    for _ in pairs(summary.tags) do
        occupied = occupied + 1
    end
    assert(occupied <= 3, "long elapsed time caused deferred column expansion")
    equal(select(3, map:column(level, 1)), true, "unsampled columns must stay empty")
end

-- Missing telemetry marks the occupied column; resumes in it must stay hidden.
record, map = recorder(1), nil
map = attach(record, 600)
record.sample(0, { 0.2 })
record.sample(5, { 0 }, true)
record.sample(6, { 0.8 })
low, high = map:column(0, 0)
equal(low, high)
equal(select(3, map:column(0, 0)), true)
record.sample(10, { 0.7 })
equal(select(3, map:column(0, 1)), false)
record.sample(11, { 0.7 }, false, false)
record.sample(1000, { 0.1 }, false, true)
equal(select(3, map:column(0, 1)), true, "equal-time resume must not become a spike")

-- The observer sees exactly the recorder's smoothed input, not raw telemetry.
record = recorder(1, { smoothing = "medium" })
map = attach(record, 600)
record.sample(0, { 0 })
record.sample(100, { 1 })
local filtered = 1 - math.exp(-1)
assert(math.abs(select(1, map:column(0, 10)) - filtered) < 1e-12)
equal(record.feeds[1].value, 1, "raw live reading changed")

-- Attaching an observer does not change compression, readings or storage.
local observed, baseline = recorder(1), recorder(1)
map = attach(observed, 600)
for index = 0, 200 do
    local value = ((index * 13) % 29) / 100
    observed.sample(index * 9, { value })
    baseline.sample(index * 9, { value })
end
equal(observed.feeds[1].count, baseline.feeds[1].count)
for index = 1, baseline.feeds[1].last do
    local a, b, c, d = observed.history:point(observed.feeds[1], index)
    local x, y, z, w = baseline.history:point(baseline.feeds[1], index)
    equal(a, x)
    equal(b, y)
    equal(c, z)
    equal(d, w)
end

map:releaseBelow(10)
local span = map.levels[10].span
equal(select(2, map:select(span)), 150)
equal(select(2, map:select(span * 1.24)), 150)
equal(select(2, map:select(span * 1.25)), 300)
local nextIndex = 1
repeat
    nextIndex = observed.history:resetSession(2000, nextIndex)
until not nextIndex
equal(map.level, 0)
equal(map.at, nil)
observed.sample(2100, { 0.6 })
equal(select(1, map:column(0, 0)), 0.6)

-- Invalid events fail explicitly instead of corrupting the hierarchy.
assert(not pcall(map.sample, map, -1, 0))
assert(not pcall(map.sample, map, 0, math.huge))
assert(not pcall(map.releaseBelow, map, 1.5))

-- Full recording freezes summaries too, but live readings continue to update.
record = recorder(1)
map = attach(record, 600)
for index = 0, 6500 do
    record.sample(index, { index % 2 })
    if record.feeds[1].full then
        break
    end
end
assert(record.feeds[1].full, "fixture did not exhaust recorded history")
local frozenAt, frozenRevision = map.at, map.revision
record.sample(7000, { 0.25 })
record.sample(7001, { 0 }, true)
equal(map.at, frozenAt)
equal(map.revision, frozenRevision)
equal(record.feeds[1].value, 0.25)
print("Incoming-reading chart mipmap tests passed")
