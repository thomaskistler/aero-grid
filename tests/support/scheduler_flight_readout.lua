-- SPDX-License-Identifier: GPL-2.0-only

return function(load, id)
    local panel = load("panels/" .. id .. ".lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local function setup(rect, span, detail, variant)
        return function(seed)
            local theme = {}
            for key, value in pairs(api.theme) do
                theme[key] = value
            end
            theme.alertColor = { warning = 0x705020, critical = 0x702020 }
            local state = {
                available = true,
                name = "NORMAL",
                index = 0,
                raw = 12,
                value = 100,
                countdown = true,
                start = 100,
                remaining = 100,
                elapsed = 0,
            }
            local flight = { active = false }
            local view = support.snapshot(state)
            local config = {}
            if id == "flight-mode" then
                config.showIndex = detail
            elseif id == "flight-timer" then
                config.warning, config.critical = 20, 10
                if variant == 7 then
                    config.label = string.rep("W", seed * 820)
                end
            end
            local settings = assert(host.resolveSettings(panel, config))
            local context = api.withApi(panel.create, api.node(), rect, settings, {
                theme = theme,
                themeBuilder = builder,
                primitives = primitives,
                fonts = builder.typography(span.colSpan, span.rowSpan),
                span = span,
                clock = function()
                    return 100
                end,
                model = {
                    widestFlightModeName = function()
                        return "MMMMMMMMMM"
                    end,
                    flightMode = function()
                        return view
                    end,
                    timer = function()
                        return view
                    end,
                },
                control = {
                    globalVariable = function()
                        return view
                    end,
                },
                flight = {
                    state = function()
                        return flight
                    end,
                },
                armed = {
                    state = function()
                        return {}
                    end,
                },
                state = function(name, accent)
                    return builder.state(theme, name, accent)
                end,
            })
            if variant == 2 then
                state.name, state.index = "WWWWWWWWWW", seed
                state.raw, state.value, state.remaining, state.elapsed = -seed * 98765, -seed * 98765, 0, seed * 98765
                state.expired = true
                flight.active = true
            elseif variant == 3 then
                state.available = false
            elseif variant == 4 or variant == 5 then
                state.raw, state.name, state.index = seed * 120, "FM" .. seed, seed
                state.remaining = variant == 4 and 15 or 5
                state.value, state.elapsed = state.remaining, 100 - state.remaining
            elseif variant == 6 then
                state.name, state.index, state.raw = "", seed, seed * 987
                state.countdown, state.showElapsed, state.elapsed = false, true, seed * 3601
            elseif variant == 7 then
                state.name, state.raw, state.value = "RENAMED", seed * 1000, seed * 9999
            elseif variant == 8 and id ~= "flight-counter" then
                context.feed = nil
            elseif variant == 9 then
                state.raw, state.index, state.name = 0, seed, "ACRO"
                state.available, state.expired = false, true
                flight.active = true
            end
            local task = host.task({ module = panel, instance = context, interval = panel.refreshInterval })
            local step = task.step
            function task:step(grant, stage, now)
                return api.withApi(step, self, grant, stage, now)
            end
            return task, 1000000
        end
    end
    local cases = {}
    for _, shape in ipairs({
        { 1, 1, 117, 65 },
        { 2, 2, 238, 134 },
        { 4, 1, 800, 90 },
        { 1, 4, 160, 480 },
        { 4, 4, 800, 480 },
    }) do
        local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
        local span = { colSpan = shape[1], rowSpan = shape[2] }
        for _, detail in ipairs(id == "flight-mode" and { false, true } or { false }) do
            for variant = 1, 9 do
                if variant ~= 8 or id ~= "flight-counter" then
                    cases[#cases + 1] = { stage = "run", grant = 1, setup = setup(rect, span, detail, variant) }
                end
            end
        end
    end
    return { id = "panel:" .. id, decl = panel.decl, cases = cases }
end
