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

local pending = false
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

-- Finishing work is its own variable task: refreshes wait while it is pending.
local module = {
    id = "demo",
    refreshCost = "variable",
    refreshMinCost = 1,
    finishMinCost = 2,
    refresh = function(_, creating, slots)
        assert(creating == false)
        record("refresh", slots)
        return 1, false, 1
    end,
    finishPending = function(instance)
        return pending, instance.minimum
    end,
    finish = function(_, creating, slots)
        assert(creating == false)
        record("finish", slots)
        return nil, false, 2
    end,
}
pending = true
run({ entry(module) })
assert(#calls == 1 and calls[1].id == "finish", "refreshes must wait while finishing work is pending")
assert(calls[1].slots >= 2, "finishing must receive at least its declared minimum")
pending = false
run({ entry(module) })
assert(#calls == 1 and calls[1].id == "refresh", "refreshes resume once finishing is done")

-- A finish can move the next refresh deadline; the refresh task must see it
-- before another scheduler pass in the same callback.
local refreshesAfterFinish = 0
pending = true
local delayedRefresh = {
    id = "demo",
    refreshCost = 1,
    finishMinCost = 1,
    refresh = function()
        refreshesAfterFinish = refreshesAfterFinish + 1
        return 1, false, 1
    end,
    finishPending = function()
        return pending
    end,
    finish = function()
        pending = false
        return 50, false, 1
    end,
}
local delayedEntry = entry(delayedRefresh)
run({ delayedEntry })
assert(refreshesAfterFinish == 0, "finish must defer refresh until its new deadline")
assert(delayedEntry.refreshTask.due == delayedEntry.nextRefresh)

-- The minimum finishPending reports is resolved again before a continuation grant.
local finishTurns, finishGrants = 0, {}
pending = true
local dynamicFinish = {
    id = "demo",
    finishMinCost = 8,
    finishPending = function(instance)
        return pending, instance.minimum
    end,
    finish = function(instance, _, slots)
        finishTurns = finishTurns + 1
        finishGrants[#finishGrants + 1] = slots
        if finishTurns == 1 then
            instance.minimum = 1
            return nil, true, 1
        end
        pending = false
        return nil, false, 1
    end,
}
local dynamicEntry = entry(dynamicFinish, { minimum = 8 })
run({ dynamicEntry })
assert(finishTurns == 2 and finishGrants[1] == 8 and finishGrants[2] == 7)

-- finishPending can report a larger minimum than the module default.
local instance = { minimum = 8 }
pending = true
run({ entry(module, instance) })
assert(#calls == 1 and calls[1].id == "finish" and calls[1].slots == 8)
assert(context.remainingSlots == 6, "finishing is charged what it reports: " .. tostring(context.remainingSlots))

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
pending = false
turns = 0
run({ entry(continuing) })
assert(turns > 1 and turns <= 8, "a direct continuation runs while slots remain, up to the callback")
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
local dynamicRefreshEntry = entry(dynamicRefresh, { refreshMinCost = 8 })
run({ dynamicRefreshEntry })
assert(
    dynamicRefreshTurns == 2 and dynamicRefreshGrants[1] == 8 and dynamicRefreshGrants[2] == 7,
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
local dynamicBackgroundEntry = entry(dynamicBackground, { backgroundMinCost = 8 })
context.panels = { dynamicBackgroundEntry }
fixture.tick(10)
definition.background(context)
assert(
    dynamicBackgroundTurns == 2 and dynamicBackgroundGrants[1] == 8 and dynamicBackgroundGrants[2] == 7,
    "continuing background work must use its updated minimum on each turn"
)

-- A failing readiness callback is isolated and reported rather than escaping the scheduler.
local broken = entry({
    id = "demo",
    refreshCost = "variable",
    refreshMinCost = 1,
    finish = function() end,
    finishMinCost = 1,
    finishPending = function()
        error("broken finish check")
    end,
    refresh = function()
        error("failed panels must not refresh after their readiness callback fails")
    end,
})
context.errors = {}
run({ broken })
assert(broken.failed, "a failing finishPending callback must disable its panel")
assert(#context.errors == 1 and string.find(context.errors[1], "broken finish check", 1, true))

local invalid = entry({
    id = "demo",
    refreshCost = "variable",
    refreshMinCost = 1,
    finish = function() end,
    finishMinCost = 1,
    finishPending = function()
        return "yes"
    end,
})
context.errors = {}
run({ invalid })
assert(invalid.failed, "a non-boolean finishPending result must disable its panel")
assert(#context.errors == 1 and string.find(context.errors[1], "must return a boolean", 1, true))

-- Failed readiness disables only that panel; a same-type neighbor keeps refreshing.
local neighborRefreshes = 0
local failing = entry({
    id = "demo",
    refresh = function() end,
    finishPending = function()
        error("panel failed readiness")
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
assert(failing.failed)
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
assert(scalarRefreshes == 8 and not scalarEntry.failed, "non-table panel state remains supported")
