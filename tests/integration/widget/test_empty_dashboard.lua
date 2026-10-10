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
local function assertHorizontallyCentred()
    for _, key in ipairs({ "title", "instruction" }) do
        local label = hint[key].properties
        local width = context.themeBuilder.measureText(SMLSIZE, label.text)
        assert(label.w == width, "hint width must match rendered text")
        assert(math.abs(label.x - (context.zone.w - label.x - width)) <= 1, "hint is not horizontally centred")
    end
end
assertHorizontallyCentred()
assert(#context.document.panels == 0, "hint was added to the document")
assert(#context.panels == 0, "hint was instantiated as a panel")

fixture.lvglMock.setFullScreen(true)
fixture.pump(context, 3)
assert(hint.instruction.properties.text == "Long-press to start editing")
assertHorizontallyCentred()
context.zone.w, context.zone.h = 320, 180
fixture.pump(context, 3)
assertHorizontallyCentred()
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
