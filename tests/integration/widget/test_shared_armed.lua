-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local yaml = fixture.module("lib/yaml.lua")
local editor = fixture.module("lib/editor.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local widgetPath = root .. "/build/test-widget-fixture/"
fixture.reset()
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(true)
lvgl.UI_ELEMENT_HEIGHT = 32
EVT_VIRTUAL_EXIT = 9106

equal(definition.options[1][1], "Layout")
equal(definition.options[2][1], "Theme")
equal(#definition.options, 2, "Armed belongs only in Model settings")

local function placement(id, kind, col, row, height, config)
    return { id = id, type = kind, col = col, row = row, colSpan = 2, rowSpan = height, config = config }
end
local document = {
    version = 4,
    grid = { columns = 4, rows = 4 },
    session = { armSource = "L02" },
    panels = {
        placement("one", "chart", 0, 0, 1, { armSwitch = "L01", metrics = { { source = "Alt" } } }),
        placement("two", "chart", 2, 0, 1, { armSwitch = "L02", metrics = { { source = "Alt" } } }),
        placement("counter", "flight-counter", 0, 1, 1, { armSwitch = "L02" }),
        placement("capture", "navigation", 2, 1, 2, { homeMode = "first-arm", armSwitch = "L01" }),
        placement("link", "link-status", 0, 2, 2, { extrema = "flight" }),
        placement("edgetx", "navigation", 2, 3, 1, { homeMode = "edgetx" }),
    },
}
local function write(name, value)
    local file = assert(hostIo.open(widgetPath .. "layouts/" .. name .. ".yaml", "w"))
    file:write(assert(yaml.serialize(value)))
    file:close()
end
write("shared-armed", document)
write("shared-armed-copy", document)

local worst, callbacks = 0, 0
local function measured(callback, context)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    local ok, message = pcall(callback, context)
    debug.sethook()
    assert(ok, message)
    worst, callbacks = math.max(worst, instructions), callbacks + 1
    assert(instructions < 15000, "model Armed callback exceeded budget: " .. instructions)
end
local function finish(context)
    for _ = 1, 300 do
        if not context.stage and not context.reloadState then
            equal(#context.errors, 0, table.concat(context.errors, "\n"))
            return context
        end
        measured(definition.refresh, context)
    end
    error("model Armed reload did not finish")
end
local function loaded(legacy, layout)
    return finish(definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
        Layout = layout or "shared-armed",
        Theme = "modern-dark",
        Armed = legacy,
    }, widgetPath))
end
local function pump(...)
    for _ = 1, 80 do
        fixture.tick(20)
        for _, context in ipairs({ ... }) do
            measured(definition.refresh, context)
        end
    end
end
local first, second = loaded(getSwitchIndex("L64")), loaded(getSwitchIndex("L01"), "shared-armed-copy")
pump(first, second)
local armed = first.serviceRuntime.byId.armed
equal(armed:state().status, "unconfigured")
assert(armed:state("L01") ~= armed:state("L02"), "unsaved model arming preserves legacy panel sessions")
equal(fixture.instanceOf(first, "counter").arm.condition, "L02")
assert(first.serviceRuntime.byId.extrema:flight("L01") ~= first.serviceRuntime.byId.extrema:flight("L02"))

local function open(context)
    context.aeroMenuHandlers.modelSettings()
    for _ = 1, 30 do
        if context.modelSettingsUi and not context.modelSettingsUi.build then
            return context.modelSettingsUi
        end
        measured(definition.refresh, context)
    end
    error("Model settings did not open")
end
local state = open(first)
assert(string.find(state.status.properties.text, "Conflicting old widget Armed", 1, true))
equal(state.controls.armed.properties.get(), 0, "conflicting old native options must not be guessed")
first.modelSettingsUiModule.handle(first, EVT_VIRTUAL_EXIT)
measured(definition.refresh, first)
equal(first.flightBroker.document.armed, nil, "opening and closing does not publish model arming")
assert(first.serviceRuntime.byId.armed == armed, "closing unchanged settings does not rebuild consumers")

local function save(context, index)
    local dialog = open(context)
    dialog.controls.armed.properties.set(index)
    measured(definition.refresh, context)
    if index ~= 0 then
        assert(dialog.armed ~= "", tostring(dialog.status.properties.text))
    end
    context.modelSettingsUiModule.handle(context, EVT_VIRTUAL_EXIT)
    measured(definition.refresh, context)
    assert(not context.modelSettingsUi)
    finish(first)
    finish(second)
    pump(first, second)
end
save(first, getSwitchIndex("L64"))
local owner = first.flightBroker
equal(owner.document.armed, "L64")
equal(assert(owner.store:load(owner.filename)).armed, "L64", "arming is durable and model-wide")
armed = first.serviceRuntime.byId.armed
local shared = armed:state()
equal(shared.condition, "L64")
equal(shared.origin, "model")
equal(shared.fresh, true)
assert(armed:state("L01") == shared and armed:state("ch5") == shared)
assert(fixture.instanceOf(first, "one").session == fixture.instanceOf(first, "two").session)
assert(fixture.instanceOf(first, "counter").arm == shared)
equal(second.serviceRuntime.byId.armed:state().condition, "L64")
equal(owner.session.armKey, "L64", "the shared flight detector uses model arming")
local navigation = first.serviceRuntime.byId.navigation
assert(navigation:subscribe("GPS", "L01", "first-arm") == navigation:subscribe("GPS", "L02", "first-arm"))
assert(navigation:subscribe("GPS", nil, "edgetx") ~= navigation:subscribe("GPS", nil, "first-arm"))
assert(first.serviceRuntime.byId.extrema:flight("L01") == first.serviceRuntime.byId.extrema:flight("L02"))

local custom = first.serviceRuntime.byId.control:switch("L03")
fixture.radio.logicalSwitches[3] = true
pump(first, second)
equal(custom.value, true, "custom State conditions remain independent")
equal(shared.value, false)
fixture.radio.logicalSwitches[64] = true
pump(first, second)
equal(shared.value, true)
equal(second.serviceRuntime.byId.armed:state().value, true, "every instance observes the same model condition")
equal(fixture.instanceOf(first, "capture").feed.homeStatus, "captured")
equal(fixture.instanceOf(second, "capture").feed.homeStatus, "captured")

local session = assert(editor.new(first.document, first.grid, first.layoutValidator, first.panelHost, function(kind)
    return fixture.module("panels/" .. kind .. ".lua")
end))
session.modelArmed = "L64"
for _, field in ipairs(assert(editor.settings(session))) do
    assert(field.key ~= "armSwitch", "saved model arming hides retained panel fields")
end
assert(editor.setValue(session, "label", "SAVED"))
local valid, saved = editor.apply(session)
assert(valid, table.concat(saved or {}, "\n"))
equal(saved.panels[1].config.armSwitch, "L01", "editing preserves hidden legacy values")
write("shared-armed", saved)

local homes = first.navigationHomes
definition.update(first, { Layout = "shared-armed", Theme = "modern-light" })
finish(first)
assert(first.navigationHomes == homes, "theme reload preserves compatible homes")
equal(first.serviceRuntime.byId.armed:state().condition, "L64")

first.editorController.openEditor(first)
for _ = 1, 150 do
    if first.editorUi and not first.editorUi.buildStage then
        break
    end
    measured(definition.refresh, first)
end
local liveDraft = assert(first.editorSession)
assert(editor.setValue(liveDraft, "label", "UNSAVED"))
save(second, 0)
assert(first.editorSession == liveDraft and liveDraft.dirty, "another dashboard's arming Save preserves layout drafts")
equal(liveDraft.modelArmed, "")
first.editorUiModule.close(first, false)
first.editorController.restorePreview(first)
first.editorSession = nil
equal(owner.document.armed, "")
equal(first.serviceRuntime.byId.armed:state("L01").configured, false, "saved None disables legacy arming")
assert(first.navigationHomes ~= homes, "changing model arming invalidates captured homes")
equal(second.serviceRuntime.byId.armed:state("L02").configured, false)
equal(owner.state.status, "unconfigured")

save(first, -getSwitchIndex("L64"))
equal(first.serviceRuntime.byId.armed:state().condition, "!L64")
equal(second.serviceRuntime.byId.armed:state().value, false)
document.panels[2].config.armSwitch = "ch5"
write("shared-armed", document)
local recreated = fixture.createLoaded(nil, { Layout = "shared-armed", Theme = "modern-dark" })
equal(#recreated.errors, 0, table.concat(recreated.errors, "\n"))
pump(recreated)
equal(recreated.serviceRuntime.byId.armed:state().condition, "!L64")
equal(assert(owner.store:load(owner.filename)).armed, "!L64")
save(second, getSwitchIndex("SF" .. CHAR_DOWN))
equal(first.serviceRuntime.byId.armed:state().condition, "SFv", "physical positions are stored by portable name")
equal(second.serviceRuntime.byId.armed:state().condition, "SFv")
print(string.format("Model Armed callbacks: %d; worst %d instructions", callbacks, worst))
