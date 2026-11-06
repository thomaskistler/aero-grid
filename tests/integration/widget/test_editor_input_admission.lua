-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
CHAR_UP, CHAR_DOWN = string.char(192), string.char(193)
getSwitchName = function(index)
    if index > 2000 and index <= 2064 then return string.format("L%02d", index - 2000) end
    for source in pairs(fixture.radio.fields) do
        if string.match(source, "^s[a-z]$") then
            for _, suffix in ipairs({ CHAR_UP, "-", CHAR_DOWN }) do
                local name = string.upper(source) .. suffix
                if getSwitchIndex(name) == index then return name end
            end
        end
    end
    return ""
end
getSourceIndex = function(name)
    local info = getFieldInfo(name)
    return info and info.id
end
getSourceName = function(index)
    local info = getFieldInfo(index)
    return info and info.name
end
EVT_ROT_RIGHT, EVT_ROT_LEFT, EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV = 9201, 9202, 9203, 9204
EVT_TOUCH_BREAK, EVT_VIRTUAL_ENTER, EVT_TOUCH_TAP = 9205, 9206, 9207
EVT_VIRTUAL_EXIT = 9208
local context = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" })
local definition = fixture.module("main.lua")
fixture.pump(context, 80, 10)
assert(context.editorController.openEditor(context))
local function settled(value)
    local state = value.editorUi
    return state and not state.session.initializing and not state.buildStage and not state.renderStage
        and not state.previewPending and not state.previewRefresh and not state.drawerBuild and not state.drawerOpen
end
assert(fixture.pumpUntil(context, settled, 256, 10), "the editor must finish construction")
local state = context.editorUi
local finish, dispatch = context.schedulerHost.finish, context.panelHost.dispatch
local admitted
context.schedulerHost.finish = function(self, kind)
    admitted = kind
    return finish(self, kind)
end
context.panelHost.dispatch = function(entry, operation, ...)
    assert(operation ~= "refresh", "editor input cannot refresh hidden panels")
    return dispatch(entry, operation, ...)
end
local function input(event, touch)
    admitted = nil
    fixture.tick(10)
    definition.refresh(context, event, touch)
    fixture.lvglMock.settle()
    assert(admitted == "editor-input", "ordinary editor input must admit service-only work")
    assert(#context.errors == 0, table.concat(context.errors, ";"))
end
local selected = state.session.selected
input(EVT_ROT_RIGHT)
assert(state.renderStage == 1 and (state.keyAdd or state.session.selected ~= selected))
input(EVT_ROT_LEFT)
assert(state.renderStage == 1 and state.session.selected == selected,
    "preemption must not execute geometry in the input callback")
input(EVT_VIRTUAL_NEXT)
input(EVT_VIRTUAL_PREV)
state.drag = {}
input(EVT_TOUCH_BREAK)
assert(not state.drag)
assert(fixture.pumpUntil(context, settled, 32, 10))
input(EVT_VIRTUAL_ENTER)
assert(state.drawerOpen, "input must queue the bounded drawer")
input(EVT_VIRTUAL_EXIT)
assert(not state.drawerOpen and not state.nativeDrawer, "Return cancels before native construction")
input(EVT_VIRTUAL_ENTER)
assert(fixture.pumpUntil(context, settled, 128, 10))
input(EVT_VIRTUAL_ENTER)

local handle, handled = context.editorUiModule.handle, false
context.editorUiModule.handle = function(...)
    handled = true
    return handle(...)
end
context.touchTapHandled = true
input(EVT_TOUCH_TAP)
assert(not handled, "duplicate native taps must not replay input or prevent service admission")
context.editorUiModule.handle = handle
context.schedulerHost.finish, context.panelHost.dispatch = finish, dispatch
print("Editor input/preemption/native delegation admit services without hidden panel refresh")
