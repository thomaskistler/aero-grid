-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
getSourceIndex = function(name)
    local info = getFieldInfo(name)
    return info and info.id or 0
end
getSourceName = function(value)
    return getSourceIndex("GPS") == value and "GPS" or ""
end
fixture.lvglMock.setFullScreen(true)
EVT_VIRTUAL_ENTER = 9601
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 30)
local function untilState(predicate)
    for _ = 1, 200 do
        if predicate() then
            return
        end
        definition.refresh(context)
    end
    error("native editor work did not complete")
end
definition.refresh(context, EVT_VIRTUAL_ENTER)
untilState(function()
    return context.editorUi and not context.editorUi.buildStage
end)
definition.refresh(context, EVT_VIRTUAL_ENTER)
untilState(function()
    return fixture.lvglMock.menu() ~= nil
end)
local state, menu = context.editorUi, fixture.lvglMock.menu()
local index
for position, item in ipairs(state.handlers.editor.CATALOG) do
    if item.type == "navigation" then
        index = position
    end
end
menu.set(assert(index))
assert(state.nativeInput and not state.drawerPending and #state.session.draft.panels == 0)
definition.background(context)
assert(state.nativeInput and #state.session.draft.panels == 0, "hidden callbacks cannot apply native editor commands")
untilState(function()
    return #state.session.draft.panels == 1 and not state.drawerBuild
end)
assert(not state.nativeInput and state.mode == "configure")
local source
for _, row in ipairs(state.drawerControls) do
    if row.kind == "source" then
        source = row.object
        break
    end
end
assert(source)
local originalFieldInfo, lookups = getFieldInfo, 0
getFieldInfo = function(value)
    lookups = lookups + 1
    return originalFieldInfo(value)
end
local value = getSourceIndex("GPS")
local before = lookups
source.properties.set(value)
assert(lookups == before and state.nativeInput, "native setters cannot resolve sources before a grant")
source.properties.get()
assert(lookups == before, "native getters return cached values")
untilState(function()
    return not state.nativeInput
end)
assert(lookups > before, "source resolution must run in a granted editor task")
getFieldInfo = originalFieldInfo
local setter = source.properties.set
context.editorUiModule.close(context, true)
setter(value)
assert(not state.nativeInput, "callbacks from a closed editor cannot retain or apply commands")
