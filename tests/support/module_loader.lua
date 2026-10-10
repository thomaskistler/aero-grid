-- SPDX-License-Identifier: GPL-2.0-only

local root = ...
local base = root .. "/src/WIDGETS/AeroGrid/"

--- Load a runtime module with its explicit composition dependencies.
--- Each call creates fresh module state, matching the widget's ownership.
---@param relative string
---@return table
local function loadModule(relative)
    local chunk = assert(loadfile(base .. relative))
    if relative == "lib/theme.lua" then
        return chunk(loadModule("lib/typography.lua"), loadModule("lib/panel_layout.lua"))
    end
    if relative == "lib/primitives.lua" then
        return chunk(loadModule("lib/reading.lua"))
    end
    return chunk()
end

return loadModule
