-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local host = load("lib/scheduler_host.lua")
    local panelHost = load("lib/panel_host.lua")
    local decl = { class = "normal", stages = { run = { fixed = 0, perUnit = 3130, maxUnits = 1 } } }
    local cases = {}
    for _, size in ipairs({ 1, 4, 16 }) do
        for _, action in ipairs({ "admit", "retire", "legacy", "idle-to-active", "active-to-idle" }) do
            cases[#cases + 1] = {
                stage = "run",
                grant = 1,
                setup = function()
                    local context = { panels = {}, panelHost = panelHost }
                    local scheduling = host.attach(context, {
                        mode = "mixed",
                        load = load,
                        api = {
                            log = function(_, message)
                                error(message)
                            end,
                            error = function() end,
                            show = function() end,
                        },
                    })
                    scheduling.owners, scheduling.panelBounds = { ["panel:sample"] = "new" }, { sample = 0 }
                    local idle = { id = "sample", idle = true }
                    local active = {
                        id = "sample",
                        decl = { class = "normal", stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } } },
                        step = function()
                            return 50
                        end,
                    }
                    for index = 1, size do
                        context.panels[index] = {
                            module = action == "active-to-idle" and active or idle,
                            instance = {},
                            placement = { id = "p" .. index },
                            nextRefresh = 0,
                            interval = 50,
                        }
                    end
                    if action ~= "admit" then
                        assert(scheduling:ready(context))
                        if action == "retire" then
                            context.panels = {}
                        elseif action == "legacy" then
                            scheduling.owners["panel:sample"] = "legacy"
                        elseif action == "idle-to-active" then
                            context.panels[1].module = active
                        else
                            for _, entry in ipairs(context.panels) do
                                entry.module = idle
                            end
                        end
                        context.panelTasksDirty = true
                    end
                    return {
                        step = function()
                            assert(scheduling:ready(context))
                            return 50
                        end,
                    },
                        0
                end,
            }
        end
    end
    return { id = "panel:idle-admission", decl = decl, cases = cases }
end
