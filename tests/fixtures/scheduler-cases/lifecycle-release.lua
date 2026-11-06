-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local scheduler = load("lib/scheduler.lua")
    local host = load("lib/scheduler_host.lua")
    local panelHost = load("lib/panel_host.lua")
    local decl = {
        class = "normal",
        stages = {
            run = { fixed = 0, perUnit = 670, maxUnits = 1 },
            cancel = { fixed = 0, perUnit = 80, maxUnits = 1 },
            service = { fixed = 0, perUnit = 760, maxUnits = 1 },
            panel = { fixed = 0, perUnit = 810, maxUnits = 1 },
        },
    }
    local cases = {}
    for _, class in ipairs({ "critical", "normal" }) do
        for _, size in ipairs({ 1, 8, 32, 128 }) do
            for _, position in ipairs({ 1, math.max(1, size // 2), size }) do
                for _, offset in ipairs({ -100, 0, 100 }) do
                    for _, base in ipairs({ 0, 0x7ffffff0, 0xfffffff0 }) do
                        cases[#cases + 1] = {
                            stage = "run",
                            grant = 1,
                            setup = function()
                                local queue = scheduler.new({ steady = 0 })
                                local queued = {
                                    class = class,
                                    stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
                                }
                                for index = 1, size do
                                    assert(queue:add({
                                        id = index,
                                        decl = queued,
                                        instance = {
                                            step = function()
                                                return 10
                                            end,
                                        },
                                        due = base + index,
                                    }))
                                end
                                return {
                                    step = function()
                                        assert(queue:reschedule(position, base + offset))
                                        return 10
                                    end,
                                },
                                    base
                            end,
                        }
                    end
                end
            end
        end
    end
    for _, target in ipairs({ "service", "panel" }) do
        for _, name in ipairs({ "metric", "navigation", "output" }) do
            for _, position in ipairs({ 1, 64, 128 }) do
                cases[#cases + 1] = {
                    stage = target,
                    grant = 1,
                    setup = function()
                        local context = { panelHost = panelHost }
                        local scheduling = host.attach(context, { mode = "mixed", load = load, api = {} })
                        scheduling.owners = { ["service:reset"] = "new", ["panel:" .. name] = "new" }
                        local queued = {
                            class = "normal",
                            stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
                        }
                        local service = {
                            id = "reset",
                            step = function()
                                return 10
                            end,
                        }
                        for index = 1, 128 do
                            assert(context.scheduler:add({
                                id = index == position and "service:reset" or index,
                                decl = queued,
                                instance = service,
                                due = index,
                            }))
                        end
                        scheduling.registeredTasks["service:reset"] = service
                        local entry = {
                            module = load("panels/" .. name .. ".lua"),
                            placement = { id = "reset" },
                            instance = {
                                refreshWork = { stage = "layout" },
                                pendingDrawn = {},
                                rendered = {},
                                showRows = 32,
                                applyRow = 3,
                            },
                        }
                        scheduling.panelTasks[entry] = { id = "service:reset", stage = "apply" }
                        return {
                            step = function()
                                if target == "service" then
                                    local _, message = scheduling:resetServiceRelease(service, 0, 1)
                                    assert(not message, message)
                                else
                                    assert(not scheduling:resetPanelRelease(entry, 0))
                                end
                                assert(context.scheduler:dueOf("service:reset") == 0)
                                return 10
                            end,
                        },
                            0
                    end,
                }
            end
        end
    end
    for _, name in ipairs({ "metric", "navigation", "output" }) do
        local panel = load("panels/" .. name .. ".lua")
        for _, stage in ipairs({
            false,
            "geometry",
            "layout",
            "render",
            "apply",
            "reading",
            "tape-frame",
            "tape",
        }) do
            cases[#cases + 1] = {
                stage = "cancel",
                grant = 1,
                setup = function()
                    local context = {
                        refreshWork = stage and { stage = stage } or nil,
                        rendered = {},
                        pendingDrawn = stage and {} or nil,
                        captionWork = stage and {} or nil,
                        renderReady = stage or nil,
                        applyRow = stage and 3 or nil,
                    }
                    return {
                        step = function()
                            panel.cancelRefresh(context)
                            return 10
                        end,
                    },
                        0
                end,
            }
        end
    end
    return { id = "host:lifecycle-release", decl = decl, cases = cases }
end
