-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local widget = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local path = root .. "/build/test-widgets/editor-ui/"
os.execute("mkdir -p '" .. path .. "'")
os.execute("cp -R '" .. root .. "/src/WIDGETS/AeroGrid/.' '" .. path .. "'")
local events = {
    EVT_TOUCH_FIRST = 9101,
    EVT_TOUCH_LONG = 9102,
    EVT_TOUCH_TAP = 9103,
    EVT_TOUCH_SLIDE = 9104,
    EVT_TOUCH_BREAK = 9105,
    EVT_VIRTUAL_EXIT = 9106,
    EVT_VIRTUAL_ENTER = 9107,
    EVT_VIRTUAL_NEXT = 9108,
}
local previous, oldMetatable = {}, getmetatable(_G)
for name in pairs(events) do
    previous[name] = rawget(_G, name)
    rawset(_G, name, nil)
end
setmetatable(_G, {
    __index = function(_, name)
        if events[name] then
            return events[name]
        end
        local index = oldMetatable and oldMetatable.__index
        if type(index) == "function" then
            return index(_G, name)
        end
        if type(index) == "table" then
            return index[name]
        end
    end,
})

local function equal(actual, expected, message)
    assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function write(name, contents)
    local file = assert(hostIo.open(path .. "layouts/" .. name .. ".yaml", "w"))
    file:write(contents)
    file:close()
end
local function document(count)
    local lines = { "version: 1", "grid:", "  columns: 4", "  rows: 4", "panels:" }
    for index = 1, count do
        lines[#lines + 1] = string.format(
            "  - id: m%d\n    type: metric\n    col: %d\n    row: %d\n    colSpan: 1\n    rowSpan: 1\n    config:\n      metrics:\n        - source: Alt\n          label: ALT\n      visual: none",
            index,
            (index - 1) % 4,
            math.floor((index - 1) / 4)
        )
    end
    return table.concat(lines, "\n")
end
write("edit-sparse", document(1))
write("edit-full", document(16))
local definition = widget.module("main.lua")
local context
local worst = 0
local function refresh(event, touch)
    widget.lvglMock.setPropertyValidation(false)
    widget.lvglMock.setCallCounting(false)
    widget.lcdMock.setTextMeasurement(false)
    local ticks = 0
    local function hook()
        ticks = ticks + 1
    end
    debug.sethook(hook, "", 200)
    local ok, err = pcall(definition.refresh, context, event, touch)
    debug.sethook()
    widget.lvglMock.setPropertyValidation(true)
    widget.lvglMock.setCallCounting(true)
    widget.lcdMock.setTextMeasurement(true)
    assert(ok, tostring(err))
    worst = math.max(worst, ticks * 200)
    assert(ticks * 200 <= 15000, "editor callback exceeded budget: " .. tostring(ticks * 200))
end
local function settle()
    for _ = 1, 60 do
        refresh()
        if context.editorUi and not context.editorUi.buildStage then
            return
        end
    end
    error("editor did not become ready: " .. table.concat(context.errors, "; "))
end
local function settleSave()
    for _ = 1, 500 do
        if not context.editorUi or not context.editorUi.saving then
            return
        end
        refresh()
    end
    error("save did not settle")
end
local function tap(x, y)
    refresh(EVT_TOUCH_FIRST, { x = x, y = y })
    refresh(EVT_TOUCH_BREAK, { x = x, y = y })
    refresh(EVT_TOUCH_TAP, { x = x, y = y })
end
local function settleDrawer()
    for _ = 1, 150 do
        refresh()
        assert(context.editorUi, "drawer failed: " .. table.concat(context.errors, "; "))
        if not context.editorUi.drawerPending and context.editorUi.drawerBuild == nil then
            return
        end
    end
    error("drawer did not settle")
end
local function control(key, leaf)
    for _, row in ipairs(context.editorUi.drawerControls) do
        if row.field.key == key and (not leaf or row.field.path and row.field.path[#row.field.path] == leaf) then
            return row.object
        end
    end
    error("drawer control not found: " .. key)
end
local function back()
    context.editorUi.drawerBack.properties.press()
    settleDrawer()
end
getSourceIndex = function(name)
    return name == "Alt" and 100 or 101
end
getSourceName = function(index)
    return index == 100 and "Alt" or index == 101 and "RSSI" or nil
end
CHAR_UP, CHAR_DOWN = "^", "v"
getSwitchIndex = function(name)
    return name == "SF^" and 1 or 2
end
getSwitchName = function(index)
    return index == 1 and "SF^" or "L01"
end
local function action(name, key)
    for _, row in ipairs(context.editorUi.drawerControls) do
        if row.field.action == name and (not key or row.field.key == key) then
            return row.object
        end
    end
    error("drawer action not found: " .. name)
end
local function open()
    local rect = context.grid.rect(context.zone, context.document.panels[1], 4, 4, 4)
    refresh(EVT_TOUCH_FIRST, { x = rect.x + 50, y = rect.y + 40 })
    widget.tick(59)
    refresh()
    equal(context.editorUi, nil, "short hold must not open editor")
    widget.tick(1)
    refresh()
    assert(context.editorUi, "long-press must open editor")
    settle()
    refresh(EVT_TOUCH_BREAK)
end
local function load(id)
    local savePath = path .. "layouts/test-model--" .. id .. ".yaml"
    os.remove(savePath)
    os.remove(savePath .. ".bak")
    context = widget.createLoaded({ x = 0, y = 0, w = 480, h = 272 }, { DashID = id, Theme = "modern" }, path)
    assert(#context.errors == 0, table.concat(context.errors, "; "))
    widget.pump(context, 10)
end
widget.lvglMock.setAppMode(true)
widget.lvglMock.setFullScreen(false)
load("edit-sparse")
refresh(EVT_TOUCH_LONG, { x = 50, y = 40 })
equal(context.editorUi, nil, "App mode is read-only")
widget.lvglMock.setFullScreen(true)
widget.pump(context, 10)
equal(context.editButton, nil, "fullscreen has no EDIT button")
tap(50, 40)
equal(context.editorUi, nil, "ordinary tap must not open editing")
refresh(EVT_TOUCH_FIRST, { x = 50, y = 40 })
refresh(EVT_TOUCH_SLIDE, { x = 60, y = 40 })
widget.tick(100)
refresh()
equal(context.editorUi, nil, "moving finger cancels long-press entry")
open()
local entry, instance = context.panels[1], context.panels[1].instance
local state = context.editorUi
equal(state.controls[1].left, nil, "no corner remove control")
equal(state.controls[1].gear.kind, "image", "settings control uses a rendered icon")
equal(state.controls[1].gear.properties.file, path .. "assets/editor-configure.png", "settings icon asset")
equal(state.addRect.x, state.cells[2].rect.x, "+ appears in first free cell")
equal(state.addPanel.background.properties.rounded, context.theme.spacing.radius, "+ uses shared panel radius")
equal(state.addPanel.accent.properties.color, context.theme.color.textMuted, "+ has a theme-gray sidebar")
equal(state.addPanel.column.properties.w, context.theme.spacing.accentWidth, "+ uses shared sidebar clipping")
equal(state.addPanel.column.properties.h, state.addRect.h, "+ sidebar follows panel height")
equal(state.addPanel.topArc.arc.kind, "arc", "+ sidebar follows the top panel corner")
equal(state.addPanel.bottomArc.arc.kind, "arc", "+ sidebar follows the bottom panel corner")
equal(state.addLabel.properties.w, context.themeBuilder.measureText(MIDSIZE, "+"), "+ label fits its glyph")
equal(
    state.addLabel.properties.x,
    math.floor((state.addRect.w - state.addLabel.properties.w) / 2),
    "+ is horizontally centered"
)
equal(
    state.addLabel.properties.y,
    math.floor((state.addRect.h - context.themeBuilder.fontHeight(MIDSIZE)) / 2),
    "+ is vertically centered"
)
equal(#context.panels, 1, "editor reuses live instances")

-- Gear opens settings; corner controls must not begin dragging.
local rect = state.controls[1].rect
equal(state.controls[1].gear.properties.x, rect.x + rect.w - 28, "gear stays at top-right")
tap(rect.x + 12, rect.y + 12)
equal(#context.editorSession.draft.panels, 1, "old top-left X target does not remove panel")
equal(state.mode, "menu", "top-left panel tap does not configure")
tap(rect.x + rect.w - 12, rect.y + 12)
settleDrawer()
equal(state.mode, "configure", "gear opens settings")
equal(state.drag, nil, "gear press must not start drag")
equal(state.nativeDrawer.kind, "dialog", "configuration uses native centered dialog")
equal(state.drawerFields[1].key, "__size", "size is first setting")
equal(control("__size").kind, "choice", "size uses native picker")
equal(control("__size").properties.active(), true, "controls activate after construction")
action("item", "metrics").properties.press()
equal(control("__size").properties.active(), false, "controls disable while a command is pending")
settleDrawer()
equal(control("metrics", "source").kind, "source", "metric sources use native source selection")
local staleSource = control("metrics", "source")
staleSource.properties.set(999)
settleDrawer()
equal(context.editorSession.draft.panels[1].config.metrics[1].source, "Alt", "unresolved sources preserve draft")
assert(state.statusError, "unresolved source selection reports an error")
staleSource.properties.set(101)
state.nativeDrawer.properties.close()
settleDrawer()
equal(state.drawerListKey, nil, "native Return leaves nested settings one level")
equal(context.editorSession.draft.panels[1].config.metrics[1].source, "RSSI", "pending edits survive Return")
equal(context.document.panels[1].config.metrics[1].source, "Alt", "source edits are isolated")
staleSource.properties.set(100)
equal(state.drawerPending, nil, "dismissed controls cannot change a reopened drawer")
action("append", "metrics").properties.press()
settleDrawer()
equal(#context.editorSession.draft.panels[1].config.metrics, 2, "list entry can be added")
action("item", "metrics").properties.press()
settleDrawer()
action("remove-item").properties.press()
settleDrawer()
equal(#context.editorSession.draft.panels[1].config.metrics, 1, "entry removal is immediate")
control("__size").properties.set(2)
settleDrawer()
assert(
    context.editorSession.draft.panels[1].colSpan ~= 1 or context.editorSession.draft.panels[1].rowSpan ~= 1,
    "size changes draft"
)
equal(context.document.panels[1].colSpan, 1, "settings do not mutate committed layout")
local rowControl = control("__row")
local unchangedRow = context.editorSession.draft.panels[1].row
rowControl.properties.set(5)
settleDrawer()
equal(context.editorSession.draft.panels[1].row, unchangedRow, "invalid geometry leaves draft unchanged")
assert(state.statusError, "invalid geometry surfaces an error")
for _, row in ipairs(state.drawerControls) do
    if row.field.key == "__row" then
        equal(row.errorLabel.hidden, false, "validation feedback appears beside the field")
        assert(row.errorLabel.properties.text ~= "", "validation feedback explains failure")
    end
end
rowControl.properties.set(unchangedRow + 1)
settleDrawer()
lvgl.close(state.nativeDrawer)
settleDrawer()
equal(state.mode, "menu", "Return closes drawer first")
equal(entry.instance, instance, "resize reuses instance")

local placement = context.editorSession.draft.panels[1]
local oldCol, oldRow = placement.col, placement.row
rect = state.controls[1].rect
refresh(EVT_TOUCH_FIRST, { x = rect.x + rect.w / 2, y = rect.y + 40 })
refresh(EVT_TOUCH_SLIDE, { x = rect.x + rect.w / 2 + 119, y = rect.y + 107 })
refresh(EVT_TOUCH_BREAK)
assert(placement.col ~= oldCol or placement.row ~= oldRow, "drag snaps to a fitting position")
equal(context.document.panels[1].col, 0, "drag does not mutate committed layout")
for _, cell in ipairs(state.cells) do
    equal(cell.background, nil, "no grid guide objects while dragging")
end
local free = assert(state.addRect)
tap(free.x + 50, free.y + 40)
settleDrawer()
equal(state.mode, "add", "+ opens catalog")
state.drawerControls[1].object.properties.press()
settleDrawer()
equal(#context.editorSession.draft.panels, 2, "catalog adds panel")
equal(#context.panels, 1, "new panel is only a draft preview")
rect = state.controls[2].rect
tap(rect.x + rect.w - 48, rect.y + 12)
equal(#context.editorSession.draft.panels, 2, "former X target does not remove panel")
equal(state.mode, "menu", "former X target does not configure")
refresh(EVT_TOUCH_FIRST, { x = rect.x + rect.w - 48, y = rect.y + 12 })
assert(state.drag, "former X target is draggable panel body")
refresh(EVT_TOUCH_BREAK)
tap(rect.x + rect.w - 12, rect.y + 12)
settleDrawer()
local function removePanel()
    for _, row in ipairs(state.drawerControls) do
        if row.field.action == "remove" then
            row.object.properties.press()
            settleDrawer()
            return
        end
    end
    error("Remove panel missing")
end
removePanel()
equal(#context.editorSession.draft.panels, 1, "settings removes panel")
equal(state.mode, "menu", "removal returns to dashboard editing")
refresh(EVT_TOUCH_TAP, { x = rect.x + rect.w - 48, y = rect.y + 12 })
equal(#context.editorSession.draft.panels, 1, "duplicate tap is deduplicated")

local savedPath = context.layoutStore.path(path, context.modelFilename or "default", context.dashboardId)
local save = state.handlers.advanceSave
state.handlers.advanceSave = function()
    return true, false, "simulated SD write failure"
end
refresh(EVT_VIRTUAL_EXIT)
settleSave()
equal(context.editorUi, state, "save failure keeps draft open")
assert(string.find(state.status, "simulated SD write failure", 1, true), "save error is displayed")
state.handlers.advanceSave = function()
    error("simulated file API exception")
end
refresh(EVT_VIRTUAL_EXIT)
settleSave()
equal(context.editorUi, state, "file API exception retains draft")
assert(string.find(state.status, "simulated file API exception", 1, true), "file API exception is surfaced")
state.handlers.advanceSave = save
refresh(EVT_VIRTUAL_EXIT)
settleSave()
equal(context.editorUi, nil, "Return saves and exits")
for _ = 1, 60 do
    widget.module("main.lua").refresh(context)
end
local file = assert(hostIo.open(savedPath, "r"))
local parsed = assert(context.yaml.parse(file:read("*a")))
file:close()
equal(parsed.panels[1].col, placement.col, "saved placement matches preview")
equal(parsed.panels[1].rowSpan, placement.rowSpan, "saved size matches preview")
assert(not hostIo.open(savedPath .. ".tmp", "r"), "temporary save file was removed")

-- Full grid startup and interactions include host callback costs.
load("edit-full")
open()
state = context.editorUi
equal(state.addRect, nil, "full grid hides + tile")
rect = state.controls[6].rect
tap(rect.x + rect.w - 12, rect.y + 12)
settleDrawer()
equal(state.mode, "configure", "full-grid gear works")
equal(#control("__size").properties.values, 1, "blocked sizes are hidden by native picker")
removePanel()
equal(#context.editorSession.draft.panels, 15, "full-grid settings removes only one panel")
assert(state.addRect, "removing panel makes + appear")
equal(state.addPanel.root.properties.x, state.addRect.x, "+ panel moves to newly available cell")
equal(state.addPanel.root.properties.y, state.addRect.y, "+ panel keeps shared geometry")
rect = state.controls[1].rect
refresh(EVT_TOUCH_FIRST, { x = rect.x + 55, y = rect.y + 40 })
refresh(EVT_TOUCH_SLIDE, { x = 170, y = 110 })
refresh(EVT_TOUCH_BREAK)
equal(context.editorSession.draft.panels[1].col, 1, "drag skips occupied destinations")
equal(context.editorSession.draft.panels[1].row, 1, "drag uses free destination")
refresh(EVT_VIRTUAL_EXIT)
settleSave()
equal(context.editorUi, nil, "full-grid save exits")
for _ = 1, 60 do
    definition.refresh(context)
end
open()
refresh(EVT_VIRTUAL_EXIT)

-- Interrupted startup has not changed anything and can be discarded.
for _ = 1, 60 do
    definition.refresh(context)
end
refresh(EVT_VIRTUAL_ENTER)
assert(context.editorUi.buildStage, "key entry starts staged editor")
widget.lvglMock.setFullScreen(false)
refresh()
equal(context.editorUi, nil, "fullscreen exit cancels incomplete startup")
widget.lvglMock.setFullScreen(true)
widget.pump(context, 10)
open()
widget.lvglMock.setFullScreen(false)
refresh()
settleSave()
equal(context.editorUi, nil, "fullscreen exit saves completed editor")

widget.lvglMock.setFullScreen(true)
load("default")
open()
for index = 1, #context.editorSession.draft.panels do
    rect = context.editorUi.controls[index].rect
    tap(rect.x + rect.w - 12, rect.y + 12)
    settleDrawer()
    equal(context.editorUi.mode, "configure", "aircraft panel settings open")
    local panelType = context.editorSession.draft.panels[index].type
    if panelType == "flight-timer" then
        equal(control("timer").kind, "timer", "model timer uses native timer selection")
        equal(control("label").kind, "textEdit", "labels use the native keyboard")
        control("label").properties.set("Elapsed")
        settleDrawer()
        equal(context.editorSession.draft.panels[index].config.label, "Elapsed", "native text updates draft")
    elseif panelType == "flight-counter" then
        equal(control("armSwitch").kind, "switch", "arm position uses native switch selection")
        equal(control("motorSource").kind, "source", "motor channel uses source selection")
        equal(control("announcements").kind, "toggle", "booleans use native toggles")
        control("announcements").properties.set(1)
        settleDrawer()
        equal(context.editorSession.draft.panels[index].config.announcements, true, "toggle stores boolean")
        equal(control("minFlightDuration").kind, "numberEdit", "numbers use native bounded inputs")
    end
    back()
end
context.editorSession.dirty = true
refresh(EVT_VIRTUAL_EXIT)
settleSave()
equal(context.editorUi, nil, "aircraft layout and service configuration save")
widget.lvglMock.setFullScreen(false)

widget.lvglMock.setAppMode(false)
for name in pairs(events) do
    rawset(_G, name, previous[name])
end
setmetatable(_G, oldMetatable)
print("Editor UI integration passed; worst callback: " .. worst .. " instructions")
