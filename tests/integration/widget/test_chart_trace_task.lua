-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
local panelHost = fixture.module("lib/panel_host.lua")
local dashboard = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" })
local reference = assert(fixture.instanceOf(dashboard, "power"))
local metrics, feeds, points = {}, {}, {}
for index = 1, 3 do
    metrics[index] = { source = "Q" .. index }
    feeds[index] = {
        available = true,
        first = 1,
        last = 70,
        value = 40,
        min = -100,
        max = 100,
        revision = 1,
        plotRevision = 1,
        precision = 0,
        unitText = "V",
        id = index,
    }
    points[index] = {}
    for sample = 1, 70 do
        points[index][sample] = {
            sample * 10,
            sample % 2 == 0 and sample or -sample,
            sample % 11 == 0 or sample % 19 == 0,
            sample % 19 == 0,
        }
    end
end
local settings = assert(panelHost.resolveSettings(chart, {
    armSwitch = "SAv",
    duration = "30s",
    metrics = metrics,
}))
local function create()
    local cursor = 0
    local panel = chart.create(
        lvgl.box({ x = 0, y = 0, w = 800, h = 480 }),
        {
            x = 0,
            y = 0,
            w = 800,
            h = 480,
        },
        settings,
        {
            theme = reference.theme,
            themeBuilder = reference.themeBuilder,
            primitives = reference.primitives,
            state = function(state, accent)
                return reference.themeBuilder.state(reference.theme, state, accent)
            end,
            history = {
                session = function()
                    return {
                        configured = true,
                        available = true,
                        recording = true,
                        elapsed = 700,
                        armFirst = 1,
                        armLast = 0,
                        resumeFirst = 1,
                        resumeLast = 0,
                        flightLast = 0,
                    }
                end,
                subscribe = function()
                    cursor = cursor + 1
                    return feeds[cursor]
                end,
                point = function(_, feed, index)
                    local point = points[feed.id][index]
                    if point then
                        return table.unpack(point)
                    end
                end,
                block = function() end,
            },
        }
    )
    chart.render(panel)
    assert(select(2, chart.refresh(panel)))
    assert(select(2, chart.refresh(panel)))
    assert(panel.framePhase == "traces")
    local run = { pts = {}, pool = {}, size = 0, changes = {} }
    panel.series[1].runs[1] = run
    for index = 1, 4096 do
        run.pts[index] = { index, 0 }
        run.pool[index] = run.pts[index]
    end
    return panel
end
local module = {
    decl = chart.traceDecl,
    stageOf = chart.traceStageOf,
    step = function(panel, grant, stage)
        panel.session = panel.frameSession
        for _, item in ipairs(panel.series) do
            item.feed = item.snapshot
        end
        chart.ranges(panel)
        local interval, unfinished = chart.traceStep(panel, grant, stage)
        panel.session = panel.liveSession
        for _, item in ipairs(panel.series) do
            item.feed = item.liveFeed
        end
        return interval, unfinished
    end,
}
local function snapshot(panel)
    local result = {}
    for _, item in ipairs(panel.series) do
        result[#result + 1] = tostring(item.runCount)
        for index = 1, item.runCount do
            local run = item.runs[index]
            result[#result + 1] = tostring(run.dotted)
            assert(#run.pts == run.size, "no stale coordinates reach a native line")
            for _, point in ipairs(run.pts) do
                result[#result + 1] = point[1] .. ":" .. point[2]
            end
        end
        for _, key in ipairs(item.markerKeys) do
            result[#result + 1] = key .. ":" .. tostring(item.markers[key].active)
        end
    end
    return table.concat(result, "\n")
end

for grant = 1, 2 do
    local legacy, panel = create(), create()
    local done
    for _ = 1, 10000 do
        local _, unfinished = chart.refresh(legacy)
        if not unfinished then
            done = true
            break
        end
    end
    assert(done, "legacy comparison frame must complete")
    local task = panelHost.task({ module = module, instance = panel, interval = 10 })
    local trimmed, finished = false, false
    for _ = 1, 10000 do
        local stage, pending = task.stage, panel.pending
        local oldIndex = pending and pending.job.index
        local run = pending and pending.runs[pending.applyIndex or 1]
        local oldLength = run and #run.pts
        local delay = task:step(stage == "project" and grant or 1, stage, getTime())
        assert(task.used <= (stage == "project" and grant or 1))
        if stage == "project" then
            assert(pending.job.index - oldIndex <= grant, "one grant advances at most that many source knots")
        elseif stage == "apply" and oldLength and oldLength > run.size then
            assert(oldLength - #run.pts <= 128, "a step retires at most 128 old coordinates")
            if #run.pts > run.size then
                assert(run.line == nil, "partial cleanup must not publish the stale coordinate tail")
            end
            trimmed = true
        end
        if delay == 10 then
            finished = true
            break
        end
    end
    assert(finished and trimmed, "grant-sized traces must finish including oversized old buffers")
    assert(snapshot(panel) == snapshot(legacy), "partial trace grants preserve legacy runs, connectors and markers")
end

local expired = create()
local task = panelHost.task({ module = module, instance = expired, interval = 10 })
task:step(1, task.stage, getTime())
assert(task.stage == "project")
local first = points[1][1]
points[1][1] = nil
assert(task:step(1, task.stage, getTime()) == 10 and expired.frameExpired, "expired history returns to the frame owner")
points[1][1] = first
chart.resetSession(expired)
assert(expired.pending == nil and expired.frameExpired == nil)
assert(task:step(1, "project", getTime()) == 1 and task.used == 0 and task.stage == "trace")

print("Chart trace grants and bounded coordinate retirement passed")
