-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
assert(loadfile(root .. "/tests/integration/widget/test_chart_recording.lua"))(root, false, false, true)
