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
local function create(cold, boundaries)
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
                        armLast = boundaries and 4 or 0,
                        armRevision = 1,
                        resumeFirst = 1,
                        resumeLast = boundaries and 2 or 0,
                        resumeRevision = 1,
                        flightFirst = 1,
                        flightLast = boundaries and 2 or 0,
                        flightRevision = 1,
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
                recordingBreak = function(_, _, index)
                    return ({ 200, 400 })[index]
                end,
                armBoundary = function(_, _, index)
                    return ({ 10, 180, 300, 600 })[index], index % 2 == 1
                end,
                FLIGHT_CAPACITY = 32,
                flight = function(_, _, index)
                    return ({ 100, 350 })[index], ({ 300, 650 })[index]
                end,
            },
        }
    )
    if cold then
        return panel
    end
    local frame = panelHost.task({ module = chart, instance = panel, interval = 20 })
    for _ = 1, 2000 do
        if panel.taskPhase == "trace" then break end
        assert(frame:step(frame.want or 1, frame.stage, getTime()) == 1)
    end
    assert(panel.taskPhase == "trace" and panel.framePhase == "traces")
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
    local expected, panel = create(), create()
    local expectedTask = panelHost.task({ module = module, instance = expected, interval = 10 })
    local done
    for _ = 1, 10000 do
        if expectedTask:step(expectedTask.want or 1, expectedTask.stage, getTime()) == 10 then
            done = true
            break
        end
    end
    assert(done, "comparison frame must complete")
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
    assert(snapshot(panel) == snapshot(expected), "partial trace grants preserve runs, connectors and markers")
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

for grant = 1, 2 do
    local expected, panel = create(), create()
    local completed, expectedDone
    local expectedTask = panelHost.task({ module = chart, instance = expected, interval = 10 })
    for _ = 1, 10000 do
        if expectedTask:step(expectedTask.want or 1, expectedTask.stage, getTime()) ~= 1 and not expected.framePhase then
            expectedDone = true
            break
        end
    end
    assert(expectedDone, "comparison frame must complete")
    local full = panelHost.task({ module = chart, instance = panel, interval = 10 })
    for _ = 1, 10000 do
        local stage = full.stage
        if panel.framePhase and stage ~= "publish" then
            assert(not panel.displayRoot.hidden, "the previous plot remains visible until publication")
        end
        local units = stage == "project" and grant or full.want
        local delay = full:step(units, stage, getTime())
        assert(full.used <= units)
        if delay ~= 1 and not panel.framePhase then
            completed = true
            break
        end
    end
    assert(completed, "the full scheduler-owned frame must complete")
    assert(panel.displayRoot.hidden and not panel.plotRoot.hidden, "publication swaps both plot roots together")
    assert(snapshot(panel) == snapshot(expected), "the full frame preserves completed traces across grants")
end

local function fullTask(panel)
    return panelHost.task({ module = chart, instance = panel, interval = 10 })
end
local function reach(task, panel, target)
    for _ = 1, 10000 do
        if task.stage == target then
            return
        end
        task:step(task.want, task.stage, getTime())
    end
    error("full frame did not reach " .. target .. " from " .. tostring(panel.taskPhase))
end
local function finishFrame(task, panel)
    for _ = 1, 10000 do
        local delay = task:step(task.want, task.stage, getTime())
        if delay ~= 1 and not panel.framePhase then
            return delay
        end
    end
    error("full frame did not finish")
end

local function frameSnapshot(panel)
    local result = { snapshot(panel), tostring(panel.axis.start), tostring(panel.axis.scale) }
    local function object(node)
        result[#result + 1] = tostring(node.hidden)
        for _, name in ipairs({ "x", "y", "w", "h", "text" }) do
            result[#result + 1] = name .. "=" .. tostring(node.properties[name])
        end
        for _, point in ipairs(node.properties.pts or {}) do
            result[#result + 1] = point[1] .. ":" .. point[2]
        end
    end
    for _, node in ipairs({ panel.baseline, panel.title, panel.duration, panel.status }) do
        object(node)
    end
    for _, at in ipairs(panel.axis.breaks) do
        result[#result + 1] = tostring(at)
    end
    for _, line in ipairs(panel.grid) do
        object(line.object)
    end
    for _, band in ipairs(panel.flightBands or {}) do
        object(band)
    end
    for _, pool in ipairs({ panel.armMarkers, panel.resumeMarkers }) do
        for _, key in ipairs(pool.markerKeys) do
            result[#result + 1] = tostring(key)
            object(pool.markers[key].object)
        end
    end
    return table.concat(result, "\n")
end
for grant = 1, 2 do
    local panel, expected = create(true, true), create(true, true)
    finishFrame(fullTask(expected), expected)
    local full = fullTask(panel)
    for _ = 1, 10000 do
        local stage = full.stage
        local delay = full:step(stage == "project" and grant or full.want, stage, getTime())
        if delay ~= 1 and not panel.framePhase then
            break
        end
    end
    assert(not panel.framePhase)
    assert(#panel.flightBands == 2 and #panel.armMarkers.markerKeys > 0 and #panel.resumeMarkers.markerKeys > 0)
    assert(
        frameSnapshot(panel) == frameSnapshot(expected),
        "axis, grid, session markers, flight bands and complete-frame publication are consistent across grants"
    )
end

local cold, expectedCold = create(true), create(true)
finishFrame(fullTask(expectedCold), expectedCold)
local coldTask = fullTask(cold)
finishFrame(coldTask, cold)
assert(snapshot(cold) == snapshot(expectedCold), "cold frame capture preserves geometry and traces")
local published = cold.plotRoot
assert(coldTask.stage == "frame")
finishFrame(coldTask, cold)
assert(cold.plotRoot == published and not published.hidden, "a cached frame does not exchange plots")

for _, target in ipairs({ "measure", "axis", "plot", "project", "apply", "flights", "publish" }) do
    local panel = create(true)
    local full = fullTask(panel)
    reach(full, panel, target)
    chart.update(panel, { x = 0, y = 0, w = 480, h = 272 })
    assert(
        full:step(1, target, getTime()) == 1 and full.used == 0 and full.stage == "frame",
        "reflow invalidates the previously planned " .. target .. " stage"
    )
    finishFrame(full, panel)
    assert(panel.displayRoot.hidden and not panel.plotRoot.hidden)
end

local reset = create(true)
local resetTask = fullTask(reset)
reach(resetTask, reset, "publish")
local previous = reset.displayRoot
repeat
until not select(2, chart.resetSession(reset))
assert(resetTask:step(1, "publish", getTime()) == 1 and resetTask.used == 0)
assert(not previous.hidden, "reset invalidates publication without hiding the previous root")
finishFrame(resetTask, reset)

local rollback = create(true)
local rollbackTask = fullTask(rollback)
reach(rollbackTask, rollback, "project")
local visible = rollback.displayRoot
points[1][1] = nil
rollbackTask:step(1, "project", getTime())
points[1][1] = first
assert(rollbackTask.stage == "frame" and rollback.framePhase == nil)
assert(rollback.plotRoot == visible and not visible.hidden, "expired history rolls back to the visible plot")
finishFrame(rollbackTask, rollback)

local frozen = create(true)
local frozenTask = fullTask(frozen)
frozenTask:step(1, "frame", getTime())
feeds[1].value, feeds[1].revision = 99, 2
frozen.session.elapsed = 900
finishFrame(frozenTask, frozen)
assert(
    frozen.series[1].valueText == "40" and frozen.frameSession.elapsed == 700,
    "readings and elapsed time remain bound to the captured frame"
)
assert(frozen.series[1].feed == feeds[1] and frozen.session == frozen.liveSession)
feeds[1].value, feeds[1].revision = 40, 1

for _, missing in ipairs({ "absent", "failed" }) do
    local panel = create(true)
    panel.history = { failed = true }
    if missing == "absent" then
        panel.history = nil
    end
    local full = fullTask(panel)
    assert(finishFrame(full, panel) == 20 and panel.taskPhase == nil and not panel.framePhase)
    assert(panel.status.properties.text == "HISTORY N/A", "unavailable History displays its status")
end

print("Chart trace grants and bounded coordinate retirement passed")
