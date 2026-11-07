-- SPDX-License-Identifier: GPL-2.0-only

--- The telemetry mixes and the other declared tasks of plans/scheduler-framework.md
--- section 4, as declarations and periodic releases. Shared by the simulator tests
--- and the framework overhead measurement.

local mixes = {}

local function once(class, bound, extra)
    local decl = { class = class, stages = { run = { fixed = 0, perUnit = bound, maxUnits = 1 } } }
    for key, value in pairs(extra or {}) do
        decl[key] = value
    end
    return decl
end
mixes.once = once

--- A telemetry task polls up to `batch` sources of one interval; a recorded
--- source costs 1180 (k = 1), an unrecorded one 420, and the link state 560 is
--- charged once per plan.
local function telemetry(batch, unit)
    return {
        class = "critical",
        shared = { link = 560 },
        stages = { run = { fixed = 0, perUnit = unit, maxUnits = batch } },
    }
end

mixes.HISTORY = once("critical", 650)
mixes.CONTROL_CRITICAL = {
    class = "critical",
    stages = { run = { fixed = 200, perUnit = 100, maxUnits = 6 } },
}
mixes.CONTROL_NORMAL = {
    class = "normal",
    stages = { run = { fixed = 130, perUnit = 240, maxUnits = 6 } },
}
mixes.CONTROL_OUTPUTS = {
    class = "normal",
    stages = { run = { fixed = 120, perUnit = 60, maxUnits = 32 } },
}
mixes.PANEL = once("normal", 1800)
mixes.CHART = {
    class = "normal",
    exclusive = true,
    kinds = { steady = true },
    first = "begin",
    stages = {
        begin = { fixed = 0, perUnit = 1300, maxUnits = 1 },
        project = { fixed = 200, perUnit = 830, maxUnits = 9 },
        apply = { fixed = 0, perUnit = 1300, maxUnits = 1 },
    },
}
mixes.NEXT_CHART_STAGE = { begin = "project", project = "apply", apply = "begin" }

--- Sources by mix: `recorded` and `unrecorded` counts at one `interval` (ticks).
mixes.MIXES = {
    A = { recorded = 8, interval = 25 },
    B = { recorded = 8, interval = 100 },
    C = { recorded = 4, unrecorded = 4, interval = 20 },
    D = { recorded = 8, interval = 10 },
}

--- The critical releases of a mix in registration order, `{ decl, interval, units }`.
--- Recorded sources are grouped `batch` per task, unrecorded ones form one batch
--- task; history and control follow.
function mixes.releases(mix, batch)
    local list = {}
    local function sources(count, unit)
        while count > 0 do
            local size = math.min(batch, count)
            list[#list + 1] = { decl = telemetry(batch, unit), interval = mix.interval, units = size }
            count = count - size
        end
    end
    sources(mix.recorded or 0, 1180)
    local cheap = mix.unrecorded or 0
    if cheap > 0 then
        list[#list + 1] = { decl = telemetry(cheap, 420), interval = mix.interval, units = cheap }
    end
    list[#list + 1] = { decl = mixes.HISTORY, interval = 5 }
    list[#list + 1] = { decl = mixes.CONTROL_CRITICAL, interval = 20, units = 6 }
    return list
end

return mixes
