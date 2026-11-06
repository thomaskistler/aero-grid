-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local ui = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/editor_ui.lua"))()
local state = { mode = "menu", session = { draft = { panels = { {} } } } }
local context = { editorUi = state }
for index, name in ipairs({
    "EVT_VIRTUAL_ENTER", "EVT_TOUCH_TAP", "EVT_VIRTUAL_PREV", "EVT_VIRTUAL_NEXT",
    "EVT_ROT_LEFT", "EVT_ROT_RIGHT", "EVT_TOUCH_BREAK", "EVT_TOUCH_FIRST", "EVT_TOUCH_SLIDE", "EVT_VIRTUAL_EXIT",
}) do
    _G[name] = index
end
KEY_LEFT, KEY_RIGHT = 21, 22
EVT_KEY_FIRST = function(key) return key + 100 end
EVT_KEY_REPT = function(key) return key + 200 end
assert(ui.inputWorkBound(context, EVT_VIRTUAL_ENTER) == ui.INPUT_BOUNDS.open)
assert(ui.inputWorkBound(context, EVT_TOUCH_TAP) == ui.INPUT_BOUNDS.tap)
for _, event in ipairs({
    EVT_VIRTUAL_PREV, EVT_VIRTUAL_NEXT, EVT_ROT_LEFT, EVT_ROT_RIGHT,
}) do
    assert(ui.inputWorkBound(context, event) == ui.INPUT_BOUNDS.select)
end
assert(ui.inputWorkBound(context, EVT_TOUCH_BREAK) == ui.INPUT_BOUNDS.release)
for _, event in ipairs({
    EVT_TOUCH_FIRST, EVT_TOUCH_SLIDE, EVT_VIRTUAL_EXIT, EVT_KEY_FIRST(KEY_LEFT), EVT_KEY_REPT(KEY_RIGHT),
}) do
    assert(ui.inputWorkBound(context, event) == nil, "unmeasured drag, exit and optional key APIs stay ineligible")
end
state.keyAdd = true
assert(ui.inputWorkBound(context, EVT_VIRTUAL_ENTER) == ui.INPUT_BOUNDS.open)
state.keyAdd = false
state.renderStage = 1
assert(ui.inputWorkBound(context, EVT_ROT_LEFT) == ui.INPUT_BOUNDS.select, "input preemption has a separate bound")
state.session.selected = 1
assert(ui.handle(context, EVT_VIRTUAL_ENTER))
assert(state.drawerOpen.mode == "configure" and state.drawerOpen.selected == 1)
assert(ui.renderWorkBound(state) == nil and ui.drawerWorkBound(context) == ui.DRAWER_OPEN_BOUNDS.configure)
assert(ui.inputWorkBound(context, EVT_ROT_LEFT) == nil, "queued opening is not replayed by input")
assert(ui.inputWorkBound(context, EVT_VIRTUAL_EXIT) == ui.INPUT_BOUNDS.cancel)
assert(ui.handle(context, EVT_VIRTUAL_EXIT) and not state.drawerOpen, "Return cancels before native construction")
state.mode = "configure"
assert(ui.inputWorkBound(context, EVT_VIRTUAL_EXIT) == ui.INPUT_BOUNDS.modal)
assert(ui.handle(context, EVT_VIRTUAL_EXIT), "native modal input remains delegated")
for _, stage in ipairs({ "buildStage", "saving", "previewPending", "previewRefresh", "exitCommand" }) do
    state[stage] = true
    assert(ui.inputWorkBound(context, EVT_VIRTUAL_ENTER) == nil, stage)
    state[stage] = nil
end
context.editorUi = nil
assert(ui.inputWorkBound(context, EVT_VIRTUAL_ENTER) == nil)
print("Editor input eligibility excludes drag, exit and lifecycle work")
