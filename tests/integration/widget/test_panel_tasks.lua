-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local definition = fixture.module("main.lua")
local support = fixture.module("lib/services.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 6)
fixture.isolateWork(context)

local calls = {}
local function record(id, slots)
    calls[#calls + 1] = { id = id, slots = slots }
end

local function entry(module, instance)
    return { placement = { id = "demo" }, module = module, instance = instance or {}, interval = 0, nextRefresh = 0 }
end
local function run(panels)
    context.panels = panels
    fixture.requeue(context)
    calls = {}
    fixture.tick(10)
    definition.refresh(context)
end

-- A refresh result directly requests another turn in the same callback.
local turns = 0
local continuing = {
    id = "demo",
    refreshCost = "variable",
    refreshMinCost = 1,
    refresh = function(self_, _, slots)
        turns = turns + 1
        record("refresh", slots)
        return 1, true, 1
    end,
}
turns = 0
run({ entry(continuing) })
assert(turns > 1 and turns <= 32, "a direct continuation runs while slots remain, up to the callback")
assert(#context.errors == 0, "continuation must not raise errors")

local dynamicRefreshTurns, dynamicRefreshGrants = 0, {}
local dynamicRefresh = {
    id = "demo",
    refreshCost = "variable",
    refreshMinCost = 1,
    refresh = function(instance, _, slots)
        dynamicRefreshTurns = dynamicRefreshTurns + 1
        dynamicRefreshGrants[#dynamicRefreshGrants + 1] = slots
        instance.refreshMinCost = 1
        return 1, dynamicRefreshTurns < 2, 1
    end,
}
local dynamicRefreshEntry = entry(dynamicRefresh, { refreshMinCost = 32 })
run({ dynamicRefreshEntry })
assert(
    dynamicRefreshTurns == 2 and dynamicRefreshGrants[1] == 32 and dynamicRefreshGrants[2] == 31,
    "a continuing refresh must use its updated minimum on each turn"
)

-- A hidden dashboard's background work is a variable task when it declares a minimum.
local background = {
    id = "demo",
    backgroundMinCost = 3,
    background = function(_, _, slots)
        record("background", slots)
        return nil, false, 3
    end,
}
context.panels = { entry(background) }
calls = {}
fixture.tick(10)
definition.background(context)
assert(#calls == 1 and calls[1].slots >= 3, "background must receive its declared minimum")
assert(context.scheduler.state(context.panels[1].backgroundTask).spent == 3, "background is charged what it reports")

local dynamicBackgroundTurns, dynamicBackgroundGrants = 0, {}
local dynamicBackground = {
    id = "demo",
    background = function(instance, _, slots)
        dynamicBackgroundTurns = dynamicBackgroundTurns + 1
        dynamicBackgroundGrants[#dynamicBackgroundGrants + 1] = slots
        instance.backgroundMinCost = 1
        return nil, dynamicBackgroundTurns < 2, 1
    end,
}
local dynamicBackgroundEntry = entry(dynamicBackground, { backgroundMinCost = 32 })
context.panels = { dynamicBackgroundEntry }
fixture.tick(10)
definition.background(context)
assert(
    dynamicBackgroundTurns == 2 and dynamicBackgroundGrants[1] == 32 and dynamicBackgroundGrants[2] == 31,
    "continuing background work must use its updated minimum on each turn"
)

-- A failing panel is isolated; a same-type neighbor keeps refreshing.
local neighborRefreshes = 0
local failing = entry({
    id = "demo",
    refresh = function()
        error("panel failed refresh")
    end,
})
local neighbor = entry({
    id = "demo",
    refresh = function()
        neighborRefreshes = neighborRefreshes + 1
    end,
})
context.errors = {}
run({ failing, neighbor })
assert(failing.failed and #context.errors == 1 and string.find(context.errors[1], "panel failed refresh", 1, true))
assert(neighborRefreshes == 1, "a failed panel must not block a healthy same-type panel")

-- The create contract permits opaque panel state, including non-tables.
local scalarRefreshes = 0
local scalarEntry = entry({
    id = "scalar",
    refreshCost = 1,
    refresh = function()
        scalarRefreshes = scalarRefreshes + 1
        return nil, true
    end,
}, 17)
run({ scalarEntry })
assert(scalarRefreshes == 32 and not scalarEntry.failed, "non-table panel state remains supported")
