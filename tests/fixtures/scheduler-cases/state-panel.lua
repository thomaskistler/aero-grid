-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local panel = load("panels/state.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local function setup(shape, count, variant)
        return function(seed)
            local theme = {}
            for key, value in pairs(api.theme) do
                theme[key] = value
            end
            theme.light = seed % 2 == 0
            theme.alertRgb = { warning = 0x705020, critical = 0x702020 }
            theme.alertColor = { warning = 0x705020, critical = 0x702020 }
            local entries, states = {}, {}
            for index = 1, count do
                local name = "S" .. string.char(64 + index)
                entries[index] = {
                    label = "STATE" .. index,
                    states = {
                        { switch = name .. "^", text = "UP", background = "active" },
                        { switch = name .. "-", text = "MID", background = "warning" },
                        { switch = name .. "v", text = "DOWN", background = "critical" },
                    },
                }
                for _, condition in ipairs(entries[index].states) do
                    states[condition.switch] = { known = true, available = true, fresh = true, value = variant == 7 }
                end
            end
            if variant == 8 then
                entries[1].states[1].text = string.rep("W", seed * 820)
            end
            local settings = assert(host.resolveSettings(panel, { entries = entries }))
            local context = api.withApi(
                panel.create,
                api.node(),
                { x = 0, y = 0, w = shape[3], h = shape[4] },
                settings,
                {
                    theme = theme,
                    themeBuilder = builder,
                    primitives = primitives,
                    fonts = builder.typography(shape[1], shape[2]),
                    control = {
                        displaySwitch = function(_, name)
                            return support.snapshot(states[name])
                        end,
                    },
                    state = function(name, accent)
                        return builder.state(theme, name, accent)
                    end,
                }
            )
            if variant <= 3 or variant == 8 then
                local selected = variant <= 3 and variant or 1
                for _, entry in ipairs(entries) do
                    states[entry.states[selected].switch].value = true
                end
            elseif variant <= 6 then
                for _, state in pairs(states) do
                    state[variant == 4 and "known" or variant == 5 and "available" or "fresh"] = false
                end
            elseif variant == 7 or variant == 9 then
                for _, state in pairs(states) do
                    state.value = variant == 9
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
        for count = 1, 3 do
            for variant = 1, 10 do
                cases[#cases + 1] = { stage = "run", grant = 1, setup = setup(shape, count, variant) }
            end
        end
    end
    return { id = "panel:state", decl = panel.decl, cases = cases }
end
