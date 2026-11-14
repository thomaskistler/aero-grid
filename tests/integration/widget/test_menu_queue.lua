-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 20)
local menu = context.aerogridMenu
local advances, flightSteps = 0, 0
local advance = context.aeroMenuModule.advance
context.aeroMenuModule.advance = function(host)
    assert(host.menuTask.ran ~= host.scheduler.callbacks, "advance is called before grant attribution")
    assert(host.menuTask.cost == host.scheduler.capacity)
    advances = advances + 1
    return advance(host)
end
local broker = { documentLoaded = true, filename = menu.modelFilename }
context.flightFactory = { broker = broker }
context.flightTask = {
    broker = broker,
    step = function(_, _, slots)
        flightSteps = flightSteps + 1
        return slots, false
    end,
}
menu.pending = true
context.scheduler.cursor = 1
definition.refresh(context)
assert(flightSteps == 1 and advances == 0 and menu.pending, "menu must wait for a full-capacity pre-grant")
definition.refresh(context)
assert(flightSteps == 1 and advances == 1 and menu.open and not menu.pending)
assert(not context.menuTask.pending, "menu transitions retain callback separation")
context.flightFactory = nil
definition.refresh(context)
assert(advances == 1, "idle menu state must not enroll preparation work")
menu.selected, menu.selectionDirty = 2, true
definition.refresh(context)
assert(advances == 2 and not menu.selectionDirty)
menu.dismiss = true
definition.background(context)
assert(advances == 2 and menu.dismiss, "hidden callbacks must not process menu actions")
definition.refresh(context)
assert(advances == 3 and not menu.open)
local actions = 0
menu.handlers.uiSetup = function()
    assert(context.menuTask.cost == context.scheduler.capacity)
    actions = actions + 1
end
menu.action = "uiSetup"
definition.refresh(context)
assert(advances == 4 and actions == 1 and not menu.action)
menu.pending = true
EVT_VIRTUAL_ENTER = 992
definition.refresh(context, EVT_VIRTUAL_ENTER)
assert(menu.open and context.inputQueue, "menu construction retains input for the host route")
menu.selected = 2
definition.refresh(context)
assert(menu.action == "uiSetup" and not context.inputQueue and actions == 1)
definition.refresh(context)
assert(actions == 2 and not menu.action, "input only records the action; the menu task performs it")

context.stage = "probe"
context.dashboardLoader.advanceLoad = function()
    context.stage = nil
end
fixture.lvglMock.setFullScreen(false)
definition.refresh(context)
assert(context.chromeRoot.hidden and context.stage == "probe", "chrome hiding stays queued even during loading")
assert(context.menuTask.ran == context.scheduler.callbacks)
definition.background(context)
assert(not context.menuTask.ready(context.menuTask, getTime(), true))
