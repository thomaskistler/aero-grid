-- SPDX-License-Identifier: GPL-2.0-only

-- Binds instruction estimates to AeroGrid modules loaded outside the widget's
-- module loader. tests/run.py runs this before each suite, which makes every
-- `loadfile` of a widget module bind it. The native audit (`native` true)
-- copies it to /WIDGETS/AeroGrid/audit/ and binds its few direct loads itself.

local root, native = ...
local load = native and loadScript or loadfile
local base = native and "/WIDGETS/AeroGrid/" or root .. "/src/WIDGETS/AeroGrid/"
local costs = assert(load(base .. "lib/costs.lua"))().new(assert(load(base .. "lib/instruction_snapshot.lua"))())
if native then
    return costs
end

local originalLoadfile = loadfile
function loadfile(filename, ...)
    local chunk, message = originalLoadfile(filename, ...)
    local relative = chunk and type(filename) == "string" and string.match(filename, "WIDGETS/AeroGrid/(.+%.lua)$")
    if not relative then
        return chunk, message
    end
    return function(...)
        local results = table.pack(chunk(...))
        costs:bind(relative, results[1])
        return table.unpack(results, 1, results.n)
    end
end

return costs
