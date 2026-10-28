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

equal(definition.options[1][1], "Layout")
equal(definition.options[2][1], "Theme")
equal(definition.options[3][1], "Armed")
equal(definition.options[3][2], SWITCH)
equal(definition.options[3][3], 0)
equal(definition.translate("Armed"), "Armed switch")

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

local function measured(callback, context)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    local ok, message = pcall(callback, context)
    debug.sethook()
    assert(ok, message)
    assert(instructions < 15000, "native Armed callback exceeded budget: " .. instructions)
end
local function finish(context)
    for _ = 1, 200 do
        if not context.stage and not context.reloadState then
            equal(#context.errors, 0, table.concat(context.errors, "\n"))
            return context
        end
        measured(definition.refresh, context)
    end
    error("native Armed reload did not finish")
end
local function options(arm, theme)
    return { Layout = "shared-armed", Theme = theme or "modern-dark", Armed = arm }
end
local function loaded(arm)
    return finish(definition.create({ x = 0, y = 0, w = 480, h = 272 }, options(arm), widgetPath))
end
local function pump(...)
    local contexts = { ... }
    for _ = 1, 80 do
        fixture.tick(20)
        for _, context in ipairs(contexts) do
            measured(definition.refresh, context)
        end
    end
end

local nativeId = getSwitchIndex("L64")
local first, second = loaded(nativeId), loaded(getSwitchIndex("L01"))
pump(first, second)
local armed = first.serviceRuntime.byId.armed
local shared = armed:state()
equal(shared.condition, "L64")
equal(shared.configured, true)
equal(shared.fresh, true)
equal(shared.value, false)
assert(armed:state("L01") == shared and armed:state("L02") == shared)
assert(fixture.instanceOf(first, "one").session == fixture.instanceOf(first, "two").session)
assert(fixture.instanceOf(first, "counter").arm == shared)
local navigation = first.serviceRuntime.byId.navigation
assert(navigation:subscribe("GPS", "L01", "first-arm") == navigation:subscribe("GPS", "L02", "first-arm"))
assert(navigation:subscribe("GPS", nil, "edgetx") ~= navigation:subscribe("GPS", nil, "first-arm"))
equal(first.serviceRuntime.byId.control.count, second.serviceRuntime.byId.control.count)

local custom = first.serviceRuntime.byId.control:switch("L03")
fixture.radio.logicalSwitches[3] = true
pump(first, second)
equal(custom.value, true, "custom State conditions remain independent")
equal(shared.value, false)
fixture.radio.logicalSwitches[64] = true
pump(first, second)
equal(shared.value, true)
equal(second.serviceRuntime.byId.armed:state().value, false, "instances must not share native options")
equal(fixture.instanceOf(first, "capture").feed.homeStatus, "captured")
assert(fixture.instanceOf(second, "capture").feed.homeStatus ~= "captured")
local retainedHomes = first.navigationHomes
definition.update(first, options(nativeId, "modern-light"))
finish(first)
assert(first.navigationHomes == retainedHomes, "theme reload preserves compatible home capture")
equal(first.serviceRuntime.byId.armed:state().condition, "L64")

local session = assert(editor.new(first.document, first.grid, first.layoutValidator, first.panelHost, function(kind)
    return fixture.module("panels/" .. kind .. ".lua")
end))
session.nativeArmed = nativeId
local function showsArm()
    for _, field in ipairs(assert(editor.settings(session))) do
        if field.key == "armSwitch" then
            return true
        end
    end
    return false
end
assert(not showsArm(), "overridden legacy fields are hidden")
assert(editor.setValue(session, "label", "SAVED"))
local valid, saved = editor.apply(session)
assert(valid, table.concat(saved or {}, "\n"))
equal(saved.panels[1].config.armSwitch, "L01", "editing preserves hidden legacy values")
write("shared-armed", saved)
write("shared-armed-copy", saved)
local copy = fixture.createLoaded(nil, { Layout = "shared-armed-copy", Theme = "modern-dark", Armed = nativeId })
equal(copy.document.panels[1].config.armSwitch, "L01", "Save As preserves hidden legacy values")

session.nativeArmed = 0
assert(showsArm(), "unset Armed shows the retained switch")
session.draft.panels[1].config.armSwitch = ""
assert(not showsArm(), "blank legacy fields are hidden")
definition.update(first, options(0))
finish(first)
pump(first, second)
assert(first.navigationHomes ~= retainedHomes, "changing Armed invalidates retained capture")
armed = first.serviceRuntime.byId.armed
equal(armed:state().status, "unconfigured")
assert(armed:state("L01") ~= armed:state("L02"))
assert(fixture.instanceOf(first, "one").session ~= fixture.instanceOf(first, "two").session)
equal(fixture.instanceOf(first, "counter").arm.condition, "L02")
local extrema = first.serviceRuntime.byId.extrema
assert(extrema:flight("L01") ~= extrema:flight("L02"), "legacy extrema sessions retain independent switches")

document.panels[2].config.armSwitch = "ch5"
write("shared-armed", document)
local overridden = loaded(nativeId)
assert(overridden.serviceRuntime.byId.armed:state("ch5") == overridden.serviceRuntime.byId.armed:state())
local recreated = loaded(nativeId)
equal(recreated.serviceRuntime.byId.armed:state().condition, "L64", "recreation uses the model's native option")
local inverse = loaded(-nativeId)
pump(inverse)
equal(inverse.serviceRuntime.byId.armed:state().condition, "!L64")
equal(inverse.serviceRuntime.byId.armed:state().value, false)
