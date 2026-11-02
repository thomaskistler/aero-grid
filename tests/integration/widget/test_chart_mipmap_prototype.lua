-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local run = assert(loadfile(root .. "/tests/experiments/chart_feasibility.lua"))
local rows = run(root, "combined", true, { { charts = 1, series = 3, points = 800, chunk = 1, sample_ticks = 5 } })
assert(#rows == 5, "prototype must exercise all operations")
for _, row in ipairs(rows) do
    assert(row.submitted > 0, "incoming-reading prototype did not submit any columns")
    assert(row.pool_objects == 2401, "prototype must retain one native pool, not two")
end
assert(rows[2].submitted >= 1750, "dense warm-up must exercise occupied columns across all three series")
assert(rows[4].shifted >= 1750, "scroll must reuse the retained three-quarter window")

-- Repeated quarter shifts recycle native slots, preserve resized geometry,
-- handle fractional origins and never show stale/gap columns.
for _, width in ipairs({ 240, 226 }) do
    rows = run(root, "combined", true, {
        {
            charts = 1,
            series = 2,
            points = width,
            chunk = 1,
            sample_ticks = 5,
            scroll_gaps = true,
            operations = { "append", "vertical", "scroll", "resize", "scroll", "scroll", "scroll", "scroll" },
        },
    })
    for _, row in ipairs(rows) do
        if row.operation == "scroll" then
            assert(row.shifted > 0, "scroll did not reuse native column heights")
            assert(row.turns <= 2, "small two-series scroll exceeded two callbacks")
            assert(row.ms < 500, "small two-series scroll exceeded latency limit")
        end
    end
end
-- The experiment checks gap visibility and every final native span against the
-- hierarchy. Its performance gate may fail; do not turn failed gates into passes.
print("Incoming-reading chart prototype geometry checks passed")
