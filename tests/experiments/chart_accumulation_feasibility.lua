-- SPDX-License-Identifier: GPL-2.0-only

local worst, previous, rows = 0, 0, {}
local buckets = 468
local levels = {}
for index = 0, 10 do
    levels[index + 1] = { width = 6000 * (4 / 3) ^ index / buckets, bucket = 0 }
end
for sample = 1, 2000 do
    local at, value = sample * 10, sample % 2 == 0 and 1 or -1
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    for _, level in ipairs(levels) do
        local cursor = previous
        while cursor < at do
            local boundary = (level.bucket + 1) * level.width
            local finish = math.min(at, boundary)
            local fraction = (finish - previous) / (at - previous)
            local endpoint = -value + fraction * (2 * value)
            level.low = math.min(level.low or -value, endpoint)
            level.high = math.max(level.high or -value, endpoint)
            level.last = endpoint
            cursor = finish
            if finish == boundary then
                level.bucket = level.bucket + 1
                level.low, level.high = endpoint, endpoint
            end
        end
    end
    debug.sethook()
    worst = math.max(worst, instructions)
    previous = at
end
rows.worst = worst
print(
    string.format(
        "ACCUMULATION levels=11 bucket_count=%d samples=2000 worst_instructions_per_segment=%d"
            .. " (extrema/crossings only; excludes prepared paths, breaks, storage and host work)",
        buckets,
        worst
    )
)
return rows
