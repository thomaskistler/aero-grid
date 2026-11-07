-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local ui = load("lib/editor_ui.lua")
    local grid = load("lib/grid.lua")
    local editor = load("lib/editor.lua")
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local function stageName(stage)
        return stage == 6 and "finish" or "rows" .. (stage - 1)
    end
    local cases = {}
    for _, count in ipairs({ 0, 1, 4, 8, 15, 16 }) do
        for _, width in ipairs({ 320, 480, 800 }) do
            for target = 2, 6 do
                for _, changed in ipairs({ false, true }) do
                    cases[#cases + 1] = {
                        stage = stageName(target), grant = 1,
                        setup = function()
                            local panels, entries = {}, {}
                            for index = 1, count do
                                panels[index] = {
                                    id = "metric-" .. index, type = "metric",
                                    col = (index - 1) % 4, row = math.floor((index - 1) / 4),
                                    colSpan = 1, rowSpan = 1,
                                }
                                if index % 2 == 0 then
                                    entries[#entries + 1] = { placement = panels[index] }
                                end
                            end
                            local context = {
                                root = api.node(), page = api.node(), path = "/WIDGETS/AeroGrid/",
                                zone = { w = width, h = width == 800 and 480 or 272 },
                                grid = grid, panels = entries, theme = api.theme,
                                primitives = primitives, themeBuilder = builder,
                                editorDrawerModule = { close = function() end },
                            }
                            local state = api.withApi(ui.open, context,
                                { draft = { panels = panels }, selected = 1, grid = grid }, {
                                    editor = editor,
                                    preview = function() return true end,
                                    logError = function(_, message) error(message) end,
                                })
                            for _ = 1, 15 do
                                api.withApi(ui.advance, context)
                            end
                            state.renderStage, state.renderChanged = target, changed
                            if changed then
                                for _, control in ipairs(state.controls) do
                                    control.placement = nil
                                end
                            end
                            local task = { stage = stageName(target), want = 1 }
                            function task:step()
                                api.withApi(ui.advance, context)
                                return 1
                            end
                            return task, 1000000
                        end,
                    }
                end
            end
        end
    end
    local stages = {}
    for stage = 2, 6 do
        stages[stageName(stage)] = {
            fixed = 0, perUnit = ui.renderWorkBound({ renderStage = stage, session = {} }), maxUnits = 1,
        }
    end
    return {
        id = "editor:render",
        decl = { class = "normal", first = "rows1", kinds = { steady = true }, stages = stages },
        cases = cases,
    }
end
