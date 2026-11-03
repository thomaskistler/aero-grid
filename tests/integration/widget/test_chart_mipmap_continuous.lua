-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local run = assert(loadfile(root .. "/tests/experiments/chart_feasibility.lua"))
local rows = run(root, "combined", true, {
    {
        charts = 2,
        series = 3,
        points = 800,
        chunk = 1,
        sample_ticks = 5,
        continuous = true,
        operations = { "horizontal", "vertical", "scroll", "resize" },
    },
})
assert(#rows == 4)
for _, row in ipairs(rows) do
    assert(row.submitted > 0)
end
print("Continuous competing-chart geometry checks passed")
