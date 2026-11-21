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
local tileRow = row("Alt")
assert(tileRow.object.properties.text == "Alt" and tileRow.object.properties.x == 0)
assert(
    tileRow.object.properties.w == state().drawerView.width - state().drawerView.controlInset,
    "a tile button spans the drawer row"
)
for _, child in ipairs(tileRow.row.children or {}) do
    assert(child.kind ~= "label", "a full-width tile has no separate caption")
end
assert((row("Tile size").field.description == note) == unconfigured, "the note follows flight detection")

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
    row("Tile size").field.description == context.debriefPageModule.FILL_EMPTY .. (unconfigured and " " .. note or "")
)
state().status = nil
state().drawerPending = { action = "list" }
settle()
assert((row("Tile size").field.description == note) == unconfigured, "the note follows flight detection")
for _, configured in ipairs({ false, true }) do
    local fields = context.debriefPageModule.listFields(state(), { configured = configured, canAdd = true })
    assert(fields[1].description == (not configured and note or nil))
end

row("Tile size").object.properties.set(2)
settle()
assert(state().session.draft.debrief.size == "wide", "the shared size survives an empty debrief")
press("Add tile")
assert(#tiles() == 1 and state().debriefTarget.kind == "tile", "Add opens the new tile")
row("Title").object.properties.set("Battery")
settle()
assert(tiles()[1].title == "Battery" and tiles()[1].colSpan == 4 and tiles()[1].rowSpan == 2)
for _, entry in ipairs(state().drawerView.controls) do
    assert(entry.field.label ~= "Size", "tile settings have no individual size")
end
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
assert(row("Tile size").object.properties.get() == 2, "the shared size remains Wide")
local sizeDrawer, sizeGeneration = state().nativeDrawer, state().drawerGeneration
row("Tile size").object.properties.set(1)
settle()
assert(tiles()[1].colSpan == 2 and tiles()[1].rowSpan == 2)
assert(row("Tile size").object.properties.get() == 1)
assert(
    state().nativeDrawer == sizeDrawer and state().drawerGeneration == sizeGeneration,
    "size changes retain the drawer"
)
assert(row("Battery").object.properties.text == "Battery", "the title remains the button caption")
row("Tile size").object.properties.set(2)
settle()
assert(tiles()[1].colSpan == 4 and tiles()[1].rowSpan == 2)
assert(row("Tile size").object.properties.get() == 2)
assert(state().nativeDrawer == sizeDrawer and state().drawerGeneration == sizeGeneration)
assert(row("Battery").object.properties.text == "Battery")

press("Add tile")
back()
assert(#tiles() == 2 and tiles()[2].title == "Tile 2")
assert(tiles()[2].colSpan == 4 and tiles()[2].rowSpan == 2, "new tiles inherit the debrief size")
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
assert(state().nativeDrawer.properties.title == "Unsaved layout changes")
local hasSaveAs = false
local save
for _, object in ipairs(fixture.lvglMock.objects) do
    if object.kind == "button" and object.properties.text == "Save layout" and not object.cleared then
        save = object
    end
    if object.kind == "button" and object.properties.text == "Save layout as..." and not object.cleared then
        hasSaveAs = true
    end
end
assert(hasSaveAs, "Save As explicitly names the layout")
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
    if object.kind == "button" and object.properties.text == "Save layout" and not object.cleared then
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
local persisted = assert(context.yaml.parse(text))
assert(persisted.debrief.size == "wide" and #persisted.debrief.tiles == 2, "Save writes the shared size and tiles")

-- Saving the largest supported debrief must stay below the radio's CPU limit,
-- including the editor's panel checks and adopting the saved layout.
context.aeroMenuHandlers.debrief()
assert(fixture.pumpUntil(context, function(host)
    return host.editorUi ~= nil
end, 300))
settle()
while #tiles() < 12 do
    assert(editDebrief(state().session, "addTile"))
end
for index = 1, #tiles() do
    local tile = tiles()[index]
    while #tile.series < 3 do
        assert(editDebrief(state().session, "addSeries", index))
    end
    for position = 1, 3 do
        for key, value in pairs({
            source = "Alt",
            statistic = "max",
            label = "Altitude",
            unit = "m",
            precision = 1,
            rangeMin = 0,
            rangeMax = 100,
            accent = "cyan",
        }) do
            assert(editDebrief(state().session, "setSeriesValue", index, position, key, value))
        end
    end
end
back()
local worst, refresh = 0, definition.refresh
definition.refresh = function(...)
    local count = 0
    debug.sethook(function()
        count = count + 100
    end, "", 100)
    refresh(...)
    debug.sethook()
    worst = math.max(worst, count)
end
state().exitCommand = { action = "save" }
assert(
    fixture.pumpUntil(context, function(host)
        return not host.editorUi and not host.editorRestore
    end, 1000),
    "maximum debrief Save did not finish"
)
definition.refresh = refresh
assert(worst < 18000, "debrief Save callback exceeded its budget: " .. worst)
assert(#context.document.debrief.tiles == 12 and context.serviceRuntime.byId.debrief.count == 36)
assert(context.page == page and context.serviceRuntime == runtime, "maximum debrief Save keeps the dashboard")
