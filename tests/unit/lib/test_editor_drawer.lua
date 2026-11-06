-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local drawer = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/editor_drawer.lua"))()
local previous = lvgl
local writes = 0
local function node(_, properties)
    local object = { properties = properties or {} }
    function object:set(values)
        writes = writes + 1
        for key, value in pairs(values) do self.properties[key] = value end
    end
    function object:clear() self.cleared = true end
    return object
end
lvgl = {
    setting = node, toggle = node, label = node,
    close = function() end,
    hide = function(object) object.hidden = true end,
    show = function(object) object.hidden = false end,
}

local function stateFor(count)
    local state = {
        drawerBuild = count + 1, drawerFields = {}, drawerControls = {},
        drawerBuildConfig = { enabled = true },
        drawerPadding = 2, drawerErrorHeight = 18, nativeDrawer = node(),
        handlers = { editor = { settings = function() error("construction must use its captured configuration") end } },
    }
    for index = 1, count do
        local field = { visibleWhen = { key = "enabled", value = index % 2 == 0 } }
        state.drawerFields[index] = field
        state.drawerControls[index] = {
            field = field, row = node(), errorLabel = node(), height = 36,
            errorShown = index % 3 == 0,
        }
    end
    return state
end

for _, count in ipairs({ 0, 1, 16, 128 }) do
    local state = stateFor(count)
    assert(drawer.workBound(state) == drawer.WORK_BOUNDS.finish)
    assert(drawer.advance({}, state) and state.drawerLayout == 1)
    local calls = 0
    while state.drawerLayout do
        writes = 0
        assert(drawer.workBound(state) == drawer.WORK_BOUNDS.layout)
        assert(drawer.advance({}, state))
        assert(writes <= 8, "one advance lays out at most four rows and their errors")
        calls = calls + 1
    end
    assert(calls == math.max(1, math.ceil(count / 4)))
    assert(state.drawerBuild == nil and state.drawerBuildConfig == nil and state.drawerLayoutY == nil)
    local y = 4
    for index, entry in ipairs(state.drawerControls) do
        if index % 2 == 0 then
            assert(not entry.row.hidden and entry.row.properties.y == y)
            y = y + entry.height
            if entry.errorShown then
                assert(not entry.errorLabel.hidden and entry.errorLabel.properties.y == y)
                y = y + 18
            else
                assert(entry.errorLabel.hidden)
            end
        else
            assert(entry.row.hidden and entry.errorLabel.hidden)
        end
    end
end

for position = 0, 4 do
    local state = stateFor(16)
    drawer.advance({}, state)
    for _ = 1, position do drawer.advance({}, state) end
    drawer.close(state)
    writes = 0
    assert(not drawer.advance({}, state) and writes == 0, "cancelled layout must never resume")
    assert(not state.drawerBuild and not state.drawerLayout and not state.drawerBuildConfig)
end

for _, phase in ipairs({ "snapshot", "forms" }) do
    local state = stateFor(16)
    local command = { action = "append", job = {} }
    state.drawerPending = command
    state.drawerOpening = { phase = phase, job = {} }
    drawer.close(state)
    assert(not state.drawerOpening and not drawer.advance({}, state), "closing must cancel unfinished opening")
    assert(command.job == nil, "cancelled native commands must release their copy graph")
end

do
    local config = { enabled = true }
    local state = {
        drawerBuild = 1, drawerFields = {}, drawerControls = {}, drawerBuildConfig = config,
        drawerGeneration = 1, drawerPadding = 2, drawerNextY = 4, drawerWidth = 384,
        drawerControlHeight = 32, drawerRowHeight = 36, drawerErrorHeight = 18,
        nativeDrawer = node(),
        session = { selected = 1, draft = { panels = { { config = config } } } },
        handlers = { editor = { settings = function() error("construction must not resolve settings per row") end } },
    }
    for index = 1, 16 do
        state.drawerFields[index] = { key = "enabled", type = "boolean", label = "Enabled" }
    end
    for _ = 1, 16 do
        writes = 0
        assert(drawer.advance({ theme = { color = { critical = 1 } } }, state))
        assert(writes == 0, "building a field must not relayout all preceding rows")
    end
    assert(#state.drawerControls == 16)
    assert(drawer.advance({}, state) and state.drawerLayout)
    local pending = true
    state.handlers.blocked = function() return pending end
    assert(not drawer.workBound(state) and not drawer.advance({}, state) and state.drawerLayout == 1)
    pending = false
    while state.drawerLayout do drawer.advance({}, state) end
    pending = true
    local control = state.drawerControls[1].object
    assert(not control.properties.active())
    control.properties.set(0)
    assert(not state.drawerPending, "native setters cannot queue edits while registration drains")
    pending = false
    assert(control.properties.active())
    control.properties.set(0)
    assert(state.drawerPending and state.drawerPending.action == "write", "controls resume after registration")
end

for _, rejected in ipairs({ false, true }) do
    local state, calls = stateFor(128), 0
    drawer.advance({}, state)
    while state.drawerLayout do drawer.advance({}, state) end
    state.session = {}
    state.handlers.logError = function() calls = calls + 1 end
    state.handlers.editor.setValue = function() return not rejected, "rejected" end
    state.handlers.editor.startSettings = function() return {} end
    state.handlers.editor.advanceSettings = function() return true, { enabled = false }, {} end
    local control = state.drawerControls[1]
    control.object, control.kind = node(), "toggle"
    state.drawerPending = { action = "write", field = { key = "enabled" }, value = false, control = control }
    writes = 0
    assert(drawer.workBound(state) == drawer.WORK_BOUNDS.write and drawer.advance({}, state))
    assert(writes <= 1 and state.drawerRefresh and state.drawerBuild, "writes must not synchronously relayout")
    assert(calls == (rejected and 1 or 0) and control.errorShown == rejected)
    while state.drawerBuild do
        writes = 0
        assert(drawer.workBound(state) and drawer.advance({}, state))
        assert(writes <= 8, "mutation visibility advances touch at most four rows")
    end
    assert(not state.drawerRefresh and not state.drawerBuildConfig)
    assert(not state.drawerControls[1].row.hidden and state.drawerControls[2].row.hidden)
    state.drawerPending = { action = "error", message = "source unavailable", control = control }
    drawer.advance({}, state)
    assert(state.drawerRefresh and state.status == "source unavailable")
    drawer.close(state)
    assert(not state.drawerRefresh and not state.drawerBuild and not drawer.advance({}, state))
end

do
    local editor = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/editor.lua"))()
    local module = {
        settings = {
            { key = "a", type = "boolean", default = true }, { key = "b", type = "boolean", default = false },
            { key = "label", type = "boolean", default = true },
        },
        drawerGroups = { { key = "group", label = "Options", fields = { "b", "missing", "a", "label", "b" } } },
    }
    local state = {
        screen = node(), session = {
            selected = 1, draft = { panels = { { type = "metric", config = {} } } },
            loadPanel = function() return module end, panelHost = { validateModule = function() return true end },
        },
        handlers = { editor = editor },
    }
    lvgl.box, lvgl.dialog, lvgl.button, lvgl.choice = node, node, node, node
    lvgl.numberEdit, lvgl.textEdit = node, node
    drawer.open({ zone = { w = 480 } }, state, "configure", nil, nil, nil, "group")
    assert(drawer.workBound(state) == nil, "compatibility groups are not production admission declarations")
    while state.drawerOpening do drawer.advance({}, state) end
    assert(#state.drawerFields == 4 and state.drawerFields[1].key == "b" and state.drawerFields[2].key == "a"
        and state.drawerFields[3].key == "label" and state.drawerFields[4].key == "b",
        "staged groups preserve metadata order, duplicates and skipped unknown keys")
    drawer.close(state)
    module.settings = { { key = "raw", type = "table", default = { value = 1 } } }
    drawer.open({ zone = { w = 480 } }, state, "configure")
    while state.drawerOpening.phase == "snapshot" do drawer.advance({}, state) end
    assert(drawer.workBound(state) == nil, "custom recursive schemas must not borrow a production forms bound")
    drawer.advance({}, state)
    assert(state.drawerUnmeasured and drawer.workBound(state) == nil)
    drawer.close(state)
    assert(not state.drawerUnmeasured)
    state.session.draft.panels[1].type = "custom"
    module.settings = { { key = "a", type = "boolean", default = true } }
    drawer.open({ zone = { w = 480 } }, state, "configure")
    assert(drawer.workBound(state) == nil, "custom schemas do not inherit measured catalog eligibility")
    while state.drawerOpening do
        assert(drawer.workBound(state) == nil)
        drawer.advance({}, state)
    end
    assert(#state.drawerFields == 2, "unmeasured custom schemas must remain editable")
    drawer.close(state)
end

lvgl = previous
print("Editor drawer construction: bounded layout, frozen visibility and cancellation passed")
