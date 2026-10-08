-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local widget = fixture.new()
local widgetPath = root .. "/build/test-widgets/editor-ui/"

local function assertEqual(actual, expected, message)
    assert(
        actual == expected,
        (message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)
    )
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

local events = {
    EVT_TOUCH_TAP = 9101,
    EVT_VIRTUAL_ENTER = 9102,
    EVT_VIRTUAL_EXIT = 9103,
    EVT_TOUCH_FIRST = 9104,
    EVT_TOUCH_BREAK = 9105,
}
local previousEvents, previousMetatable = {}, getmetatable(_G)
for name in pairs(events) do
    previousEvents[name] = rawget(_G, name)
    rawset(_G, name, nil)
end
-- Firmware constants resolve through the global lookup, not raw table fields.
setmetatable(_G, {
    __index = function(_, key)
        if events[key] then
            return events[key]
        end
        local index = previousMetatable and previousMetatable.__index
        if type(index) == "function" then
            return index(_G, key)
        elseif type(index) == "table" then
            return index[key]
        end
    end,
})

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
widget.module("main.lua").refresh(context, EVT_TOUCH_FIRST, { x = 430, y = 10 })
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
local originalEntry = context.panels[1]
local originalInstance = originalEntry.instance
local originalBounds = {
    x = originalEntry.container.properties.x,
    y = originalEntry.container.properties.y,
    w = originalEntry.container.properties.w,
    h = originalEntry.container.properties.h,
}
assert(not context.page.hidden, "editing hid the live dashboard")
assertEqual(originalEntry.instance, originalInstance, "editing recreated the live panel")

local function tap(x, y)
    widget.module("main.lua").refresh(context, EVT_TOUCH_FIRST, { x = x, y = y })
    widget.module("main.lua").refresh(context, EVT_TOUCH_BREAK)
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
local remove = context.editorUi.actions[7].rect
widget.module("main.lua").refresh(context, EVT_TOUCH_TAP, { x = remove.x + 2, y = remove.y + 2 })
assertEqual(#context.editorSession.draft.panels, 1, "bubbled duplicate tap removed another panel")
tapAction("configure")
assertEqual(context.editorUi.mode, "configure", "Configure did not open a drawer")
assertEqual(context.editorUi.fields[2].value, "green", "drawer did not show the schema default")
local accentField = context.editorUi.fieldRows[2].rect
tap(accentField.x + accentField.w - 2, accentField.y + 2)
assertEqual(context.editorSession.draft.panels[1].config.accent, "amber", "drawer did not edit the draft setting")
assertEqual(originalEntry.settings.accent, "green", "drawer changed live panel settings before Apply")
tap(10, context.zone.h - 10)
assertEqual(context.editorUi.mode, "menu", "Back did not return to dashboard editing")
assert(context.editorModule.move(context.editorSession, 1, 0))
-- Render the draft without replacing the panel instance.
tapAction("move")
assert(originalEntry.container.properties.x > originalBounds.x, "moving did not preview on the actual panel")
assertEqual(originalEntry.instance, originalInstance, "geometry preview replaced the panel instance")
assertEqual(context.document.panels[1].col, 0, "preview mutated the committed placement")
assertEqual(
    context.editorUi.selection.properties.x,
    originalEntry.container.properties.x,
    "selection did not outline the actual panel"
)
tapAction("resize")
tap(geometry.gridX + geometry.cell * 2 + 2, geometry.gridY + 2)
assert(originalEntry.container.properties.w > originalBounds.w, "resize did not preview on the actual panel")
assertEqual(context.editorSession.draft.panels[1].col, 1, "resize moved the top-left cell")
tapAction("remove")
assert(originalEntry.container.hidden, "removed panel remained visible in the draft")
tapAction("cancel")
assert(not context.editorUi, "Cancel did not close the editor")
assertEqual(context.document.panels[1].col, 0, "Cancel changed the active document")
assert(not originalEntry.container.hidden, "Cancel did not restore the removed live panel")
assertEqual(originalEntry.container.properties.x, originalBounds.x, "Cancel did not restore original geometry")
assertEqual(originalEntry.container.properties.w, originalBounds.w, "Cancel did not restore original size")
assertEqual(originalEntry.instance, originalInstance, "Cancel recreated the original panel")
assert(not hostIo.open(savedPath, "r"), "Cancel wrote a layout")

widget.module("main.lua").refresh(context, EVT_VIRTUAL_ENTER)
assert(context.editorUi, "rotary/key entry did not open the editor")
tapAction("move")
tap(geometry.gridX + geometry.cell + 2, geometry.gridY + 2)
tapAction("apply")
assert(
    not context.editorUi,
    "Apply did not close the editor: " .. tostring(context.editorUi and context.editorUi.status)
)

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

setmetatable(_G, previousMetatable)
for name in pairs(events) do
    rawset(_G, name, previousEvents[name])
end
widget.lvglMock.setFullScreen(false)
print("AeroGrid editor UI integration test passed")
