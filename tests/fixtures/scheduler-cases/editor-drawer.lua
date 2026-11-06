-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local drawer = load("lib/editor_drawer.lua")
    local api = load("@support/scheduler_panel_api.lua")
    local variants = {
        { key = "heading", type = "section", label = "Heading" },
        { key = "enabled", type = "boolean", label = "Enabled" },
        { key = "number", type = "number", label = "Number", value = 12.5, step = 0.1, empty = "Auto" },
        { key = "number", type = "number", label = "Bounded", value = 12, within = { "low", "high" } },
        { key = "name", type = "string", label = "Name", value = "Label" },
        { key = "mode", choices = { "a", "b" }, label = "Mode", value = "b" },
        { key = "source", type = "string", label = "Source", value = "" },
        { key = "switch", type = "string", label = "Switch", value = "" },
        { key = "timer", type = "number", label = "Timer", value = 0 },
        { key = "remove", action = "remove", label = "Remove" },
    }
    local cases = {}
    for _, count in ipairs({ 0, 16, 128 }) do
        for _, width in ipairs({ 320, 480, 800 }) do
            for _, stage in ipairs({ "build", "layout", "finish" }) do
                local fields = stage == "build" and variants or { variants[1] }
                for _, variant in ipairs(fields) do
                    cases[#cases + 1] = {
                        stage = stage, grant = 1,
                        setup = function(seed)
                            local config = { enabled = true, low = 1, high = 20 }
                            local field = {}
                            for key, value in pairs(variant) do field[key] = value end
                            local state = {
                                drawerBuild = 1, drawerFields = { field }, drawerControls = {},
                                drawerBuildConfig = config,
                                drawerGeneration = 1, drawerPadding = 2,
                                drawerWidth = width, drawerNextY = 4,
                                drawerControlHeight = 32, drawerRowHeight = 36, drawerErrorHeight = 18,
                                nativeDrawer = api.node(),
                                session = { selected = 1, draft = { panels = { { config = config } } } },
                                handlers = { editor = {
                                    settings = function() error("construction must reuse its frozen configuration") end,
                                } },
                            }
                            if stage ~= "build" then
                                state.drawerBuild = 2
                                for index = 1, count do
                                    state.drawerControls[index] = {
                                        row = api.node(), errorLabel = api.node(), height = 36,
                                        errorShown = seed % 2 == 0,
                                        field = { visibleWhen = { key = "enabled", value = index % 2 == 0 } },
                                    }
                                end
                                if stage == "layout" then state.drawerLayout = 1 end
                            end
                            local context = { theme = api.theme, themeBuilder = { fontHeight = function() return 17 end } }
                            local task = { stage = stage, want = 1 }
                            function task:step()
                                local previous = {}
                                for _, key in ipairs({ "getSourceIndex", "getSourceName", "getSwitchIndex", "getSwitchName", "getFieldInfo" }) do
                                    previous[key] = _G[key]
                                    _G[key] = function() return 1 end
                                end
                                local ok, message = pcall(api.withApi, drawer.advance, context, state)
                                for _, key in ipairs({ "getSourceIndex", "getSourceName", "getSwitchIndex", "getSwitchName", "getFieldInfo" }) do
                                    _G[key] = previous[key]
                                end
                                assert(ok, message)
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
    for stage, bound in pairs(drawer.WORK_BOUNDS) do
        stages[stage] = { fixed = 0, perUnit = bound, maxUnits = 1 }
    end
    return {
        id = "editor:drawer",
        decl = { class = "normal", first = "build", kinds = { steady = true }, stages = stages },
        cases = cases,
    }
end
