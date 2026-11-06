-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.radio.values[300] = 1024
fixture.lvglMock.setFullScreen(true)
local context = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" })
local definition = fixture.module("main.lua")
fixture.pump(context, 80, 10)
assert(#context.errors == 0, table.concat(context.errors, ";"))
assert(context.serviceRuntime.byId.history.interval == 10)
assert(context.serviceRuntime.byId.telemetry.interval == 10)
local feed = assert(context.panels[1].instance.series[1].feed)
local before = assert(feed.revision)
context.document.future = {}
for index = 1, 256 do
    context.document.future[index] = index
end

local dispatch, refreshed = context.panelHost.dispatch, 0
context.panelHost.dispatch = function(entry, event, ...)
    if event == "refresh" then
        refreshed = refreshed + 1
    end
    return dispatch(entry, event, ...)
end
assert(context.editorController.openEditor(context))
assert(context.editorSession.initializing and context.editorUi.screen.hidden)
local copies, builds, duringCopy = 0, 0, before
for _ = 1, 256 do
    local copying = context.editorSession.initializing ~= nil
    if copying then
        copies = copies + 1
    else
        builds = builds + 1
    end
    fixture.tick(10)
    definition.refresh(context)
    fixture.lvglMock.settle()
    assert(#context.errors == 0, table.concat(context.errors, ";"))
    assert(refreshed == 0, "hidden panels must not refresh during editor construction")
    if copying then
        duringCopy = feed.revision
    end
    if context.editorUi.buildStage == nil then
        break
    end
end
assert(context.editorSession.initializing == nil and context.editorUi.buildStage == nil)
assert(copies > 20 and builds == 15)
assert(duringCopy > before + 4, "History must continue recording through a long document copy")
assert(feed.revision > duringCopy, "History must continue during UI construction")
assert(not context.editorUi.screen.hidden)
assert(context.editorSession.draft.future[256] == 256)
local state = context.editorUi
local placement = state.session.draft.panels[1]
placement.config.smoothing = placement.config.smoothing == "off" and "light" or "off"
placement.future = {}
for index = 1, 128 do
    placement.future[index] = index
end
state.session.dirty, state.previewPending = true, true
local partials, copySteps, previewRevision = 0, 0, feed.revision
for _ = 1, 256 do
    fixture.tick(10)
    definition.refresh(context)
    fixture.lvglMock.settle()
    assert(refreshed == 0, "hidden panels must not refresh while previews are rebuilt")
    local job = state.previewRefresh
    local action = job and job.actions[job.index]
    if action and action.copy then
        copySteps = copySteps + 1
    end
    local partial = context.pendingConstruction
    if partial then
        partials = partials + 1
        assert(partial.container.hidden)
        for _, entry in ipairs(context.panels) do
            assert(entry ~= partial, "partial previews must stay outside the live registry")
        end
    end
    if not state.previewPending and not state.previewRefresh then
        break
    end
end
assert(copySteps > 10 and partials > 3 and not state.previewError)
assert(feed.revision > previewRevision + 4, "preview cloning/construction must not suspend History")
assert(context.pendingConstruction == nil)
assert(context.panels[#context.panels].settings.smoothing == placement.config.smoothing)

placement.config.smoothing = placement.config.smoothing == "off" and "light" or "off"
state.previewPending = true
assert(fixture.pumpUntil(context, function(value)
    return value.pendingConstruction ~= nil
end, 256, 10))
local partial = context.pendingConstruction
local construct = partial.module.construct
partial.module.construct = function()
    return "invalid preview construction"
end
fixture.tick(10)
definition.refresh(context)
partial.module.construct = construct
assert(context.pendingConstruction == nil and state.previewError)
assert(string.find(state.previewError, "construct must return a boolean", 1, true))
assert(#context.errors == 0, "preview construction failures belong to the editor")

state.previewPending = true
assert(fixture.pumpUntil(context, function(value)
    return value.pendingConstruction ~= nil
end, 256, 10))
local cancelled = context.pendingConstruction
state.handlers.close(false)
assert(context.editorUi == nil and context.editorSession == nil)
fixture.tick(10)
definition.refresh(context)
fixture.lvglMock.settle()
assert(context.pendingConstruction == nil)
assert(cancelled.container.hidden, "cancelled preview must never be published")
for _ = 1, 200 do
    if context.reloadState == "rebuild" then
        break
    end
    fixture.tick(10)
    definition.refresh(context)
    fixture.lvglMock.settle()
    assert(cancelled.container.hidden, "cancelled preview must never be published")
end
assert(context.reloadState == "rebuild", "cancelled preview must finish bounded retirement")
context.panelHost.dispatch = dispatch
print("editor initialization: recording, hidden construction, preview failure/cancellation and publication passed")
