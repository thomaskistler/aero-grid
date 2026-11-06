-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local chart = load("panels/chart.lua")
    local panelHost = load("lib/panel_host.lua")
    local api = load("@support/scheduler_panel_api.lua")
    local create = load("@support/scheduler_chart_fixture.lua")(load)
    local function setup(target, mode, grant, cursor, rect)
        return function(seed)
            local panel = api.withApi(function()
                local context = create(seed, {
                    boundaries = true,
                    longText = true,
                    largeValues = true,
                    rect = rect,
                })
                context.legendWidth = 0
                local reached = false
                for turn = 1, 20000 do
                    local stage, want = chart.stageOf(context)
                    if stage == target and (mode ~= "cached" or turn > 1 and not context.framePhase) then
                        reached = true
                        break
                    end
                    chart.step(context, want, stage)
                end
                assert(reached, "frame setup did not reach " .. target)
                if mode == "layout-final" then
                    for _ = 1, 20 do
                        if chart.stageOf(context) == "layout" and context.readingWork.geometry then
                            break
                        end
                        local stage, want = chart.stageOf(context)
                        chart.step(context, want, stage)
                    end
                    assert(chart.stageOf(context) == "layout" and context.readingWork.geometry)
                elseif mode == "axis-final" then
                    assert((context.frameSession.resumeLast or 0) > 1, "the case needs recorded resume boundaries")
                    chart.step(context, 1, "axis")
                    assert(context.axisWork, "first scan must leave axis work")
                    local work = context.axisWork
                    local count = math.min(context.frameSession.resumeLast, math.max(1, context.area.w // 48))
                    work.reverse = {}
                    for index = 1, count - (grant > 1 and 1 or 0) do
                        work.reverse[index] = context.history:recordingBreak(
                            context.liveSession,
                            context.frameSession.resumeLast - index + 1
                        )
                    end
                    work.index = grant > 1 and context.frameSession.resumeFirst or 0
                elseif mode == "marker-show" or mode == "marker-final" then
                    local pool = target == "arms" and context.armMarkers or context.resumeMarkers
                    for _ = 1, 1000 do
                        if pool.markerPhase == "show" then
                            break
                        end
                        chart.step(context, 1, target)
                        assert(chart.stageOf(context) == target, "marker case must not finish early")
                    end
                    assert(pool.job and #pool.job.markerColumns > 0, "marker case needs drawable boundaries")
                    if mode == "marker-final" then
                        pool.markerIndex = #pool.job.markerColumns + 1
                    end
                elseif mode == "cursor" then
                    if target == "font" then
                        context.readingWork.geometry.index = cursor
                    elseif target == "readings" or target == "position" then
                        while (context.readingWork and context.readingWork.index or 1) < cursor do
                            chart.step(context, 1, target)
                        end
                    else
                        for _ = 1, cursor do
                            chart.step(context, 1, target)
                            assert(chart.stageOf(context) == target, "cursor must still need " .. target)
                        end
                    end
                elseif mode == "retire" then
                    local run = assert(context.pending.runs[1])
                    for index = #run.pts + 1, 4096 do
                        run.pts[index] = { index, 0 }
                    end
                    context.pending.applyIndex = 1
                elseif mode == "header" then
                    context.headerGeometry = nil
                elseif mode == "expired" then
                    local job = context.pending.job
                    job.index, job.last = job.last + 1, job.last + 2
                end
                return context
            end)
            local task = panelHost.task({ module = chart, instance = panel, interval = 10 })
            local step = task.step
            task.step = function(self, units, stage, now)
                return api.withApi(step, self, units, stage, now)
            end
            return task, 1000000
        end
    end
    local cases = {}
    for stage, declaration in pairs(chart.decl.stages) do
        for grant = 1, declaration.maxUnits do
            cases[#cases + 1] = { stage = stage, grant = grant, setup = setup(stage, nil, grant) }
            if stage == "axis" then
                cases[#cases + 1] = { stage = stage, grant = grant, setup = setup(stage, "axis-final", grant) }
                for _, mode in ipairs({ "cursor", "axis-final" }) do
                    cases[#cases + 1] = {
                        stage = stage,
                        grant = grant,
                        setup = setup(stage, mode, grant, 0, { x = 0, y = 0, w = 800, h = 180 }),
                    }
                end
            end
        end
    end
    cases[#cases + 1] = { stage = "frame", grant = 1, setup = setup("frame", "cached", 1) }
    cases[#cases + 1] = { stage = "layout", grant = 1, setup = setup("layout", "layout-final", 1) }
    cases[#cases + 1] = { stage = "plot", grant = 1, setup = setup("plot", "header", 1) }
    cases[#cases + 1] = { stage = "apply", grant = 1, setup = setup("apply", "retire", 1) }
    for _, rect in ipairs({
        { x = 0, y = 0, w = 800, h = 480 },
        { x = 0, y = 0, w = 800, h = 180 },
        { x = 0, y = 0, w = 160, h = 90 },
    }) do
        for _, stage in ipairs({ "readings", "font", "position" }) do
            for cursor = 1, 3 do
                cases[#cases + 1] = { stage = stage, grant = 1, setup = setup(stage, "cursor", 1, cursor, rect) }
            end
        end
    end
    for grant = 1, 2 do
        cases[#cases + 1] = { stage = "project", grant = grant, setup = setup("project", "expired", grant) }
        for cursor = 0, 31 do
            cases[#cases + 1] = { stage = "project", grant = grant, setup = setup("project", "cursor", grant, cursor) }
        end
    end
    for _, stage in ipairs({ "arms", "resumes" }) do
        for _, mode in ipairs({ "marker-show", "marker-final" }) do
            cases[#cases + 1] = { stage = stage, grant = 1, setup = setup(stage, mode, 1) }
        end
    end
    return { id = "panel:chart", decl = chart.decl, cases = cases }
end
