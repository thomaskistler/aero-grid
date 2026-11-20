-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
fixture.reset()
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(true)
lvgl.UI_ELEMENT_HEIGHT = 32
local context =
    fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" }, root .. "/build/test-widget-fixture/")
fixture.pump(context, 100)
local history = context.serviceRuntime.byId.history
local original = fixture.instanceOf(context, "power")
assert(original.series[1].feed.available)
local feed, session = original.series[1].feed, original.session
local subscriptions = history.count
local telemetry = context.serviceRuntime.byId.telemetry
local controls = context.serviceRuntime.byId.control
local telemetryCount, controlCount = telemetry.count, controls.count

local function preview(edit)
    context.editorController.openEditor(context)
    assert(fixture.pumpUntil(context, function()
        return context.editorUi and not context.editorUi.buildStage
    end, 300))
    local draft, handlers = context.editorSession.draft, context.editorUi.handlers
    edit(draft.panels[1].config)
    local job = handlers.startPreview(draft)
    for _ = 1, 50 do
        local done, message = handlers.advancePreview(job)
        assert(not message, message)
        if done then
            return draft, handlers
        end
    end
    error("chart preview did not settle")
end
local function save(draft, handlers)
    local job = handlers.startSave(draft)
    for _ = 1, 200 do
        local done, saved, message = handlers.advanceSave(job)
        if done then
            assert(saved, message)
            handlers.close(true)
            return
        end
    end
    error("chart save did not settle")
end
local draft, handlers = preview(function(config)
    config.label = "In-flight preview"
end)
local compatible = fixture.instanceOf(context, "power")
assert(compatible.preview and not compatible.previewMissing)
equal(compatible.series[1].feed, feed)
assert(
    fixture.pumpUntil(context, function()
        return compatible.columnRenderer and compatible.columnRenderer.published[1]
    end, 2500),
    "editor preview did not initialize its empty presentation"
)
assert(next(compatible.columnConsumers[1].map.kinds) == nil, "previews must not reconstruct recorded history")
equal(history.count, subscriptions)
equal(telemetry.count, telemetryCount)
equal(controls.count, controlCount)
save(draft, handlers)
equal(context.reloadState, nil, "saving a compatible visual edit must not clear live history")
equal(context.serviceRuntime.byId.history, history)
equal(compatible.history, history)
equal(compatible.preview, false)
equal(compatible.session, session)
equal(compatible.series[1].feed, feed)
fixture.pump(context, 200)
assert(
    not compatible.columnConsumers[1].readonly and compatible.columnConsumers[1].history == history,
    "saving a compatible preview must attach observers for new telemetry"
)

local sections = {
    { tiles = { { title = "Link", colSpan = 2, rowSpan = 2, series = { { source = "RQly", statistic = "min" } } } } },
    { tiles = {} },
    false,
}
-- A layout that has never had a debrief records one derived from its chart.
assert(context.debriefGenerated and #context.document.debrief.tiles > 0, "the charts must derive debrief tiles")
assert(context.serviceRuntime.byId.debrief, "derived debrief tiles must load the recorder")
for _, section in ipairs(sections) do
    draft, handlers = preview(function()
        context.editorSession.draft.debrief = section or nil
        context.editorModule.setDebriefDerived(context.editorSession, not section)
    end)
    save(draft, handlers)
    equal(context.reloadState, nil, "a debrief-only save must not reload the dashboard")
    equal(context.serviceRuntime.byId.history, history)
    if section then
        equal(context.document.debrief, section)
    else
        -- Without a section of its own the layout derives its debrief again.
        assert(context.debriefGenerated and #context.document.debrief.tiles > 0, "the debrief must be derived again")
    end
    equal(fixture.instanceOf(context, "power"), compatible)
    assert(context.serviceRuntime.byId.debrief, "a debrief save must load the recorder")
end
-- Saving debrief series subscribes them before the next flight; history keeps
-- subscriptions until the dashboard reloads.
equal(history.count, subscriptions + 1, "a debrief save must record its series")
subscriptions, telemetryCount = history.count, telemetry.count

fixture.radio.fields.NewChart = { id = 5100, name = "NewChart", unit = 1 }
fixture.radio.values[5100] = 55
fixture.radioMock.indexFields()
draft, handlers = preview(function(config)
    config.metrics[1].source = "NewChart"
end)
local incompatible = fixture.instanceOf(context, "power")
assert(incompatible.previewMissing)
fixture.pump(context, 30)
equal(incompatible.status.properties.text, "PREVIEW: NO DATA")
equal(history.count, subscriptions)
equal(telemetry.count, telemetryCount, "draft-only telemetry sources must not become live")
save(draft, handlers)
equal(context.reloadState, "clear", "a new recording must become live only after a saved rebuild")
assert(fixture.pumpUntil(context, function()
    local panel = fixture.instanceOf(context, "power")
    return not context.stage and not context.reloadState and panel and panel.series[1].feed.available
end, 500))
local live = fixture.instanceOf(context, "power")
assert(live.history ~= history and not live.preview)
equal(live.series[1].feed.value, 55)
equal(#context.errors, 0, table.concat(context.errors, "\n"))
