-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
for _, panel in ipairs({ "metric", "chart" }) do
    fixture.reset()
    fixture.lvglMock.setFullScreen(true)
    local context = fixture.createLoaded(nil, { Layout = "review-" .. panel, Theme = "modern-dark" })
    local scheduling = assert(context.schedulerHost)
    local owners = {}
    for key, value in pairs(scheduling.owners) do
        owners[key] = value
    end
    owners["panel:" .. panel] = "new"
    scheduling.owners, context.panelTasksDirty = owners, true
    fixture.pump(context, 80, 10)
    assert(context.editorController.openEditor(context))
    for _ = 1, 100 do
        fixture.tick(10)
        definition.refresh(context)
        fixture.lvglMock.settle()
        if not context.editorUi.buildStage then
            break
        end
    end
    assert(not context.editorUi.buildStage and not context.editorSession.initializing)
    local dispatch, refreshes, steps = context.panelHost.dispatch, 0, 0
    context.panelHost.dispatch = function(entry, event, ...)
        if event == "refresh" then
            refreshes = refreshes + 1
        elseif event == "step" then
            steps = steps + 1
        end
        return dispatch(entry, event, ...)
    end
    for _ = 1, 80 do
        fixture.tick(10)
        definition.refresh(context)
        fixture.lvglMock.settle()
        assert(#context.errors == 0, table.concat(context.errors, ";"))
    end
    context.panelHost.dispatch = dispatch
    assert(steps > 0, "visible editor previews must retain scheduler progress")
    assert(refreshes == 0, "scheduler-owned previews must not also dispatch legacy refresh")
end
print("Editor preview scheduler: visible progress without duplicate legacy refresh passed")
