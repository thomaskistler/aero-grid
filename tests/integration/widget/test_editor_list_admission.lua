-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
CHAR_UP, CHAR_DOWN = string.char(192), string.char(193)
getSourceIndex = function(name) local info = getFieldInfo(name); return info and info.id end
getSourceName = function(index) local info = getFieldInfo(index); return info and info.name or "" end
getSwitchName = function() return "" end
local context = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" })
local definition = fixture.module("main.lua")
fixture.pump(context, 80, 10)
assert(context.editorController.openEditor(context))
local function settled(value)
    local state = value.editorUi
    return state and not state.session.initializing and not state.buildStage and not state.renderStage
        and not state.previewPending and not state.previewRefresh and not state.drawerBuild
        and not state.drawerOpen and not state.drawerPending
end
assert(fixture.pumpUntil(context, settled, 256, 10))
local state, stages = context.editorUi, {}
local config = state.session.draft.panels[state.session.selected].config
config.audit = {}
for index = 1, 128 do config.audit[index] = { label = "row", nested = { index } } end
local original = #config.metrics
local function advance()
    local stage = state.drawerOpening and state.drawerOpening.phase or state.drawerPending and state.drawerPending.action
        or state.drawerOpen and "open"
    local expected = context.editorUiModule.drawerWorkBound(context)
    local finish, dispatch = context.schedulerHost.finish, context.panelHost.dispatch
    local admitted
    context.schedulerHost.finish = function(self, kind) admitted = kind; return finish(self, kind) end
    context.panelHost.dispatch = function(entry, operation, ...)
        assert(operation ~= "refresh" and operation ~= "step", "list work must not refresh hidden panels")
        return dispatch(entry, operation, ...)
    end
    fixture.tick(10)
    definition.refresh(context)
    context.schedulerHost.finish, context.panelHost.dispatch = finish, dispatch
    if expected then
        assert(admitted == "editor-drawer", tostring(stage))
        if stage then stages[stage] = true end
    end
    fixture.lvglMock.settle()
end
local function drain()
    for _ = 1, 512 do
        advance()
        if settled(context) then return end
    end
    error("list drawer did not settle")
end
local function press(action)
    for _, control in ipairs(state.drawerControls) do
        if control.field.action == action then
            assert(control.object.properties.active())
            control.object.properties.press()
            return
        end
    end
    error("missing " .. action)
end
context.editorDrawerModule.open(context, state, "configure")
assert(state.drawerOpening and state.drawerBuild, "opening must not copy a large config synchronously")
drain()
press("item")
drain()
press("remove-item")
drain()
assert(#config.metrics == original - 1 and not state.drawerListKey)
press("append")
drain()
assert(#config.metrics == original and config.audit[128].nested[1] == 128)
assert(stages.snapshot and stages.forms and stages.item and stages["remove-item"] and stages.append and stages.open)

press("item")
drain()
press("remove-item")
drain()
press("append")
advance()
assert(state.drawerPending.job and #config.metrics == original - 1)
state.nativeDrawer.properties.close()
assert(state.drawerDismiss and not state.drawerOpening)
for _ = 1, 128 do
    advance()
    if state.drawerPending.action == "back" then break end
end
assert(state.drawerPending.action == "back" and #config.metrics == original and not state.drawerOpen)
advance()
assert(state.mode == "menu" and state.previewPending and not state.nativeDrawer)
print("List/opening continuations admit services and preserve committed edits across native Return")
