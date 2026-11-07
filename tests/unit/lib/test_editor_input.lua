-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local ui = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/editor_ui.lua"))()
local state = { mode = "menu", session = { draft = { panels = { { type = "metric" } } } } }
local context = {
    editorUi = state,
    editorDrawerModule = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/editor_drawer.lua"))(),
}
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
assert(ui.inputWorkBound(context, EVT_TOUCH_FIRST) == ui.INPUT_BOUNDS.first, "drag start only queues enumeration")
assert(ui.inputWorkBound(context, EVT_TOUCH_SLIDE) == ui.INPUT_BOUNDS.slide, "slides only record the target")
for _, event in ipairs({
    EVT_VIRTUAL_EXIT, EVT_KEY_FIRST(KEY_LEFT), EVT_KEY_REPT(KEY_RIGHT),
}) do
    assert(ui.inputWorkBound(context, event) == nil, "unmeasured exit and optional key APIs stay ineligible")
end
state.session.selected = 1
for _, case in ipairs({
    { drag = { resize = true, job = { phase = "module" }, rects = {}, positions = {} }, stage = "module" },
    { drag = { resize = true, job = { phase = "settings" }, rects = {}, positions = {} }, stage = "settings" },
    { drag = { job = { phase = "positions" }, rects = {}, positions = {} }, stage = "positions" },
    { drag = { rects = {}, positions = { {} } }, stage = "rects" },
    { drag = { rects = { {} }, positions = { {} }, x = 1, y = 1 }, stage = "apply" },
}) do
    state.drag = case.drag
    assert(ui.dragStage(state) == case.stage and ui.dragWorkBound(context) == ui.DRAG_BOUNDS[case.stage], case.stage)
end
state.drag = { resize = true, job = { phase = "positions" }, rects = {}, positions = {} }
state.session.draft.panels[1].type = "custom"
assert(ui.dragWorkBound(context) == nil, "custom resize validation remains unmeasured")
state.session.draft.panels[1].type = "metric"
state.previewRefresh = true
assert(ui.dragWorkBound(context) == nil, "preview work keeps its own charge")
state.previewRefresh = nil
state.drag.released = true
assert(ui.inputWorkBound(context, EVT_TOUCH_TAP) == nil, "a released drag applies before further input")
state.drag, state.session.selected = nil, nil
state.keyAdd = true
assert(ui.inputWorkBound(context, EVT_VIRTUAL_ENTER) == ui.INPUT_BOUNDS.open)
state.keyAdd = false
state.renderStage = 1
assert(ui.inputWorkBound(context, EVT_ROT_LEFT) == ui.INPUT_BOUNDS.select, "input preemption has a separate bound")
state.session.selected = 1
assert(ui.handle(context, EVT_VIRTUAL_ENTER))
assert(state.drawerOpen.mode == "configure" and state.drawerOpen.selected == 1)
assert(ui.renderWorkBound(state) == nil and ui.drawerWorkBound(context) == ui.DRAWER_OPEN_BOUNDS.configure)
state.session.draft.panels[1].type = "custom"
assert(ui.drawerWorkBound(context) == nil, "custom Configure opening remains unmeasured")
state.session.draft.panels[1].type = "metric"
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
do
    local pending = true
    state.handlers = { blocked = function() return pending end }
    state.drawerOpen, state.previewPending, state.renderStage = { mode = "configure", selected = 1 }, true, 2
    assert(ui.inputWorkBound(context, EVT_VIRTUAL_EXIT) == nil)
    assert(ui.renderWorkBound(state) == nil and ui.drawerWorkBound(context) == nil)
    assert(not ui.handle(context, EVT_VIRTUAL_EXIT) and state.drawerOpen)
    assert(not ui.advance(context) and state.previewPending and state.renderStage == 2,
        "registration pauses all preview work without dropping queued commands")
    pending = false
    assert(ui.handle(context, EVT_VIRTUAL_EXIT) and not state.drawerOpen)
end
context.editorUi = nil
assert(ui.inputWorkBound(context, EVT_VIRTUAL_ENTER) == nil)
print("Editor input eligibility admits measured drag stages and excludes exit and lifecycle work")
