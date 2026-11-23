-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 30)
local broker = context.flightFactory.broker
local flights, closes, rebuilds = 0, 0, 0
context.flightTask = {
    name = "flight",
    owner = "flight",
    broker = broker,
    step = function(_, _, slots)
        flights = flights + 1
        return slots, false
    end,
}
local function tick()
    fixture.requeue(context)
    definition.refresh(context)
end
local function spent()
    return context.scheduler.state(context.hostTask).spent
end
local state = {}
local spentBefore = spent()
context.locationDetails = state
context.aeroMenuModal = true
context.locationDetailsModule = {
    close = function()
        closes = closes + 1
        context.locationDetails = nil
    end,
}
state.closing = true
tick()
assert(flights == 1 and closes == 1 and context.remainingSlots == context.scheduler.budget.capacity - 2)
assert(spent() == spentBefore + 1 and not context.scheduler.state(context.hostTask).pending)

state = {}
context.locationDetails = state
tick()
assert(closes == 1 and context.locationDetails == state, "only a closing overlay is closed")
context.locationDetails = nil

context.logViewer = { closing = true, width = context.zone.w - 16, height = context.zone.h }
context.logViewerModule = {
    close = function()
        closes = closes + 1
        context.logViewer = nil
    end,
}
-- Match the existing modal state so menu maintenance does not take this turn.
context.aeroMenuModal = true
local before = flights
spentBefore = spent()
tick()
assert(closes == 2 and flights == before + 1)
assert(spent() == spentBefore + 1)
assert(context.remainingSlots == context.scheduler.budget.capacity - 2)
context.aeroMenuModal = false

local retired
context.dashboardLifecycle.retirePage = function()
    retired = context.scheduler.callbacks
    context.reloadState = "rebuild"
end
context.dashboardLifecycle.rebuildPage = function()
    assert(context.scheduler.callbacks > retired, "rebuild must stay on a later native callback")
    rebuilds = rebuilds + 1
    context.reloadState = nil
end
context.dashboardLoader.beginLoad = function()
    context.stage = "probe"
end
context.dashboardLoader.advanceLoad = function()
    error("rebuild cannot also execute loading")
end
context.reloadState = "clear"
tick()
assert(not retired and context.hostKind == "retire", "flight defers full-budget retirement")
definition.refresh(context)
assert(retired and rebuilds == 0 and not context.scheduler.state(context.hostTask).pending)
before, spentBefore = flights, spent()
tick()
assert(rebuilds == 1 and flights == before + 1 and context.stage == "probe")
assert(spent() == spentBefore + 4 and not context.scheduler.state(context.hostTask).pending)
assert(context.remainingSlots == context.scheduler.budget.capacity - 5)
assert(#context.errors == 0, table.concat(context.errors, "\n"))
