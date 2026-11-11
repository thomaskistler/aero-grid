-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
local chartAssertions = assert(loadfile(root .. "/tests/support/chart_assertions.lua"))()
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
        assert(guard < 200, "reload or reflow did not finish")
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
        for _ = 1, 2500 do
            refresh()
            ready = true
            for _, entry in ipairs(context.panels) do
                local panel = entry.instance
                ready = ready and #panel.grid == 12 and chartAssertions.finished(panel)
            end
            if ready then
                break
            end
        end
        assert(ready, "the sole chart pool must finish mounting before resource measurement")
        for _, entry in ipairs(context.panels) do
            local panel = entry.instance
            assert(chartAssertions.nativeColumns(panel.columnRenderer) <= panel.area.w * #panel.series * 2)
        end
    end
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
    fixture.lvglMock.releaseClearedObjects()
    collectgarbage("collect")
end

local function chartCells()
    local count = 0
    for _, entry in ipairs(context.panels) do
        if entry.instance.columnRenderer then
            count = count + chartAssertions.nativeColumns(entry.instance.columnRenderer)
        end
        -- Auto charts prepare their next window in a lazily built hidden layer.
        local hidden = entry.instance.auto and entry.instance.auto.hidden
        local host = hidden and rawget(hidden, "layerHost")
        if host then
            for _, object in ipairs(fixture.lvglMock.objects) do
                local ancestor = object
                while ancestor and ancestor ~= host do
                    ancestor = ancestor.parent
                end
                count = count + (ancestor and 1 or 0)
            end
        end
    end
    return count
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

-- Warm the same workloads before taking baselines: lazy chart columns grow
-- the mock object registry, whose array capacity survives cleared objects.
for cycle = 1, 22 do
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

        local fullObjects = #fixture.lvglMock.objects
        local fixedObjects = fullObjects - chartCells()
        for _, size in ipairs({ { 320, 180 }, { 480, 227 }, { 480, 272 } }) do
            zone.w, zone.h = size[1], size[2]
            finish()
            assert(
                #fixture.lvglMock.objects - chartCells() == fixedObjects,
                string.format(
                    "%s reflow changed non-column objects: %d -> %d",
                    dashboard,
                    fixedObjects,
                    #fixture.lvglMock.objects - chartCells()
                )
            )
        end
        local memory = collectgarbage("count")
        assert(fixture.lvglMock.replacedFontRefCount() == 0, dashboard .. " replaced font callbacks during reflow")
        peakObjects = math.max(peakObjects, fullObjects)
        if cycle == 2 then
            baseline[dashboard] = { memory = memory, objects = fullObjects }
        elseif cycle > 2 then
            local growth = memory - baseline[dashboard].memory
            maxGrowth = math.max(maxGrowth, growth)
            assert(fullObjects == baseline[dashboard].objects, dashboard .. " grew its live object count")
            assert(growth < 16, string.format("%s retained %.1f KiB after cycle %d", dashboard, growth, cycle))
        end
        if cycle == 1 or cycle == 22 then
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
        20 * #dashboards,
        peakObjects,
        maxGrowth,
        worstRefreshMs,
        worstRefreshDashboard
    )
)
