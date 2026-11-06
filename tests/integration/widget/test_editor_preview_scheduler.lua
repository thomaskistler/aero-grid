-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local function check(panel, ownership)
    fixture.reset()
    fixture.lvglMock.setFullScreen(true)
    local context = fixture.createLoaded(nil, { Layout = "review-" .. panel, Theme = "modern-dark" })
    local scheduling = assert(context.schedulerHost)
    local owners = {}
    for key, value in pairs(scheduling.owners) do
        owners[key] = value
    end
    owners["panel:" .. panel] = ownership
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
    if ownership == "new" then
        assert(steps > 0, "visible editor previews must retain scheduler progress")
        assert(refreshes == 0, "scheduler-owned previews must not also dispatch legacy refresh")
    else
        assert(steps == 0 and refreshes > 0, "bounded admission must preserve legacy preview progress")
        local legacy = scheduling.legacy
        local panelCost, deadlines = legacy.panelCost, {}
        for index, entry in ipairs(context.panels) do
            deadlines[index] = entry.nextRefresh
        end
        legacy.panelCost = function()
            return scheduling.scheduler.CEILING
        end
        refreshes = 0
        context.panelHost.dispatch = function(entry, event, ...)
            if event == "refresh" then
                refreshes = refreshes + 1
            end
            return dispatch(entry, event, ...)
        end
        fixture.pump(context, 6, 10)
        assert(refreshes == 0, "over-budget previews must remain deferred")
        for index, entry in ipairs(context.panels) do
            assert(entry.nextRefresh == deadlines[index], "deferring a preview must preserve its deadline")
        end
        legacy.panelCost = panelCost
        fixture.pump(context, 80, 10)
        assert(refreshes > 0, "deferred previews must resume when their work fits")
        context.panelHost.dispatch = dispatch
    end
end

for _, panel in ipairs({ "metric", "chart" }) do
    for _, ownership in ipairs({ "legacy", "new" }) do
        check(panel, ownership)
    end
end
print("Editor preview scheduler: visible progress without duplicate legacy refresh passed")
