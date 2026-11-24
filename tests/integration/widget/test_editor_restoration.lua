-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local noGrant = assert(loadfile(root .. "/tests/support/no_grant.lua"))()
fixture.reset()
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(false)
local file = assert(fixture.hostIo.open(fixture.path .. "layouts/selective-restore.yaml", "w"))
file:write([[
version: 5
grid:
  columns: 4
  rows: 4
panels:
  - id: metric
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: ALT
  - id: chart
    type: chart
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
]])
file:close()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "selective-restore", Theme = "modern-dark" }, nil, definition)
fixture.pump(context, 60)
local refresh, worst = definition.refresh, 0
definition.refresh = function(host, ...)
    if not host.editorRestore then
        return refresh(host, ...)
    end
    fixture.lvglMock.setPropertyValidation(false)
    fixture.lvglMock.setCallCounting(false)
    fixture.lcdMock.setTextMeasurement(false)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    local ok, message = pcall(refresh, host, ...)
    debug.sethook()
    fixture.lvglMock.setPropertyValidation(true)
    fixture.lvglMock.setCallCounting(true)
    fixture.lcdMock.setTextMeasurement(true)
    assert(ok, message)
    worst = math.max(worst, instructions)
    assert(instructions <= 15000, "editor restoration callback exceeded its budget: " .. instructions)
end
local page, runtime = context.page, context.serviceRuntime
local history, session = runtime.byId.history, runtime.byId.history.sessions[1]
local chart = fixture.instanceOf(context, "chart")

local function untilReady(predicate)
    assert(fixture.pumpUntil(context, predicate, 500), "transition did not finish")
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
    assert(not context.reloadState and not context.stage, "editor restoration must not reload the dashboard")
    assert(
        context.page == page and context.serviceRuntime == runtime,
        "editor restoration preserves the page and services"
    )
    assert(
        history == runtime.byId.history and history.sessions[1] == session,
        "editor restoration preserves recordings"
    )
end
local function open()
    fixture.lvglMock.setFullScreen(true)
    context.aeroMenuHandlers.uiSetup()
    untilReady(function(host)
        return host.editorUi and not host.editorUi.buildStage
    end)
end
local function preview(label)
    assert(context.editorModule.setPath(context.editorSession, "metrics", { 1, "label" }, label))
    context.editorUi.previewPending = true
    untilReady(function(host)
        return not host.editorUi.previewPending and not host.editorUi.previewRefresh
    end)
    if context.editorSession.selected == 1 then
        assert(fixture.instanceOf(context, "metric").label.properties.text == label)
    end
end
local function restored()
    untilReady(function(host)
        return not host.editorRestore
    end)
    assert(fixture.instanceOf(context, "metric").label.properties.text == "ALT", "committed content is restored")
    assert(fixture.instanceOf(context, "chart") == chart, "unrelated charts keep their native instances")
    assert(context.panels[1].placement == context.document.panels[1], "restored services use the committed placement")
end

open()
preview("DISCARD")
local draft = context.editorSession
assert(context.editorModule.add(draft, "metric"))
draft.draft.panels[1].col, draft.draft.panels[1].row = 0, 2
context.editorUi.previewPending = true
untilReady(function(host)
    return not host.editorUi.previewPending and not host.editorUi.previewRefresh
end)
context.editorUi.handlers.close(false)
local job = assert(context.editorRestore)
noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    definition.background(context)
    assert(context.editorRestore == job and job.index == 1, "restoration waits for a full scheduler grant")
end)
definition.background(context)
assert(context.editorRestore == job and job.index == 1, "native restoration waits until the widget is visible")
restored()
assert(#context.panels == 2, "discard removes added preview panels")
assert(context.panels[1].container.properties.y == 0, "discard restores committed geometry")

open()
preview("SUSPENDED")
draft = context.editorSession
context.aeroMenuHandlers.modelSettings()
untilReady(function(host)
    return host.modelSettingsUi and not host.modelSettingsUi.build and not host.editorRestore
end)
assert(context.editorStash == draft and not context.editorUi, "Model settings suspend the edited draft")
restored()
lvgl.close(context.modelSettingsUi.dialog)
untilReady(function(host)
    return host.editorUi
        and not host.editorUi.buildStage
        and not host.editorUi.previewPending
        and not host.editorUi.previewRefresh
end)
assert(context.editorSession == draft, "closing Model settings resumes the same draft")
assert(fixture.instanceOf(context, "metric").label.properties.text == "SUSPENDED")
context.editorUi.handlers.close(false)
restored()

open()
preview("APP")
draft = context.editorSession
fixture.lvglMock.setFullScreen(false)
untilReady(function(host)
    return not host.editorUi and not host.editorRestore and not host.appRebuild and not host.reflowIndex
end)
restored()
assert(context.editorStash == draft, "App mode retains the edited draft")
fixture.lvglMock.setFullScreen(true)
untilReady(function(host)
    return host.editorUi
        and not host.editorUi.buildStage
        and not host.editorUi.previewPending
        and not host.editorUi.previewRefresh
end)
assert(context.editorSession == draft)
assert(fixture.instanceOf(context, "metric").label.properties.text == "APP", "fullscreen resumes content previews")
context.editorUi.handlers.close(false)
restored()

open()
assert(context.editorModule.select(context.editorSession, 2))
preview("CHART")
local previewChart = fixture.instanceOf(context, "chart")
assert(previewChart.preview and previewChart.history ~= history, "chart previews use read-only history")
context.editorUi.handlers.close(false)
untilReady(function(host)
    return not host.editorRestore
end)
local restoredChart = fixture.instanceOf(context, "chart")
assert(restoredChart ~= previewChart and not restoredChart.preview, "restored charts leave preview mode")
assert(
    restoredChart.history == history and restoredChart.session == session.view,
    "restored charts reconnect to live recording"
)
assert(fixture.instanceOf(context, "metric").label.properties.text == "ALT")
open()
preview("SUPERSEDED")
context.editorUi.handlers.close(false)
assert(context.editorRestore)
context.modelArmingReload, context.reloadState = true, "clear"
assert(
    fixture.pumpUntil(context, function(host)
        return not host.editorRestore and not host.modelArmingReload and not host.reloadState and not host.stage
    end, 500),
    "a necessary reload must supersede restoration without blocking arming"
)
assert(context.page ~= page and #context.errors == 0, "a superseding reload completes normally")
print("Selective editor restoration integration passed; worst callback: " .. worst .. " instructions")
