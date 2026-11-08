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
local sourceNames = {}
for _, info in pairs(fixture.radio.fields) do
    assert(sourceNames[info.id] == nil or sourceNames[info.id] == info.name, "duplicate mock source id")
    sourceNames[info.id] = info.name
end
getSourceName = function(index)
    return sourceNames[index]
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
for _, field in ipairs({ "flightRegistrationJob", "flightPublicationJob", "pendingFlightError" }) do
    context[field] = field == "pendingFlightError" and "registration failed" or {}
    assert(not context.editorController.openEditor(context), "registration must block native editor entry")
    assert(not context.editorController.advanceEditor(context))
    assert(not context.editorUiModule.inputWorkBound(context, EVT_VIRTUAL_ENTER))
    assert(not context.editorUiModule.handle(context, EVT_VIRTUAL_EXIT))
    for _, entry in ipairs(state.drawerControls) do
        local properties = entry.object.properties
        if properties.set and properties.active then
            assert(not properties.active())
            properties.set(0)
            assert(not state.drawerPending, "disabled native controls must reject programmatic edits too")
        end
    end
    context[field] = nil
end
local started
context.beginFlightRegistration = function(host)
    assert(host == context)
    started, host.flightRegistrationJob = true, {}
    return true
end
context.configureFlight = function() error("saved-layout adoption must not synchronously re-read model settings") end
context.editorSavedDocument = context.editorModule.clone(context.document)
state.handlers.close(true)
assert(started and context.flightRegistrationJob and not context.reloadState,
    "compatible saved adoption starts registration without reloading or blocking the callback")
print("Editor input/preemption/native delegation admit services without hidden panel refresh")
