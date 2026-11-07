-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
CHAR_UP, CHAR_DOWN = string.char(192), string.char(193)
getSourceIndex = function(name) local info = getFieldInfo(name); return info and info.id end
getSourceName = function(index) local info = getFieldInfo(index); return info and info.name or "" end
getSwitchName = function() return "SAv" end
for _, case in ipairs({
    { panel = "metric", key = "metrics" }, { panel = "chart", key = "metrics" },
    { panel = "state", key = "entries" }, { panel = "state", nested = true },
}) do
    fixture.reset()
    fixture.lvglMock.setFullScreen(true)
    local context = fixture.createLoaded(nil, { Layout = "review-" .. case.panel, Theme = "modern-dark" })
    local definition = fixture.module("main.lua")
    fixture.pump(context, 80, 10)
    assert(context.editorController.openEditor(context))
    assert(fixture.pumpUntil(context, function(value)
        local state = value.editorUi
        return state and not state.session.initializing and not state.buildStage and not state.renderStage
    end, 256, 10))
    local state, editor = context.editorUi, context.editorModule
    local config = state.session.draft.panels[state.session.selected].config
    local items = case.nested and config.entries[1].states or config[case.key]
    local template = assert(items[1])
    for index = 1, 128 do
        items[index] = editor.clone(template)
        if case.nested then items[index].text = "State " .. index else items[index].label = "Entry " .. index end
    end
    local function drain()
        local stages = {}
        for _ = 1, 4000 do
            local stage = state.drawerOpening and state.drawerOpening.phase
            local expected = context.editorUiModule.drawerWorkBound(context)
            local finish, dispatch = context.schedulerHost.finish, context.panelHost.dispatch
            local admitted
            context.schedulerHost.finish = function(self, kind) admitted = kind; return finish(self, kind) end
            context.panelHost.dispatch = function(entry, operation, ...)
                assert(operation ~= "refresh" and operation ~= "step", "large drawers cannot refresh hidden panels")
                return dispatch(entry, operation, ...)
            end
            fixture.tick(10)
            definition.refresh(context)
            context.schedulerHost.finish, context.panelHost.dispatch = finish, dispatch
            if expected then
                assert(admitted == "editor-drawer")
                if stage then stages[stage] = true end
            end
            if not state.drawerBuild and not state.drawerPending and not state.drawerOpen then
                assert(stages.snapshot and stages.forms and stages.items)
                return
            end
        end
        error("large drawer did not finish")
    end
    local function rows()
        local result = {}
        for _, control in ipairs(state.drawerControls) do
            if control.field.action == "item" then
                assert(type(control.field.text) == "function" and control.object.properties.text == control.field.text)
                result[#result + 1] = control
            end
        end
        return result
    end
    context.editorDrawerModule.open(context, state, "configure")
    drain()
    local controls = rows()
    if case.nested then
        assert(#controls == #config.entries and string.find(controls[1].field.text(), "State 128", 1, true))
        local count = 0
        for token in string.gmatch(controls[1].field.text(), "State %d+") do
            count = count + 1
            assert(token == "State " .. count)
        end
        assert(count == 128, "the summary must retain every condition, not just its last row")
        controls[1].object.properties.press()
        drain()
        controls = rows()
        assert(string.find(controls[128].field.text(), "State 128", 1, true))
    end
    assert(#controls == 128 and #items == 128, "oversized lists must not be truncated")
    for index, control in ipairs(controls) do
        local path = control.field.itemPath
        assert(path[#path] == index)
    end
    context.editorUiModule.close(context, true)
end
print("Oversized Metric/Chart/State root/nested drawers retain all 128 rows and bound native summaries")
