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
end

lvgl = previous
print("Editor drawer construction: bounded layout, frozen visibility and cancellation passed")
