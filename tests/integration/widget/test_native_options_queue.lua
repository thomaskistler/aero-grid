-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local noGrant = assert(loadfile(root .. "/tests/support/no_grant.lua"))()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 20)
local factory, broker = context.flightFactory, context.flightFactory.broker
local member, revision = factory.members[context], factory.revision
local closed, restored, flightSteps = 0, 0, 0
context.editorSession, context.editorStash, context.editorUi = {}, {}, { saving = {} }
context.editorTransitionRequest, context.modelSettingsRequest = "open", true
context.editorUiModule = {
    close = function(_, discard)
        assert(context.optionsTask.cost == context.scheduler.capacity)
        assert(discard == true, "changing native options discards the old draft and any unfinished save")
        closed = closed + 1
        context.editorUi = nil
    end,
}
context.editorController.restorePreview = function()
    assert(context.optionsTask.cost == context.scheduler.capacity)
    restored = restored + 1
end
context.flightTask = {
    broker = broker,
    step = function()
        flightSteps = flightSteps + 1
    end,
}
local pending = member.pending
definition.update(context, { Layout = "Default", Theme = "modern-light" })
assert(closed == 0 and restored == 0 and context.editorStash)
assert(context.layoutName == "Empty" and context.themeMode == "modern-dark" and not context.reloadState)
assert(member.pending == pending and factory.revision == revision, "native update cannot mutate shared membership")

definition.update(context, { Layout = "Default", Theme = "modern-dark" })
assert(context.optionsRequest.themeMode == "modern-dark", "only the latest option selection is applied")
definition.update(context, { Layout = "Empty", Theme = "modern-dark" })
assert(not context.optionsRequest, "returning to the active options cancels a deferred change")
definition.update(context, { Layout = "Default", Theme = "modern-light" })
context.scheduler.cursor = 1
noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    definition.background(context)
    assert(closed == 0 and restored == 0 and flightSteps == 0 and context.optionsRequest)
    assert(member.pending == pending and factory.revision == revision)
end)
definition.background(context)
assert(flightSteps == 1 and closed == 0 and context.optionsRequest, "option changes must wait for their full grant")
definition.background(context)
assert(flightSteps == 1 and closed == 1 and restored == 1)
assert(context.layoutName == "Default" and context.themeMode == "modern-light")
assert(member.pending and factory.revision == revision + 1)
assert(not context.editorSession and not context.editorStash and not context.editorTransitionRequest)
assert(not context.modelSettingsRequest and not context.optionsRequest)
assert(context.reloadState == "clear" and context.page and not context.page.cleared)
assert(not context.optionsTask.pending, "option application must not retire/rebuild the page in the same callback")

context.flightTask = nil
fixture.pump(context, 150)
assert(not context.stage and not context.reloadState and #context.errors == 0, table.concat(context.errors, "\n"))
assert(context.document and #context.document.panels > 0, "the deferred option change must finish loading")
