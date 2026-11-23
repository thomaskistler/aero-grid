-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local definition = fixture.module("main.lua")
local support = fixture.module("lib/services.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 6)
fixture.isolateWork(context)
context.panels = {}
fixture.requeue(context)
local calls = {}
local function record(id, slots)
    calls[#calls + 1] = { id = id, slots = slots }
end
local telemetry = {
    id = "telemetry",
    interval = 0,
    count = 1,
    revision = 0,
    updateCost = "variable",
    updateMinCost = 1,
    update = function(_, _, slots)
        record("telemetry", slots)
        return slots
    end,
}
local ordinary = {
    id = "ordinary",
    interval = 0,
    count = 1,
    revision = 0,
    update = function(_, _, slots)
        record("service", slots)
    end,
}
support.register(context.serviceRuntime, telemetry, 0)
support.register(context.serviceRuntime, ordinary, 0)

local function panel(id, cost, used)
    return {
        placement = { id = id },
        module = {
            id = id,
            refreshCost = cost,
            refreshMinCost = cost == "variable" and 1 or nil,
            refresh = function(_, creating, slots)
                assert(creating == false)
                record(id, slots)
                return 1, false, used
            end,
        },
        instance = {},
        interval = 0,
        nextRefresh = 0,
        painted = true,
    }
end
context.panels = { panel("first"), panel("chart", "variable", 2), panel("last") }
fixture.tick(10)
definition.refresh(context)
assert(#calls == 1 and calls[1].id == "telemetry" and calls[1].slots == 32)
assert(context.remainingSlots == 0)

fixture.tick(10)
definition.refresh(context)
assert(calls[2].id == "service" and calls[2].slots == 1)
assert(calls[3].id == "first" and calls[3].slots == 1)
assert(calls[4].id == "chart" and calls[4].slots == 30)
assert(calls[5].id == "last" and calls[5].slots == 1, "unused variable slots must remain available")
assert(calls[6].id == "telemetry" and calls[6].slots == 27)
assert(context.remainingSlots == 0)

-- A task that cannot fit keeps its due time, so it runs ahead of later work.
context.panels[2] = panel("large", 32)
context.tasksDirty = true
calls = {}
fixture.tick(10)
definition.refresh(context)
assert(#calls == 2 and calls[1].id == "service" and calls[2].id == "telemetry")
assert(context.remainingSlots == 0)
fixture.tick(10)
definition.refresh(context)
assert(calls[3].id == "large" and calls[3].slots == 32)
assert(context.remainingSlots == 0)

context.panels = { panel("first") }
context.tasksDirty = true
ordinary.updateCost = 32
calls = {}
fixture.tick(10)
definition.refresh(context)
assert(#calls == 1 and calls[1].id == "service" and calls[1].slots == 32)
fixture.tick(10)
definition.refresh(context)
assert(calls[2].id == "telemetry", "work waiting behind a full grant must run first next callback")
ordinary.updateCost = nil

local serviceOrder = context.serviceRuntime.order
context.serviceRuntime.order = {}
context.panels = { panel("invalid", "variable", 33) }
context.tasksDirty = true
fixture.tick(10)
definition.refresh(context)
assert(context.panels[1].failed and context.remainingSlots == 0)
assert(string.find(context.panels[1].error, "consumption", 1, true))
assert(#context.errors == 1, "invalid usage must be reported")
context.panels = { panel("missing", "variable") }
context.tasksDirty = true
fixture.tick(10)
definition.refresh(context)
assert(context.panels[1].failed and #context.errors == 2, "variable tasks must report consumption")
context.panels = { panel("invalid-fixed", 2, 3) }
context.tasksDirty = true
fixture.tick(10)
definition.refresh(context)
assert(context.panels[1].failed and #context.errors == 3, "invalid fixed consumption must be reported")
context.serviceRuntime.order = serviceOrder

-- Fixed reservations can return unused slots to later services and panels.
context.serviceRuntime = support.runtime({})
local partial = {
    id = "partial",
    interval = 0,
    count = 1,
    revision = 0,
    updateCost = 32,
    update = function(_, _, slots)
        record("partial", slots)
        return 1
    end,
}
support.register(context.serviceRuntime, partial, 0)
context.panels = { panel("partial-panel", 16, 1), panel("after", 30) }
fixture.requeue(context)
calls = {}
fixture.tick(10)
definition.refresh(context)
assert(#calls == 3 and calls[1].slots == 32 and calls[2].slots == 16 and calls[3].slots == 30)
assert(context.remainingSlots == 0, "unused fixed reservations must be available to later work")

local continuationTurns = 0
partial.updateCost, partial.interval = 1, 100
partial.update = function()
    continuationTurns = continuationTurns + 1
    return 1, continuationTurns < 33
end
context.panels = { panel("companion") }
fixture.requeue(context)
fixture.tick(10)
definition.refresh(context)
assert(continuationTurns == 31 and partial.due > getTime())
fixture.tick(1)
definition.refresh(context)
assert(continuationTurns == 33, "pending service work must resume despite its future deadline")

context.serviceRuntime = support.runtime({})
context.panels = {}
local dynamicMinimumTurns, dynamicGrants = 0, {}
local dynamicMinimum = {
    id = "dynamic minimum",
    interval = 0,
    count = 1,
    revision = 0,
    updateCost = "variable",
    updateMinCost = 32,
    update = function(self, _, slots)
        dynamicMinimumTurns = dynamicMinimumTurns + 1
        dynamicGrants[#dynamicGrants + 1] = slots
        if dynamicMinimumTurns == 1 then
            self.updateMinCost = 1
            return 1, true
        end
        if dynamicMinimumTurns == 2 then
            self.updateCost = 2
            self.updateMinCost = nil
            return 1, true
        end
        return 1, false
    end,
}
support.register(context.serviceRuntime, dynamicMinimum, 0)
fixture.requeue(context)
fixture.tick(10)
definition.refresh(context)
assert(
    dynamicMinimumTurns == 3 and dynamicGrants[1] == 32 and dynamicGrants[2] == 31 and dynamicGrants[3] == 2,
    "a continuing service must use updated slot cost and minimum on each turn"
)

context.serviceRuntime = support.runtime({})
support.register(context.serviceRuntime, telemetry, 0)
support.register(context.serviceRuntime, ordinary, 0)

-- Hidden services share slots too; ordinary foreground refreshes stay dormant.
context.panels = { panel("hidden") }
fixture.requeue(context)
calls = {}
fixture.tick(10)
definition.background(context)
assert(#calls == 1 and calls[1].id == "telemetry" and calls[1].slots == 32)
definition.background(context)
assert(#calls == 3 and calls[2].id == "service" and calls[3].id == "telemetry")

-- Free services still run once after a variable task exhausts the allowance.
ordinary.updateCost = 0
context.panels = { panel("blocked") }
fixture.requeue(context)
calls = {}
fixture.tick(10)
definition.refresh(context)
assert(#calls == 2 and calls[1].id == "telemetry" and calls[2].id == "service")
assert(calls[2].slots == 0 and context.remainingSlots == 0)
fixture.tick(10)
definition.refresh(context)
assert(calls[3].id == "blocked", "charged work deferred by free-service scanning must retain its turn")
assert(calls[4].id == "telemetry" and calls[5].id == "service")
assert(#calls == 5, "each service must run at most once per callback")
fixture.requeue(context)
calls = {}
fixture.tick(10)
definition.background(context)
assert(#calls == 2 and calls[2].id == "service" and calls[2].slots == 0)
assert(fixture.module("lib/history_service.lua").updateCost == 1)
assert(fixture.module("lib/control_service.lua").updateCost == 1)

-- Free panels run even after charged work was deferred, without affecting demand.
context.panels = { panel("blocked"), panel("diagnostic", 0) }
local stats = context.scheduler.stats()
local function counters()
    return { used = stats.used, available = stats.available, requested = stats.requested, denied = stats.denied }
end
local before = counters()
fixture.requeue(context)
calls = {}
fixture.tick(100)
definition.refresh(context)
assert(#calls == 3 and calls[3].id == "diagnostic" and calls[3].slots == 0)
assert(stats.used - before.used == stats.available - before.available)
assert(stats.denied > before.denied and (stats.denied - before.denied) * 2 == stats.requested - before.requested)
assert(context.remainingSlots == 0)
-- The same zero-cost contract can be selected by an individual panel instance.
context.panels[2].module.refreshCost = 1
context.panels[2].instance.refreshCost = 0
fixture.requeue(context)
calls = {}
before = counters()
fixture.tick(100)
definition.refresh(context)
assert(#calls == 3 and calls[3].id == "diagnostic" and calls[3].slots == 0)
assert(stats.denied > before.denied and (stats.denied - before.denied) * 2 == stats.requested - before.requested)
assert(stats.available - before.available == 32, "one callback offers one segment")
context.serviceRuntime = support.runtime({})
context.panels = { panel("two", 2), panel("one", 1), panel("not-due", 32) }
context.panels[3].nextRefresh = getTime() + 1000
fixture.requeue(context)
fixture.tick(100)
before = counters()
definition.refresh(context)
assert(stats.used - before.used == 3 and stats.available - before.available == 32 and stats.denied == before.denied)
context.panels = {}
fixture.tick(100)
-- Keep an inactive service in the registry so the normal dispatch path runs.
local inactive = {
    id = "inactive",
    count = 0,
    interval = 0,
    revision = 0,
    update = function()
        error("inactive work must not run")
    end,
}
support.register(context.serviceRuntime, inactive, 0)
before = counters()
definition.refresh(context)
assert(stats.used == before.used and stats.denied == before.denied)

context.serviceRuntime = support.runtime({})
local backgroundTurns = 0
context.panels = {
    {
        placement = { id = "background" },
        module = {
            background = function()
                backgroundTurns = backgroundTurns + 1
                return nil, backgroundTurns == 1, 0
            end,
        },
        instance = {},
    },
}
fixture.tick(10)
definition.background(context)
assert(backgroundTurns == 2, "background continuation must resume in the same callback")
assert(context.scheduler.state(context.panels[1].backgroundTask).spent == 0)
