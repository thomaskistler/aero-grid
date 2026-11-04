-- SPDX-License-Identifier: GPL-2.0-only
-- Stand-in widget for the framework measurements: installed as main.lua in an
-- isolated simulator SD image, where its refresh callback runs the measurements.

local measure = assert(loadScript("/WIDGETS/AeroGrid/audit/framework.lua"))()

return {
    name = "AeroGrid",
    options = {
        { "Layout", CHOICE, 1, { "capture-panels" } },
        { "Theme", CHOICE, 1, { "Modern Dark", "Modern Light" } },
    },
    create = function(zone)
        return { zone = zone }
    end,
    update = function() end,
    refresh = function()
        measure()
    end,
    background = function() end,
}
