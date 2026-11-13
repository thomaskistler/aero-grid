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
    step = function()
        flights = flights + 1
    end,
}
local function tick()
    context.scheduler.cursor = 1
    definition.refresh(context)
end
local state = {}
context.locationDetails = state
context.aeroMenuModal = true
context.locationDetailsModule = {
    close = function()
        closes = closes + 1
        context.locationDetails = nil
    end,
}
context.locationRequest = { kind = "close", state = state }
tick()
assert(flights == 1 and closes == 1 and context.remainingSlots == context.scheduler.capacity - 2)
assert(context.locationTask.spent == 1 and not context.locationTask.pending)

context.locationDetails = state
context.locationRequest = { kind = "close", state = {} }
tick()
assert(closes == 1 and context.locationDetails == state, "small close grants still reject stale owners")
context.locationDetails = nil

context.logViewer = { closing = true, width = context.zone.w - 16, height = context.zone.h }
context.uiRequest = "log viewer"
context.logViewerModule = {
    advanceInput = function()
        closes = closes + 1
        context.logViewer = nil
    end,
}
-- Match the existing modal state so menu maintenance does not take this turn.
context.aeroMenuModal = true
local before = flights
tick()
assert(closes == 2 and flights == before + 1)
assert(context.uiTasks["log viewer"].spent == 1)
assert(context.remainingSlots == context.scheduler.capacity - 2)
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
assert(not retired and context.lifecycleRequest == "retire", "flight defers full-budget retirement")
definition.refresh(context)
assert(retired and rebuilds == 0 and not context.lifecycleTasks.retire.pending)
before = flights
tick()
assert(rebuilds == 1 and flights == before + 1 and context.stage == "probe")
assert(context.lifecycleTasks.rebuild.spent == 1 and not context.lifecycleTasks.rebuild.pending)
assert(context.remainingSlots == context.scheduler.capacity - 2)
assert(#context.errors == 0, table.concat(context.errors, "\n"))
