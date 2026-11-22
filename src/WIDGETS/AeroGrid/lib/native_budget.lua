-- SPDX-License-Identifier: GPL-2.0-only

--- Native callback budget: the one place that knows how EdgeTX enforces its
--- per-callback instruction limit. The scheduler stays firmware-agnostic.

local nativeBudget = {}

--- Burns VM instructions until EdgeTX's per-callback CPU limit raises an error.
--- Only the instruction count matters, so the body is cheap register moves
--- spread between loop instructions. The iteration count is a safety cap for
--- firmware that never raises the limit.
local function burn()
    local a, b = 0, 0
    for _ = 1, 3000 do
        a = b
        b = a
        a = b
        b = a
        a = b
        b = a
        a = b
        b = a
        a = b
        b = a
    end
end

--- Run `work` past EdgeTX's per-callback instruction limit.
--- The limit's error is raised from inside the firmware hook, and an `xpcall`
--- message handler runs at the point of the error with hooks still disabled, so
--- work done there is not counted. If the burn finishes without the limit
--- firing (simulator, debug builds, tests) nothing enforces it and `work` runs
--- directly. `work` is called under `pcall`.
---@param work fun()
---@return boolean ok `work` ran and did not fail.
---@return any result Failure message, or the burn error when the limit was not usable.
function nativeBudget.cross(work)
    local ok, result
    local finished, failure = xpcall(burn, function(message)
        if type(message) == "string" and string.find(message, "CPU limit", 1, true) then
            ok, result = pcall(work)
        end
        return message
    end)
    if ok == nil then
        if finished then
            ok, result = pcall(work)
        else
            return false, failure
        end
    end
    return ok, result
end

return nativeBudget
