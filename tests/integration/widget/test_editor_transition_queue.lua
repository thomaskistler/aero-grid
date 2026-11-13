-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 20)
context.document.panels, context.emptyHint = { {} }, nil
context.serviceRuntime = context.servicesModule.runtime({})
local opened, closed, restored, flightSteps = 0, 0, 0, 0
context.editorController.openEditor = function()
    assert(context.editorTransitionTask.cost == context.scheduler.capacity)
    opened = opened + 1
    return true
end
context.editorController.restorePreview = function()
    assert(context.editorTransitionTask.cost == context.scheduler.capacity)
    restored = restored + 1
end
context.editorUiModule = {
    close = function(_, discard)
        assert(discard == false)
        closed = closed + 1
        context.editorUi = nil
    end,
}
local broker = { documentLoaded = true, filename = context.aerogridMenu.modelFilename }
context.flightFactory = { broker = broker }
context.flightTask = {
    broker = broker,
    step = function()
        flightSteps = flightSteps + 1
    end,
}
context.aeroMenuHandlers.uiSetup()
assert(opened == 0 and context.editorTransitionRequest == "open", "menu action only records editor entry")
definition.background(context)
assert(opened == 0 and context.editorTransitionRequest == "open", "hidden callbacks retain pending entry")
context.scheduler.cursor = 1
definition.refresh(context)
assert(opened == 0 and flightSteps == 2, "editor entry must wait for full capacity")
definition.refresh(context)
assert(opened == 1 and flightSteps == 2 and not context.editorTransitionRequest)
local task = context.editorTransitionTask
assert(not task.pending, "opening cannot advance editor construction in the same callback")
context.flightFactory = nil

local draft = { dirty = true }
context.editorSession, context.editorUi = draft, {}
context.aeroMenuModal = true
fixture.lvglMock.setFullScreen(false)
for _ = 1, 10 do
    definition.refresh(context)
    if closed == 1 then
        break
    end
end
assert(closed == 1 and restored == 1 and context.editorStash == draft)
assert(not context.editorSession and not task.pending)
context.editorTransitionRequest = "open"
fixture.lvglMock.setFullScreen(true)
for _ = 1, 10 do
    definition.refresh(context)
    if opened == 2 then
        break
    end
end
assert(opened == 2, "fullscreen return grants draft resumption separately")
context.editorStash = nil
context.editorUi, context.editorSession = {}, draft
context.modelArmingReload = true
context.sessionResetPending = true
definition.background(context)
assert(closed == 1 and context.editorTransitionRequest == "suspend", "arming routing cannot restore a preview")
definition.background(context)
assert(closed == 2 and restored == 2 and context.editorStash == draft)
assert(not context.modelArmingReload and context.sessionResetPending, "suspension precedes session reset")
context.sessionResetPending, context.editorStash = nil, nil

context.editorTransitionRequest = "open"
fixture.lvglMock.setFullScreen(false)
for _ = 1, 10 do
    definition.refresh(context)
    if not context.editorTransitionRequest then
        break
    end
end
assert(opened == 2 and not context.editorTransitionRequest, "stale entry must not open an editor in App mode")
