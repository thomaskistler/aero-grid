-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local paths = assert(loadfile(root .. "/tests/support/scheduler_path_witness.lua"))()
paths(scheduler, function(s, used) s:run("steady", 0, used) end)
print("Framework witnesses: rounded shared-cost skips and reinsertions passed")
