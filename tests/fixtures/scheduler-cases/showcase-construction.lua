-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local showcase = load("panels/theme-showcase.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local decl = { class = "normal", first = "begin", stages = {} }
    local bounds = {
        begin = 140,
        frame = 500,
        swatches = 200,
        type = 750,
        bars = 360,
        dial = 190,
        cards = 750,
        reflow = 2120,
        place = 450,
        publish = 130,
        ["restart-place"] = 130,
        ["restart-publish"] = 130,
    }
    for stage, bound in pairs(bounds) do
        decl.stages[stage] = { fixed = 0, perUnit = bound, maxUnits = 1 }
    end
    local cases = {}
    for _, light in ipairs({ false, true }) do
        for _, shape in ipairs({ { 480, 272 }, { 800, 480 }, { 212, 90 } }) do
            for stage in pairs(bounds) do
                local restart = stage == "restart-place" or stage == "restart-publish"
                local target = restart and string.sub(stage, 9) or stage
                local count = stage == "swatches" and 14
                    or stage == "bars" and 4
                    or (stage == "cards" or stage == "place") and 6
                    or 1
                for index = 1, count do
                    cases[#cases + 1] = {
                        stage = stage,
                        grant = 1,
                        setup = function()
                            local theme = {}
                            for key, value in pairs(api.theme) do
                                if type(value) == "table" then
                                    theme[key] = {}
                                    for field, item in pairs(value) do
                                        theme[key][field] = item
                                    end
                                else
                                    theme[key] = value
                                end
                            end
                            theme.label, theme.light = light and "Modern Light" or "Modern Dark", light
                            theme.spacing.gutter = 4
                            for _, token in ipairs({ "canvas", "surfaceRaised", "track", "blue", "orange" }) do
                                theme.color[token] = light and 0xEEEEEE or 0x223344
                            end
                            theme.alertColor = { active = 0x335577, warning = 0x554433, critical = 0x663333 }
                            local dependencies = {
                                theme = theme,
                                themeBuilder = builder,
                                primitives = primitives,
                                staged = true,
                                state = function(state, accent)
                                    return builder.state(theme, state, accent)
                                end,
                            }
                            local rect = { x = 0, y = 0, w = shape[1], h = shape[2] }
                            local context = api.withApi(showcase.create, api.node(), rect, {}, dependencies)
                            if target ~= "begin" then
                                for _ = 1, 36 do
                                    if context.createStage == target and context.createIndex == index then
                                        break
                                    end
                                    assert(not api.withApi(showcase.construct, context, rect))
                                end
                                assert(context.createStage == target and context.createIndex == index)
                            end
                            if restart then
                                rect = { x = 1, y = 2, w = rect.w + 20, h = rect.h + 30 }
                            end
                            return {
                                step = function()
                                    if stage == "begin" then
                                        api.withApi(showcase.create, api.node(), rect, {}, dependencies)
                                    else
                                        api.withApi(showcase.construct, context, rect)
                                    end
                                    return 1
                                end,
                            },
                                0
                        end,
                    }
                end
            end
        end
    end
    return { id = "load:theme-showcase", decl = decl, cases = cases }
end
