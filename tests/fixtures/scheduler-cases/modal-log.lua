-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local viewer = load("lib/log_viewer.lua")
    local logs = load("lib/diagnostics_log.lua")
    local api = load("@support/scheduler_panel_api.lua")
    local stages = {}
    for stage, bound in pairs(viewer.WORK_BOUNDS) do
        if bound > 0 then
            stages[stage] = { fixed = 0, perUnit = bound, maxUnits = 1 }
        end
    end
    stages.open = { fixed = 0, perUnit = 1000, maxUnits = 1 }
    local cases = {}
    for _, shape in ipairs({ { 320, 240 }, { 480, 272 }, { 800, 480 } }) do
        for _, count in ipairs({ 0, 1, 256 }) do
            for _, length in ipairs({ 32, 4096 }) do
                for target in pairs(stages) do
                    cases[#cases + 1] = {
                        stage = target, grant = 1,
                        setup = function()
                            local log = logs.new()
                            local hosts = {}
                            for index = 1, 4 do
                                local host = { panels = {} }
                                for panel = 1, 16 do
                                    host.panels[panel] = {
                                        placement = { type = "host-diagnostics" },
                                        settings = { section = "log", maxEntries = 256 },
                                        instance = {},
                                    }
                                end
                                hosts[index] = host
                                log:register(host)
                            end
                            for index = 1, count do
                                log:append(hosts[1], "log", string.rep("x", length), index * 100)
                            end
                            local host = {
                                zone = { w = shape[1], h = shape[2] },
                                page = api.node(), theme = api.theme,
                                diagnosticsLog = log,
                                themeBuilder = {
                                    fontHeight = function() return 17 end,
                                    measureText = function(_, text) return #text * 10 end,
                                },
                                primitives = { label = api.node },
                            }
                            local fn
                            if target == "open" then
                                fn = viewer.open
                            else
                                api.withApi(viewer.open, host)
                                if target == "snapshot" then
                                    if count > 0 then
                                        while host.logViewer.snapshot.stage == "demand" do
                                            api.withApi(viewer.advance, host)
                                        end
                                    end
                                else
                                    while viewer.stageOf(host.logViewer) ~= target
                                        and viewer.stageOf(host.logViewer) ~= "idle" do
                                        api.withApi(viewer.advance, host)
                                    end
                                end
                                if target == "input" then
                                    while viewer.stageOf(host.logViewer) ~= "idle" do
                                        api.withApi(viewer.advance, host)
                                    end
                                    fn = function(current)
                                        local previous = EVT_ROT_LEFT
                                        EVT_ROT_LEFT = 9001
                                        viewer.handle(current, EVT_ROT_LEFT)
                                        EVT_ROT_LEFT = previous
                                    end
                                else
                                    assert(viewer.stageOf(host.logViewer) == target)
                                    fn = viewer.advance
                                end
                            end
                            local task = { stage = target, want = 1 }
                            function task:step()
                                api.withApi(fn, host)
                                assert(#hosts == 4)
                                return 1
                            end
                            return task, 1000000
                        end,
                    }
                end
            end
        end
    end
    return {
        id = "modal:log",
        decl = { class = "normal", first = "open", kinds = { steady = true }, stages = stages },
        cases = cases,
    }
end
