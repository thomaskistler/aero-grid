-- SPDX-License-Identifier: GPL-2.0-only

-- EdgeTX creates every AeroGrid instance in one Lua state, whose heap is capped
-- at 6 MiB (LUA_MEM_MAX). Instances must share compiled module code, and a
-- model switch builds the new instances before the old ones are collected.

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local helpers = assert(loadfile(root .. "/tests/support/widget_helpers.lua"))()
local widgetPath = root .. "/build/test-widget-fixture/"

local loads = {}
local firmwareLoadScript = loadScript
loadScript = function(filename, ...)
    loads[filename] = (loads[filename] or 0) + 1
    return firmwareLoadScript(filename, ...)
end

-- One main.lua per Lua state, as in EdgeTX.
local definition = fixture.module("main.lua")

local THREE = { "main", "review-chart", "review-navigation" }
local SEVEN = { "main", "review-chart", "review-navigation", "review-metric", "review-output", "main", "main" }

-- Measured on 64-bit Lua: seven instances take about 3.1 MiB with shared code
-- and 6.7 MiB without it; switching peaks at about 4.1 MiB against 9.7 MiB.
-- Both figures include about 1 MiB of module code that stays resident.
-- The bounds leave headroom for growth but stay far from the uncached figures.
local SEVEN_LOADED_KIB = 4096
local SWITCH_PEAK_KIB = 5120
local GROWTH_KIB = 16

local function heap()
    collectgarbage("collect")
    collectgarbage("collect")
    return collectgarbage("count")
end

local function create(layout)
    local context = helpers.createLoaded(
        definition,
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = layout, Theme = "modern-dark" },
        widgetPath
    )
    assert(#context.errors == 0, layout .. ": " .. table.concat(context.errors, "\n"))
    return context
end

local function createAll(layouts)
    local instances = {}
    for index, layout in ipairs(layouts) do
        instances[index] = create(layout)
    end
    return instances
end

local function destroyAll(instances)
    for _, context in ipairs(instances) do
        context.root:clear()
    end
    fixture.lvglMock.settle()
    fixture.lvglMock.releaseClearedObjects()
end

-- Heap above an empty widget state, counting the shared module code.
local base = heap()

local seven = createAll(SEVEN)
local sevenLoaded = heap() - base
assert(
    sevenLoaded < SEVEN_LOADED_KIB,
    string.format("seven instances hold %.0f KiB after load; the bound is %d KiB", sevenLoaded, SEVEN_LOADED_KIB)
)

for path, count in pairs(loads) do
    if string.find(path, "/panels/", 1, true) or string.find(path, "/lib/grid.lua", 1, true) then
        assert(count == 1, path .. " was loaded " .. count .. " times")
    end
end
assert(seven[1].grid ~= seven[2].grid, "instances share module state")
assert(seven[1].panelHost ~= seven[2].panelHost, "instances share module state")
assert(seven[1].dashboardLoader ~= seven[2].dashboardLoader, "instances share loader state")
assert(seven[1].scheduler ~= seven[2].scheduler, "instances share scheduler state")
assert(seven[1].schedulerHost.registeredTasks ~= seven[2].schedulerHost.registeredTasks, "instances share task registrations")
assert(seven[1].diagnosticsLog == seven[2].diagnosticsLog, "instances must share the diagnostics log")

local weak = setmetatable({}, { __mode = "v" })
for index, context in ipairs(seven) do
    weak[index] = context
end
destroyAll(seven)
seven = nil
heap()
for index = 1, #SEVEN do
    assert(weak[index] == nil, "a destroyed instance remains reachable")
end

local live = createAll(THREE)
local settled = heap() - base
local worstGrowth, peak = 0, 0
local previous = {}
for cycle = 1, 10 do
    local layouts = cycle % 2 == 1 and SEVEN or THREE
    local old = live
    live = createAll(layouts)
    peak = math.max(peak, heap() - base)
    destroyAll(old)
    old = nil
    local now = heap() - base
    previous[#layouts] = previous[#layouts] or now
    worstGrowth = math.max(worstGrowth, now - previous[#layouts])
end
assert(
    peak < SWITCH_PEAK_KIB,
    string.format("a model switch peaked at %.0f KiB; the bound is %d KiB", peak, SWITCH_PEAK_KIB)
)
assert(worstGrowth < GROWTH_KIB, string.format("heap grew %.1f KiB across model switches", worstGrowth))

loadScript = firmwareLoadScript
print(
    string.format(
        "  shared module code: 7 instances %.0f KiB, 3 instances %.0f KiB, switch peak %.0f KiB, growth %.1f KiB",
        sevenLoaded,
        settled,
        peak,
        worstGrowth
    )
)
