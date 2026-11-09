-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local Mipmap = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/chart_mipmap.lua"))()
for _, width in ipairs({ 226, 398, 399, 800 }) do
    local map = Mipmap.new(width)
    for _, at in ipairs({ 0, 5999, 6000, 80000, 1000000 }) do
        map:sample(at, at)
        for level = 0, Mipmap.LAST_LEVEL do
            local bucket = (at * width / map.levels[level].span) // 1
            local low, high, gap = map:column(level, bucket)
            assert(not gap and low <= at and high == at, "bucket quantization changed")
        end
    end
end

-- On float32, replacing multiply-then-divide with a cached reciprocal moves
-- this event to the preceding bucket. Keep the original arithmetic order.
local map = Mipmap.new(226)
local span = map.levels[2].span
if string.packsize("n") == 4 then
    assert((80000 * 226 / span) // 1 ~= (80000 * (226 / span)) // 1)
end
map:sample(80000, 0.25)
local low, high, gap = map:column(2, (80000 * 226 / span) // 1)
assert(not gap and low == 0.25 and high == 0.25)
print("Mipmap quantization preserves multiply-then-divide on float32 and float64")
