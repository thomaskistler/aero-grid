-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local rows = assert(loadfile(root .. "/tests/experiments/chart_mipmap_stress_mock.lua"))(root, 64)
assert(#rows == 4)
for _, row in ipairs(rows) do
    assert(#row.callback_instructions == row.callbacks)
    assert(row.input_events > 0, "a timed operation missed incoming chart readings")
    assert(row.oldest_source_ms < 3000, "heavy recording was starved")
    assert(row.output_columns == 398 and row.native_spans == 398 * 6, "pool must follow actual drawable width")
    if row.operation == "scroll" then
        assert(row.group_moves == 24, "both three-series charts must use four integer parents per series")
    end
end
