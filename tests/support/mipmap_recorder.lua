-- SPDX-License-Identifier: GPL-2.0-only

-- Real history service with deterministic inputs; no telemetry/storage substitute.
local root, load = ...
load = load or function(path)
    return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. path))()
end
local support = load("lib/services.lua")
local historyModule = load("lib/history_service.lua")
local armedModule = load("lib/armed_service.lua")
local controlModule = load("lib/control_service.lua")

return function(count, options)
    local clock = 0
    local env = support.environment({
        getTime = function()
            return clock
        end,
        getSwitchIndex = function()
            return 1
        end,
        getSwitchValue = function()
            return true
        end,
        model = {},
    })
    local runtime = support.runtime(env)
    runtime.byId.control = controlModule.new(env, support)
    runtime.byId.armed = armedModule.new(env, support, runtime)
    local history = historyModule.new(env, support, runtime)
    local feeds = {}
    for index = 1, count do
        feeds[index] = history:subscribe("Mipmap" .. index, {
            armSwitch = "L01",
            precision = 3,
            smoothing = options and options.smoothing,
        })
    end
    local reading = { fresh = true, kind = "number", precision = 3, unitText = "V" }
    local function sample(at, values, missing, armed)
        assert(at % 1 == 0, "recorder timestamps must be integer ticks")
        clock = at
        local state = runtime.byId.control.entries[1].state
        state.available, state.fresh, state.value, state.updatedAt = true, true, armed ~= false, at
        for index = 1, count do
            reading.name, reading.value, reading.updatedAt = feeds[index].name, values[index], at
            reading.fresh = not missing
            history:sample(reading, at)
        end
        history:update(at)
    end
    return { history = history, feeds = feeds, sample = sample, session = history:session("L01") }
end
