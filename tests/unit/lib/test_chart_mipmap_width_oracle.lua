-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local mipmap = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/chart_mipmap.lua"))()
local Oracle = assert(loadfile(root .. "/tests/support/mipmap_reading_oracle.lua"))()
local recorder = assert(loadfile(root .. "/tests/support/mipmap_recorder.lua"))(root)

for _, width in ipairs({ 226, 397, 398, 399, 400 }) do
    local map, oracle = mipmap.new(width), Oracle.new()
    for index = 0, 1700 do
        local at = index * 79
        local value = index % 23 ~= 7 and (index * 37 % 103) / 100 or nil
        local broken = index % 71 == 0
        map:sample(at, value, broken)
        oracle:sample(at, value, broken)
    end
    for level = 0, 10 do
        local finish = (map.at * width / map.levels[level].span) // 1
        for bucket = finish - width, finish do
            local low, high, gap = map:column(level, bucket)
            local expectedLow, expectedHigh, expectedGap = oracle:column(width, level, bucket)
            assert(gap == expectedGap, "physical-column gap differs from independent readings")
            if not gap then
                assert(low == expectedLow and high == expectedHigh, "physical-column extrema differ")
            end
        end
    end
    local span = map.levels[10].span
    for quarter = 0, 12 do
        local _, origin = map:select(span + quarter * span / 4 + 0.001)
        assert(origin == math.floor((quarter + 1) * width / 4), "scroll origin must be an integer pixel")
    end
end

-- A real break inside a physical column poisons that column, not unrelated data.
local map, oracle = mipmap.new(398), Oracle.new()
for _, event in ipairs({ { 0, 0.1 }, { 1, 0.9 }, { 2, false }, { 3, 0.5 }, { 16, 0.7 } }) do
    local value = event[2] ~= false and event[2] or nil
    map:sample(event[1], value)
    oracle:sample(event[1], value)
end
assert(select(3, oracle:column(398, 0, 0)), "in-column resume must not fill a real telemetry break")
assert(select(3, map:column(0, 0)), "screen map lost the break")
assert(not select(3, oracle:column(398, 0, 1)), "next column must resume")

-- Screen resolution is independent of the authoritative recorder and other consumers.
local observed, baseline = recorder(1), recorder(1)
local screen, detail = mipmap.new(398), mipmap.new(800)
observed.history:observeSamples(observed.feeds[1], screen)
observed.history:observeSamples(observed.feeds[1], detail)
for index = 0, 500 do
    local value = index * 13 % 29 / 100
    observed.sample(index * 9, { value })
    baseline.sample(index * 9, { value })
end
screen:releaseBelow(1)
assert(detail.level == 0 and detail.width == 800, "screen retirement affected another consumer")
assert(observed.feeds[1].count == baseline.feeds[1].count, "screen width changed recording")
for index = 1, baseline.feeds[1].last do
    local a, b, c, d = observed.history:point(observed.feeds[1], index)
    local x, y, z, w = baseline.history:point(baseline.feeds[1], index)
    assert(a == x and b == y and c == z and d == w, "recorded history changed")
end
print("Physical-width envelopes match independent readings and preserve shared recording")
