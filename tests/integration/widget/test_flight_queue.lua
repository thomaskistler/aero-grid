-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 10)
context.document.panels, context.emptyHint = { {} }, nil
context.serviceRuntime = context.servicesModule.runtime({})
local calls = {}
local owner = {
    filename = "model",
    documentLoaded = true,
    session = true,
    state = {},
    errors = {},
    view = { diagnosticRevision = 0, epoch = 1 },
    identity = function()
        calls[#calls + 1] = "identity"
        return "model"
    end,
    setup = function()
        assert(context.flightTask.cost == 1, "ordinary flight work requests one slot before setup")
        calls[#calls + 1] = "setup"
    end,
    tasks = function()
        return {}
    end,
    dropTasks = function() end,
}
context.flightFactory = { broker = owner }
if context.aerogridMenu then
    context.aerogridMenu.modelFilename = "model"
end
context.flightReportedRevision, context.flightReportedEpoch = 0, 1
context.stage = "probe"
context.dashboardLoader.advanceLoad = function()
    assert(context.hostTask.kind == "load" and context.hostTask.cost == context.scheduler.budget.capacity)
    calls[#calls + 1] = "load"
    context.stage = nil
end
fixture.requeue(context)
definition.refresh(context)
assert(table.concat(calls, ",") == "identity,setup")
assert(context.stage == "probe" and context.remainingSlots == 31)
definition.refresh(context)
assert(table.concat(calls, ",") == "identity,setup,load", "a full-capacity host turn must defer flight entirely")
assert(context.remainingSlots == 0 and not context.stage)

owner.documentLoaded = false
owner.store = {
    load = function(_, filename)
        assert(filename == "model" and context.flightTask.cost == context.scheduler.budget.capacity)
        calls[#calls + 1] = "document"
        return {}
    end,
}
owner.setDocument = function()
    owner.documentLoaded = true
end
fixture.requeue(context)
definition.background(context)
assert(calls[#calls] == "document" and context.remainingSlots == 0)

local reset = false
owner.filename = "old-model"
if context.aerogridMenu then
    context.aerogridMenu.modelFilename = "old-model"
end
owner.reset = function(_, filename)
    reset = true
    owner.filename, owner.documentLoaded = filename, false
end
fixture.requeue(context)
definition.refresh(context)
assert(reset and not owner.documentLoaded and context.scheduler.state(context.flightTask).pending)
assert(context.remainingSlots == 31, "identity reset must defer document work until a full grant fits")
definition.refresh(context)
assert(owner.documentLoaded and context.remainingSlots == 0)
assert(context.flightTask.cost == 1, "setup continues at the ordinary flight cost")

context.flightFactory.members = { [context] = {} }
context.document.legacyFlightArms = {}
context.flightSources = {}
context.serviceRuntime.byId.armed = {
    state = function()
        return { key = "armed" }
    end,
}
local count = #calls
context.configureFlight(context)
assert(#calls == count, "configuration must not synchronously pump flight outside the queue")
