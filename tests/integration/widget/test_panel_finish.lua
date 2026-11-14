-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local definition = fixture.module("main.lua")
local support = fixture.module("lib/services.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 6)
context.document.panels, context.emptyHint = { {} }, nil
context.flightFactory = nil
context.serviceRuntime = support.runtime({})

local calls = {}
local function record(id, slots)
    calls[#calls + 1] = { id = id, slots = slots }
end

local pending = false
local function entry(module, instance)
    return { placement = { id = "demo" }, module = module, instance = instance or {}, interval = 0, nextRefresh = 0 }
end
local function run(panels)
    context.panels, context.refreshOwner = panels, nil
    context.scheduler.cursor = 1
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
    finishPending = function()
        return pending
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

-- The minimum can change per instance and per turn.
local instance = { finishMinCost = 8 }
pending = true
run({ entry(module, instance) })
assert(#calls == 1 and calls[1].id == "finish" and calls[1].slots == 8)
assert(context.remainingSlots == 6, "finishing is charged what it reports: " .. tostring(context.remainingSlots))

-- A refresh asks for a second turn in the same callback only when its instance opts in.
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
assert(turns == 1, "continuation is off unless the instance asks for it")
turns = 0
local opted = { refreshContinuation = true }
run({ entry(continuing, opted) })
assert(turns > 1 and turns <= 8, "an opted-in refresh continues while slots remain, up to the callback")
assert(#context.errors == 0, "continuation must not raise errors")

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
assert(context.panels[1].backgroundTask.spent == 3, "background is charged what it reports")
