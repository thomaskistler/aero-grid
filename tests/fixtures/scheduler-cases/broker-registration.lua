-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local host, panelHost = load("lib/scheduler_host.lua"), load("lib/panel_host.lua")
    local declaration = { class = "normal", stages = { run = { fixed = 0, perUnit = 3690, maxUnits = 1 } } }
    local cases = {}
    for _, size in ipairs({ 0, 16 }) do
        for _, action in ipairs({ "enroll", "registry-gap", "partial", "facade", "disable" }) do
            cases[#cases + 1] = {
                stage = "run",
                grant = 1,
                setup = function()
                    local source = { id = "flight", count = 1, interval = 20, schedulerTasks = {} }
                    for index, name in ipairs({ "flight", "smart" }) do
                        source.schedulerTasks[index] = {
                            id = "service:" .. name,
                            instance = {
                                decl = {
                                    class = "normal",
                                    stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
                                },
                                interval = index * 20,
                                want = 1,
                                step = function()
                                    return 20
                                end,
                            },
                        }
                    end
                    local enabled = true
                    local context = { panels = {}, panelHost = panelHost, serviceRuntime = { order = {}, byId = {} } }
                    context.flightFactory = {
                        broker = {
                            schedulerService = function()
                                return enabled and source or nil
                            end,
                        },
                    }
                    for index = 1, size do
                        context.panels[index] = {
                            placement = { id = "p" .. index },
                            module = { id = "sample", idle = true },
                            instance = {},
                        }
                    end
                    local scheduling = host.attach(context, {
                        mode = "mixed",
                        load = load,
                        api = {
                            log = function(_, message)
                                error(message)
                            end,
                        },
                    })
                    scheduling.owners = {
                        ["service:flight"] = "new",
                        ["service:smart"] = "new",
                        ["panel:sample"] = "new",
                    }
                    local function ready()
                        local previous = getTime
                        getTime = function()
                            return 0
                        end
                        local ok, result = pcall(scheduling.ready, scheduling, context)
                        getTime = previous
                        assert(ok, result)
                        return assert(result)
                    end
                    if action ~= "enroll" then
                        ready()
                        context.serviceRuntime = { order = {}, byId = {} }
                        if action == "registry-gap" then
                            context.serviceRuntime = nil
                        elseif action == "facade" then
                            context.serviceRuntime.order[1] =
                                { id = "flight", count = 1, schedulerTasks = source.schedulerTasks }
                        elseif action == "disable" then
                            enabled = false
                        end
                    end
                    return {
                        step = function()
                            ready()
                            return 1
                        end,
                    },
                        0
                end,
            }
        end
    end
    return { id = "host:broker-registration", decl = declaration, cases = cases }
end
