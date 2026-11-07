-- SPDX-License-Identifier: GPL-2.0-only

-- Runs one suite under the int32 Lua interpreter with the same setup as tests/run.py.
local file, root = ...
assert(loadfile(root .. "/tests/support/costs.lua"))(root)
assert(loadfile(file))(root)
