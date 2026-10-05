-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { DashID = "resource-initial", Theme = "modern" })
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
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
    fixture.lvglMock.releaseClearedObjects()
    collectgarbage("collect")
end

local dashboards = { "main", "review-metric", "review-navigation", "host", "services", "services2" }
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
        definition.update(context, { DashID = dashboard, Theme = "modern" })
        finish()
        assert(
            context.layoutOrigin == (dashboard == "main" and "default" or "dashboard"),
            dashboard .. " did not load its intended layout"
        )
        assert(weak.page == nil, "a retired page remains reachable")
        assert(weak.runtime == nil, "a retired service runtime remains reachable")

        local fullObjects = #fixture.lvglMock.objects
        for _, size in ipairs({ { 320, 180 }, { 480, 227 }, { 480, 272 } }) do
            zone.w, zone.h = size[1], size[2]
            finish()
            assert(#fixture.lvglMock.objects == fullObjects, dashboard .. " allocated objects during reflow")
        end
        local memory = collectgarbage("count")
        assert(fixture.lvglMock.replacedFontRefCount() == 0, dashboard .. " replaced font callbacks during reflow")
        peakObjects = math.max(peakObjects, fullObjects)
        if cycle == 1 then
            baseline[dashboard] = { memory = memory, objects = fullObjects }
        else
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
        "  mock resource stability: 120 reloads after warm-up, peak %d objects, growth %.1f KiB;"
            .. " worst average %.3f ms/refresh (%s)",
        peakObjects,
        maxGrowth,
        worstRefreshMs,
        worstRefreshDashboard
    )
)
