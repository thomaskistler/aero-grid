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
