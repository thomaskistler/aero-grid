-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local widget = fixture.new()
local widgetPath = root .. "/build/test-widgets/editor-ui/"

local function assertEqual(actual, expected, message)
    assert(actual == expected, (message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

os.execute("rm -rf '" .. string.gsub(widgetPath, "/$", "") .. "'")
os.execute("mkdir -p '" .. widgetPath .. "'")
os.execute("cp -R '" .. root .. "/src/WIDGETS/AeroGrid/.' '" .. widgetPath .. "'")
local layout = table.concat({
    "version: 1",
    "grid:",
    "  columns: 4",
    "  rows: 4",
    "panels:",
    "  - id: mode",
    "    type: flight-mode",
    "    col: 0",
    "    row: 0",
    "    colSpan: 1",
    "    rowSpan: 1",
    "",
}, "\n")
local layoutFile = assert(hostIo.open(widgetPath .. "layouts/default.yaml", "w"))
layoutFile:write(layout)
layoutFile:close()

local previousEvents = {
    EVT_TOUCH_TAP = rawget(_G, "EVT_TOUCH_TAP"),
    EVT_VIRTUAL_ENTER = rawget(_G, "EVT_VIRTUAL_ENTER"),
    EVT_VIRTUAL_EXIT = rawget(_G, "EVT_VIRTUAL_EXIT"),
}
EVT_TOUCH_TAP = 9101
EVT_VIRTUAL_ENTER = 9102
EVT_VIRTUAL_EXIT = 9103

local context = widget.createLoaded(
    { x = 0, y = 0, w = 480, h = 272 },
    { DashID = "editor", Theme = "modern" },
    widgetPath
)
assert(#context.errors == 0, table.concat(context.errors, "\n"))
local originalPath = assert(context.layoutPath)
local savedPath = context.layoutStore.path(widgetPath, context.modelFilename or "default", context.dashboardId)
assert(not hostIo.open(savedPath, "r"), "model-specific layout existed before editing")

widget.lvglMock.setFullScreen(true)
widget.pump(context, 10)
widget.module("main.lua").refresh(context, EVT_TOUCH_TAP, { x = 430, y = 10 })
assert(
    context.editorUi,
    "touching the fullscreen editor affordance did not open the editor: "
        .. "button="
        .. tostring(context.editButton.properties.x)
        .. ", fullscreen="
        .. tostring(context.fullScreen)
        .. ", stage="
        .. tostring(context.stage)
        .. ", errors="
        .. table.concat(context.errors, "; ")
)

local function tap(x, y)
    widget.module("main.lua").refresh(context, EVT_TOUCH_TAP, { x = x, y = y })
end

local function tapAction(id)
    for _, action in ipairs(context.editorUi.actions) do
        if action.id == id then
            tap(action.rect.x + 2, action.rect.y + 2)
            return
        end
    end
    error("missing editor action: " .. id)
end

tapAction("add")
assertEqual(context.editorUi.mode, "add", "Add did not open the catalog")
local catalogRow = context.editorUi.catalogRows[3]
tap(catalogRow.rect.x + 2, catalogRow.rect.y + 2)
assertEqual(#context.editorSession.draft.panels, 2, "catalog tap did not add a panel")
assertEqual(context.editorSession.selected, 2, "added panel was not selected")
local geometry = context.editorUi.geometry
tap(geometry.gridX + 2, geometry.gridY + 2)
assertEqual(context.editorSession.selected, 1, "grid tap did not select the original panel")
tap(geometry.gridX + geometry.cell + 2, geometry.gridY + 2)
assertEqual(context.editorSession.selected, 2, "grid tap did not select the added panel")
tapAction("remove")
assertEqual(#context.editorSession.draft.panels, 1, "Remove did not remove the selected panel")
assert(context.editorModule.move(context.editorSession, 1, 0))
widget.module("main.lua").refresh(context, EVT_VIRTUAL_EXIT)
assert(not context.editorUi, "Cancel did not close the editor")
assertEqual(context.document.panels[1].col, 0, "Cancel changed the active document")
assert(not hostIo.open(savedPath, "r"), "Cancel wrote a layout")

widget.module("main.lua").refresh(context, EVT_VIRTUAL_ENTER)
assert(context.editorUi, "rotary/key entry did not open the editor")
assert(context.editorModule.move(context.editorSession, 1, 0))
context.editorUi.actionIndex = 9
widget.module("main.lua").refresh(context, EVT_VIRTUAL_ENTER)
assert(not context.editorUi, "Apply did not close the editor: " .. tostring(context.editorUi and context.editorUi.status))

local guard = 0
while context.stage or context.reloadState do
    widget.module("main.lua").refresh(context)
    guard = guard + 1
    assert(guard < 100, "saved layout did not reload")
end
assert(context.layoutPath == savedPath, "Apply did not select the saved model-specific layout")
assertEqual(context.document.panels[1].col, 1, "Apply did not persist the edited position")

local savedFile = assert(hostIo.open(savedPath, "r"))
local savedText = savedFile:read("*a")
savedFile:close()
local parsed, parseError = context.yaml.parse(savedText)
assert(parsed, tostring(parseError))
assertEqual(parsed.panels[1].col, 1, "saved YAML does not contain the applied placement")

local backupFile = assert(hostIo.open(savedPath .. ".bak", "w"))
backupFile:write(savedText)
backupFile:close()
local corruptFile = assert(hostIo.open(savedPath, "w"))
corruptFile:write("invalid:\n\tlayout\n")
corruptFile:close()
local recovered = widget.createLoaded(
    { x = 0, y = 0, w = 480, h = 272 },
    { DashID = "editor", Theme = "modern" },
    widgetPath
)
assertEqual(recovered.layoutPath, savedPath .. ".bak", "invalid primary did not load its backup")
assertEqual(recovered.layoutOrigin, "model-backup", "backup recovery origin was not reported")
assertEqual(recovered.document.panels[1].col, 1, "backup recovery loaded the wrong document")

for name, value in pairs(previousEvents) do
    rawset(_G, name, value)
end
widget.lvglMock.setFullScreen(false)
print("AeroGrid editor UI integration test passed")
