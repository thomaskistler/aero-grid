-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 20)
local broker = context.flightFactory.broker
local loads, opened, closed, restored, flightSteps, saves = 0, 0, 0, 0, 0, 0
local document = { revision = 1, armed = "", flight = {}, sessionReset = "" }
broker.store.load = function(_, filename)
    assert(filename == broker.filename)
    assert(context.modelSettingsOpenTask.cost == context.scheduler.capacity)
    loads = loads + 1
    return document
end
broker.setDocument = function(_, value)
    assert(value == document)
    broker.document = value
end
context.modelSettingsUiModule = {
    open = function(_, value)
        assert(context.modelSettingsOpenTask.cost == context.scheduler.capacity)
        assert(value.modelFilename == broker.filename)
        opened = opened + 1
        context.modelSettingsUi = {}
    end,
}
local draft = { dirty = true }
context.editorSession, context.editorUi = draft, { saving = {} }
context.aeroMenuModal = true
context.editorUiModule = {
    close = function(_, discard)
        assert(context.modelSettingsOpenTask.cost == context.scheduler.capacity)
        assert(not discard and not context.editorUi.saving)
        closed = closed + 1
        context.editorUi = nil
    end,
}
context.editorController.restorePreview = function()
    assert(context.modelSettingsOpenTask.cost == context.scheduler.capacity)
    restored = restored + 1
end
context.editorController.advanceEditor = function()
    assert(context.uiTasks.editor.cost == context.scheduler.capacity)
    saves = saves + 1
    context.editorUi.saving = nil
end
context.flightTask = {
    broker = broker,
    step = function(_, _, slots)
        flightSteps = flightSteps + 1
        return slots, false
    end,
}
context.aeroMenuHandlers.modelSettings()
assert(loads == 0 and opened == 0 and closed == 0 and context.modelSettingsRequest)
for _ = 1, 10 do
    definition.background(context)
    if saves == 1 then
        break
    end
end
assert(saves == 1 and opened == 0 and closed == 0 and context.modelSettingsRequest)
assert(not context.editorUi.saving, "an ongoing editor save finishes before settings suspension")

context.scheduler.cursor = 1
local flights = flightSteps
definition.refresh(context)
assert(flightSteps == flights + 1 and opened == 0, "settings opening must wait for a full-capacity grant")
definition.refresh(context)
assert(flightSteps == flights + 1 and loads == 1 and opened == 1 and closed == 1 and restored == 1)
assert(context.editorStash == draft and not context.editorSession and not context.modelSettingsRequest)
assert(not context.modelSettingsOpenTask.pending, "modal construction waits for a separate advancement grant")

context.modelSettingsUi, context.editorStash = nil, nil
context.aeroMenuHandlers.modelSettings()
local filename = broker.filename
fixture.radio.modelFilename, broker.filename = "another-model.yml", "another-model.yml"
for _ = 1, 10 do
    definition.refresh(context)
    if not context.modelSettingsRequest then
        break
    end
end
assert(opened == 1 and loads == 1 and not context.modelSettingsRequest, "deferred entry belongs to its original model")
fixture.radio.modelFilename, broker.filename = filename, filename
context.aeroMenuHandlers.modelSettings()
fixture.lvglMock.setFullScreen(false)
for _ = 1, 10 do
    definition.refresh(context)
    if not context.modelSettingsRequest then
        break
    end
end
assert(opened == 1 and loads == 1 and not context.modelSettingsRequest, "stale entry cannot open settings in App mode")
