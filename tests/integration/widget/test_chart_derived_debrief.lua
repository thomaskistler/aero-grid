-- SPDX-License-Identifier: GPL-2.0-only

-- Eight three-series charts in a layout that has never had a debrief: the
-- derived debrief records beside the charts within the callback budget.
local root = assert(...)
assert(loadfile(root .. "/tests/integration/widget/test_chart_recording.lua"))(root, false, true, false, true)
