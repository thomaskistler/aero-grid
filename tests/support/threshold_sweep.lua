-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local level = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/telemetry_service.lua"))().level
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

--- Assert a registered threshold judges values just below, at, and just above
--- each limit exactly as the panel's live state does.
---@param spec table Registered threshold.
---@param live fun(value: number): string Panel state for a reading.
---@param step number Smallest difference the sensor reports.
---@param label string
return function(spec, live, step, label)
    assert(type(spec) == "table", label .. ": nothing was registered")
    local limits = {}
    limits[#limits + 1] = spec.warning
    limits[#limits + 1] = spec.critical
    assert(#limits > 0, label .. ": a registration without thresholds")
    for _, limit in ipairs(limits) do
        for _, value in ipairs({ limit - step, limit, limit + step }) do
            local state = live(value)
            if state ~= "warning" and state ~= "critical" then
                state = "normal"
            end
            assertEqual(level(spec, value), state, label .. " at " .. tostring(value))
        end
    end
end
