-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local panel = load("panels/tx-battery.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local function setup(shape, visual, percent, variant)
        return function(seed)
            local theme = {}
            for key, value in pairs(api.theme) do
                theme[key] = value
            end
            theme.light = seed % 2 == 0
            theme.alertRgb = { warning = 0x705020, critical = 0x702020 }
            theme.alertColor = { warning = 0x705020, critical = 0x702020 }
            local reading = { available = true, value = 7.4, stale = false }
            local range = { available = variant ~= 8, empty = 6.4, full = 8.4 }
            local config = { visual = visual, showPercent = percent, warning = 6.5, critical = 6.0 }
            if variant == 10 then
                config.packEmpty, config.packFull = 6.4, 8.4
            end
            local settings = assert(host.resolveSettings(panel, config))
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
                    span = { colSpan = shape[1], rowSpan = shape[2] },
                    model = {
                        txVoltage = function()
                            return support.snapshot(reading)
                        end,
                        batteryRange = function()
                            return support.snapshot(range)
                        end,
                    },
                    state = function(name, accent)
                        return builder.state(theme, name, accent)
                    end,
                }
            )
            if variant == 2 then
                reading.value = seed * 9.876
                context.readingAnchor, context.detailAnchor = nil, nil
            elseif variant == 3 then
                reading.available = false
            elseif variant == 4 then
                reading.stale = true
            elseif variant == 5 or variant == 6 then
                reading.value = variant == 5 and 6.3 or 5.8
            elseif variant == 7 or variant == 10 then
                range.available = false
            elseif variant == 8 then
                range.available = true
                reading.value = 6.4 + seed / 5
            elseif variant == 9 then
                range.full = range.empty
            elseif variant == 11 then
                context.feed = nil
            elseif variant == 12 then
                context.range = nil
            elseif variant == 13 then
                context.rendered, context.readingAnchor, context.detailAnchor = nil, nil, nil
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
        for _, visual in ipairs({ "battery", "bar", "none" }) do
            for _, percent in ipairs({ false, true }) do
                for variant = 1, 13 do
                    cases[#cases + 1] = {
                        stage = "run",
                        grant = 1,
                        setup = setup(shape, visual, percent, variant),
                    }
                end
            end
        end
    end
    return { id = "panel:tx-battery", decl = panel.decl, cases = cases }
end
