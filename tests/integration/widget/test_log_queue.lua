-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local noGrant = assert(loadfile(root .. "/tests/support/no_grant.lua"))()
fixture.reset()
EVT_TOUCH_FIRST, EVT_TOUCH_TAP, EVT_ROT_LEFT = 9201, 9202, 9203
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Diagnostics", Theme = "modern-dark" })
fixture.pump(context, 30)
local entry = assert(fixture.entryById(context, "sources"))
entry.settings.section = "log"
local rect = context.dashboardLoader.panelRect(context, entry.placement)
local point = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
local broker = context.flightFactory.broker
local flights = 0
context.flightTask = {
    broker = broker,
    step = function(_, _, slots)
        flights = flights + 1
        return slots, false
    end,
}
local function untilState(predicate, hidden)
    for _ = 1, 100 do
        if predicate() then
            return
        end
        if hidden then
            definition.background(context)
        else
            definition.refresh(context)
        end
    end
    error("queued log work did not finish")
end

definition.event(context, EVT_TOUCH_FIRST, point)
definition.event(context, EVT_TOUCH_TAP, point)
assert(context.inputQueue and not context.logOpenRequest and not context.logViewerModule)
untilState(function()
    return context.logOpenRequest ~= nil
end)
definition.background(context)
assert(context.logOpenRequest and not context.logViewer, "hidden callbacks retain entry without constructing UI")
noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    definition.background(context)
    assert(context.logOpenRequest and not context.logViewer)
end)
context.scheduler.cursor = 1
local before = flights
definition.refresh(context)
assert(flights == before + 1 and not context.logViewer, "opening must wait for its whole-capacity grant")
definition.refresh(context)
local state = assert(context.logViewer)
assert(flights == before + 1 and context.logOpenTask.cost == context.scheduler.capacity)
assert(not context.logOpenTask.pending and not context.logOpenRequest and state.prepareIndex)
untilState(function()
    return not state.prepareIndex
end)
local position, offset = state.index, state.offset
local touch = { x = 120, y = 100 }
context.logViewerModule.handle(context, EVT_TOUCH_FIRST, touch)
touch.y = 200
assert(state.inputs[1].touch.y == 100 and not state.dragY, "deferred input must retain its arrival coordinates")
untilState(function()
    return not state.inputs
end)
assert(state.dragY == 100)
context.logViewerModule.handle(context, EVT_ROT_LEFT)
assert(state.inputs and state.index == position and state.offset == offset, "viewer input cannot scroll synchronously")
local task = context.uiTasks["log viewer"]
context.scheduler.cursor = 1
definition.refresh(context)
assert(state.inputs and task.refused == context.scheduler.callbacks)
definition.refresh(context)
assert(not state.inputs and task.cost == context.scheduler.capacity and not task.pending)

state.closeButton.properties.press()
assert(context.logViewer == state and state.closing and not context.logOverlay.hidden)
noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    assert(context.logViewer == state and not context.logOverlay.hidden)
end)
definition.background(context)
assert(context.logViewer == state, "hidden callbacks cannot mutate the log overlay")
untilState(function()
    return not context.logViewer
end)
assert(context.logOverlay.hidden and not task.ui and not task.pending)
assert(task.cost == 1, "closing must not retain the viewer's full-budget reservation")

-- Retired buttons cannot close a later viewer that reused the overlay.
definition.event(context, EVT_TOUCH_FIRST, point)
definition.event(context, EVT_TOUCH_TAP, point)
untilState(function()
    return context.logViewer ~= nil
end)
local nextState = context.logViewer
state.closeButton.properties.press()
assert(not nextState.closing, "stale native callbacks must not affect a replacement viewer")
context.zone.w = 320
untilState(function()
    return not context.logViewer
end)
assert(context.logOverlay.hidden, "geometry cancellation closes on a granted viewer turn")
context.zone.w = 480
fixture.pump(context, 30)

definition.event(context, EVT_TOUCH_FIRST, point)
definition.event(context, EVT_TOUCH_TAP, point)
untilState(function()
    return context.logOpenRequest ~= nil
end)
local filename = fixture.radio.modelFilename
fixture.radio.modelFilename = "another-model.yml"
untilState(function()
    return not context.logOpenRequest
end)
assert(not context.logViewer, "deferred entry cannot open a snapshot for a different model")
fixture.radio.modelFilename = filename

definition.event(context, EVT_TOUCH_FIRST, point)
definition.event(context, EVT_TOUCH_TAP, point)
untilState(function()
    return context.logOpenRequest ~= nil
end)
fixture.lvglMock.setFullScreen(false)
untilState(function()
    return not context.logOpenRequest
end)
assert(not context.logViewer, "stale entry cannot construct an overlay after fullscreen exit")

fixture.lvglMock.setFullScreen(true)
assert(fixture.pumpUntil(context, function()
    return not context.stage and not context.reloadState and not context.lifecycleRequest
end, 200))
fixture.pump(context, 10)
entry = assert(fixture.entryById(context, "sources"))
entry.settings.section = "log"
rect = context.dashboardLoader.panelRect(context, entry.placement)
point = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
definition.event(context, EVT_TOUCH_FIRST, point)
definition.event(context, EVT_TOUCH_TAP, point)
untilState(function()
    return context.logOpenRequest ~= nil
end)
local oldPage = context.page
context.page = {}
untilState(function()
    return not context.logOpenRequest
end)
context.page = oldPage
assert(not context.logViewer, "deferred entry cannot construct under a replaced page")
