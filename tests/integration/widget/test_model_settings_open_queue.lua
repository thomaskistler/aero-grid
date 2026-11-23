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
    assert(context.hostTask.cost == context.scheduler.budget.capacity)
    loads = loads + 1
    return document
end
broker.setDocument = function(_, value)
    assert(value == document)
    broker.document = value
end
local handlers
context.modelSettingsUiModule = {
    open = function(_, value, callbacks)
        handlers = callbacks
        assert(context.hostTask.cost == context.scheduler.budget.capacity)
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
        assert(context.hostTask.cost == context.scheduler.budget.capacity)
        assert(not discard and not context.editorUi.saving)
        closed = closed + 1
        context.editorUi = nil
    end,
}
context.editorController.restorePreview = function()
    assert(context.hostTask.cost == context.scheduler.budget.capacity)
    restored = restored + 1
end
context.editorController.advanceEditor = function()
    assert(context.hostTask.cost == context.scheduler.budget.capacity)
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
assert(loads == 0 and opened == 0 and closed == 0 and context.openRequest)
for _ = 1, 10 do
    definition.background(context)
    if saves == 1 then
        break
    end
end
assert(saves == 1 and opened == 0 and closed == 0 and context.openRequest)
assert(not context.editorUi.saving, "an ongoing editor save finishes before settings suspension")

fixture.requeue(context)
local flights = flightSteps
definition.refresh(context)
assert(flightSteps == flights + 1 and opened == 0, "settings opening must wait for a full-capacity grant")
definition.refresh(context)
assert(flightSteps == flights + 1 and loads == 1 and opened == 1 and closed == 1 and restored == 1)
assert(context.editorStash == draft and not context.editorSession and not context.openRequest)
assert(
    not context.scheduler.state(context.hostTask).pending,
    "modal construction waits for a separate advancement grant"
)

local storeCommit = broker.store.commit
broker.store.commit = function()
    return false, "Disarm before linking model settings", true
end
local committed, commitMessage, retry = handlers.commit({})
broker.store.commit = storeCommit
assert(
    not committed and commitMessage == "Disarm before linking model settings" and retry == nil,
    "a claim deferred until disarm must not replace the prepared save with its message"
)

context.modelSettingsUi, context.editorStash = nil, nil
context.aeroMenuHandlers.modelSettings()
local filename = broker.filename
fixture.radio.modelFilename, broker.filename = "another-model.yml", "another-model.yml"
for _ = 1, 10 do
    definition.refresh(context)
    if not context.openRequest then
        break
    end
end
assert(opened == 1 and loads == 1 and not context.openRequest, "deferred entry belongs to its original model")
fixture.radio.modelFilename, broker.filename = filename, filename
context.aeroMenuHandlers.modelSettings()
fixture.lvglMock.setFullScreen(false)
for _ = 1, 10 do
    definition.refresh(context)
    if not context.openRequest then
        break
    end
end
assert(opened == 1 and loads == 1 and not context.openRequest, "stale entry cannot open settings in App mode")
