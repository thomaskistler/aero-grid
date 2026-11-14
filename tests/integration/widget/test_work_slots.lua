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
context.panels = {}
context.scheduler.cursor = 1
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
context.scheduler.cursor = 3
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
context.scheduler.cursor = 3
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
context.scheduler.cursor = 3
fixture.tick(10)
definition.refresh(context)
assert(context.panels[1].failed and context.remainingSlots == 0)
assert(string.find(context.panels[1].error, "consumption", 1, true))
assert(#context.errors == 1, "invalid usage must be reported")
context.panels = { panel("missing", "variable") }
context.scheduler.cursor = 3
fixture.tick(10)
definition.refresh(context)
assert(context.panels[1].failed and #context.errors == 2, "variable tasks must report consumption")
context.panels = { panel("invalid-fixed", 2, 3) }
context.scheduler.cursor = 3
fixture.tick(10)
definition.refresh(context)
assert(context.panels[1].failed and #context.errors == 3, "invalid fixed consumption must be reported")

-- Fixed reservations can return unused slots to later services and panels.
context.serviceRuntime = support.runtime({})
local partial = {
    id = "partial",
    interval = 0,
    count = 1,
    revision = 0,
    updateCost = 8,
    update = function(_, _, slots)
        record("partial", slots)
        return 1
    end,
}
support.register(context.serviceRuntime, partial, 0)
context.panels = { panel("partial-panel", 4, 1), panel("after", 6) }
context.scheduler.cursor = 1
calls = {}
fixture.tick(10)
definition.refresh(context)
assert(#calls == 3 and calls[1].slots == 8 and calls[2].slots == 4 and calls[3].slots == 6)
assert(context.remainingSlots == 0, "unused fixed reservations must be available to later work")

local continuationTurns = 0
partial.updateCost, partial.interval = 1, 100
partial.update = function()
    continuationTurns = continuationTurns + 1
    return 1, continuationTurns < 9
end
context.panels = { panel("companion") }
context.scheduler.cursor = 1
fixture.tick(10)
definition.refresh(context)
assert(continuationTurns == 7 and partial.due > getTime())
fixture.tick(1)
definition.refresh(context)
assert(continuationTurns == 9, "pending service work must resume despite its future deadline")

context.serviceRuntime = support.runtime({})
support.register(context.serviceRuntime, telemetry, 0)
support.register(context.serviceRuntime, ordinary, 0)

-- Hidden services share slots too; ordinary foreground refreshes stay dormant.
context.panels = { panel("hidden") }
context.scheduler.cursor = 1
calls = {}
fixture.tick(10)
definition.background(context)
assert(#calls == 1 and calls[1].id == "telemetry" and calls[1].slots == 8)
definition.background(context)
assert(#calls == 3 and calls[2].id == "service" and calls[3].id == "telemetry")

-- Free services still run once after a variable task exhausts the allowance.
ordinary.updateCost = 0
context.panels = { panel("blocked") }
context.scheduler.cursor = 1
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
context.scheduler.cursor = 1
calls = {}
fixture.tick(10)
definition.background(context)
assert(#calls == 2 and calls[2].id == "service" and calls[2].slots == 0)
assert(fixture.module("lib/history_service.lua").updateCost == 0)
assert(fixture.module("lib/control_service.lua").updateCost == 1)

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
context.scheduler.cursor = 1
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
context.scheduler.cursor = 1
calls = {}
fixture.tick(100)
definition.refresh(context)
assert(#calls == 3 and calls[3].id == "diagnostic" and calls[3].slots == 0)
assert(stats.revision == 2 and stats.deferrals == 50)
assert(stats.capacity == 8 and stats.seconds == 1, "capacity is reported per measured second")
context.flightFactory = {
    broker = {
        identity = function()
            return "model"
        end,
        filename = "model",
        documentLoaded = true,
        session = true,
        errors = {},
        state = {},
        view = { diagnosticRevision = 0, epoch = 1 },
        tick = function() end,
    },
}
context.flightReportedRevision, context.flightReportedEpoch = 0, 1
fixture.tick(100)
definition.refresh(context)
context.flightFactory = nil

context.serviceRuntime = support.runtime({})
context.panels = { panel("two", 2), panel("one", 1), panel("not-due", 8) }
context.panels[3].nextRefresh = getTime() + 1000
context.scheduler.cursor = 1
fixture.tick(100)
definition.refresh(context)
assert(stats.revision == 4 and stats.utilization == 37.5 and stats.deferrals == 0)
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
assert(stats.revision == 5 and stats.utilization == 0 and stats.deferrals == 0)

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
assert(context.panels[1].backgroundTask.spent == 0)
