-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local editor = fixture.module("lib/editor.lua")
local definition = fixture.module("main.lua")
local path = root .. "/build/test-widget-fixture/"
local name = "installation"
local context, panelType
local originalPrint = print
local errorLogs = {}

print = function(...)
    local values = {}
    for index = 1, select("#", ...) do
        values[index] = tostring(select(index, ...))
    end
    local message = table.concat(values, " ")
    if string.find(message, "[AeroGrid] ERROR", 1, true) then
        errorLogs[#errorLogs + 1] = message
    else
        originalPrint(...)
    end
end

-- EdgeTX luaGetFieldInfo (radio/src/lua/api_general.cpp) uses luaL_checkstring
-- after its numeric-id branch. In particular, a blank new list entry is not
-- a valid argument. Keep this suite faithful even before the shared mock fix.
local fieldInfo = getFieldInfo
getFieldInfo = function(source)
    assert(
        type(source) == "string" or type(source) == "number",
        tostring(panelType) .. ": getFieldInfo requires a name or id"
    )
    return fieldInfo(source)
end
getSourceName = function(index)
    local info = getFieldInfo(index)
    return info and info.name or ""
end
getSourceIndex = function(source)
    local info = getFieldInfo(source)
    return info and info.id or 0
end
CHAR_UP, CHAR_DOWN = string.char(192), string.char(193)
getSwitchName = function(index)
    if index > 2000 and index <= 2064 then
        return string.format("L%02d", index - 2000)
    end
    for source in pairs(fixture.radio.fields) do
        if string.match(source, "^s[a-z]$") then
            for _, suffix in ipairs({ CHAR_UP, "-", CHAR_DOWN }) do
                local display = string.upper(source) .. suffix
                if getSwitchIndex(display) == index then
                    return display
                end
            end
        end
    end
    return ""
end

EVT_TOUCH_FIRST, EVT_TOUCH_BREAK, EVT_TOUCH_TAP = 9101, 9102, 9103
EVT_VIRTUAL_EXIT = 9104
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(true)

local firstObject
local function healthy()
    assert(#errorLogs == 0, panelType .. ": " .. table.concat(errorLogs, "\n"))
    assert(#context.errors == 0, panelType .. ": " .. table.concat(context.errors, "\n"))
    assert(#context.rejected == 0, panelType .. ": rejected panel")
    local state = context.editorUi
    assert(not state or not state.previewError, panelType .. ": " .. tostring(state and state.previewError))
    for _, entry in ipairs(context.panels) do
        assert(not entry.failed, panelType .. ": failed panel")
    end
end

local function frame(event, touch)
    fixture.tick(20)
    definition.refresh(context, event, touch)
    fixture.lvglMock.settle()
    -- The mock stores dynamic LVGL properties but does not run callRefs.
    -- Evaluate display getters, not input/action callbacks, each frame.
    for index = firstObject, #fixture.lvglMock.objects do
        local object = fixture.lvglMock.objects[index]
        local current, retired = object, false
        while current do
            if current.invalid or current.cleared then
                retired = true
                break
            end
            current = current.parent
        end
        if not retired then
            for _, key in ipairs({ "text", "value", "get", "font", "color", "textColor", "visible", "active" }) do
                local getter = object.properties[key]
                if type(getter) == "function" then
                    getter()
                end
            end
        end
    end
    healthy()
end

local function untilReady(predicate, message)
    for _ = 1, 500 do
        frame()
        if predicate() then
            return
        end
    end
    error(panelType .. ": " .. message)
end

local function drawerReady()
    untilReady(function()
        local state = assert(context.editorUi, "editor closed unexpectedly")
        return not state.buildStage
            and not state.drawerPending
            and not state.drawerBuild
            and not state.previewPending
            and not state.previewRefresh
    end, "editor/drawer did not settle")
end

local function tap(x, y)
    frame(EVT_TOUCH_FIRST, { x = x, y = y })
    frame(EVT_TOUCH_BREAK, { x = x, y = y })
    frame(EVT_TOUCH_TAP, { x = x, y = y })
end

local function action(kind, key)
    for _, row in ipairs(context.editorUi.drawerControls) do
        if row.field.action == kind and row.field.key == key then
            return row.object.properties
        end
    end
    error(panelType .. ": missing drawer action " .. kind .. "/" .. key)
end

local function control(key, leaf)
    for _, row in ipairs(context.editorUi.drawerControls) do
        local field = row.field
        if field.key == key and (not leaf or field.path and field.path[#field.path] == leaf) then
            return row.object.properties
        end
    end
    error(panelType .. ": missing control " .. key .. "/" .. tostring(leaf))
end

local function back()
    lvgl.close(context.editorUi.nativeDrawer)
    drawerReady()
end

local function same(actual, expected)
    assert(type(actual) == type(expected), panelType .. ": persisted value changed type")
    if type(expected) ~= "table" then
        assert(actual == expected, panelType .. ": persisted value changed")
        return
    end
    for key, value in pairs(expected) do
        same(actual[key], value)
    end
    for key in pairs(actual) do
        assert(expected[key] ~= nil, panelType .. ": unexpected persisted key " .. tostring(key))
    end
end

local function running()
    healthy()
    assert(#context.panels == 1, panelType .. ": panel was not built")
    local entry = context.panels[1]
    assert(entry.placement.type == panelType and entry.instance and entry.container, panelType .. ": missing instance")
    assert(entry.container.properties.w > 0 and entry.container.properties.h > 0, panelType .. ": empty bounds")
    for _ = 1, 20 do
        frame()
    end
    assert(not entry.failed, panelType .. ": panel failed while refreshing")
end

for catalogIndex, item in ipairs(editor.CATALOG) do
    panelType = item.type
    fixture.reset()
    errorLogs = {}
    firstObject = #fixture.lvglMock.objects + 1
    local savedPath = path .. "AEROGRID/layouts/" .. name .. ".yaml"
    os.remove(savedPath)
    os.remove(savedPath .. ".bak")
    local file = assert(hostIo.open(path .. "layouts/" .. name .. ".yaml", "w"))
    file:write("version: 3\ngrid:\n  columns: 4\n  rows: 4\npanels: []\n")
    file:close()
    context = fixture.createLoaded(nil, { Layout = name, Theme = "modern-dark" }, path)
    healthy()
    assert(#context.document.panels == 0 and #context.panels == 0, "installation must start empty")

    frame(EVT_TOUCH_FIRST, { x = 50, y = 40 })
    fixture.tick(60)
    frame()
    drawerReady()
    frame(EVT_TOUCH_BREAK)
    local add = assert(context.editorUi.addRect, "empty grid has no Add button")
    tap(add.x + add.w / 2, add.y + add.h / 2)
    local menu = fixture.lvglMock.menu()
    assert(menu.title == "Select panel" and menu.values[catalogIndex] == item.label, "catalog/picker mismatch")
    menu.set(catalogIndex)
    drawerReady()
    local session = context.editorSession
    assert(#session.draft.panels == 1, panelType .. ": picker failed to add panel")
    assert(context.editorUi.mode == "configure", panelType .. ": picker did not open configuration")
    local placement = session.draft.panels[1]
    assert(placement.type == panelType, "picker added the wrong panel")
    local module = fixture.module("panels/" .. panelType .. ".lua")
    local supported = module.supportedSpans == nil
    for _, span in ipairs(module.supportedSpans or {}) do
        supported = supported or span == "any" or span == placement.colSpan .. "x" .. placement.rowSpan
    end
    assert(supported, panelType .. ": added at an unsupported size")

    if panelType == "metric" then
        assert(#placement.config.metrics == 0, "Metric must start with an empty list")
        action("append", "metrics").press()
        drawerReady()
        assert(#placement.config.metrics == 1 and placement.config.metrics[1].source == nil, "first metric is blank")
        assert(action("item", "metrics").text() == "--", "blank metric summary must render")
        action("item", "metrics").press()
        drawerReady()
        control("metrics", "source").set(getFieldInfo("Alt").id)
        drawerReady()
        control("metrics", "label").set("Installed altitude")
        drawerReady()
        back()
    end
    back()
    assert(#context.document.panels == 0, "preview must not commit the draft")
    running()
    local expected = editor.clone(session.draft)

    frame(EVT_VIRTUAL_EXIT)
    menu = fixture.lvglMock.menu()
    assert(menu.title == "Unsaved changes", "installation must offer to save")
    local saveIndex
    for index, label in ipairs(menu.values) do
        if label == "Save" then
            saveIndex = index
        end
    end
    menu.set(assert(saveIndex, "Save missing"))
    untilReady(function()
        return not context.editorUi and not context.stage and not context.reloadState
    end, "save/apply did not finish")
    same(context.document, expected)
    running()
    local saved = assert(hostIo.open(savedPath, "r"), "Save did not write a user layout")
    local document = assert(context.yaml.parse(saved:read("*a")))
    saved:close()
    same(document, expected)

    firstObject = #fixture.lvglMock.objects + 1
    context = fixture.createLoaded(nil, { Layout = name, Theme = "modern-dark" }, path)
    same(context.document, expected)
    running()
    if panelType == "metric" then
        assert(context.panels[1].settings.metrics[1].source == "Alt", "configured metric source did not reload")
    end
end

print = originalPrint
