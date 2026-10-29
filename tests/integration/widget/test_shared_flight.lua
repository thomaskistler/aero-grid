-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local path = root .. "/build/test-widget-fixture/"
local definition = fixture.module("main.lua")
local file = assert(io.open(path .. "layouts/shared-flight.yaml", "w"))
file:write([[
version: 4
grid:
  columns: 4
  rows: 4
panels:
  - id: flights
    type: flight-counter
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      armSwitch: SFv
      minFlightDuration: 1
      disarmDuration: 1
      history: false
]])
file:close()
os.execute("mkdir -p '" .. path .. "AEROGRID/models'")

EVT_TOUCH_TAP, EVT_VIRTUAL_EXIT = 9301, 9302
fixture.reset()
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(true)
lvgl.UI_ELEMENT_HEIGHT = 32
fixture.radio.fields.ch3 = { id = 306, name = "ch3" }
fixture.radio.rssi = 80
fixture.radio.values[305], fixture.radio.values[306] = -1024, -1024
local armed = getSwitchIndex("SF" .. CHAR_DOWN)
local writes, tones, full = {}, {}, false
setStickySwitch = function(index, value)
    if full then
        return true
    end
    assert(index == 19, "L20 must use the zero-based Sticky index")
    writes[#writes + 1] = value
    fixture.radio.logicalSwitches[20] = value
    return false
end
model.getLogicalSwitch = function(index)
    assert(index == 19)
    return { func = 17, v1 = 0, v2 = 0, v3 = 0, ["and"] = 0, delay = 0, duration = 0 }
end
playTone = function(frequency)
    tones[#tones + 1] = frequency
end
playNumber = function() end
model.setGlobalVariable(8, 0, 0)

local smartSamples = {}
getSourceValue = function(id)
    local sample = smartSamples[id]
    if sample then
        return sample.value, sample.current ~= false, sample.fresh ~= false
    end
end
model.getModule = function(index)
    return { Type = index == 0 and 5 or 0 }
end
local getSensor = model.getSensor
local smartSensors = {}
model.getSensor = function(index)
    return smartSensors[index] or getSensor(index)
end
local function measured(callback, context)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 200
    end, "", 200)
    local ok, message = pcall(callback, context)
    debug.sethook()
    assert(ok, message)
    assert(instructions <= 15000, "shared/Smart flight callback exceeded regression budget: " .. instructions)
end

local function create(layout, arm)
    return definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = layout, Theme = "modern-dark", Armed = arm },
        path
    )
end
local first, second = create("shared-flight", 0), create("shared-flight", armed)
local function pump(context, count, other)
    for _ = 1, count or 1 do
        fixture.tick(10)
        measured(definition.refresh, context)
        if other then
            measured(definition.background, other)
        end
    end
end
local function untilState(context, predicate, other)
    for _ = 1, 500 do
        if predicate() then
            return
        end
        pump(context, 1, other)
    end
    error(
        "shared flight did not settle at "
            .. tostring(debug.getinfo(2, "l").currentline)
            .. ": "
            .. tostring(context.flightErrorText)
            .. " stage="
            .. tostring(context.stage)
            .. " status="
            .. tostring(context.flightBroker and context.flightBroker.state.status)
    )
end
untilState(first, function()
    return not first.stage
        and not second.stage
        and first.flightBroker
        and first.flightBroker.state.status == "ready"
        and first.aeroMenuHandlers
end, second)
local owner, factory = first.flightBroker, first.flightFactory
assert(owner == second.flightBroker, "actual widget factories must share the same broker")
assert(
    owner.runtime ~= first.serviceRuntime and owner.runtime ~= second.serviceRuntime,
    "the detector must not borrow a dashboard runtime"
)

first.editorController.openEditor(first)
untilState(first, function()
    return first.editorUi and not first.editorUi.buildStage
end, second)
assert(first.editorModule.remove(first.editorSession, 1))
local guarded = first.editorUi.handlers.startSave(first.editorSession.draft)
local done, saved, message = first.editorUi.handlers.advanceSave(guarded)
assert(
    done and not saved and string.find(message, "Save Model settings", 1, true),
    "removing the last legacy detector must require an explicit Model settings Save"
)
assert(not owner.document.flight, "a layout Save must never implicitly migrate model settings")
first.editorUiModule.close(first, true)
first.editorSession = nil
first.editorController.restorePreview(first)

local function findButton(value, label, seen)
    if type(value) ~= "table" then
        return
    end
    seen = seen or {}
    if seen[value] then
        return
    end
    seen[value] = true
    if value.kind == "button" and value.properties and value.properties.text == label then
        return value
    end
    for _, child in pairs(value) do
        local found = findButton(child, label, seen)
        if found then
            return found
        end
    end
end
first.aeroMenuHandlers.modelSettings()
untilState(first, function()
    return first.modelSettingsUi and not first.modelSettingsUi.build
end, second)
local draft = first.modelSettingsUi.draft
draft.flightSwitch, draft.minFlightDuration, draft.disarmDuration = "L20", 1, 1
draft.history, draft.announcements = false, true
local save = assert(findButton(first.modelSettingsUi, "Save"), "Model settings must expose Save")
save.properties.press()
untilState(first, function()
    return not first.modelSettingsUi
end, second)
assert(
    owner.document.revision == 1 and owner.document.flight.flightSwitch == "L20",
    "the native Save action must publish the durable model document"
)
local persisted = assert(owner.store:load(owner.filename))
assert(persisted.revision == 1 and persisted.flight.flightSwitch == "L20")
first.editorController.openEditor(first)
untilState(first, function()
    return first.editorUi and not first.editorUi.buildStage
end, second)
assert(first.editorModule.remove(first.editorSession, 1))
local handlers = first.editorUi.handlers
local saving = handlers.startSave(first.editorSession.draft)
for _ = 1, 200 do
    done, saved, message = handlers.advanceSave(saving)
    if done then
        break
    end
end
assert(done and saved, message)
handlers.close(true)
untilState(first, function()
    return not first.stage and not first.reloadState and #first.panels == 0
end, second)
assert(
    first.nativeArmed == 0 and first.document.legacyFlightArms.flights == "SFv",
    "counter removal must persist the retained fallback without promoting it to native Armed"
)
pump(first, 40, second)
writes = {}

fixture.radio.values[305], fixture.radio.values[306] = 1024, 0
untilState(first, function()
    return owner.state.active
end, second)
pump(first, 10, second)
assert(model.getGlobalVariable(8, 0) == 1 and #tones == 1, "two widgets must count and announce once")
assert(#writes == 1 and writes[1] == true, "two widgets must publish one Sticky start")
local journal = owner:boundaries(0, owner.epoch)
assert(#journal == 1 and journal[1].kind == "start" and journal[1].reason == "standard")
local pinned = owner.session

-- Simulate firmware release of the original widget; the remaining callback owns no readers.
factory.members[first] = nil
first = nil
collectgarbage("collect")
local conflict = create("Empty", getSwitchIndex("L01"))
fixture.radio.logicalSwitches[1] = true
untilState(second, function()
    return not conflict.stage and owner.state.status == "conflict"
end, conflict)
assert(owner.session == pinned and owner.state.active, "an active conflict must retain the original flight")
assert(fixture.radio.logicalSwitches[20], "conflicting proposals must not reset the pinned output")
full = true
fixture.radio.values[305] = -1024
untilState(second, function()
    return not owner.state.active
end, conflict)
assert(owner.output and not owner.output.desired, "confirmed completion must retain pending false cleanup")
assert(owner.state.outputError, "a full command buffer must be actionable")
full = false
untilState(second, function()
    return owner.output == nil
end, conflict)
assert(#writes == 2 and writes[2] == false, "the old output must clear despite a configuration conflict")
assert(#tones == 2 and model.getGlobalVariable(8, 0) == 1)
journal = owner:boundaries(0, owner.epoch)
assert(#journal == 2 and journal[2].kind == "end" and journal[2].at < journal[2].observedAt)
factory.members[conflict] = nil
conflict = nil
untilState(second, function()
    return owner.state.status == "ready"
end)

definition.update(second, { Layout = "Empty", Theme = "modern-dark", Armed = armed })
untilState(second, function()
    return not second.stage and not second.reloadState and #second.panels == 0
end)
assert(second.flightBroker == owner, "Empty layout reattachment must keep the same broker")
fixture.radio.values[305] = 1024
untilState(second, function()
    return owner.state.active
end)
assert(model.getGlobalVariable(8, 0) == 2, "tracking must work without any Flight counter")
fixture.radio.values[305] = -1024
untilState(second, function()
    return not owner.state.active and not owner.output
end)

-- Model drafts neither replace nor save an independently suspended layout draft.
second.editorController.openEditor(second)
untilState(second, function()
    return second.editorUi and not second.editorUi.buildStage
end)
local layoutDraft = second.editorSession
assert(second.editorModule.add(layoutDraft, "flight-timer"))
second.aeroMenuHandlers.modelSettings()
assert(not second.editorUi and second.editorStash == layoutDraft)
untilState(second, function()
    return second.modelSettingsUi and not second.modelSettingsUi.build
end)
second.modelSettingsUi.draft.minMotorPercent = 99
second.modelSettingsUi.controls.smartDetection.properties.set(1)
assert(not owner.document.flight.smartDetection, "unsaved Smart toggle has no live effects")
definition.refresh(second, EVT_VIRTUAL_EXIT)
untilState(second, function()
    return second.editorUi and not second.editorUi.buildStage
end)
assert(second.editorSession == layoutDraft and layoutDraft.dirty, "Cancel must preserve the layout draft")
persisted = assert(owner.store:load(owner.filename))
assert(persisted.revision == 1 and persisted.flight.minMotorPercent == 25, "Cancel must not persist the model draft")
assert(not persisted.flight.smartDetection and not owner.smartRuntime)
assert(second.document.panels[1] == nil, "model Cancel must not save the layout draft")
second.editorUiModule.close(second, false)
second.editorSession = nil
second.editorController.restorePreview(second)

fixture.lvglMock.setFullScreen(false)
pump(second, 180)
assert(not second.aerogridMenu or second.chromeRoot.hidden, "App mode must not replace the native menu")
local nativeWidth, nativeHeight = second.reserved.w, second.reserved.h
fixture.lvglMock.setFullScreen(true)
pump(second, 30)
assert(
    second.reserved.w == nativeWidth and second.reserved.h == nativeHeight,
    "fullscreen must use the exact native button reservation"
)
assert(
    second.aeroMenuHandlers.modelSettings and second.aeroMenuHandlers.uiSetup,
    "Empty dashboards must expose both menu routes"
)

-- Smart remains model-specific and counts once even with two Empty dashboards
-- calling the broker through foreground/background callbacks.
smartSensors[31] = { type = 0, id = 9, instance = 0, unit = 10, prec = 2, name = "EDIT" }
fixture.radio.fields.telem32 = { id = 900, unit = 10 }
smartSamples[900] = { value = 10 }
second.aeroMenuHandlers.modelSettings()
untilState(second, function()
    return second.modelSettingsUi and not second.modelSettingsUi.build
end)
local modelUi = second.modelSettingsUi
modelUi.controls.smartDetection.properties.set(1)
modelUi.controls.minFlightDuration.properties.set(3000)
assert(not owner.document.flight.smartDetection and not owner.smartRuntime)
modelUi.save.properties.press()
untilState(second, function()
    return not second.modelSettingsUi and owner.session.smart and owner.session.smart.altitude.fresh
end)
persisted = assert(owner.store:load(owner.filename))
assert(persisted.revision == 2 and persisted.flight.smartDetection)
assert(owner.view.smartStatus and string.find(owner.view.smartStatus, "baro ready", 1, true))
local third = create("Empty", armed)
untilState(second, function()
    return not third.stage
        and third.flightBroker == owner
        and owner.state.status == "ready"
        and owner.cachedRevision == factory.revision
        and owner.session.wasArmed == false
        and owner.session.referenceCandidateAt ~= nil
end, third)
fixture.radio.values[305] = 1024
pump(second, 20, third)
assert(
    owner.session.altitudeReference == 3.048 and not owner.view.active,
    "arming reference="
        .. tostring(owner.session.altitudeReference)
        .. " phase="
        .. tostring(owner.view.phase)
        .. " sample="
        .. tostring(owner.session.smart.altitude.sampleFresh)
        .. " evidence="
        .. tostring(owner.session.smart.altitude.evidenceAt)
        .. " generation="
        .. tostring(owner.session.smart.generation)
)
local startedAt = owner.session.startedAt
smartSamples[900].value = 23
untilState(second, function()
    return owner.view.active
end, third)
assert(owner.view.reason == "smart-altitude" and owner.view.qualifiedAt - startedAt < 3000)
assert(model.getGlobalVariable(8, 0) == 3 and #tones == 5)
journal = owner:boundaries(0, owner.epoch)
assert(#journal == 5 and journal[5].reason == "smart-altitude" and journal[5].at == startedAt)
second.aeroMenuHandlers.modelSettings()
untilState(second, function()
    return second.modelSettingsUi and not second.modelSettingsUi.build
end, third)
second.modelSettingsUi.controls.smartDetection.properties.set(0)
fixture.tick(10)
definition.refresh(second, EVT_VIRTUAL_EXIT)
assert(not second.modelSettingsUi, "pending input must not be dropped on a due Smart work slice")
assert(owner.document.flight.smartDetection and owner.session.settings.smartDetection and owner.view.active)
assert(owner.view.reason == "smart-altitude" and model.getGlobalVariable(8, 0) == 3)
pump(second, 350, third)
assert(model.getGlobalVariable(8, 0) == 3 and #tones == 5, "standard timeout must not requalify Smart flight")
fixture.radio.values[305] = -1024
untilState(second, function()
    return not owner.view.active and not owner.output
end, third)
assert(model.getGlobalVariable(8, 0) == 3 and #tones == 6 and writes[#writes] == false)
