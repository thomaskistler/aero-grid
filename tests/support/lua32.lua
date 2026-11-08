-- SPDX-License-Identifier: GPL-2.0-only

-- Runs one suite under the int32 Lua interpreter with the same setup as tests/run.py.
local file, root, candidate = ...
if candidate then
    assert(math.maxinteger == 2147483647 and 16777217.0 - 16777216.0 == 0,
        "candidate memory check requires 32-bit integers and floats")
    local originalLoadfile = loadfile
    function loadfile(filename, ...)
        if type(filename) == "string" and string.match(filename, "/lib/instruction_snapshot%.lua$") then
            filename = candidate
        end
        return originalLoadfile(filename, ...)
    end
end
assert(loadfile(root .. "/tests/support/costs.lua"))(root)
assert(loadfile(file))(root)
