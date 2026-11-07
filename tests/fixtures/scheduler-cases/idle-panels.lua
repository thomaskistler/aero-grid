-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local host = load("lib/scheduler_host.lua")
    local panelHost = load("lib/panel_host.lua")
    local decl = { class = "normal", first = "admit", stages = {} }
    local cases = {}
    for _, size in ipairs({ 1, 4, 16 }) do
        for _, action in ipairs({ "admit", "retire", "legacy", "idle-to-active", "active-to-idle" }) do
            decl.stages[action] = {
                fixed = 0,
                perUnit = action == "idle-to-active" and host.PANEL_ENROLL_COST or host.RECONCILE_COST,
                maxUnits = 1,
            }
            cases[#cases + 1] = {
                stage = action,
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
                    local function untilReady(predicate)
                        for _ = 1, 256 do
                            if predicate(scheduling.reconciliation) then
                                return
                            end
                            assert(scheduling:ready(context))
                        end
                        error("idle panel readiness did not reach its target")
                    end
                    if action ~= "admit" then
                        untilReady(function()
                            return scheduling.checked == context.panels
                                and not scheduling.reconciliation
                                and not scheduling.pendingPanels
                        end)
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
                    if action == "idle-to-active" then
                        untilReady(function()
                            return not context.panelTasksDirty
                                and not scheduling.reconciliation
                                and scheduling.pendingPanels ~= nil
                        end)
                    else
                        untilReady(function(job)
                            return job and job.phase == (action == "retire" and "retire-panels" or "panels")
                        end)
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
