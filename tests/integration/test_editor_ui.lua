-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local widget = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local path = root .. "/build/test-widgets/editor-ui/"
os.execute("mkdir -p '" .. path .. "'")
os.execute("cp -R '" .. root .. "/src/WIDGETS/AeroGrid/.' '" .. path .. "'")
-- User layouts are saved beside the copy, as /AEROGRID/ sits beside /WIDGETS/.
os.execute("rm -rf '" .. path .. "AEROGRID'")
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
write("edit-pair", document(2))
for _, vertical in ipairs({ true, false }) do
    write(
        vertical and "edit-vertical-swap" or "edit-horizontal-swap",
        table.concat({
            "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:",
            "  - id: first\n    type: metric\n    col: 0\n    row: 0\n    colSpan: 2\n    rowSpan: 1\n    config:\n      visual: none",
            vertical
                    and "  - id: second\n    type: metric\n    col: 0\n    row: 1\n    colSpan: 2\n    rowSpan: 2\n    config:\n      visual: none"
                or "  - id: second\n    type: metric\n    col: 2\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n    config:\n      visual: none",
            vertical
                    and "  - id: neighbour\n    type: metric\n    col: 0\n    row: 3\n    colSpan: 2\n    rowSpan: 1\n    config:\n      visual: none"
                or "  - id: neighbour\n    type: metric\n    col: 3\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n    config:\n      visual: none",
        }, "\n")
    )
end
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
    widget.lvglMock.settle()
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
--- Leave the editor with RTN and, when changes ask, pick `choice` in the menu.
local function exitWith(choice)
    refresh(EVT_VIRTUAL_EXIT)
    local state = context.editorUi
    if not state or state.saving or not choice then
        return
    end
    local menu = widget.lvglMock.menu()
    equal(menu.title, "Unsaved changes", "changed draft asks before leaving")
    for index, value in ipairs(menu.values) do
        if value == choice then
            menu.set(index)
            refresh()
            return
        end
    end
    error("exit menu has no " .. choice .. ": " .. table.concat(menu.values, ", "))
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
        if
            not context.editorUi.drawerPending
            and context.editorUi.drawerBuild == nil
            and not context.editorUi.previewPending
            and not context.editorUi.previewRefresh
        then
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
    lvgl.close(context.editorUi.nativeDrawer)
    settleDrawer()
end
-- EdgeTX's picker shares getFieldInfo's indices but shows menu names: sensors
-- carry a two-byte icon, channels and switches are upper case, and a named
-- global variable is "GVn:name". getSourceIndex matches them case-insensitively.
local TELEMETRY_ICON = "\194\147"
local UNREADABLE_SOURCE = 500
local function menuName(index)
    if index == UNREADABLE_SOURCE then
        return "SW1"
    end
    local field = getFieldInfo(index)
    local name = field and field.name
    if not name then
        return nil
    end
    local gvar = string.match(name, "^gvar(%d)$")
    if gvar then
        return "GV" .. gvar .. (gvar == "1" and ":Thr" or "")
    elseif string.match(name, "^ch%d+$") or string.match(name, "^s%l$") then
        return string.upper(name)
    end
    return field.unit and TELEMETRY_ICON .. name or nil
end
getSourceIndex = function(name)
    name = string.lower(string.gsub(name, "^" .. TELEMETRY_ICON, ""))
    for index = 1, UNREADABLE_SOURCE do
        local shown = menuName(index)
        if shown then
            shown = string.lower(string.gsub(shown, "^" .. TELEMETRY_ICON, ""))
            if shown == name or string.match(shown, "^(gv%d):") == name then
                return index
            end
        end
    end
    return nil
end
getSourceName = menuName
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
            if name == "remove" or name == "remove-item" then
                equal(row.row.properties.title, "", "remove action has no duplicated row label")
                equal(row.object.properties.x, 0, "remove button spans the settings row")
                equal(row.object.properties.w, row.row.properties.w - 8, "remove button uses full row width")
                equal(row.object.properties.textColor, nil, "remove button uses native theme text")
            end
            return row.object
        end
    end
    error("drawer action not found: " .. name)
end
local function open()
    local first = context.document.panels[1] or { col = 0, row = 0, colSpan = 1, rowSpan = 1 }
    local rect = context.grid.rect(context.zone, first, 4, 4, 4)
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
    local savePath = path .. "AEROGRID/layouts/" .. id .. ".yaml"
    os.remove(savePath)
    os.remove(savePath .. ".bak")
    context = widget.createLoaded({ x = 0, y = 0, w = 480, h = 272 }, { Layout = id, Theme = "modern-dark" }, path)
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

local function dragOntoAdd(index)
    local from, target = state.controls[index].rect, assert(state.addRect)
    local x, y = from.x + 50, from.y + 40
    refresh(EVT_TOUCH_FIRST, { x = x, y = y })
    refresh(EVT_TOUCH_SLIDE, { x = target.x + 50, y = target.y + 40 })
    refresh(EVT_TOUCH_BREAK)
    local expected = context.editorModule.availablePositions(context.editorSession, 1, 1)[1]
    assert(expected and state.addRect, "moving onto + must leave an add tile in another free cell")
    local expectedRect = context.grid.rect(context.zone, expected, 4, 4, 4)
    equal(state.addRect.x, expectedRect.x, "+ relocates to first free column")
    equal(state.addRect.y, expectedRect.y, "+ relocates to first free row")
    equal(state.addPanel.root.properties.x, expectedRect.x, "visible add tile follows hit target")
    equal(state.addPanel.root.properties.y, expectedRect.y, "visible add tile follows hit target row")
    equal(state.addPanel.root.hidden, false, "add tile remains visible after drag")
    equal(state.addLabel.properties.text, "+", "relocated add tile retains plus glyph")
end
dragOntoAdd(1)
dragOntoAdd(1)

local function resizeCorner(left, top, target)
    local from = state.controls[1].rect
    local x = left and from.x + 8 or from.x + from.w - 8
    local y = top and from.y + 8 or from.y + from.h - 8
    local to = context.grid.rect(context.zone, target, 4, 4, 4)
    refresh(EVT_TOUCH_FIRST, { x = x, y = y })
    assert(state.drag and state.drag.resize, "corner starts resize gesture")
    refresh(EVT_TOUCH_SLIDE, {
        x = (left and to.x or to.x + to.w) + state.drag.offsetX,
        y = (top and to.y or to.y + to.h) + state.drag.offsetY,
    })
    refresh(EVT_TOUCH_BREAK)
    local actual = context.editorSession.draft.panels[1]
    for _, key in ipairs({ "col", "row", "colSpan", "rowSpan" }) do
        equal(actual[key], target[key], "corner resize " .. key)
    end
    equal(entry.instance, instance, "corner resize reuses live instance")
    equal(context.document.panels[1].colSpan, 1, "corner resize preserves committed size")
end
resizeCorner(false, false, { col = 0, row = 0, colSpan = 2, rowSpan = 2 })
resizeCorner(true, true, { col = 1, row = 1, colSpan = 1, rowSpan = 1 })
resizeCorner(true, false, { col = 0, row = 1, colSpan = 2, rowSpan = 2 })
resizeCorner(false, false, { col = 0, row = 1, colSpan = 2, rowSpan = 1 })
resizeCorner(true, true, { col = 0, row = 0, colSpan = 2, rowSpan = 2 })
resizeCorner(false, false, { col = 0, row = 0, colSpan = 1, rowSpan = 1 })

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
equal(state.drawerBack, nil, "standard configuration has no custom return button")
equal(state.drawerControls[1].row.properties.y, 4, "first setting starts below native header")
equal(
    state.drawerControls[2].row.properties.y - state.drawerControls[1].row.properties.y,
    20,
    "compact section heading"
)
equal(state.drawerControls[3].row.properties.y - state.drawerControls[2].row.properties.y, 36, "native row spacing")
equal(control("accent").properties.h, 32, "controls use native input height")
for _, field in ipairs(state.drawerFields) do
    assert(string.sub(field.key or "", 1, 2) ~= "__", "geometry is edited by gestures, not settings")
end
equal(control("accent").kind, "choice", "choices use native picker")
equal(control("accent").properties.active(), true, "controls activate after construction")
equal(state.drawerControls[1].kind, "label", "metrics have a section heading")
equal(state.drawerControls[1].object.properties.text, "Metrics", "section uses the collection name")
equal(state.drawerControls[2].row.children[1].properties.text, "ALT", "metric row shows its configured label")
equal(
    state.drawerControls[2].row.children[1].properties.w,
    action("item", "metrics").properties.x - 8,
    "entry name cannot overlap summary"
)
assert(string.find(action("item", "metrics").properties.text(), "Alt", 1, true), "metric summary shows its source")
assert(string.find(action("item", "metrics").properties.text(), "none", 1, true), "metric summary shows visualization")
control("visual").properties.set(1)
settleDrawer()
assert(
    string.find(action("item", "metrics").properties.text(), "bar", 1, true),
    "summary updates when visualization changes"
)
local addMetric = action("append", "metrics")
equal(addMetric.properties.text, "+", "add entry is a plus row")
equal(addMetric.properties.x, 0, "plus spans the full row")
equal(addMetric.properties.w, state.drawerControls[3].row.properties.w - 8, "plus uses full row width")
action("item", "metrics").properties.press()
equal(control("accent").properties.active(), false, "controls disable while a command is pending")
settleDrawer()
equal(control("metrics", "source").kind, "source", "metric sources use native source selection")
local staleSource = control("metrics", "source")
staleSource.properties.set(999)
settleDrawer()
equal(context.editorSession.draft.panels[1].config.metrics[1].source, "Alt", "unresolved sources preserve draft")
assert(state.statusError, "unresolved source selection reports an error")
staleSource.properties.set(140)
state.nativeDrawer.properties.close()
settleDrawer()
equal(state.drawerListKey, nil, "native Return leaves nested settings one level")
equal(context.editorSession.draft.panels[1].config.metrics[1].source, "RSSI", "pending edits survive Return")
assert(
    string.find(action("item", "metrics").properties.text(), "RSSI", 1, true),
    "parent summary reflects edited source"
)
equal(context.document.panels[1].config.metrics[1].source, "Alt", "source edits are isolated")
staleSource.properties.set(106)
equal(state.drawerPending, nil, "dismissed controls cannot change a reopened drawer")
action("append", "metrics").properties.press()
settleDrawer()
equal(#context.editorSession.draft.panels[1].config.metrics, 2, "list entry can be added")
action("item", "metrics").properties.press()
settleDrawer()
action("remove-item").properties.press()
settleDrawer()
equal(#context.editorSession.draft.panels[1].config.metrics, 1, "entry removal is immediate")
action("item", "metrics").properties.press()
settleDrawer()
local sourceControl = control("metrics", "source")
local validSource = context.editorSession.draft.panels[1].config.metrics[1].source
sourceControl.properties.set(999)
settleDrawer()
equal(
    context.editorSession.draft.panels[1].config.metrics[1].source,
    validSource,
    "invalid setting leaves draft unchanged"
)
assert(state.statusError, "invalid setting surfaces an error")
local errorIndex
for index, row in ipairs(state.drawerControls) do
    if row.field.path and row.field.path[#row.field.path] == "source" then
        errorIndex = index
        equal(row.errorLabel.hidden, false, "validation feedback appears beside the field")
        assert(row.errorLabel.properties.text ~= "", "validation feedback explains failure")
        equal(
            state.drawerControls[index + 1].row.properties.y,
            row.errorLabel.properties.y + 18,
            "error shifts next row"
        )
    end
end
assert(errorIndex, "source control is shown")
sourceControl.properties.set(getFieldInfo(validSource).id)
settleDrawer()
equal(
    state.drawerControls[errorIndex + 1].row.properties.y - state.drawerControls[errorIndex].row.properties.y,
    36,
    "correcting an error restores compact spacing"
)
local function pickSource(index)
    control("metrics", "source").properties.set(index)
    settleDrawer()
    return context.editorSession.draft.panels[1].config.metrics[1].source
end
equal(pickSource(330), "gvar1", "a named global variable stores its Lua field name, not GV1:Thr")
equal(control("metrics", "source").properties.get(), 330, "a stored global variable reopens on its picker entry")
equal(pickSource(338), "gvar9", "every global variable stores a readable name")
equal(pickSource(305), "sf", "a switch source stores the lower-case name getFieldInfo reads")
equal(pickSource(140), "RSSI", "a sensor stores its label without the menu icon")
equal(control("metrics", "source").properties.get(), 140, "a stored sensor reopens on its picker entry")
equal(pickSource(UNREADABLE_SOURCE), "RSSI", "a source Lua cannot read leaves the draft unchanged")
assert(string.find(state.status, "Lua cannot read source SW1", 1, true), "unreadable source explains why")
local legacy = context.editorSession.draft.panels[1].config.metrics[1]
legacy.source = "GV1"
equal(control("metrics", "source").properties.get(), 330, "a menu-name source still reopens on its entry")
legacy.source = "RSSI"
pickSource(getFieldInfo(validSource).id)
-- The entry only sets source and label, yet every reading setting is offered.
local entryLabels = {}
for _, row in ipairs(state.drawerControls) do
    if row.field.path then
        entryLabels[#entryLabels + 1] = row.field.label
    end
end
equal(
    table.concat(entryLabels, ","),
    "Source,Label,Unit,Precision,Direction,Range min,Range max,Warning,Critical",
    "metric entries offer every reading setting"
)
local entry = context.editorSession.draft.panels[1].config.metrics[1]
equal(entry.warning, nil, "fixture entry omits warning")
equal(control("metrics", "direction").kind, "choice", "direction uses native picker")
equal(control("metrics", "direction").properties.get(), 1, "omitted direction shows its default")
local warningControl = control("metrics", "warning")
equal(warningControl.kind, "numberEdit", "thresholds use native number entry")
equal(warningControl.properties.get(), warningControl.properties.min, "omitted warning shows as unset")
equal(warningControl.properties.display(warningControl.properties.min), "Off", "unset warning is labelled")
warningControl.properties.set(225)
settleDrawer()
equal(entry.warning, 22.5, "number entry sets an omitted reading setting")
equal(warningControl.properties.get(), 225, "number entry reflects the new value")
warningControl.properties.set(warningControl.properties.min)
settleDrawer()
equal(entry.warning, nil, "choosing unset removes the reading setting")
control("metrics", "unit").properties.set("m")
settleDrawer()
equal(entry.unit, "m", "text entry sets an omitted reading setting")
control("metrics", "unit").properties.set("")
settleDrawer()
equal(entry.unit, nil, "clearing optional text removes it")
equal(
    control("metrics", "precision").properties.display(control("metrics", "precision").properties.min),
    "Sensor",
    "unset precision follows the sensor"
)
state.nativeDrawer.properties.close()
settleDrawer()
equal(context.document.panels[1].colSpan, 1, "settings do not mutate committed layout")
lvgl.close(state.nativeDrawer)
settleDrawer()
equal(state.mode, "menu", "Return closes drawer first")
assert(context.panels[1].instance ~= instance, "configuration preview rebuilds changed panel")
equal(context.panels[1].settings.metrics[1].source, "RSSI", "preview uses edited nested settings")
equal(context.document.panels[1].config.metrics[1].source, "Alt", "preview leaves committed configuration intact")
instance = context.panels[1].instance
rect = state.controls[1].rect
tap(rect.x + rect.w - 12, rect.y + 12)
settleDrawer()
back()
equal(context.panels[1].instance, instance, "unchanged drawer dismissal preserves panel instance")

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
equal(state.mode, "menu", "native popup cancellation needs no drawer navigation")
equal(state.nativeDrawer, nil, "catalog is a native selection popup, not a button drawer")
local selection = widget.lvglMock.menu()
equal(selection.title, "Select panel", "+ opens native panel selection")
equal(#selection.values, #state.handlers.editor.CATALOG, "popup offers catalog labels")
equal(#context.editorSession.draft.panels, 1, "opening or dismissing picker does not add")
for index, item in ipairs(state.handlers.editor.CATALOG) do
    if item.type == "metric" then
        selection.set(index)
        break
    end
end
settleDrawer()
equal(#context.editorSession.draft.panels, 2, "catalog adds panel")
equal(state.mode, "configure", "selecting a panel opens its configuration immediately")
equal(context.editorSession.selected, 2, "new panel is selected for configuration")
selection.set(2)
equal(state.drawerPending, nil, "closed selection callbacks cannot add twice")
equal(#context.panels, 1, "new panel waits for configuration dismissal")
action("item", "metrics").properties.press()
settleDrawer()
control("metrics", "label").properties.set("LIVE")
settleDrawer()
back()
equal(#context.panels, 1, "nested drawer return does not rebuild behind main configuration")
back()
assert(not state.previewError, tostring(state.previewError))
equal(#context.panels, 2, "new panel renders on returning to editing")
equal(context.panels[2].instance.label.properties.text, "LIVE", "new panel renders edited metric heading")
equal(state.previews[2].background.hidden, true, "new panel replaces placeholder")
equal(#context.document.panels, 1, "new panel preview does not commit the draft")
dragOntoAdd(2)
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
            action("remove").properties.press()
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

local savedPath = context.layoutStore.path(path, context.layoutName)
equal(savedPath, path .. "AEROGRID/layouts/edit-sparse.yaml", "Save writes the user layout of the same name")
local save = state.handlers.advanceSave
state.handlers.advanceSave = function()
    return true, false, "simulated SD write failure"
end
exitWith("Save")
assert(state.saving, "save still runs asynchronously")
equal(state.status, "", "saving has no progress text")
equal(state.statusLabel.hidden, true, "saving hides the status overlay")
settleSave()
equal(context.editorUi, state, "save failure keeps draft open")
assert(string.find(state.status, "simulated SD write failure", 1, true), "save error is displayed")
equal(state.statusLabel.hidden, false, "save failures remain visible")
state.handlers.advanceSave = function()
    error("simulated file API exception")
end
exitWith("Save")
equal(state.statusLabel.hidden, true, "retry hides the previous failure while saving")
settleSave()
equal(context.editorUi, state, "file API exception retains draft")
assert(string.find(state.status, "simulated file API exception", 1, true), "file API exception is surfaced")
state.handlers.advanceSave = save
exitWith("Save")
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
local firstPanel, secondPanel = context.panels[1], context.panels[2]
local firstRect, secondRect = state.controls[1].rect, state.controls[2].rect
refresh(EVT_TOUCH_FIRST, { x = firstRect.x + 55, y = firstRect.y + 40 })
equal(#state.drag.positions, 16, "full grid offers compatible swap positions")
refresh(EVT_TOUCH_SLIDE, { x = secondRect.x + 55, y = secondRect.y + 40 })
refresh(EVT_TOUCH_BREAK)
equal(context.editorSession.draft.panels[1].col, 1, "body drag swaps selected panel on full grid")
equal(context.editorSession.draft.panels[2].col, 0, "body drag moves displaced panel to vacated origin")
equal(firstPanel.instance, context.panels[1].instance, "swap keeps first live instance")
equal(secondPanel.instance, context.panels[2].instance, "swap keeps second live instance")
equal(firstPanel.container.properties.x, secondRect.x, "first live panel follows swap")
equal(secondPanel.container.properties.x, firstRect.x, "second live panel follows swap")
equal(context.document.panels[1].col, 0, "swap leaves committed geometry untouched")
firstRect = state.controls[1].rect
refresh(EVT_TOUCH_FIRST, { x = firstRect.x + 55, y = firstRect.y + 40 })
refresh(EVT_TOUCH_SLIDE, { x = secondPanel.container.properties.x + 55, y = firstRect.y + 40 })
refresh(EVT_TOUCH_BREAK)
equal(context.editorSession.draft.panels[1].col, 0, "reverse drag swaps back")
local blockedRect = state.controls[1].rect
refresh(EVT_TOUCH_FIRST, { x = blockedRect.x + blockedRect.w - 8, y = blockedRect.y + blockedRect.h - 8 })
assert(state.drag and state.drag.resize, "full-grid corner starts resizing")
equal(#state.drag.positions, 1, "occupied cells exclude expanded resize candidates")
refresh(EVT_TOUCH_SLIDE, { x = 470, y = 260 })
refresh(EVT_TOUCH_BREAK)
equal(context.editorSession.draft.panels[1].colSpan, 1, "blocked resize retains width")
equal(context.editorSession.draft.panels[1].rowSpan, 1, "blocked resize retains height")
rect = state.controls[6].rect
tap(rect.x + rect.w - 12, rect.y + 12)
settleDrawer()
equal(state.mode, "configure", "full-grid gear works")
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
local swapFirst = context.editorSession.draft.panels[14]
local swapSecond = context.editorSession.draft.panels[15]
local swapFirstCol, swapSecondCol = swapFirst.col, swapSecond.col
context.editorSession.selected = 14
assert(
    state.handlers.editor.move(context.editorSession, swapSecond.col - swapFirst.col, swapSecond.row - swapFirst.row)
)
exitWith("Save")
settleSave()
equal(context.editorUi, nil, "full-grid save exits")
for _ = 1, 60 do
    definition.refresh(context)
end
equal(context.document.panels[14].col, swapSecondCol, "saved layout retains selected swap position")
equal(context.document.panels[15].col, swapFirstCol, "saved layout retains displaced swap position")
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
widget.pump(context, 150)
open()
widget.lvglMock.setFullScreen(false)
refresh()
settleSave()
equal(context.editorUi, nil, "fullscreen exit closes an unchanged editor")
equal(context.editorStash, nil, "an unchanged draft is not kept")

-- A geometry-only save keeps the previewed dashboard instead of reloading it,
-- so no box is built in fullscreen and App mode needs no rebuild.
widget.lvglMock.setFullScreen(false)
load("edit-sparse")
for cycle = 1, 3 do
    local appPage = context.page
    local appInstance = context.panels[1].instance
    widget.lvglMock.setFullScreen(true)
    open()
    local placement = context.editorSession.draft.panels[1]
    local targetCol = placement.col == 0 and 1 or 0
    assert(context.editorUi.handlers.editor.move(context.editorSession, targetCol - placement.col, 0))
    exitWith("Save")
    settleSave()
    equal(context.editorUi, nil, "geometry save exits the editor")
    equal(context.reloadState, nil, "geometry save keeps the previewed dashboard")
    equal(context.page, appPage, "geometry save does not rebuild the page")
    equal(context.panels[1].instance, appInstance, "geometry save keeps live panel instances")
    equal(context.document.panels[1].col, targetCol, "geometry save adopts the saved layout")
    equal(context.panels[1].placement, context.document.panels[1], "panel placement follows saved layout")
    widget.lvglMock.setFullScreen(false)
    refresh()
    equal(context.reloadState, nil, "App exit after geometry save needs no rebuild")
    widget.pump(context, 20)
    equal(context.page, appPage, "App page is kept")
    equal(context.page.builtFullscreen, false, "kept App page remains touch-transparent")
    equal(context.editorUi, nil, "App exit does not reopen the editor")
end
widget.lvglMock.setFullScreen(false)
local reloaded = widget.createLoaded(
    { x = 0, y = 0, w = 480, h = 272 },
    { Layout = "edit-sparse", Theme = "modern-dark" },
    path
)
equal(reloaded.document.panels[1].col, context.document.panels[1].col, "adopted geometry matches the saved file")

-- A panel moved into the menu-button corner in fullscreen, where nothing is
-- reserved, must lay out around the button once App mode returns.
local function labelLayout(target)
    local found = {}
    local function walk(object, path)
        for index, child in ipairs(object.children) do
            if not child.invalid and not child.hidden then
                local key = path .. "/" .. index
                if child.kind == "label" then
                    found[#found + 1] = key
                        .. "="
                        .. tostring(child.properties.text)
                        .. "@"
                        .. tostring(child.properties.x)
                        .. ","
                        .. tostring(child.properties.y)
                end
                walk(child, key)
            end
        end
    end
    for _, entry in ipairs(target.panels) do
        walk(entry.container, entry.placement.id)
    end
    table.sort(found)
    return table.concat(found, "\n")
end
widget.lvglMock.setFullScreen(false)
load("edit-pair")
assert(context.reserved, "App mode reserves the menu button corner")
widget.lvglMock.setFullScreen(true)
open()
context.editorSession.selected = 2
assert(context.editorUi.handlers.editor.move(context.editorSession, -1, 0))
equal(context.editorSession.draft.panels[2].col, 0, "second panel moves into the corner")
exitWith("Save")
settleSave()
widget.lvglMock.setFullScreen(false)
widget.pump(context, 40)
assert(context.reserved, "App return reserves the menu button corner")
local fresh = widget.createLoaded(
    { x = 0, y = 0, w = 480, h = 272 },
    { Layout = "edit-pair", Theme = "modern-dark" },
    path
)
widget.pump(fresh, 10)
equal(labelLayout(context), labelLayout(fresh), "corner panel moved in fullscreen reserves the menu button")

-- A preview that built a panel in fullscreen rebuilds only that panel for App
-- mode; the rest of the dashboard stays on screen.
widget.lvglMock.setFullScreen(false)
load("edit-pair")
local appPage = context.page
local appRoot = context.root
local untouchedInstance = context.panels[2].instance
widget.lvglMock.setFullScreen(true)
open()
context.editorSession.selected = 1
assert(context.editorModule.setPath(context.editorSession, "metrics", { 1, "label" }, "NEW"))
context.editorUi.previewPending = true
settleDrawer()
exitWith("Save")
settleSave()
equal(context.reloadState, nil, "content save keeps the previewed dashboard")
equal(context.page, appPage, "content save does not reload in fullscreen")
equal(context.panels[1].instance.label.properties.text, "NEW", "content save keeps the edited preview")
equal(context.panels[1].builtFullscreen, true, "edited preview is marked as built in fullscreen")
local previewInstance = context.panels[1].instance
widget.lvglMock.setFullScreen(false)
widget.pump(context, 40)
equal(context.reloadState, nil, "App exit does not reload the dashboard")
equal(context.page, appPage, "App exit keeps the page")
equal(context.root, appRoot, "App exit keeps the root")
equal(appPage.cleared, false, "App exit does not clear the page")
equal(context.panels[2].instance, untouchedInstance, "App exit keeps panels built in App mode")
assert(context.panels[1].instance ~= previewInstance, "fullscreen-built panel is rebuilt")
equal(context.panels[1].builtFullscreen, nil, "rebuilt panel is App-built")
equal(context.panels[1].container.builtFullscreen, false, "rebuilt panel container is touch-transparent")
equal(context.panels[1].instance.label.builtFullscreen, false, "rebuilt panel contents are touch-transparent")
equal(context.panels[1].instance.label.properties.text, "NEW", "App rebuild retains the saved content")
equal(context.panels[1].placement, context.document.panels[1], "rebuilt panel keeps its order")
equal(context.appRebuild, nil, "App rebuild completes")
equal(context.editorUi, nil, "App rebuild does not reopen the editor")

-- A dismissed native dialog is registered under a disposable host, so closing
-- it retires the wrapper without a host-wide App reload.
widget.lvglMock.setFullScreen(false)
load("edit-sparse")
appPage = context.page
widget.lvglMock.setFullScreen(true)
open()
state = context.editorUi
context.editorDrawerModule.open(context, state, "configure")
settleDrawer()
local dismissedDialog = state.nativeDrawer
assert(dismissedDialog.registeredParent, "configuration dialog is registered under its host")
lvgl.close(dismissedDialog)
settleDrawer()
equal(dismissedDialog.invalid, true, "closed native dialog wrapper is unregistered")
equal(state.nativeDrawerHost, nil, "dialog host is released")
equal(context.nativeDialogsCreated, nil, "hosted dialogs need no host-wide reload")
exitWith("Save")
settleSave()
widget.lvglMock.setFullScreen(false)
widget.pump(context, 150)
equal(context.page, appPage, "dialog retirement keeps the App page")
equal(appPage.parent.hostRetired, nil, "dialog retirement avoids a host-wide clear")
equal(context.editorUi, nil, "dialog retirement preserves clean editor exit")

-- Unequal panels exchange order within their combined space, not origins.
for _, vertical in ipairs({ true, false }) do
    widget.lvglMock.setFullScreen(true)
    load(vertical and "edit-vertical-swap" or "edit-horizontal-swap")
    open()
    state = context.editorUi
    local originalFirst, originalSecond = context.panels[1].instance, context.panels[2].instance
    local from = state.controls[1].rect
    local target = assert(context.grid.rect(context.zone, {
        col = vertical and 0 or 1,
        row = vertical and 2 or 0,
        colSpan = 2,
        rowSpan = 1,
    }, 4, 4, 4))
    refresh(EVT_TOUCH_FIRST, { x = from.x + 55, y = from.y + 40 })
    refresh(EVT_TOUCH_SLIDE, { x = target.x + 55, y = target.y + 40 })
    refresh(EVT_TOUCH_BREAK)
    local first, second, neighbour = table.unpack(context.editorSession.draft.panels)
    equal(first.col, vertical and 0 or 1, "horizontal reorder accounts for neighbour width")
    equal(first.row, vertical and 2 or 0, "vertical reorder accounts for neighbour height")
    equal(second.col, 0, "displaced panel starts at combined-space left edge")
    equal(second.row, 0, "displaced panel starts at combined-space top edge")
    equal(neighbour.col, vertical and 0 or 3, "reorder leaves unrelated column unchanged")
    equal(neighbour.row, vertical and 3 or 0, "reorder leaves unrelated row unchanged")
    equal(context.panels[1].instance, originalFirst, "directional reorder retains selected instance")
    equal(context.panels[2].instance, originalSecond, "directional reorder retains displaced instance")
    equal(context.panels[1].container.properties.y, target.y, "selected preview uses reordered geometry")
    equal(context.panels[2].container.properties.x, 0, "displaced preview moves to combined-space origin")
    exitWith("Save")
    settleSave()
    for _ = 1, 70 do
        refresh()
    end
    equal(context.document.panels[1].col, vertical and 0 or 1, "horizontal reordered position persists")
    equal(context.document.panels[1].row, vertical and 2 or 0, "vertical reordered position persists")
    equal(context.document.panels[2].rowSpan, vertical and 2 or 1, "displaced span persists unchanged")
end

-- A small panel and empty neighbouring cell can trade rows/columns with a larger panel.
for _, vertical in ipairs({ true, false }) do
    for offset = 0, 1 do
        local id = "edit-empty-swap-" .. (vertical and "vertical" or "horizontal") .. offset
        write(
            id,
            table.concat({
                "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:",
                string.format(
                    "  - id: small\n    type: metric\n    col: %d\n    row: %d\n    colSpan: 1\n    rowSpan: 1\n    config:\n      visual: none",
                    vertical and offset or 0,
                    vertical and 0 or offset
                ),
                string.format(
                    "  - id: large\n    type: metric\n    col: %d\n    row: %d\n    colSpan: 2\n    rowSpan: 2\n    config:\n      visual: none",
                    vertical and 0 or 1,
                    vertical and 1 or 0
                ),
            }, "\n")
        )
        load(id)
        open()
        state = context.editorUi
        local smallInstance, largeInstance = context.panels[1].instance, context.panels[2].instance
        local from = state.controls[1].rect
        local target = assert(context.grid.rect(context.zone, {
            col = vertical and offset or 2,
            row = vertical and 2 or offset,
            colSpan = 1,
            rowSpan = 1,
        }, 4, 4, 4))
        refresh(EVT_TOUCH_FIRST, { x = from.x + 55, y = from.y + 40 })
        refresh(EVT_TOUCH_SLIDE, { x = target.x + 55, y = target.y + 40 })
        refresh(EVT_TOUCH_BREAK)
        equal(context.editorSession.draft.panels[1].col, vertical and offset or 2, "small panel reorders horizontally")
        equal(context.editorSession.draft.panels[1].row, vertical and 2 or offset, "small panel reorders vertically")
        equal(context.editorSession.draft.panels[2].col, 0, "large panel occupies vacated column plus empty space")
        equal(context.editorSession.draft.panels[2].row, 0, "large panel occupies vacated row plus empty space")
        equal(context.panels[1].instance, smallInstance, "small instance survives empty-space reorder")
        equal(context.panels[2].instance, largeInstance, "large instance survives empty-space reorder")
        equal(context.panels[1].container.properties.x, target.x, "small preview follows new origin")
        equal(context.panels[1].container.properties.y, target.y, "small preview follows new row")
        equal(context.panels[2].container.properties.x, 0, "large preview occupies empty adjacent column")
        equal(context.panels[2].container.properties.y, 0, "large preview occupies empty adjacent row")
        exitWith("Save")
        settleSave()
        for _ = 1, 70 do
            refresh()
        end
        equal(context.document.panels[2].col, 0, "large reordered column persists")
        equal(context.document.panels[2].row, 0, "large reordered row persists")
        equal(context.document.panels[1].col, vertical and offset or 2, "small reordered column persists")
        equal(context.document.panels[1].row, vertical and 2 or offset, "small reordered row persists")
    end
end

-- Repeated content previews reuse containers and can be discarded without saving.
widget.lvglMock.setFullScreen(true)
load("edit-sparse")
open()
local container = context.panels[1].container
for index = 1, 5 do
    state = context.editorUi
    rect = state.controls[1].rect
    tap(rect.x + rect.w - 12, rect.y + 12)
    settleDrawer()
    action("item", "metrics").properties.press()
    settleDrawer()
    control("metrics", "label").properties.set("LIVE" .. index)
    settleDrawer()
    back()
    back()
    equal(context.panels[1].container, container, "successive previews reuse the retired container")
    equal(context.panels[1].instance.label.properties.text, "LIVE" .. index, "edited heading is drawn immediately")
    refresh()
    equal(context.panels[1].failed, nil, "reused container survives deferred cleanup")
end
local rejectedPrecision, precisionError =
    context.editorModule.setPath(context.editorSession, "metrics", { 1, "precision" }, 4)
equal(rejectedPrecision, false, "declared entry fields are validated when written")
assert(precisionError, "rejected entry field explains why")
local previewSource = context.editorSession.draft.panels[1].config.metrics[1].source
assert(context.editorModule.setPath(context.editorSession, "metrics", { 1, "source" }, ""))
context.editorUi.previewPending = true
settleDrawer()
assert(context.editorUi.previewError, "invalid settings report a preview failure")
equal(context.editorUi.statusLabel.hidden, false, "preview failure is visible in editing")
equal(#context.panels, 0, "failed preview does not leave a second or stale live instance")
assert(context.editorModule.setPath(context.editorSession, "metrics", { 1, "source" }, previewSource))
context.editorUi.previewPending = true
settleDrawer()
equal(context.editorUi.previewError, nil, "corrected settings clear the preview failure")
equal(context.editorUi.statusLabel.hidden, true, "corrected preview hides its old error")
equal(context.panels[1].container, container, "corrected preview reuses the retired container")
context.editorUi.handlers.close(false)
equal(context.reloadState, "clear", "discarding content previews reloads original layout")
for _ = 1, 70 do
    refresh()
end
equal(context.panels[1].instance.label.properties.text, "ALT", "discard restores original panel contents")
equal(context.document.panels[1].config.metrics[1].label, "ALT", "previews never mutate committed layout")
assert(not hostIo.open(path .. "AEROGRID/layouts/edit-sparse.yaml", "r"), "discard does not write a layout")

-- Text entries use the same summary rows, with switch-position labels.
write(
    "edit-text",
    [[version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: labels
    type: text
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      texts:
        - label: MODE
          source: sa
          positions:
            up: CRUISE
            down: LAND
]]
)
load("edit-text")
open()
state = context.editorUi
rect = state.controls[1].rect
tap(rect.x + rect.w - 12, rect.y + 12)
settleDrawer()
equal(state.drawerControls[1].object.properties.text, "Texts", "text entries have a section heading")
equal(state.drawerControls[2].row.children[1].properties.text, "MODE", "text row uses its label")
equal(action("item", "texts").properties.text(), "SA  CRUISE  --  LAND", "text summary includes source and positions")
equal(action("append", "texts").properties.text, "+", "text list uses plus row")
action("item", "texts").properties.press()
settleDrawer()
control("texts", "label").properties.set("FLIGHT")
settleDrawer()
control("texts", "middle").properties.set("HOVER")
settleDrawer()
back()
equal(state.drawerControls[2].row.children[1].properties.text, "FLIGHT", "parent shows edited text label")
equal(action("item", "texts").properties.text(), "SA  CRUISE  HOVER  LAND", "parent shows edited positions")
for _ = 1, 2 do
    action("append", "texts").properties.press()
    settleDrawer()
end
equal(#context.editorSession.draft.panels[1].config.texts, 3, "text plus adds entries")
equal(action("append", "texts").properties.active(), false, "plus disables at the entry limit")
action("item", "texts").properties.press()
settleDrawer()
action("remove-item").properties.press()
settleDrawer()
equal(#context.editorSession.draft.panels[1].config.texts, 2, "text entry removal returns to summary")
equal(action("append", "texts").properties.active(), true, "removal re-enables plus")
back()
exitWith("Discard changes")
for _ = 1, 70 do
    refresh()
end

-- Exit menu: Discard, Save As with a suggested name, overwrite confirmation.
local function changeFirstLabel(text)
    assert(context.editorModule.setPath(context.editorSession, "metrics", { 1, "label" }, text))
end
local function savedLabel(name)
    local file = hostIo.open(path .. "AEROGRID/layouts/" .. name .. ".yaml", "r")
    if not file then
        return nil
    end
    local parsed = assert(context.yaml.parse(file:read("*a")))
    file:close()
    return parsed.panels[1].config.metrics[1].label
end
widget.lvglMock.setFullScreen(true)
load("edit-sparse")
open()
changeFirstLabel("GONE")
refresh(EVT_VIRTUAL_EXIT)
local exitMenu = widget.lvglMock.menu()
equal(table.concat(exitMenu.values, "|"), "Save|Save as...|Discard changes", "exit menu offers three actions")
equal(context.editorUi.mode, "menu", "RTN on the exit menu keeps editing")
exitWith("Discard changes")
equal(context.editorUi, nil, "Discard leaves the editor")
equal(savedLabel("edit-sparse"), nil, "Discard writes nothing")
for _ = 1, 70 do
    refresh()
end
equal(context.document.panels[1].config.metrics[1].label, "ALT", "Discard keeps the committed layout")

os.remove(path .. "AEROGRID/layouts/" .. model.getInfo().name .. "1.yaml")
open()
changeFirstLabel("COPY")
exitWith("Save as...")
state = context.editorUi
equal(state.mode, "name", "Save As asks for a name")
local nameEdit, nameButton
for _, child in ipairs(state.nativeDrawer.children) do
    if child.kind == "textEdit" then
        nameEdit = child
    elseif child.kind == "button" then
        nameButton = child
    end
end
local suggested = string.gsub(model.getInfo().name, "[^%w_-]+", "-") .. "1"
equal(nameEdit.properties.value, suggested, "Save As suggests the model name and a free number")
lvgl.close(state.nativeDrawer)
refresh()
equal(widget.lvglMock.menu().title, "Unsaved changes", "RTN on the name returns to the exit menu")
exitWith("Save as...")
state = context.editorUi
for _, child in ipairs(state.nativeDrawer.children) do
    if child.kind == "textEdit" then
        nameEdit = child
    elseif child.kind == "button" then
        nameButton = child
    end
end
nameEdit.properties.set("Empty")
nameButton.properties.press()
refresh()
equal(context.editorUi.mode, "name", "a reserved name is refused")
local refused
for _, child in ipairs(context.editorUi.nativeDrawer.children) do
    if child.kind == "label" and child.properties.text ~= "" then
        refused = child.properties.text
    end
end
assert(refused and string.find(refused, "reserved", 1, true), "the refusal is explained")
for _, child in ipairs(context.editorUi.nativeDrawer.children) do
    if child.kind == "textEdit" then
        nameEdit = child
    elseif child.kind == "button" then
        nameButton = child
    end
end
nameEdit.properties.set("Copy_1")
nameButton.properties.press()
refresh()
settleSave()
equal(context.editorUi, nil, "Save As leaves the editor")
equal(savedLabel("Copy_1"), "COPY", "Save As writes the draft under the new name")
equal(savedLabel("edit-sparse"), nil, "Save As leaves this dashboard's layout alone")
local note = widget.lvglMock.message()
equal(note.title, "Saved as Copy_1", "Save As reports the saved name")
assert(string.find(note.message, "Restart the radio", 1, true), "Save As explains the restart")
for _ = 1, 70 do
    refresh()
end
equal(context.document.panels[1].config.metrics[1].label, "ALT", "this dashboard keeps its committed layout")
equal(context.layoutName, "edit-sparse", "this dashboard keeps its layout name")

open()
changeFirstLabel("AGAIN")
exitWith("Save as...")
state = context.editorUi
for _, child in ipairs(state.nativeDrawer.children) do
    if child.kind == "textEdit" then
        nameEdit = child
    elseif child.kind == "button" then
        nameButton = child
    end
end
nameEdit.properties.set("Copy_1")
nameButton.properties.press()
refresh()
local overwrite = widget.lvglMock.confirm()
equal(overwrite.title, "Overwrite Copy_1?", "an existing name asks before replacing")
equal(context.editorUi.mode, "name", "Back keeps the name dialog")
overwrite.confirm()
refresh()
settleSave()
equal(savedLabel("Copy_1"), "AGAIN", "Overwrite replaces the existing layout")

-- Empty is never written: Save is not offered, and Save As names the copy.
write("Empty", "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels: {}\n")
load("Empty")
equal(#context.document.panels, 0, "Empty starts blank")
open()
local addTile = assert(context.editorUi.addRect)
tap(addTile.x + 50, addTile.y + 40)
settleDrawer()
for index, item in ipairs(context.editorUi.handlers.editor.CATALOG) do
    if item.type == "metric" then
        widget.lvglMock.menu().set(index)
        break
    end
end
settleDrawer()
back()
refresh(EVT_VIRTUAL_EXIT)
equal(table.concat(widget.lvglMock.menu().values, "|"), "Save as...|Discard changes", "Empty offers no Save")
exitWith("Discard changes")
assert(not hostIo.open(path .. "AEROGRID/layouts/Empty.yaml", "r"), "Empty is never written")

-- Leaving fullscreen neither saves nor discards; the draft resumes on return.
load("edit-sparse")
os.remove(path .. "AEROGRID/layouts/edit-sparse.yaml")
widget.lvglMock.setFullScreen(true)
open()
changeFirstLabel("KEPT")
local stashed = context.editorSession
widget.lvglMock.setFullScreen(false)
refresh()
equal(context.editorUi, nil, "App mode shows no editor")
equal(context.editorStash, stashed, "the changed draft is kept")
equal(savedLabel("edit-sparse"), nil, "leaving fullscreen does not save")
widget.pump(context, 80)
equal(context.panels[1].instance.label.properties.text, "ALT", "App mode shows the committed layout")
widget.lvglMock.setFullScreen(true)
settle()
equal(context.editorSession, stashed, "returning to fullscreen resumes the draft")
settleDrawer()
equal(context.panels[1].instance.label.properties.text, "KEPT", "the resumed draft is previewed")
exitWith("Save")
settleSave()
equal(savedLabel("edit-sparse"), "KEPT", "the resumed draft saves")

widget.lvglMock.setFullScreen(true)
lvgl.UI_ELEMENT_HEIGHT = 48
load("Default")
open()
for index = 1, #context.editorSession.draft.panels do
    rect = context.editorUi.controls[index].rect
    tap(rect.x + rect.w - 12, rect.y + 12)
    settleDrawer()
    equal(context.editorUi.mode, "configure", "aircraft panel settings open")
    equal(
        context.editorUi.drawerControls[2].row.properties.y - context.editorUi.drawerControls[1].row.properties.y,
        context.editorUi.drawerControls[1].field.type == "section" and 30 or 54,
        "row spacing follows scaled native control height"
    )
    local panelType = context.editorSession.draft.panels[index].type
    if panelType == "flight-mode" then
        control("showIndex").properties.set(1)
        settleDrawer()
        control("showIndex").properties.set(0)
        settleDrawer()
    elseif panelType == "flight-timer" then
        equal(control("timer").kind, "timer", "model timer uses native timer selection")
        equal(control("label").kind, "textEdit", "labels use the native keyboard")
        equal(type(control("label").properties.value), "string", "native text entry starts with a string")
        control("label").properties.set("Elapsed")
        settleDrawer()
        equal(context.editorSession.draft.panels[index].config.label, "Elapsed", "native text updates draft")
        equal(control("label").properties.value, "Elapsed", "text input reflects accepted draft value")
    elseif panelType == "flight-counter" then
        equal(control("armSwitch").kind, "switch", "arm position uses native switch selection")
        equal(control("motorSource").kind, "source", "motor channel uses source selection")
        equal(control("announcements").kind, "toggle", "booleans use native toggles")
        equal(control("announcements").properties.get(), 0, "toggle getter returns native integer false")
        control("announcements").properties.set(1)
        settleDrawer()
        equal(context.editorSession.draft.panels[index].config.announcements, true, "toggle stores boolean")
        equal(control("announcements").properties.get(), 1, "toggle getter returns native integer true")
        equal(control("minFlightDuration").kind, "numberEdit", "numbers use native bounded inputs")
    end
    back()
    if panelType == "flight-timer" then
        local preview
        for _, panel in ipairs(context.panels) do
            if panel.placement.type == panelType then
                preview = panel
            end
        end
        equal(preview.settings.label, "Elapsed", "timer label renders after returning to edit mode")
    elseif panelType == "flight-counter" then
        local preview
        for _, panel in ipairs(context.panels) do
            if panel.placement.type == panelType then
                preview = panel
            end
        end
        equal(preview.instance.preview, true, "unsaved counter preview cannot track or write flights")
    end
end
context.editorSession.dirty = true
exitWith("Save")
settleSave()
equal(context.editorUi, nil, "aircraft layout and service configuration save")
lvgl.UI_ELEMENT_HEIGHT = nil
widget.lvglMock.setFullScreen(false)

widget.lvglMock.setAppMode(false)
for name in pairs(events) do
    rawset(_G, name, previous[name])
end
setmetatable(_G, oldMetatable)
print("Editor UI integration passed; worst callback: " .. worst .. " instructions")
