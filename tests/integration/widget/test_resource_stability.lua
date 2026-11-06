-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
function getOutputValue(index)
    return index * 32
end
local context = fixture.createLoaded(nil, { Layout = "resource-initial", Theme = "modern-dark" })
local zone = context.zone

local function refresh()
    fixture.tick(20)
    definition.refresh(context)
    fixture.lvglMock.settle()
end

local function finish()
    local guard = 0
    repeat
        refresh()
        guard = guard + 1
        assert(guard < 2000, "reload or reflow did not finish")
    until not context.stage and not context.reloadState and not context.reflowIndex
    for _ = 1, 10 do
        refresh()
    end
    local output = fixture.instanceOf(context, "outputs")
    if output then
        for _ = 1, 150 do
            refresh()
        end
        assert(output.showRows == output.area.count, "output rows did not finish mounting")
        assert(output.rows[1].feed.available, "output service was not exercised")
    end
    if fixture.instanceOf(context, "power") then
        local ready = false
        for _ = 1, 500 do
            refresh()
            ready = true
            for _, entry in ipairs(context.panels) do
                local panel = entry.instance
                ready = ready and #panel.grid == 12 and panel.backPlot and #panel.backPlot.grid == 12
                for index, item in ipairs(panel.series or {}) do
                    local back = panel.backPlot and panel.backPlot.series[index]
                    ready = ready and item.runs[1] and item.runs[1].line and back and back.runs[1] and back.runs[1].line
                end
            end
            if ready then
                break
            end
        end
        if not ready then
            local host = context.schedulerHost
            local task = context.scheduler.byId["service:armed"]
            local stage = task and task.meta.stages.run
            local room = host.scheduler.CEILING - host.scheduler.MARGIN - context.scheduler.lastPlan.U
            local criticalNeed = host.scheduler.NORMAL_RESERVE
                + (stage and stage.fixed or 0)
                + (stage and stage.perUnit or 0)
                + host.scheduler.EXAMINE_COST
                + host.scheduler.RUN_COST
            assert(
                task and room < criticalNeed,
                "chart buffers must finish mounting unless critical control cannot fit"
            )
        else
            for _, entry in ipairs(context.panels) do
                for _, item in ipairs(entry.instance.series or {}) do
                    assert(item.runs[1] and item.runs[1].line, "chart traces did not finish mounting")
                end
            end
        end
    end
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
    fixture.lvglMock.releaseClearedObjects()
    collectgarbage("collect")
end

local function settleIdentity()
    for _, entry in ipairs(context.panels) do
        local panel = entry.instance
        if entry.module.id == "model-identity" and panel.area.showImage then
            local ready = false
            for _ = 1, 1500 do
                local feed = panel.feed
                if feed and feed.available
                    and (not feed.bitmapPath or panel.imagePath == feed.bitmapPath or panel.imageRejected == feed.bitmapPath)
                then
                    ready = true
                    break
                end
                fixture.tick(20)
                definition.background(context)
                refresh()
            end
            assert(ready, "model identity did not finish loading")
        end
    end
    fixture.lvglMock.releaseClearedObjects()
    collectgarbage("collect")
end

local function chartBuffersReady()
    for _, entry in ipairs(context.panels) do
        if entry.module.id == "chart" then
            local panel = entry.instance
            if not panel.grid or #panel.grid ~= 12 or not panel.backPlot or not panel.backPlot.grid then
                return false
            end
            if #panel.backPlot.grid ~= 12 then
                return false
            end
            for index, item in ipairs(panel.series or {}) do
                local back = panel.backPlot.series[index]
                if not (item.runs[1] and item.runs[1].line and back and back.runs[1] and back.runs[1].line) then
                    return false
                end
            end
        end
    end
    return true
end

local dashboards = {
    "main",
    "review-metric",
    "review-navigation",
    "review-output",
    "review-chart",
    "Diagnostics",
    "services",
    "services2",
}
local baseline = {}
local maxGrowth = 0
local peakObjects = 0
local worstRefreshMs = 0
local worstRefreshDashboard = ""
local weak = setmetatable({}, { __mode = "v" })

for cycle = 1, 21 do
    for _, dashboard in ipairs(dashboards) do
        weak.page = context.page
        weak.runtime = context.serviceRuntime
        definition.update(context, { Layout = dashboard, Theme = "modern-dark" })
        finish()
        assert(
            context.layoutOrigin == (dashboard == "main" and "default" or "shipped"),
            dashboard .. " did not load its intended layout"
        )
        assert(weak.page == nil, "a retired page remains reachable")
        assert(weak.runtime == nil, "a retired service runtime remains reachable")

        settleIdentity()
        local fullObjects = #fixture.lvglMock.objects
        local chartsReady = chartBuffersReady()
        for _, size in ipairs({ { 320, 180 }, { 480, 227 }, { 480, 272 } }) do
            zone.w, zone.h = size[1], size[2]
            finish()
            if chartsReady then
                assert(#fixture.lvglMock.objects == fullObjects, dashboard .. " allocated objects during reflow")
            else
                fullObjects = #fixture.lvglMock.objects
                chartsReady = chartBuffersReady()
            end
        end
        local memory = collectgarbage("count")
        assert(fixture.lvglMock.replacedFontRefCount() == 0, dashboard .. " replaced font callbacks during reflow")
        peakObjects = math.max(peakObjects, fullObjects)
        -- The first cycle loads every dashboard's module code, which then stays shared.
        if cycle == 2 then
            baseline[dashboard] = { memory = memory, objects = fullObjects }
        elseif cycle > 2 then
            local growth = memory - baseline[dashboard].memory
            maxGrowth = math.max(maxGrowth, growth)
            assert(fullObjects == baseline[dashboard].objects, dashboard .. " grew its live object count")
            assert(growth < 16, string.format("%s retained %.1f KiB after cycle %d", dashboard, growth, cycle))
        end
        if cycle == 21 then
            local started = os.clock()
            for _ = 1, 1000 do
                refresh()
            end
            local averageMs = (os.clock() - started) * 1000 / 1000
            if averageMs > worstRefreshMs then
                worstRefreshMs = averageMs
                worstRefreshDashboard = dashboard
            end
        end
    end
end

print(
    string.format(
        "  mock resource stability: %d reloads after warm-up, peak %d objects, growth %.1f KiB;"
            .. " worst average %.3f ms/refresh (%s)",
        19 * #dashboards,
        peakObjects,
        maxGrowth,
        worstRefreshMs,
        worstRefreshDashboard
    )
)
