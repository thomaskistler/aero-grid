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
context.editorUi.handlers.close(false)
assert(context.editorUi == nil and context.editorSession == nil)
context.panelHost.dispatch = dispatch
print("editor initialization: service cadence, hidden-panel exclusion and completed publication passed")
