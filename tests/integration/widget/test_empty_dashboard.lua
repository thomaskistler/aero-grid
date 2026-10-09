-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
EVT_VIRTUAL_ENTER, EVT_VIRTUAL_EXIT = 9107, 9106
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = 1 })
fixture.pump(context, 3)
local hint = assert(context.emptyHint, "empty dashboard has no hint")
assert(hint.visible)
assert(hint.title.properties.text == "Empty dashboard")
assert(hint.instruction.properties.text == "Long-press for fullscreen")
assert(#hint.objects == 2, "empty dashboard should contain only two text labels")
assert(hint.title.properties.align == CENTERED)
assert(hint.instruction.properties.align == CENTERED)
assert(hint.title.properties.x == 0 and hint.title.properties.w == context.zone.w)
assert(hint.instruction.properties.x == 0 and hint.instruction.properties.w == context.zone.w)
assert(#context.document.panels == 0, "hint was added to the document")
assert(#context.panels == 0, "hint was instantiated as a panel")

fixture.lvglMock.setFullScreen(true)
fixture.pump(context, 3)
assert(hint.instruction.properties.text == "Long-press to start editing")
context.zone.w, context.zone.h = 320, 180
fixture.pump(context, 3)
assert(hint.title.properties.w == 320 and hint.instruction.properties.w == 320, "labels did not resize")
local top = hint.title.properties.y
local bottom = hint.instruction.properties.y + hint.instruction.properties.h
assert(math.abs(top - (180 - bottom)) <= 1, "text block is not vertically centred")

definition.refresh(context, EVT_VIRTUAL_ENTER)
fixture.pump(context, 40)
assert(context.editorUi, "empty dashboard could not enter editing")
assert(not hint.visible, "empty hint overlaps the editor")
for _, object in ipairs(hint.objects) do
    assert(object.hidden, "empty decoration remains visible in editor")
end

definition.refresh(context, EVT_VIRTUAL_EXIT)
fixture.pump(context, 40)
assert(not context.editorUi, "unchanged empty editor did not exit")
assert(context.emptyHint.visible, "empty hint did not return after editing")
definition.update(context, { Layout = "Default", Theme = 1 })
fixture.pump(context, 100)
assert(not context.emptyHint, "empty hint remained after selecting a populated layout")
assert(#context.errors == 0, table.concat(context.errors, "\n"))
assert(fixture.lvglMock.replacedFontRefCount() == 0, "hint leaked font callbacks")
