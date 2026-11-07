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
end
assert(fixture.pumpUntil(context, settled, 256, 10))
local state = context.editorUi
context.editorDrawerModule.open(context, state, "configure")
assert(fixture.pumpUntil(context, settled, 128, 10))
local control
for _, entry in ipairs(state.drawerControls) do
    if entry.field.key == "timeRange" then control = entry; break end
end
assert(control)
control.object.properties.set(control.object.properties.get() % #control.field.choices + 1)
assert(state.drawerPending)
local function drain()
    local stages = {}
    for _ = 1, 128 do
        local stage = state.drawerRefresh and (state.drawerLayout and "layout" or state.drawerRefresh.phase)
            or state.drawerPending and state.drawerPending.action
        local expected = context.editorUiModule.drawerWorkBound(context)
        local finish, dispatch = context.schedulerHost.finish, context.panelHost.dispatch
        local admitted
        context.schedulerHost.finish = function(self, kind) admitted = kind; return finish(self, kind) end
        context.panelHost.dispatch = function(entry, operation, ...)
            assert(operation ~= "refresh", "drawer mutation must never refresh hidden panels")
            return dispatch(entry, operation, ...)
        end
        fixture.tick(10)
        definition.refresh(context)
        context.schedulerHost.finish, context.panelHost.dispatch = finish, dispatch
        if expected then
            assert(admitted == "editor-drawer", tostring(stage))
            stages[stage] = true
        end
        fixture.lvglMock.settle()
        if settled(context) and not state.drawerPending then break end
    end
    assert(stages.write and stages.snapshot and stages.layout and stages.summaries)
    assert(not state.drawerRefresh and not state.drawerBuildConfig and not state.drawerBuild)
end
drain()
assert(state.session.dirty and #context.errors == 0)
local rolling = state.session.draft.panels[state.session.selected].config.timeRange == "rolling"
for _, entry in ipairs(state.drawerControls) do
    if entry.field.key == "duration" then assert(entry.row.hidden == not rolling) end
end
state.drawerPending = { action = "write", field = control.field, value = {}, control = control }
drain()
assert(control.errorShown and state.statusError and next(context.errorLog.messages))
control.object.properties.set(control.object.properties.get())
fixture.pump(context, 1, 10)
assert(state.drawerRefresh and not control.object.properties.active())
state.nativeDrawer.properties.close()
assert(not state.drawerRefresh and not state.drawerBuild and state.drawerPending.action == "back")
fixture.pump(context, 1, 10)
assert(state.previewPending and state.mode == "menu", "closing drops only UI refresh, not its completed edit")
print("Drawer writes/snapshots/layout/summaries admit services and retain native cancellation")
