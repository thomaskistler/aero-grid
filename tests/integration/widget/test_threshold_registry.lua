-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local definition = fixture.module("main.lua")

local function metricPanel(id, col, warning)
    return string.format(
        [[
  - id: %s
    type: metric
    col: %d
    row: 0
    colSpan: 1
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          rangeMax: 500
          warning: %d
]],
        id,
        col,
        warning
    )
end

fixture.reset()
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(false)
local path = fixture.makeWidget(
    "thresholds",
    "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n"
        .. metricPanel("high", 0, 300)
        .. metricPanel("low", 1, 100)
        .. [[
  - id: rx
    type: rx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      cellWarning: 3.6
      cellCritical: 3.4
]]
)
local context = fixture.createLoaded(nil, { Layout = "main", Theme = "modern-dark" }, path, definition)
fixture.pump(context, 80)
local runtime = context.serviceRuntime
local telemetry = runtime.byId.telemetry

local function altWarning()
    local spec = telemetry:thresholds("Alt")
    return spec and spec.warning
end

local function settle(predicate)
    assert(fixture.pumpUntil(context, predicate, 500), "transition did not finish")
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
end

local function appRebuild(id)
    local entry = fixture.entryById(context, id)
    entry.builtFullscreen = true
    settle(function(host)
        return host.appRebuild ~= nil
    end)
    settle(function(host)
        return host.appRebuild == nil
    end)
    assert(fixture.entryById(context, id) ~= entry, "the panel was not rebuilt")
end

local function openEditor()
    fixture.lvglMock.setFullScreen(true)
    context.editorController.openEditor(context)
    settle(function(host)
        return host.editorUi and not host.editorUi.buildStage
    end)
    return context.editorSession, context.editorUi.handlers
end

local function preview(draft, handlers)
    local job = handlers.startPreview(draft)
    for _ = 1, 50 do
        local done, message = handlers.advancePreview(job)
        assert(not message, message)
        if done then
            return
        end
    end
    error("preview did not settle")
end

local function save(draft, handlers)
    local job = handlers.startSave(draft)
    for _ = 1, 200 do
        local done, saved, message = handlers.advanceSave(job)
        if done then
            assert(saved, message)
            handlers.close(true)
            settle(function(host)
                return not host.editorUi and not host.reloadState and not host.stage
            end)
            assert(context.serviceRuntime == runtime, "Save must adopt the previewed panels without reloading")
            return
        end
    end
    error("save did not settle")
end

equal(altWarning(), 300, "the first panel in the layout wins")
equal(telemetry:thresholds("VCel").critical, 3.4)

-- An App-mode rebuild replaces one panel at a time; ownership stays put.
appRebuild("high")
equal(altWarning(), 300, "a rebuilt panel keeps its place")

-- Previews never register, so a flight ending mid-edit keeps saved thresholds.
local session, handlers = openEditor()
session.draft.panels[1].config.metrics[1].warning = 250
preview(session.draft, handlers)
equal(altWarning(), 300, "a draft threshold took effect before Save")
handlers.close(false)
settle(function(host)
    return not host.editorUi and not host.editorRestore
end)
equal(altWarning(), 300, "cancel restores the saved threshold")

session, handlers = openEditor()
session.draft.panels[1].config.metrics[1].warning = 250
preview(session.draft, handlers)
save(session.draft, handlers)
equal(altWarning(), 250, "Save adopts the new threshold")

session, handlers = openEditor()
local panels = session.draft.panels
panels[1], panels[2] = panels[2], panels[1]
save(session.draft, handlers)
equal(altWarning(), 100, "reordering the layout changes the winner")

session, handlers = openEditor()
assert(context.editorModule.remove(session, 1))
preview(session.draft, handlers)
save(session.draft, handlers)
equal(altWarning(), 250, "deleting the winner hands its sensor to the next panel")
equal(telemetry.thresholdOwners.low, nil, "a deleted panel is pruned")

-- A rebuild that fails to create clears the panel's registration.
fixture.lvglMock.setFullScreen(false)
settle(function(host)
    return host.appRebuild == nil and not host.reflowIndex
end)
local entry = fixture.entryById(context, "high")
entry.builtFullscreen = true
telemetry.subscribe = function()
    error("create failed")
end
assert(fixture.pumpUntil(context, function(host)
    return host.appRebuild == nil and fixture.entryById(host, "high") ~= entry
end, 500))
telemetry.subscribe = nil
assert(#context.errors > 0, "the failed create was not reported")
equal(altWarning(), nil, "a failed create kept its thresholds")
equal(telemetry:thresholds("VCel").critical, 3.4)
fixture.reset()
