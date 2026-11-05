-- SPDX-License-Identifier: GPL-2.0-only

-- Loads the widget's `main.lua` with the development scheduler host switched on.
-- The mode and the probe are constants of that file (a release can only ship
-- `legacy` and `false`), so a test overrides them in the text it loads.
local root = (... and ... ~= "" and ...) or "."
local hostIo = io

local file = assert(hostIo.open(root .. "/src/WIDGETS/AeroGrid/main.lua", "r"))
local source = file:read("a")
file:close()

--- Returns the widget definition (`create`, `refresh`, `background`, ...).
---@param mode "legacy"|"mixed"|"new"
---@param probe? boolean
---@return table
return function(mode, probe)
    local text, modes =
        string.gsub(source, 'local SCHEDULER_MODE = "legacy"', 'local SCHEDULER_MODE = "' .. mode .. '"')
    local probes
    text, probes =
        string.gsub(text, "local SCHEDULER_PROBE = false", "local SCHEDULER_PROBE = " .. tostring(probe or false))
    assert(modes == 1 and probes == 1, "main.lua no longer declares the scheduler constants")
    return assert(load(text, "@main.lua"))()
end
