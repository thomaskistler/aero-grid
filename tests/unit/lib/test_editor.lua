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

local function loadPanel(typeName)
    return modules[typeName], modules[typeName] and nil or "missing module"
end

local function document()
    return {
        version = 1,
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
    neighbour.id, neighbour.col = "third", 2
    session.draft.panels[3] = neighbour
    local moved, conflict = editor.move(session, -1, 1)
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

local function testRestoreDefaultDoesNotApply()
    local session = newSession()
    local default = {
        version = 1,
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
    local ok, err = editor.resize(session, 0, -1)
    assert(not ok and string.find(err, "showIndex", 1, true), "incompatible resize reports setting constraint")
    assert(session.draft.panels[1].rowSpan == 2 and not session.dirty)
    assert(session.draft.panels[1].config.showIndex == true, "resize must not change user settings")
    for _, size in ipairs(editor.sizes(session)) do
        assert(not string.match(size, "x1$"), "picker must exclude incompatible spans")
    end
    for _, position in ipairs(editor.resizePositions(session, false, false)) do
        assert(position.rowSpan >= 2, "corner candidates must honor settings")
    end
    assert(editor.setValue(session, "showIndex", false))
    assert(editor.resize(session, 0, -1), "explicitly disabling detail permits single-row resize")
    assert(session.draft.panels[1].rowSpan == 1)

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
    assert(session.draft.panels[1].col == 2 and session.draft.panels[1].colSpan == 2)
    assert(session.draft.panels[2].col == 0 and session.draft.panels[2].colSpan == 1)
    session = newSession(original)
    editor.select(session, 2)
    local before = editor.clone(session.draft)
    assert(not editor.move(session, -1, 0), "partial overlap is not an anchored swap")
    assert(session.draft.panels[1].col == before.panels[1].col)
    assert(session.draft.panels[2].col == before.panels[2].col)

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
end

testCompatibleSwaps()
testWorkingCopyCancelAndApply()
testPlacementRulesAndResizeAnchor()
testAddRemoveAndStrictSettings()
testRestoreDefaultDoesNotApply()
testResizePreservesSpanDependentSettings()
