-- SPDX-License-Identifier: GPL-2.0-only

-- Opt-in opcode attribution. Run with tests/experiments/run_telemetry_cost.py.
local root, baseline = ...
local function load(path)
    local saved = baseline and string.match(path, "lib/(.+)_service%.lua$")
    if baseline and path == "lib/chart_mipmap.lua" then
        return assert(loadfile(root .. "/build/chart_mipmap-baseline.lua"))()
    elseif saved == "history" or saved == "telemetry" then
        return assert(loadfile(root .. "/build/" .. saved .. "_service-baseline.lua"))()
    end
    return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. path))()
end
local support = load("lib/services.lua")
local History, Telemetry, Mipmap =
    load("lib/history_service.lua"), load("lib/telemetry_service.lua"), load("lib/chart_mipmap.lua")
local Control, Armed = load("lib/control_service.lua"), load("lib/armed_service.lua")
local rows = {}
for _, smoothing in ipairs({ "off", "medium" }) do
    for _, copies in ipairs({ 0, 1, 2 }) do
        local now = 0
        local env = support.environment({
            getTime = function()
                return now
            end,
            getSwitchIndex = function()
                return 1
            end,
            getSwitchValue = function()
                return true
            end,
            getRSSI = function()
                return 80
            end,
            getFieldInfo = function(name)
                return { id = tonumber(string.sub(name, 2)), unit = 1 }
            end,
            getValue = function(id)
                return ((now * 17 + id * 13) % 97 + 1) / 100
            end,
            getSensor = function()
                return nil
            end,
            model = {},
        })
        local runtime = support.runtime(env)
        runtime.byId.control = Control.new(env, support)
        runtime.byId.armed = Armed.new(env, support, runtime)
        local telemetry = Telemetry.new(env, support)
        runtime.byId.telemetry = telemetry
        local history = History.new(env, support, runtime)
        local feeds = {}
        for source = 1, 24 do
            feeds[source] =
                history:subscribe("Q" .. source, { armSwitch = "L01", precision = 3, smoothing = smoothing })
            if source <= 6 then
                for _ = 1, copies do
                    Mipmap.attach(history, feeds[source], 398)
                end
            end
        end
        local function step(cap)
            now = now + 15
            local state = runtime.byId.control.entries[1].state
            state.available, state.fresh, state.value, state.updatedAt = true, true, true, now
            telemetry.pollCap = cap
            telemetry:update(now)
        end
        for _ = 1, 80 do
            step(8)
        end
        for _, cap in ipairs({ 4, 8 }) do
            local counts = {}
            debug.sethook(function()
                local info = debug.getinfo(2, "S")
                local key = info.source .. ":" .. info.linedefined
                counts[key] = (counts[key] or 0) + 1
            end, "", 1)
            for _ = 1, 24 do
                step(cap)
            end
            debug.sethook()
            rows[#rows + 1] = { smoothing = smoothing, copies = copies, cap = cap, updates = 24, counts = counts }
        end
    end
end
return rows
