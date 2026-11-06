-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local chart = load("panels/chart.lua")
    local panelHost = load("lib/panel_host.lua")
    local services = load("lib/services.lua")
    local historyService = load("lib/history_service.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local module = { decl = chart.traceDecl, step = chart.traceStep, stageOf = chart.traceStageOf }
    local function setup(mode, remaining, cursor)
        return function(seed)
            local context = api.withApi(function()
                local now = 0
                local runtime = services.runtime(services.environment({
                    getTime = function()
                        return now
                    end,
                }))
                local arm =
                    { key = "SAv", configured = true, available = true, fresh = true, value = true, updatedAt = 0 }
                runtime.byId.armed = {
                    state = function()
                        return arm
                    end,
                }
                runtime.byId.telemetry = {
                    subscribe = function()
                        return {}
                    end,
                    observe = function() end,
                }
                local history = historyService.new(runtime.env, services, runtime)
                local settings = assert(panelHost.resolveSettings(chart, {
                    armSwitch = "SAv",
                    duration = "30s",
                    timeRange = "rolling",
                    metrics = { { source = "Q1" }, { source = "Q2" }, { source = "Q3" } },
                }))
                local panel = chart.create(api.node(), { x = 0, y = 0, w = 800, h = 480 }, settings, {
                    theme = api.theme,
                    themeBuilder = builder,
                    primitives = primitives,
                    history = history,
                    state = function(state, accent)
                        return builder.state(api.theme, state, accent)
                    end,
                })
                for index = 1, mode == "seek" and 512 or 256 do
                    now, arm.updatedAt = index * 10, index * 10
                    history:advance(now)
                    for series = 1, 3 do
                        history:sample({
                            name = "Q" .. series,
                            value = index % 2 == 0 and index * seed or -index * seed,
                            kind = "number",
                            fresh = index % 13 ~= 0,
                            updatedAt = now,
                            precision = 0,
                            unitText = "V",
                        }, now)
                    end
                end
                chart.render(panel)
                chart.ranges(panel)
                if mode == "block" then
                    panel.window = 60000
                end
                panel.start = math.max(0, panel.session.elapsed - panel.window)
                if mode == "axis" then
                    local breaks = { 400, 800, 1200, 1600 }
                    panel.axis = {
                        breaks = breaks,
                        start = 0,
                        x = panel.area.x,
                        gap = 24,
                        scale = (panel.area.w - #breaks * 24) / panel.window,
                    }
                end
                if mode == "trace-last" then
                    for index = 1, 2 do
                        local item = panel.series[index]
                        item.drawnVersion, item.drawnRevision = panel.version, item.feed.plotRevision
                        item.drawnLow, item.drawnHigh = item.low, item.high
                    end
                    return panel
                end
                chart.traceStep(panel, 1, "trace")
                local item, job = panel.pending, panel.pending.job
                assert(job.last > job.index, "the native fixture must contain recorded history")
                for _ = 1, cursor or 0 do
                    chart.traceStep(panel, 1, "project")
                end
                assert(chart.traceStageOf(panel) == "project", "cursor stimulus must still need projection")
                if mode == "tail" or mode == "apply" or mode == "connector" or mode == "marker" then
                    job.index = job.last + 1
                    local run = item.runs[1]
                    run.size, run.column = 2, nil
                    run.pts[1], run.pts[2] = { 0, 0 }, { 40, 20 }
                    for index = 3, 4096 do
                        run.pts[index] = { index, 0 }
                    end
                    if mode ~= "tail" then
                        chart.traceStep(panel, 1, "project")
                        for index = #run.pts, (remaining or 0) + 3, -1 do
                            run.pts[index] = nil
                        end
                        if mode == "connector" then
                            run.dotted, run.dotIndex, run.dotCount = true, 1, nil
                        elseif mode == "marker" then
                            item.runCount, item.applyIndex, item.markerPhase, item.markerIndex = 0, 2, "show", 1
                            job.markerColumns, job.marked = { 20 }, { [20] = true }
                        end
                    end
                elseif mode == "expired" then
                    job.index, job.last = job.last + 1, job.last + 2
                end
                return panel
            end)
            local task = panelHost.task({ module = module, instance = context, interval = 10 })
            local step = task.step
            task.step = function(self, grant, stage, now)
                return api.withApi(step, self, grant, stage, now)
            end
            return task, 1000000
        end
    end
    local cases = { { stage = "trace", grant = 1, setup = setup("trace-last") } }
    for grant = 1, 2 do
        for _, mode in ipairs({ "project", "seek", "axis", "tail", "expired" }) do
            cases[#cases + 1] = { stage = "project", grant = grant, setup = setup(mode) }
        end
        for cursor = 0, 31 do
            cases[#cases + 1] = {
                stage = "project",
                grant = grant,
                setup = setup("block", nil, cursor),
            }
        end
    end
    for _, remaining in ipairs({ 0, 128, 4094 }) do
        cases[#cases + 1] = { stage = "apply", grant = 1, setup = setup("apply", remaining) }
    end
    cases[#cases + 1] = { stage = "apply", grant = 1, setup = setup("connector") }
    cases[#cases + 1] = { stage = "apply", grant = 1, setup = setup("marker") }
    return { id = "panel:chart:traces", decl = chart.traceDecl, cases = cases }
end
