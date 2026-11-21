-- SPDX-License-Identifier: GPL-2.0-only

-- The Flight debrief setup page: open from the menu, edit tiles and series in
-- native dialogs, and Save the draft without reloading the dashboard.

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(true)
local file = assert(fixture.hostIo.open(fixture.path .. "layouts/debrief-setup.yaml", "w"))
file:write([[
version: 4
grid:
  columns: 4
  rows: 4
panels:
  - id: metric
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
]])
file:close()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "debrief-setup", Theme = "modern-dark" }, nil, definition)
fixture.pump(context, 60)
local page, runtime = context.page, context.serviceRuntime

local function settle()
    assert(
        fixture.pumpUntil(context, function(host)
            local state = host.editorUi
            return not state or not state.drawerBuild and not state.drawerPending and not state.nativeInput
        end, 300),
        "debrief page work did not finish"
    )
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
end
local function state()
    return assert(context.editorUi)
end
local function row(label)
    for _, entry in ipairs(state().drawerView.controls) do
        if entry.field.label == label then
            return entry
        end
    end
    error("no row " .. label)
end
local function active(label)
    local value = row(label).object.properties.active
    if type(value) == "function" then
        return value()
    end
    return value ~= false
end
local function press(label)
    row(label).object.properties.press()
    settle()
end
local function choose(label)
    local menu = assert(fixture.lvglMock.menu())
    for index, value in ipairs(menu.values) do
        if value == label then
            menu.set(index)
            settle()
            return
        end
    end
    error("no menu choice " .. label)
end
local function back()
    lvgl.close(state().nativeDrawer)
    settle()
end
local function tiles()
    return state().session.draft.debrief.tiles
end

context.aeroMenuHandlers.debrief()
assert(fixture.pumpUntil(context, function(host)
    return host.editorUi and host.editorUi.nativeDrawer
end, 300))
settle()
assert(state().debrief and state().debriefTarget.kind == "list")
assert(state().mode == "debrief" and state().nativeDrawer)
assert(active("Add tile"))
-- EdgeTX stops polling `active` beneath a hidden object, which would leave
-- every row disabled and the dialog deaf to RTN.
local ancestor = state().nativeDrawer
while ancestor do
    assert(not ancestor.hidden, "the debrief dialog sits under a hidden object")
    ancestor = ancestor.parent or ancestor.registeredParent
end
local note = context.debriefPageModule.FLIGHT_NOTE
local unconfigured = context.flightFactory.broker.view.status == "unconfigured"

-- The layout has never had a debrief, so the page shows the one derived from
-- its panels; deriving is not an edit.
assert(context.debriefGenerated and state().session.debriefDerived and not state().session.dirty)
assert(#tiles() == 1 and tiles()[1].title == "Alt" and tiles()[1].series[1].source == "Alt")
assert((row("Alt").field.description == note) == unconfigured, "the note follows flight detection")

-- Fill from dashboard asks before it replaces tiles, then makes them the layout's own.
tiles()[1].title = "Renamed"
press("Fill from dashboard")
local confirmation = assert(fixture.lvglMock.confirm(), "Fill asks before replacing tiles")
assert(confirmation.title == "Fill from dashboard?" and tiles()[1].title == "Renamed")
confirmation.confirm()
settle()
assert(#tiles() == 1 and tiles()[1].title == "Alt", "Fill rebuilds the tiles from the panels")
assert(not state().session.debriefDerived and state().session.dirty)

-- Fill judges each reading by the draft's thresholds, not the saved layout's.
assert(tiles()[1].series[1].statistic == "max")
local reading = state().session.draft.panels[1].config.metrics[1]
reading.warning, reading.critical = 20, 10
press("Fill from dashboard")
assert(fixture.lvglMock.confirm()).confirm()
settle()
assert(tiles()[1].series[1].statistic == "min", "a falling draft threshold records the minimum")
reading.warning, reading.critical = nil, nil

-- A Fill that maps no panels leaves an empty debrief and says why.
assert(state().handlers.editor.editDebrief(state().session, "removeTile", 1))
local panels = state().session.draft.panels
state().session.draft.panels = {}
press("Fill from dashboard")
state().session.draft.panels = panels
assert(#tiles() == 0 and state().session.draft.debrief)
assert(
    row("Add tile").field.description == context.debriefPageModule.FILL_EMPTY .. (unconfigured and " " .. note or "")
)
state().status = nil
state().drawerPending = { action = "list" }
settle()
assert((row("Add tile").field.description == note) == unconfigured, "the note follows flight detection")
for _, configured in ipairs({ false, true }) do
    local fields = context.debriefPageModule.listFields(state(), { configured = configured, canAdd = true })
    assert(fields[1].description == (not configured and note or nil))
end

press("Add tile")
assert(#tiles() == 1 and state().debriefTarget.kind == "tile", "Add opens the new tile")
row("Title").object.properties.set("Battery")
settle()
row("Size").object.properties.set(3)
settle()
assert(tiles()[1].title == "Battery" and tiles()[1].colSpan == 4 and tiles()[1].rowSpan == 1)
assert(row("Size").object.properties.get() == 3, "the Size control shows the edited size")
assert(active("Add series"))

press("min")
assert(state().debriefTarget.kind == "series")
for _, entry in ipairs(state().drawerView.controls) do
    assert(entry.field.label ~= "Remove series", "the only series cannot be removed")
end
row("Statistic").object.properties.set(2)
settle()
assert(tiles()[1].series[1].statistic == "max" and row("Statistic").object.properties.get() == 2)
row("Label").object.properties.set("Low")
settle()
assert(tiles()[1].series[1].label == "Low")
row("Label").object.properties.set("")
settle()
assert(tiles()[1].series[1].label == nil, "a cleared label falls back to the statistic")
back()
assert(state().debriefTarget.kind == "tile")
press("Add series")
assert(#tiles()[1].series == 2 and state().debriefTarget.series == 2)
press("Remove series")
assert(#tiles()[1].series == 1 and state().debriefTarget.kind == "tile")
back()
assert(state().debriefTarget.kind == "list")

press("Add tile")
back()
assert(#tiles() == 2 and tiles()[2].title == "Tile 2")
press("Battery")
choose("Copy")
assert(string.find(row("Battery").object.properties.text, "(copy)", 1, true))
press("Tile 2")
choose("Paste after")
assert(#tiles() == 3 and tiles()[3].title == "Battery" and tiles()[3] ~= tiles()[1])
press("Tile 2")
choose("Move")
press("Battery")
choose("Paste before")
assert(tiles()[1].title == "Tile 2" and tiles()[2].title == "Battery")
press("Battery")
choose("Delete")
assert(#tiles() == 2)

local editDebrief = state().handlers.editor.editDebrief
while #tiles() < 12 do
    assert(editDebrief(state().session, "addTile"))
end
state().drawerPending = { action = "list" }
settle()
assert(not active("Add tile"), "Add is disabled at the tile limit")
press("Battery")
choose("Copy")
press("Battery")
for _, value in ipairs(fixture.lvglMock.menu().values) do
    assert(value ~= "Paste after", "a copy cannot paste past the tile limit")
end
choose("Edit")
back()
while #tiles() > 2 do
    assert(editDebrief(state().session, "removeTile", #tiles()))
end
state().debriefMark = nil
state().drawerPending = { action = "list" }
settle()

local original = getFieldInfo
getFieldInfo = function(name)
    if name == "VCel" then
        return nil
    end
    return original(name)
end
tiles()[1].series[1].source = "VCel"
state().drawerPending = { action = "list" }
settle()
assert(row(context.debriefPageModule.SENSOR_HINT).field.type == "section", "missing sensors show the hint")
getFieldInfo = original
tiles()[1].series[1].source = "Alt"

back()
assert(state().mode == "exit", "leaving with changes asks to Save or Discard")
local save
for _, object in ipairs(fixture.lvglMock.objects) do
    if object.kind == "button" and object.properties.text == "Save" and not object.cleared then
        save = object
    end
end
assert(save).properties.press()
assert(
    fixture.pumpUntil(context, function(host)
        return host.editorUi.mode == "debrief" and not host.editorUi.drawerBuild
    end, 300),
    "a failed Save returns to the list"
)
assert(state().debriefTarget.kind == "list")
assert(
    string.find(state().drawerView.fields[1].description, "source is required", 1, true),
    "the list explains why Save failed"
)
for index = 1, #tiles() do
    assert(state().handlers.editor.editDebrief(state().session, "setSeriesValue", index, 1, "source", "Alt"))
end
back()
for _, object in ipairs(fixture.lvglMock.objects) do
    if object.kind == "button" and object.properties.text == "Save" and not object.cleared then
        save = object
    end
end
save.properties.press()
assert(
    fixture.pumpUntil(context, function(host)
        return not host.editorUi and not host.editorRestore
    end, 500),
    "Save did not finish"
)
assert(#context.errors == 0, table.concat(context.errors, "\n"))
assert(context.page == page and context.serviceRuntime == runtime, "a debrief-only Save keeps the dashboard")
assert(#context.document.debrief.tiles == 2 and context.document.debrief.tiles[1].title == "Tile 2")
assert(not context.debriefGenerated, "the saved debrief is the layout's own")
local saved = assert(fixture.hostIo.open(context.layoutPath, "r"))
local text = saved:read("*a")
saved:close()
assert(string.find(text, "debrief:\n  tiles:\n", 1, true), "Save writes the edited debrief")
