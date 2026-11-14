-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local noGrant = assert(loadfile(root .. "/tests/support/no_grant.lua"))()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 20)
context.flightFactory = nil
context.document.panels, context.emptyHint = { {} }, nil
context.serviceRuntime = context.servicesModule.runtime({})
context.editorUi = { buildStage = 1 }
context.aeroMenuModal = true
local steps = 0
context.editorController.advanceEditor = function()
    local task = assert(context.uiTasks.editor)
    assert(task.cost == (context.editorUi.saving and context.scheduler.capacity or 3))
    steps = steps + 1
    local state = context.editorUi
    if state.saving then
        state.saving = state.saving > 1 and state.saving - 1 or nil
    else
        state.buildStage = state.buildStage < 3 and state.buildStage + 1 or nil
    end
end
definition.refresh(context)
assert(steps == 0 and context.uiRequest == "editor", "host routing must not perform editor advancement")
noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    definition.background(context)
    assert(steps == 0 and context.editorUi.buildStage == 1)
end)
definition.background(context)
assert(steps == 0, "hidden callbacks must not build the editor")
definition.refresh(context)
assert(steps == 0 and context.uiRequest == "editor")
definition.refresh(context)
local task = context.uiTasks.editor
assert(steps == 1 and not task.pending, "editor phases keep native callback separation")
definition.refresh(context)
definition.refresh(context)
assert(steps == 3 and not context.uiRequest and not context.editorUi.buildStage)
context.editorUi.saving = 2
context.modelArmingReload = true
context.uiRequest = "editor"
context.sessionResetPending = true
noGrant(context, fixture.lvglMock.objects, function()
    definition.background(context)
    assert(steps == 3 and context.editorUi.saving == 2)
end)
definition.background(context)
assert(steps == 4 and context.editorUi.saving == 1, "arming-driven save takes precedence over reset")
definition.refresh(context)
assert(steps == 5 and not context.editorUi.saving and context.modelArmingReload)
assert(not task.ready(task, getTime(), false), "completed save must return to arming suspension")
context.sessionResetPending, context.modelArmingReload = nil, nil
context.editorUi.previewPending = true
assert(task.ready(task, getTime(), false))
assert(not task.ready(task, getTime(), true), "hidden callbacks cannot rebuild previews")
fixture.lvglMock.setFullScreen(false)
assert(not task.ready(task, getTime(), false), "fullscreen exit must return to editor teardown")
context.editorUi.saving = 1
assert(task.ready(task, getTime(), true), "hidden callbacks finish an already-started save")
context.editorUi = nil
definition.background(context)
assert(not task.ui, "closed editors must be released from cached tasks")
