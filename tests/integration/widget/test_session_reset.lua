-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local yaml = fixture.module("lib/yaml.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local path = root .. "/build/test-widget-fixture/"
fixture.reset()
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(true)
lvgl.UI_ELEMENT_HEIGHT = 32
EVT_VIRTUAL_EXIT = 9106

local function placement(id, kind, col, row, height, config)
    return { id = id, type = kind, col = col, row = row, colSpan = 2, rowSpan = height, config = config }
end
local layout = {
    version = 5,
    grid = { columns = 4, rows = 4 },
    panels = {
        placement("chart", "chart", 0, 0, 2, { metrics = { { source = "Alt" } } }),
        placement("link", "link-status", 2, 0, 1, { extrema = "flight", reading = "quality", qualitySource = "RQly" }),
        placement("counter", "flight-counter", 2, 1, 1, {}),
        placement("home", "navigation", 0, 2, 1, { homeMode = "first-arm" }),
        placement("radio-home", "navigation", 2, 2, 1, { homeMode = "edgetx" }),
        placement("battery", "rx-battery", 0, 3, 1, { source = "RxBt", cells = 0 }),
        placement("timer", "flight-timer", 2, 3, 1, {}),
    },
}
local file = assert(hostIo.open(path .. "layouts/session-reset.yaml", "w"))
local layoutText = assert(yaml.serialize(layout))
file:write(layoutText)
file:close()
os.execute("mkdir -p '" .. path .. "AEROGRID/models'")

local setCount, writes = model.setGlobalVariable, 0
setCount(8, 0, 17)
model.setGlobalVariable = function(...)
    writes = writes + 1
    return setCount(...)
end
local sticky = false
setStickySwitch = function(index, value)
    equal(index, 19)
    sticky = value
    fixture.radio.logicalSwitches[20] = value
    return false
end
model.getLogicalSwitch = function()
    return { func = 17, v1 = 0, v2 = 0, v3 = 0, ["and"] = 0, delay = 0, duration = 0 }
end
fixture.radio.fields.ch3 = { id = 306, name = "ch3" }
fixture.radio.values[306] = -1024
fixture.radio.rssi = 80
fixture.radio.values[fixture.radio.fields.RQly.id] = 80
fixture.radio.values[fixture.radio.fields.RxBt.id] = 16.8
local first = definition.create({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "session-reset" }, path)
local second = definition.create({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "session-reset" }, path)
local worst = 0
local function measured(callback, context)
    fixture.lvglMock.setPropertyValidation(false)
    fixture.lvglMock.setCallCounting(false)
    fixture.lcdMock.setTextMeasurement(false)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    local ok, message = pcall(callback, context)
    debug.sethook()
    fixture.lcdMock.setTextMeasurement(true)
    fixture.lvglMock.setCallCounting(true)
    fixture.lvglMock.setPropertyValidation(true)
    assert(ok, message)
    worst = math.max(worst, instructions)
    assert(instructions < 15000, "session reset callback exceeded budget: " .. instructions)
end
local secondVisible = true
local function pump(count)
    for _ = 1, count or 1 do
        fixture.tick(20)
        measured(definition.refresh, first)
        measured(secondVisible and definition.refresh or definition.background, second)
    end
end
local function untilState(predicate)
    for _ = 1, 800 do
        if predicate() then
            return
        end
        pump()
    end
    error(
        "session reset did not settle: " .. tostring(first.flightErrorText) .. "; " .. table.concat(first.errors, "; ")
    )
end
local function settled()
    return not first.stage
        and not second.stage
        and not first.reloadState
        and not second.reloadState
        and not first.sessionResetPending
        and not second.sessionResetPending
end
untilState(function()
    return settled() and first.aeroMenuHandlers
end)
local owner = first.flightBroker
assert(owner == second.flightBroker)
local values = first.flightConfig.resolve({ minFlightDuration = 1, disarmDuration = 1, flightSwitch = "L20" })
local saved, document = owner.store:save(owner.filename, 0, values, "L64", "L03")
assert(saved, document)
owner:setDocument(document)
untilState(settled)
pump(80)
measured(definition.refresh, second)
local function panel(context, id)
    return assert(fixture.instanceOf(context, id), id)
end
local beforeFirst, beforeSecond = first.serviceRuntime, second.serviceRuntime
local beforeCharts = { panel(first, "chart"), panel(second, "chart") }
local timer = model.getTimer(0).value
fixture.radio.logicalSwitches[64] = true
fixture.radio.values[306] = 1024
untilState(function()
    for _, context in ipairs({ first, second }) do
        if
            context.serviceRuntime.byId.history:session().elapsed == 0
            or not panel(context, "home").feed.home
            or not panel(context, "link").sessionExtrema.available
            or panel(context, "battery").estimatedCells ~= 4
        then
            return false
        end
    end
    return owner.view.active
end)
secondVisible = false
equal(writes, 1)
equal(model.getGlobalVariable(8, 0), 18)
assert(owner.view.active and sticky)
for _, context in ipairs({ first, second }) do
    assert(context.serviceRuntime.byId.history:session().elapsed > 0)
    assert(panel(context, "home").feed.home)
    assert(panel(context, "link").sessionExtrema.available)
    equal(panel(context, "battery").estimatedCells, 4)
end
fixture.radio.rssi = 25
fixture.radio.values[fixture.radio.fields.RQly.id] = 25
pump(200)
equal(panel(first, "link").sessionExtrema.min, 25)
local chartElapsed = {}
for index, context in ipairs({ first, second }) do
    local chart = panel(context, "chart")
    chartElapsed[index] = chart.session.elapsed
    assert(chart.series[1].feed.available and chart.series[1].feed.count > 0)
end
first.editorController.openEditor(first)
untilState(function()
    return first.editorUi and not first.editorUi.buildStage
end)
local draft = first.editorSession
local editorUi = first.editorUi
draft.dirty = true
draft.draft.panels[1].config.label = "Retained draft"
local epoch, revision = owner.epoch, owner.document.revision
fixture.radio.rssi = 80
fixture.radio.values[fixture.radio.fields.RQly.id] = 80
fixture.radio.values[fixture.radio.fields.RxBt.id] = 8.4
fixture.radio.values[fixture.radio.fields.Alt.id] = 50
fixture.radio.logicalSwitches[3] = true
untilState(function()
    return owner.epoch == epoch + 1 and settled()
end)
assert(
    first.serviceRuntime == beforeFirst and second.serviceRuntime == beforeSecond,
    "foreground and hidden dashboards must reset in place"
)
assert(first.editorStash == draft or first.editorSession == draft, "session reset preserves unsaved layout edits")
equal(first.editorUi, editorUi, "session reset must not dismiss or rebuild the editor")
equal(draft.draft.panels[1].config.label, "Retained draft")
equal(owner.document.revision, revision, "switch activation must not save model settings")
equal(writes, 1)
equal(model.getGlobalVariable(8, 0), 18)
assert(not owner.view.active)
pump(60)
equal(sticky, false)
for index, context in ipairs({ first, second }) do
    local history = context.serviceRuntime.byId.history
    local session = history:session()
    local chart = panel(context, "chart")
    assert(chart == beforeCharts[index], "reset must retain charts and their display objects")
    equal(chart.session, session, "charts must use the reset recording session")
    equal(chart.series[1].feed, history:subscribe("Alt"), "chart previews must observe reset recordings too")
    assert(chart.session.elapsed < chartElapsed[index], "chart timelines must restart after reset")
    equal(chart.series[1].feed.min, 50, "chart readouts must discard pre-reset extrema")
    equal(chart.series[1].feed.max, 50)
    for point = chart.series[1].feed.first, chart.series[1].feed.last do
        local _, value = history:point(chart.series[1].feed, point)
        equal(value, 50, "chart traces must contain only post-reset samples")
    end
    equal(session.flightLast, 0)
    equal(session.armLast, 0)
    equal(session.resumeLast, 0)
    equal(history:subscribe("Alt").min, 50, "recorded extrema must not retain old samples")
    equal(panel(context, "home").feed.homeStatus, "waiting", "custom home requires a new arm edge")
    assert(not panel(context, "home").feed.home)
    assert(panel(context, "radio-home").feed.home, "EdgeTX home is never reset")
    equal(panel(context, "link").sessionExtrema.min, 80)
end
first.editorUiModule.close(first, false)
first.editorSession, first.editorStash = nil, nil
first.editorController.restorePreview(first)
untilState(function()
    return panel(first, "battery").estimatedCells == 2
end)
equal(panel(second, "battery").estimatedCells, nil, "hidden panels discard old estimates before their next render")
secondVisible = true
untilState(function()
    return panel(second, "battery").estimatedCells == 2
end)
secondVisible = false
equal(model.getTimer(0).value, timer, "radio-owned timers are untouched")
equal(owner.epoch, epoch + 1, "holding the input resets once")
equal(writes, 1, "a reset while armed cannot count the same flight again")
local persisted = assert(owner.store:load(owner.filename))
equal(persisted.revision, revision)
equal(persisted.sessionReset, "L03")
file = assert(hostIo.open(path .. "layouts/session-reset.yaml", "r"))
equal(file:read("*a"), layoutText, "reset must not save or alter layouts")
file:close()

fixture.radio.logicalSwitches[64] = false
pump(20)
fixture.radio.logicalSwitches[64] = true
pump(100)
equal(writes, 2, "a new flight can qualify after disarming")
equal(model.getGlobalVariable(8, 0), 19)
assert(panel(first, "home").feed.home and panel(second, "home").feed.home)

first.aeroMenuHandlers.modelSettings()
untilState(function()
    return first.modelSettingsUi and not first.modelSettingsUi.build
end)
local drawer = first.modelSettingsUi
equal(drawer.controls.sessionReset.properties.get(), getSwitchIndex("L03"))
fixture.radio.logicalSwitches[3] = false
pump(5)
fixture.radio.logicalSwitches[3] = true
untilState(function()
    return owner.epoch == epoch + 2 and settled()
end)
assert(first.modelSettingsUi == drawer, "reset must not dismiss Model settings")
drawer.controls.sessionReset.properties.set(0)
untilState(function()
    return owner.document.sessionReset == ""
end)
equal(assert(owner.store:load(owner.filename)).sessionReset, "", "None saves immediately")
first.modelSettingsUiModule.handle(first, EVT_VIRTUAL_EXIT)
pump(5)
fixture.radio.logicalSwitches[3] = false
pump(5)
fixture.radio.logicalSwitches[3] = true
pump(30)
equal(owner.epoch, epoch + 2, "None disables the reset input")
saved, document = owner.store:save(owner.filename, owner.document.revision, values, "", "L03")
assert(saved, document)
owner:setDocument(document)
untilState(settled)
owner:reset(owner.filename)
pump(100)
assert(owner.documentLoaded and not owner.session and owner.dormantRevision, "unarmed models leave detection dormant")
local dormantEpoch, dormantRuntime = owner.epoch, second.serviceRuntime
fixture.radio.logicalSwitches[3] = false
pump(5)
fixture.radio.logicalSwitches[3] = true
untilState(function()
    return owner.epoch == dormantEpoch + 1 and settled()
end)
assert(second.serviceRuntime == dormantRuntime, "dormant flight detection must reset without rebuilding")
for _, context in ipairs({ first, second }) do
    local history = context.serviceRuntime.byId.history
    equal(history:session().elapsed, 0)
    equal(history:subscribe("Alt").count, 0, "paused recordings are cleared without restarting")
end
equal(writes, 2)
equal(#first.errors, 0, table.concat(first.errors, "; "))
equal(#second.errors, 0, table.concat(second.errors, "; "))
print("model session reset: foreground and hidden consumers, worst " .. worst .. " instructions")
