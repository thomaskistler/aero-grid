-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local editor = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/editor.lua"))()
local grid = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/grid.lua"))()
local layout = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/layout.lua"))()
local panelHost = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()

local modules = {
    sample = {
        id = "sample",
        apiVersion = 1,
        supportedSpans = { "1x1", "2x1", "1x2" },
        settings = {
            { key = "label", type = "string", default = "SAMPLE" },
            { key = "enabled", type = "boolean", default = true },
            { key = "scale", type = "number", min = 0, max = 10, default = 1 },
            { key = "mode", type = "string", choices = { "bar", "none" }, default = "bar" },
        },
        validateSettings = function(settings)
            if settings.label == "" then
                return { "label must not be empty" }
            end
            return {}
        end,
        create = function()
            return {}
        end,
    },
}
modules["rx-battery"] = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/rx-battery.lua"))()

local function loadPanel(typeName)
    return modules[typeName], modules[typeName] and nil or "missing module"
end

local function document()
    return {
        version = 3,
        grid = { columns = 4, rows = 4 },
        panels = {
            {
                id = "first",
                type = "sample",
                col = 0,
                row = 0,
                colSpan = 1,
                rowSpan = 1,
                config = { label = "First", futureOption = "preserved" },
            },
            {
                id = "second",
                type = "sample",
                col = 1,
                row = 0,
                colSpan = 1,
                rowSpan = 1,
                config = { label = "Second" },
            },
        },
    }
end

local function newSession(input)
    return assert(editor.new(input or document(), grid, layout, panelHost, loadPanel))
end

local function testCatalogAlphabeticalOrder()
    local previous = ""
    local rxIndex
    for index, entry in ipairs(editor.CATALOG) do
        local label = string.lower(entry.label)
        assert(previous < label, "panel types must be ordered alphabetically by label")
        previous = label
        if entry.type == "rx-battery" then
            rxIndex = index
        end
    end
    assert(rxIndex and editor.CATALOG[rxIndex - 1].type == "navigation")
    assert(editor.CATALOG[rxIndex + 1].type == "service-probe")
end

local function testWorkingCopyCancelAndApply()
    local session = newSession()
    local moved = editor.move(session, -1, 0)
    assert(not moved)
    assert(not session.dirty, "rejected movement must not alter the draft")

    editor.select(session, 2)
    assert(editor.setValue(session, "scale", 3))
    assert(editor.setValue(session, "enabled", false))
    assert(editor.setValue(session, "mode", "none"))
    assert(editor.setValue(session, "label", "Changed"))
    local applied, result = editor.apply(session)
    assert(applied, table.concat(result or {}, "; "))
    assert(not session.dirty)
    assert(result.panels[2].config.scale == 3)
    assert(result.panels[2].config.enabled == false)
    assert(result.panels[1].config.futureOption == "preserved")

    assert(editor.setValue(session, "label", "temporary"))
    assert(editor.cancel(session))
    assert(session.draft.panels[2].config.label == "Changed")
    assert(not session.dirty)
end

local function testPlacementRulesAndResizeAnchor()
    local session = newSession()
    assert(editor.move(session, 0, 1))
    assert(session.draft.panels[1].col == 0 and session.draft.panels[1].row == 1)
    assert(editor.resize(session, 1, 0))
    assert(session.draft.panels[1].col == 0 and session.draft.panels[1].row == 1)
    assert(session.draft.panels[1].colSpan == 2)

    editor.select(session, 2)
    local neighbour = editor.clone(session.draft.panels[2])
    neighbour.id, neighbour.col = "third", 0
    session.draft.panels[3] = neighbour
    local moved, conflict = editor.move(session, 0, 1)
    assert(not moved and string.find(conflict, "overlaps", 1, true))
    local resized, spanError = editor.resize(session, 2, 0)
    assert(not resized and string.find(spanError, "does not support", 1, true))
end

local function testAddRemoveAndStrictSettings()
    local session = newSession()
    local added, addError = editor.add(session, "sample")
    assert(added, addError)
    assert(session.draft.panels[3].id == "sample-1")
    assert(session.draft.panels[3].config.label == "SAMPLE")
    assert(not editor.setValue(session, "scale", 11))
    assert(not editor.setValue(session, "mode", "circle"))
    assert(not editor.setValue(session, "unlisted", "x"))
    assert(editor.remove(session))
    assert(#session.draft.panels == 2)

    editor.select(session, 1)
    assert(editor.setValue(session, "label", ""))
    local valid, errors = editor.validate(session)
    assert(not valid and string.find(table.concat(errors, "\n"), "label must not be empty", 1, true))
end

local function testRxBatteryFormAndSourceDrawers()
    local input = { version = 3, grid = { columns = 4, rows = 4 }, panels = {} }
    local session = newSession(input)
    local added, addError = editor.add(session, "rx-battery")
    assert(added, addError)
    local config = session.draft.panels[1].config
    assert(config.cells == 0 and config.source == "Cels" and config.sourceType == nil)
    assert(config.reading == "cell")
    assert(
        config.cellFull == 4.2 and config.cellWarning == 3.6 and config.cellCritical == 3.4 and config.cellEmpty == 3.2
    )
    -- Supporting details are preferences shed by size, never a size error, so
    -- a new panel states them like any other default.
    assert(config.showPack == true and config.showCount == true and config.showDelta == false)

    local fields = assert(editor.formFields(session))
    assert(fields[1].key == "label", "Label is not the first editor control")
    local flatOrder = {}
    for _, field in ipairs(fields) do
        if field.key then
            flatOrder[#flatOrder + 1] = field.key
        end
    end
    for index, key in ipairs({
        "label",
        "source",
        "cells",
        "reading",
        "cellFull",
        "cellWarning",
        "cellCritical",
        "cellEmpty",
        "visual",
        "showPack",
        "showCount",
        "showDelta",
        "accent",
    }) do
        assert(flatOrder[index] == key, "flat RX drawer order: " .. key)
    end
    local indices = {}
    for index, field in ipairs(fields) do
        if field.key then
            indices[field.key] = index
        end
    end
    assert(
        indices.cellFull < indices.cellWarning
            and indices.cellWarning < indices.cellCritical
            and indices.cellCritical < indices.cellEmpty
    )
    assert(fields[indices.cellFull].label == "Full (V/cell)")
    assert(fields[indices.cellWarning].label == "Warning (V/cell)")
    assert(fields[indices.cellCritical].label == "Critical (V/cell)")
    assert(fields[indices.cellEmpty].label == "Empty (V/cell)")
    assert(fields[indices.showPack].label == "Show alt reading")
    assert(fields[indices.cells].label == "Cell count (0 = auto)")
    assert(fields[indices.showDelta].label == "Show cell delta" and fields[indices.showDelta].value == false)
    assert(fields[indices.showPack].visibleWhen.value == "battery" and fields[indices.showPack].visibleWhen.invert)
    assert(fields[indices.showCount].visibleWhen.value == "battery" and fields[indices.showCount].visibleWhen.invert)
    local visual = fields[indices.visual]
    assert(visual.choices[3] == "none" and visual.choiceLabels[3] == "details")
    assert(fields[indices.cellFull].visibleWhen.invert and fields[indices.cellEmpty].visibleWhen.invert)
    for _, field in ipairs(fields) do
        assert(field.type ~= "drawer" and field.key ~= "sourceType", "RX source subdrawers must be absent")
    end
    assert(editor.setValue(session, "cells", 6))
    assert(editor.setValue(session, "showDelta", true))
    assert(session.draft.panels[1].config.cells == 6)
    local valid, validationErrors = editor.validate(session)
    assert(valid, table.concat(validationErrors or {}, "; "))
end

local function testSinglePrecisionVoltageSteps()
    local session = newSession({ version = 3, grid = { columns = 4, rows = 4 }, panels = {} })
    assert(editor.add(session, "rx-battery"))
    local settings = modules["rx-battery"].settings
    local critical
    for _, setting in ipairs(settings) do
        if setting.key == "cellCritical" then
            critical = setting
            break
        end
    end
    local step = critical.step
    critical.step = 0.009999999776482582
    local accepted, message = editor.setValue(session, "cellCritical", 3.4000000953674316)
    critical.step = step
    assert(accepted, message)
    assert(editor.setValue(session, "cellFull", 4.199999809265137))
    assert(editor.setValue(session, "cellWarning", 3.5999999046325684))
    assert(editor.setValue(session, "cellEmpty", 3.200000047683716))
    local valid, errors = editor.validate(session)
    assert(valid, table.concat(errors or {}, "; "))
    assert(not editor.setValue(session, "cellCritical", 3.405), "half-step values must still be rejected")
    assert(not editor.setValue(session, "cellCritical", 3.4001), "real off-step values must still be rejected")
    assert(not editor.setValue(session, "cells", 1.001), "integer steps must still be enforced")
end

local function testDeclaredEntryFieldsAreAlwaysOffered()
    modules.listed = {
        id = "listed",
        apiVersion = 1,
        supportedSpans = { "1x1" },
        settings = {
            {
                key = "items",
                type = "table",
                minItems = 1,
                maxItems = 3,
                fields = {
                    { key = "source", label = "Source", type = "string", required = true },
                    { key = "limit", label = "Limit", type = "number", min = 0, max = 5 },
                    { path = { "positions", "middle" }, label = "Middle", type = "string" },
                },
                default = { { source = "A", positions = {} } },
            },
        },
        create = function()
            return {}
        end,
    }
    local input = document()
    input.panels[1].type = "listed"
    input.panels[1].config = { items = { { source = "A", positions = {} }, { source = "B", positions = {} } } }
    local session = newSession(input)
    local fields = assert(editor.formFields(session))
    local offered = {}
    for _, field in ipairs(fields) do
        if field.path then
            offered[#offered + 1] = field.path[1] .. ":" .. field.entryLabel
        end
    end
    assert(
        table.concat(offered, ",") == "1:Source,1:Limit,1:Middle,2:Source,2:Limit,2:Middle",
        "unset declared entry fields must still be offered: " .. table.concat(offered, ",")
    )
    assert(editor.setPath(session, "items", { 2, "limit" }, 4))
    assert(session.draft.panels[1].config.items[2].limit == 4)
    assert(not editor.setPath(session, "items", { 2, "limit" }, 6), "declared ranges are enforced")
    assert(not editor.setPath(session, "items", { 2, "source" }, nil), "required entry fields cannot be removed")
    assert(editor.setPath(session, "items", { 2, "limit" }, nil), "optional entry fields can be removed")
    assert(session.draft.panels[1].config.items[2].limit == nil)
    assert(editor.setPath(session, "items", { 1, "positions", "middle" }, "MID"))
    assert(session.draft.panels[1].config.items[1].positions.middle == "MID")
    modules.listed = nil
end

local function testRestoreDefaultDoesNotApply()
    local session = newSession()
    local default = {
        version = 3,
        grid = { columns = 4, rows = 4 },
        panels = {
            {
                id = "default",
                type = "sample",
                col = 0,
                row = 0,
                colSpan = 1,
                rowSpan = 1,
                config = {},
            },
        },
    }
    assert(editor.restoreDefault(session, default))
    assert(session.draft.panels[1].id == "default")
    assert(session.original.panels[1].id == "first")
    editor.cancel(session)
    assert(session.draft.panels[1].id == "first")
end

local function testResizePreservesSpanDependentSettings()
    local flightMode = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/flight-mode.lua"))()
    local input = document()
    input.panels = { input.panels[1] }
    local panel = input.panels[1]
    panel.type, panel.rowSpan, panel.config = "flight-mode", 2, { showIndex = true }
    local session = assert(editor.new(input, grid, layout, panelHost, function()
        return flightMode
    end))
    local compactSize, compactPosition = false, false
    for _, size in ipairs(editor.sizes(session)) do
        compactSize = compactSize or string.match(size, "x1$") ~= nil
    end
    for _, position in ipairs(editor.resizePositions(session, false, false)) do
        compactPosition = compactPosition or position.rowSpan == 1
    end
    assert(compactSize, "picker must include spans that shed optional detail")
    assert(compactPosition, "corner candidates must include compact spans")
    assert(editor.resize(session, 0, -1), "optional detail must not prevent a single-row resize")
    assert(session.draft.panels[1].rowSpan == 1 and session.dirty)
    assert(session.draft.panels[1].config.showIndex == true, "resize must preserve optional detail")
    assert(editor.resize(session, 0, 1), "enlargement must restore room for detail")
    assert(session.draft.panels[1].rowSpan == 2)
    assert(session.draft.panels[1].config.showIndex == true)

    flightMode.validateSettings = function()
        error("broken validator")
    end
    local resized, message = editor.resize(session, 1, 0)
    assert(not resized and string.find(message, "validateSettings raised", 1, true))
end

local function testCompatibleSwaps()
    local original = document()
    local session = newSession(original)
    assert(editor.move(session, 0, 0))
    assert(not session.dirty, "no-op movement does not dirty the draft")
    assert(#editor.movePositions(session) == 16, "equal-sized occupied cell is a move candidate")
    assert(editor.move(session, 1, 0))
    assert(session.draft.panels[1].col == 1 and session.draft.panels[2].col == 0)
    assert(session.draft.panels[1].config.label == "First")
    assert(session.draft.panels[2].config.label == "Second")
    assert(original.panels[1].col == 0 and original.panels[2].col == 1, "swap remains isolated")
    assert(editor.move(session, -1, 0), "swapping back restores origins")

    original.panels[1].colSpan = 2
    original.panels[2].col = 2
    session = newSession(original)
    assert(editor.move(session, 2, 0), "different spans can swap when both fit")
    assert(session.draft.panels[1].col == 1 and session.draft.panels[1].colSpan == 2)
    assert(session.draft.panels[2].col == 0 and session.draft.panels[2].colSpan == 1)
    session = newSession(original)
    editor.select(session, 2)
    assert(editor.move(session, -1, 0), "smaller panel can move into its adjacent wider neighbour")
    assert(session.draft.panels[1].col == 1 and session.draft.panels[2].col == 0)

    original.panels[1].col, original.panels[1].colSpan = 3, 1
    original.panels[2].col, original.panels[2].colSpan = 0, 2
    session = newSession(original)
    assert(not editor.move(session, -3, 0), "displaced panel must fit inside the grid")
    assert(not session.dirty)
    original.panels[1].col, original.panels[1].colSpan = 0, 2
    original.panels[2].col, original.panels[2].colSpan = 2, 1
    original.panels[3] = editor.clone(original.panels[2])
    original.panels[3].id, original.panels[3].col = "third", 3
    session = newSession(original)
    assert(not editor.move(session, 2, 0), "multiple occupied panels cannot be displaced")
    assert(not session.dirty)
    original.panels[1].colSpan = 1
    original.panels[2].col, original.panels[2].row, original.panels[2].colSpan = 0, 2, 2
    original.panels[3].col, original.panels[3].row = 1, 0
    session = newSession(original)
    assert(not editor.move(session, 0, 2), "displaced panel must not overlap a later-listed neighbour")
    assert(not session.dirty)
end

local function testDirectionalReordering()
    for _, vertical in ipairs({ true, false }) do
        for firstSpan = 1, 3 do
            for secondSpan = 1, 4 - firstSpan do
                local input = document()
                local first, second = input.panels[1], input.panels[2]
                first.colSpan = vertical and 2 or firstSpan
                first.rowSpan = vertical and firstSpan or 1
                second.col = vertical and 0 or firstSpan
                second.row = vertical and firstSpan or 0
                second.colSpan = vertical and 2 or secondSpan
                second.rowSpan = vertical and secondSpan or 1
                local neighbour = editor.clone(first)
                neighbour.id, neighbour.col, neighbour.row = "unrelated", vertical and 2 or 0, vertical and 0 or 1
                input.panels[3] = neighbour
                local session = newSession(input)
                local candidates = editor.movePositions(session)
                local offered = false
                for _, position in ipairs(candidates) do
                    if
                        position.col == (vertical and 0 or secondSpan)
                        and position.row == (vertical and secondSpan or 0)
                    then
                        offered = true
                    end
                end
                assert(offered, "unequal-size directional reorder must be a drag candidate")
                assert(editor.move(session, vertical and 0 or secondSpan, vertical and secondSpan or 0))
                local a, b = session.draft.panels[1], session.draft.panels[2]
                assert(a.col == (vertical and 0 or secondSpan) and a.row == (vertical and secondSpan or 0))
                assert(b.col == 0 and b.row == 0)
                assert(not grid.overlaps(a, b))
                assert(a.colSpan == first.colSpan and a.rowSpan == first.rowSpan)
                assert(b.colSpan == second.colSpan and b.rowSpan == second.rowSpan)
                assert(a.config.label == "First" and b.config.label == "Second")
                assert(session.draft.panels[3].col == neighbour.col and session.draft.panels[3].row == neighbour.row)
                assert(input.panels[1].col == 0 and input.panels[1].row == 0, "reorder stays in draft")
                assert(editor.move(session, vertical and 0 or -secondSpan, vertical and -secondSpan or 0))
                assert(a.col == 0 and a.row == 0, "reverse reorder restores selected origin")
                assert(b.col == second.col and b.row == second.row, "reverse reorder restores neighbour origin")
            end
        end
    end
end

local function testReorderingWithEmptySpace()
    for _, vertical in ipairs({ true, false }) do
        for offset = 0, 1 do
            for largeSpan = 1, 3 do
                local input = document()
                local first, second = input.panels[1], input.panels[2]
                first.col, first.row = vertical and offset or 0, vertical and 0 or offset
                second.col, second.row = vertical and 0 or 1, vertical and 1 or 0
                second.colSpan, second.rowSpan = vertical and 2 or largeSpan, vertical and largeSpan or 2
                for selected = 1, 2 do
                    local session = newSession(input)
                    editor.select(session, selected)
                    local delta = selected == 1 and largeSpan or -1
                    local wantedCol = vertical and (selected == 1 and offset or 0) or (selected == 1 and largeSpan or 0)
                    local wantedRow = vertical and (selected == 1 and largeSpan or 0) or (selected == 1 and offset or 0)
                    local offered = false
                    for _, candidate in ipairs(editor.movePositions(session)) do
                        if candidate.col == wantedCol and candidate.row == wantedRow then
                            offered = true
                        end
                    end
                    assert(offered, "empty adjacent space permits either panel's drag")
                    assert(editor.move(session, vertical and 0 or delta, vertical and delta or 0))
                    local a, b = session.draft.panels[1], session.draft.panels[2]
                    assert(a.col == (vertical and offset or largeSpan))
                    assert(a.row == (vertical and largeSpan or offset))
                    assert(b.col == 0 and b.row == 0)
                    assert(a.colSpan == 1 and a.rowSpan == 1)
                    assert(b.colSpan == second.colSpan and b.rowSpan == second.rowSpan)
                    assert(not grid.overlaps(a, b))
                    assert(input.panels[2].col == second.col and input.panels[2].row == second.row)
                    assert(editor.move(session, vertical and 0 or -delta, vertical and -delta or 0))
                    assert(a.col == first.col and a.row == first.row)
                    assert(b.col == second.col and b.row == second.row)
                end
                local blocker = editor.clone(first)
                blocker.id = "blocker"
                blocker.col, blocker.row = vertical and (1 - offset) or 0, vertical and 0 or (1 - offset)
                input.panels[3] = blocker
                for selected = 1, 2 do
                    local session = newSession(input)
                    editor.select(session, selected)
                    local delta = selected == 1 and largeSpan or -1
                    assert(not editor.move(session, vertical and 0 or delta, vertical and delta or 0))
                    assert(not session.dirty, "occupied adjacent space blocks the reorder atomically")
                    assert(session.draft.panels[1].col == first.col and session.draft.panels[1].row == first.row)
                    assert(session.draft.panels[2].col == second.col and session.draft.panels[2].row == second.row)
                end
            end
        end
    end
end

local function testNestedStateLists()
    local statePanel = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/state.lua"))()
    modules.state = statePanel
    local input = document()
    input.panels[1].type = "state"
    input.panels[1].config = {
        entries = {
            { label = "MODE", states = { { switch = "SF^", text = "OFF" } } },
        },
    }
    local session = newSession(input)
    local fields = assert(editor.formFields(session))
    local offered = {}
    for _, field in ipairs(fields) do
        if field.path then
            offered[table.concat(field.path, ".")] = field
        end
    end
    assert(offered["1.states"].type == "table-list")
    assert(offered["1.states"].value == 1)
    assert(offered["1.states.1.switch"].entryLabel == "When")
    assert(offered["1.states.1.background"].value == "normal", "omitted nested fields expose their default")
    assert(not editor.removeItem(session, "entries", 1, { 1, "states" }), "condition minimum is enforced")
    assert(not session.dirty, "rejected removal does not dirty draft")
    assert(editor.setPath(session, "entries", { 1, "states", 1, "background" }, "critical"))
    assert(not editor.setPath(session, "entries", { 1, "states", 1, "background" }, "red"))
    assert(not editor.setPath(session, "entries", { 1, "states", 1, "switch" }, nil))
    assert(not editor.setPath(session, "entries", { 1, "states", 1, "text" }, 1))
    assert(editor.appendItem(session, "entries", { 1, "states" }))
    assert(editor.appendItem(session, "entries", { 1, "states" }))
    assert(not editor.appendItem(session, "entries", { 1, "states" }), "condition maximum is enforced")
    assert(not editor.appendItem(session, "entries", { 1, "label" }), "scalar paths cannot be appended")
    assert(not editor.appendItem(session, "entries", { 2, "states" }), "missing list paths cannot be appended")
    local entries = session.draft.panels[1].config.entries
    assert(entries[1].states[1].background == "critical")
    assert(entries[1].states[2].background == nil, "append uses a fresh condition, not the winner's background")
    assert(editor.setPath(session, "entries", { 1, "states", 2, "text" }, "SECOND"))
    assert(entries[1].states[3].text == "UP", "new conditions never alias each other or the declaration")
    assert(editor.removeItem(session, "entries", 1, { 1, "states" }))
    assert(entries[1].states[1].text == "SECOND", "removing preserves priority of remaining conditions")
    assert(editor.appendItem(session, "entries"))
    assert(editor.setPath(session, "entries", { 2, "states", 1, "text" }, "COPY"))
    assert(entries[1].states[1].text == "SECOND", "duplicated entries deep-copy their conditions")
    assert(input.panels[1].config.entries[1].states[1].background == nil, "nested edits stay in the working copy")
    local applied, saved = editor.apply(session)
    assert(applied, table.concat(saved or {}, "; "))
    local reopened = newSession(saved)
    assert(reopened.draft.panels[1].config.entries[2].states[1].text == "COPY", "nested lists survive applying")
    modules.state = nil
end

local function testAllPanelDrawersStartWithLabel()
    local expectedOrder = {
        output = { "label", "firstChannel", "channelCount", "showNames", "showTrim", "accent" },
        ["flight-counter"] = {
            "label",
            "armSwitch",
            "motorSource",
            "motorReversed",
            "minMotorPercent",
            "minFlightDuration",
            "disarmDuration",
            "announcements",
            "history",
        },
        ["flight-mode"] = { "label", "showIndex", "accent" },
        ["flight-timer"] = { "label", "timer", "warning", "critical", "accent" },
        ["host-diagnostics"] = { "label", "section", "maxEntries", "accent" },
        ["link-status"] = {
            "label",
            "rssiSource",
            "qualitySource",
            "modeSource",
            "snrSource",
            "powerSource",
            "protocol",
            "reading",
            "extrema",
            "extremaSource",
            "qualityWarning",
            "qualityCritical",
            "marginWarning",
            "marginCritical",
            "rssiWarning",
            "rssiCritical",
            "barMin",
            "barMax",
            "visual",
            "accent",
        },
        metric = { "metrics", "visual", "accent" },
        ["model-identity"] = { "label", "presentation", "showLabels", "accent" },
        navigation = {
            "label",
            "source",
            "armSwitch",
            "satelliteSource",
            "satelliteWarning",
            "satelliteCritical",
            "showTape",
            "bearingFormat",
            "showCoordinates",
            "accent",
        },
        ["rx-battery"] = {
            "label",
            "source",
            "cells",
            "reading",
            "cellFull",
            "cellWarning",
            "cellCritical",
            "cellEmpty",
            "visual",
            "showPack",
            "showCount",
            "showDelta",
            "accent",
        },
        ["service-probe"] = { "label", "service", "source", "extra", "index", "accent" },
        state = { "entries", "accent" },
        ["tx-battery"] = {
            "label",
            "packEmpty",
            "packFull",
            "warning",
            "critical",
            "visual",
            "showPercent",
            "accent",
        },
        ["trim-panel"] = { "label", "trim1", "trim2", "trim4", "scale", "readout", "accent" },
    }
    for _, entry in ipairs(editor.CATALOG) do
        local module = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/" .. entry.type .. ".lua"))()
        modules[entry.type] = module
        local input = document()
        input.panels[1].type = entry.type
        input.panels[1].config = {}
        local session = newSession(input)
        local fields = assert(editor.formFields(session))
        local actualOrder = {}
        for _, field in ipairs(fields) do
            if field.key and not field.path then
                actualOrder[#actualOrder + 1] = field.key
            end
        end
        local expected = assert(expectedOrder[entry.type], entry.type .. " has no drawer order")
        assert(#actualOrder == #expected, entry.type .. " drawer has an unexpected setting count")
        for index, key in ipairs(expected) do
            assert(actualOrder[index] == key, entry.type .. " drawer order at " .. index .. " should be " .. key)
        end
        local hasLabel = false
        for _, setting in ipairs(module.settings or {}) do
            hasLabel = hasLabel or setting.key == "label"
        end
        if hasLabel then
            assert(fields[1].key == "label", entry.type .. " drawer must start with Label")
            local count = 0
            for _, field in ipairs(fields) do
                if field.key == "label" then
                    count = count + 1
                end
            end
            assert(count == 1, entry.type .. " drawer must not duplicate Label")
        end
    end
end

--- Drawer labels share the row with their control. "Critical below
--- satellites" is the longest that fits at the drawer's label width.
local function testDrawerLabelsFit()
    local longest = #"Critical below satellites"
    local function check(kind, settings)
        for _, setting in ipairs(settings or {}) do
            if type(setting.label) == "string" then
                assert(#setting.label <= longest, kind .. " label is truncated in the drawer: " .. setting.label)
            end
            check(kind, setting.fields)
        end
    end
    for _, entry in ipairs(editor.CATALOG) do
        local module = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/" .. entry.type .. ".lua"))()
        check(entry.type, module.settings)
    end
end

--- A number that may be left unset needs a drawer step that unsets it again;
--- without one, the drawer shows 0 and a cleared alarm cannot be restored.
local function testOptionalNumbersCanBeCleared()
    for _, entry in ipairs(editor.CATALOG) do
        local module = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/" .. entry.type .. ".lua"))()
        modules[entry.type] = module
        local input = document()
        input.panels[1].type = entry.type
        input.panels[1].config = {}
        local fields = assert(editor.formFields(newSession(input)))
        local byKey = {}
        for _, field in ipairs(fields) do
            if field.key and not field.path then
                byKey[field.key] = field
            end
        end
        for _, setting in ipairs(module.settings) do
            if setting.type == "number" and setting.default == nil and not setting.drawerField then
                assert(setting.empty, entry.type .. " " .. setting.key .. " cannot be cleared in the drawer")
                assert(
                    type(setting.min) == "number",
                    entry.type .. " " .. setting.key .. " needs a minimum below which it is unset"
                )
                local field = assert(byKey[setting.key], entry.type .. " " .. setting.key .. " is not in the drawer")
                assert(
                    field.empty == setting.empty,
                    entry.type .. " " .. setting.key .. " loses its unset step in the drawer"
                )
            end
        end
    end
end

testAllPanelDrawersStartWithLabel()
testCatalogAlphabeticalOrder()
testNestedStateLists()
testReorderingWithEmptySpace()
testDirectionalReordering()
testCompatibleSwaps()
testWorkingCopyCancelAndApply()
testPlacementRulesAndResizeAnchor()
testAddRemoveAndStrictSettings()
testRxBatteryFormAndSourceDrawers()
testSinglePrecisionVoltageSteps()
testRestoreDefaultDoesNotApply()
testDeclaredEntryFieldsAreAlwaysOffered()
testResizePreservesSpanDependentSettings()
testOptionalNumbersCanBeCleared()
testDrawerLabelsFit()
