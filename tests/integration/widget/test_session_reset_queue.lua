-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local noGrant = assert(loadfile(root .. "/tests/support/no_grant.lua"))()
fixture.reset()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 10)
context.flightFactory = nil
context.document.panels, context.emptyHint = { {} }, nil
context.serviceRuntime = context.servicesModule.runtime({})
local items, panelTurns, liveTurns = 0, 0, 0
local now = getTime()
local service = {
    id = "resettable",
    count = 1,
    interval = 0,
    revision = 0,
    update = function()
        liveTurns = liveTurns + 1
    end,
    resetSession = function(_, resetTime, item)
        assert(resetTime == now, "a reset job keeps its original time")
        assert(context.sessionResetTask.cost == context.scheduler.capacity)
        items = items + 1
        assert(item == items)
        return item < 10 and item + 1 or nil
    end,
}
context.servicesModule.register(context.serviceRuntime, service, now)
context.panels = {
    {
        placement = { id = "panel" },
        instance = {},
        interval = 0,
        module = {
            id = "panel",
            resetSession = function()
                panelTurns = panelTurns + 1
                return nil, panelTurns < 2
            end,
            refresh = function()
                liveTurns = liveTurns + 1
            end,
        },
    },
}
context.sessionResetPending = true
noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    definition.background(context)
    assert(items == 0 and panelTurns == 0 and liveTurns == 0 and not context.sessionResetJob)
end)
context.scheduler.cursor = 1
definition.refresh(context)
assert(items == 8 and panelTurns == 0 and liveTurns == 0)
assert(context.sessionResetTask.pending and context.remainingSlots == 0)
assert(context.sessionResetTask.spent == context.scheduler.capacity)
fixture.tick(10)
definition.background(context)
assert(items == 10 and service.revision == 1 and service.due == now)
assert(context.sessionResetTask.pending and panelTurns == 0)
definition.refresh(context)
assert(panelTurns == 1 and context.sessionResetTask.pending)
definition.background(context)
assert(panelTurns == 2 and context.sessionResetPending)
definition.refresh(context)
assert(not context.sessionResetPending and not context.sessionResetJob and not context.sessionResetTask.pending)
assert(liveTurns == 0, "reset completion still owns its whole callback")
assert(context.sessionResetTask.spent == 5 * context.scheduler.capacity)
definition.refresh(context)
assert(liveTurns == 2, "normal queued work resumes after reset completion")

local runs = context.sessionResetTask.ran
context.sessionResetPending = true
context.stage = "probe"
context.lifecycleRequest = "load"
context.dashboardLoader.advanceLoad = function()
    context.stage = nil
end
definition.refresh(context)
assert(context.sessionResetTask.ran == runs, "loading must block reset")
assert(context.sessionResetPending and not context.stage)

local flightTurns = 0
context.flightFactory = {
    broker = {
        filename = "model",
        documentLoaded = true,
        session = true,
        state = {},
        errors = {},
        view = { diagnosticRevision = 0, epoch = 1 },
        identity = function()
            return "model"
        end,
        tick = function()
            flightTurns = flightTurns + 1
        end,
    },
}
context.flightReportedRevision, context.flightReportedEpoch = 0, 1
context.sessionResetPending, context.sessionResetJob = true, nil
items, panelTurns = 0, 0
now = getTime()
context.scheduler.cursor = 1
definition.refresh(context)
assert(flightTurns == 1 and items == 0, "reset cannot run after flight consumed a slot")
definition.refresh(context)
assert(flightTurns == 1 and items == 8, "deferred reset receives the next full grant")

context.flightFactory = nil
context.sessionResetJob = nil
service.resetSession = function()
    error("deliberate reset failure", 0)
end
definition.refresh(context)
assert(service.failed and context.sessionResetJob.service == 2)
assert(string.find(table.concat(context.errors, "\n"), "deliberate reset failure", 1, true))
assert(not context.sessionResetTask.failed, "a service reset failure must not retire the reset task")
