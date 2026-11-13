-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
EVT_TOUCH_FIRST, EVT_TOUCH_TAP, EVT_VIRTUAL_EXIT = 9501, 9502, 9503
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "review-navigation", Theme = "modern-dark" })
fixture.pump(context, 40)
local entry = assert(fixture.entryById(context, "compass"))
local rect = context.dashboardLoader.panelRect(context, entry.placement)
local point = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
local feed = { fix = true, state = "normal", latitude = 47, longitude = 8 }
entry.instance.feed = feed
local broker = context.flightFactory.broker
local flights = 0
context.flightTask = {
    broker = broker,
    step = function()
        flights = flights + 1
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
    error("location work did not receive its grant")
end
local function requestOpen()
    definition.event(context, EVT_TOUCH_FIRST, point)
    definition.event(context, EVT_TOUCH_TAP, point)
    untilState(function()
        return context.locationRequest ~= nil
    end)
end
requestOpen()
assert(context.locationRequest.kind == "open" and not context.locationDetailsModule and not context.locationOverlay)
feed.latitude, feed.longitude = -33, 151
definition.background(context)
assert(context.locationRequest and not context.locationOverlay, "hidden callbacks retain entry without building")
untilState(function()
    return not (context.aerogridMenu and context.aerogridMenu.selectionDirty)
end)
context.scheduler.cursor = 1
local before = flights
definition.refresh(context)
assert(flights == before + 1 and not context.locationDetails, "location opening waits for a whole-capacity grant")
untilState(function()
    return context.locationDetails ~= nil
end)
local state = assert(context.locationDetails)
assert(flights == before + 1 and state.latitude == 47 and state.longitude == 8)
assert(context.locationTask.cost == context.scheduler.capacity and not context.locationTask.pending)
assert(state.url == "https://www.google.com/maps/search/?api=1&query=47.000000,8.000000")

context.locationDetailsModule.handle(context, EVT_VIRTUAL_EXIT)
assert(
    context.locationDetails == state and context.locationRequest.kind == "close" and not context.locationOverlay.hidden
)
definition.background(context)
assert(context.locationDetails == state, "hidden callbacks cannot clear an overlay")
untilState(function()
    return not context.locationDetails
end)
assert(context.locationOverlay.hidden and not context.locationRequest and not context.locationTask.pending)

requestOpen()
untilState(function()
    return context.locationDetails ~= nil
end)
assert(context.locationDetails.latitude == -33 and context.locationDetails.longitude == 151)
context.locationDetailsModule.handle(context, EVT_VIRTUAL_EXIT)
local replacement = {}
context.locationDetails = replacement
untilState(function()
    return not context.locationRequest
end)
assert(
    context.locationDetails == replacement and not context.locationRequest,
    "stale closes cannot clear a replacement"
)
context.locationDetails = nil

requestOpen()
local filename = fixture.radio.modelFilename
fixture.radio.modelFilename = "another-model.yml"
untilState(function()
    return not context.locationRequest
end)
assert(not context.locationDetails, "deferred entry is tied to its original model")
fixture.radio.modelFilename = filename
requestOpen()
fixture.lvglMock.setFullScreen(false)
untilState(function()
    return not context.locationRequest
end)
assert(not context.locationDetails, "fullscreen exit cancels ungranted entry")
