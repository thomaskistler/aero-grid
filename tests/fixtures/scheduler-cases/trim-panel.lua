-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local panel = load("panels/trim-panel.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local function setup(shape, readout, variant)
        return function(seed)
            local states = {}
            local settings = assert(host.resolveSettings(panel, { readout = readout }))
            local context = api.withApi(
                panel.create,
                api.node(),
                { x = 0, y = 0, w = shape[3], h = shape[4] },
                settings,
                {
                    theme = api.theme,
                    themeBuilder = builder,
                    primitives = primitives,
                    fonts = builder.typography(shape[1], shape[2]),
                    control = {
                        trim = function(_, name)
                            states[name] = { available = true, fraction = 0, value = 0, raw = 0, centered = true }
                            return support.snapshot(states[name])
                        end,
                    },
                    state = function(name, accent)
                        return builder.state(api.theme, name, accent)
                    end,
                }
            )
            for index, name in ipairs({ settings.trim1, settings.trim2, settings.trim4 }) do
                local state = states[name]
                local direction = index % 2 == 0 and -1 or 1
                if variant == 2 or variant == 3 then
                    state.fraction = direction * (variant == 2 and seed / 5 or 1)
                    state.value = state.fraction * (variant == 2 and 128 or 512)
                    state.raw, state.centered = state.value * 8, false
                elseif variant == 4 or variant == 5 then
                    state.threePosition, state.centered = true, variant == 5
                    state.fraction = variant == 5 and 0 or direction
                    state.raw = state.fraction * 1024
                elseif variant == 6 or variant == 7 then
                    state.available = variant == 7 and index == 2
                elseif variant == 8 then
                    context.indicators[index].feed = nil
                elseif variant == 9 then
                    state.fraction, state.value, state.raw, state.centered =
                        direction * 0.125, direction * 16, direction * 128, false
                    context.area.groupOffset = nil
                end
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
        for _, readout in ipairs({ "percent", "raw", "none" }) do
            for variant = 1, 9 do
                cases[#cases + 1] = { stage = "run", grant = 1, setup = setup(shape, readout, variant) }
            end
        end
    end
    return { id = "panel:trim-panel", decl = panel.decl, cases = cases }
end
