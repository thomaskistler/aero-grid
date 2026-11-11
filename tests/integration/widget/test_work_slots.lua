-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local definition = fixture.module("main.lua")
local support = fixture.module("lib/services.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
context.flightFactory = nil
context.serviceRuntime = support.runtime({})
context.panels = {}
context.workCursor = nil
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
            refresh = function(_, creating, slots)
                assert(creating == false)
                record(id, slots)
                return 1, false, used
            end,
        },
        instance = {},
        interval = 0,
        nextRefresh = 0,
    }
end
context.panels = { panel("first"), panel("chart", "variable", 2), panel("last") }
fixture.tick(10)
definition.refresh(context)
assert(#calls == 1 and calls[1].id == "telemetry" and calls[1].slots == 8)
assert(context.remainingSlots == 0)

fixture.tick(10)
definition.refresh(context)
assert(calls[2].id == "service" and calls[2].slots == 1)
assert(calls[3].id == "first" and calls[3].slots == 1)
assert(calls[4].id == "chart" and calls[4].slots == 6)
assert(calls[5].id == "last" and calls[5].slots == 1, "unused variable slots must remain available")
assert(calls[6].id == "telemetry" and calls[6].slots == 3)
assert(context.remainingSlots == 0)

-- A fixed task that cannot fit keeps the next callback's first turn.
context.panels[2] = panel("large", 8)
context.workCursor = 3
calls = {}
fixture.tick(10)
definition.refresh(context)
assert(#calls == 1 and calls[1].id == "first")
assert(context.remainingSlots == 7)
fixture.tick(10)
definition.refresh(context)
assert(calls[2].id == "large" and calls[2].slots == 8)
assert(context.remainingSlots == 0)

context.panels = { panel("first") }
context.workCursor = 3
ordinary.updateCost = 8
calls = {}
fixture.tick(10)
definition.refresh(context)
assert(calls[1].id == "first" and calls[2].id == "telemetry")
fixture.tick(10)
definition.refresh(context)
assert(calls[3].id == "service" and calls[3].slots == 8, "fixed services must retain a deferred turn")
ordinary.updateCost = nil

context.panels = { panel("invalid", "variable", 9) }
context.workCursor = 3
fixture.tick(10)
definition.refresh(context)
assert(context.panels[1].failed and context.remainingSlots == 0)
assert(string.find(context.panels[1].error, "consumption", 1, true))
assert(#context.errors == 1, "invalid usage must be reported")
context.panels = { panel("missing", "variable") }
context.workCursor = 3
fixture.tick(10)
definition.refresh(context)
assert(context.panels[1].failed and #context.errors == 2, "variable tasks must report consumption")

-- Hidden services share slots too; ordinary foreground refreshes stay dormant.
context.panels = { panel("hidden") }
context.workCursor = 1
calls = {}
fixture.tick(10)
definition.background(context)
assert(#calls == 1 and calls[1].id == "telemetry" and calls[1].slots == 8)
definition.background(context)
assert(#calls == 3 and calls[2].id == "service" and calls[3].id == "telemetry")

-- Free services still run once after a variable task exhausts the allowance.
ordinary.updateCost = 0
context.panels = { panel("blocked") }
context.workCursor = 1
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
context.workCursor = 1
calls = {}
fixture.tick(10)
definition.background(context)
assert(#calls == 2 and calls[2].id == "service" and calls[2].slots == 0)
assert(fixture.module("lib/history_service.lua").updateCost == 0)
assert(fixture.module("lib/control_service.lua").updateCost == 0)

-- Free panels run even after charged work was deferred, without affecting demand.
context.panels = { panel("blocked"), panel("diagnostic", 0) }
context.schedulerStats = {
    started = getTime(),
    callbacks = 0,
    used = 0,
    requested = 0,
    denied = 0,
    revision = 0,
    utilization = 0,
    deferrals = 0,
}
context.workCursor = 1
calls = {}
fixture.tick(100)
definition.refresh(context)
assert(#calls == 3 and calls[3].id == "diagnostic" and calls[3].slots == 0)
local stats = context.schedulerStats
assert(stats.revision == 1 and stats.utilization == 100 and stats.deferrals == 50)
assert(context.remainingSlots == 0)
-- The same zero-cost contract can be selected by an individual panel instance.
context.panels[2].module.refreshCost = 1
context.panels[2].instance.refreshCost = 0
context.workCursor = 1
calls = {}
fixture.tick(100)
definition.refresh(context)
assert(#calls == 3 and calls[3].id == "diagnostic" and calls[3].slots == 0)
assert(stats.revision == 2 and stats.deferrals == 50)

context.serviceRuntime = support.runtime({})
context.panels = { panel("two", 2), panel("one", 1), panel("not-due", 8) }
context.panels[3].nextRefresh = getTime() + 1000
context.workCursor = 1
fixture.tick(100)
definition.refresh(context)
assert(stats.revision == 3 and stats.utilization == 37.5 and stats.deferrals == 0)
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
definition.refresh(context)
assert(stats.revision == 4 and stats.utilization == 0 and stats.deferrals == 0)
