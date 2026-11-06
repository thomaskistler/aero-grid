-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local ui = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/editor_ui.lua"))()
local grid = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/grid.lua"))()
local editor = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/editor.lua"))()

local previousLvgl = lvgl
local function object(parent, properties)
    local result = { parent = parent, properties = properties, hidden = false }
    function result:set(values)
        for key, value in pairs(values) do
            self.properties[key] = value
        end
    end
    function result:clear()
        self.cleared = true
    end
    return result
end
lvgl = {
    box = object,
    rectangle = object,
    image = object,
    label = object,
    show = function(value)
        value.hidden = false
    end,
    hide = function(value)
        value.hidden = true
    end,
}

local function setup(count, resumed, failure, staged)
    local panels, entries = {}, {}
    for index = 1, count do
        local placement = {
            id = "p" .. index,
            type = "metric",
            col = (index - 1) % 4,
            row = math.floor((index - 1) / 4),
            colSpan = 1,
            rowSpan = 1,
        }
        panels[index] = placement
        if index % 2 == 0 then
            entries[#entries + 1] = { placement = placement }
        end
    end
    local context = {
        root = {},
        page = {},
        zone = { w = 480, h = 272 },
        grid = grid,
        path = "/widget/",
        panels = entries,
        theme = {
            color = {
                amber = 1,
                surface = 2,
                text = 3,
                surfaceRaised = 4,
                textMuted = 5,
                border = 6,
            },
        },
        themeBuilder = {
            measureText = function()
                return 12
            end,
            fontHeight = function()
                return 20
            end,
        },
        primitives = {
            panel = function(parent, rect)
                return { root = object(parent, rect) }
            end,
            resizePanel = function(panel, rect)
                panel.root:set(rect)
            end,
        },
        editorDrawerModule = { close = function() end },
    }
    local previews, errors = 0, {}
    local session = staged and assert(editor.new({ panels = panels }, grid, {}, {}, nil, true))
        or { draft = { panels = panels } }
    local state = ui.open(context, session, {
        resumed = resumed,
        editor = editor,
        preview = function(document)
            assert(document == session.draft)
            previews = previews + 1
            return not failure, failure
        end,
        logError = function(operation, message)
            errors[#errors + 1] = { operation, message }
        end,
    })
    return context, state, function()
        return previews, errors
    end
end

for _, count in ipairs({ 0, 1, 16 }) do
    for _, resumed in ipairs({ false, true }) do
        local context, state, calls = setup(count, resumed)
        assert(state.screen.hidden)
        for stage = 1, 15 do
            assert(state.buildStage == stage)
            assert(ui.advance(context))
            assert(state.screen.hidden == (stage < 15), "partial editor must remain hidden")
            if stage >= 10 and stage <= 14 then
                assert(state.initialRenderChanged, "initial placement changes must reach final publication")
            end
        end
        assert(state.buildStage == nil and state.initialRenderChanged == nil)
        assert(state.previewPending == (resumed or nil))
        local previews, errors = calls()
        assert(previews == 1 and #errors == 0)
        for index = 1, 16 do
            local placement = state.session.draft.panels[index]
            local controls, preview = state.controls[index], state.previews[index]
            assert(controls.gearBackground.hidden == (placement == nil))
            if placement then
                local rect = assert(grid.rect(context.zone, placement, 4, 4, 4))
                assert(controls.rect.x == rect.x and controls.rect.y == rect.y)
                assert(controls.gearBackground.properties.x == rect.x + rect.w - 28)
                assert(controls.gearBackground.properties.y == rect.y + 4)
                local existing = index % 2 == 0
                assert(preview.background.hidden == existing and preview.text.hidden == existing)
                if not existing then
                    assert(preview.text.properties.text == "NEW: metric")
                    assert(preview.background.properties.w == rect.w)
                end
            else
                assert(controls.rect == nil and controls.placement == nil)
                assert(preview.background.hidden and preview.text.hidden)
            end
        end
        assert(state.addPanel.root.hidden == (count == 16))
        assert(state.statusLabel.hidden)
    end
end

do
    local context, state, calls = setup(16, false, "bad preview")
    for _ = 1, 15 do
        assert(ui.advance(context))
    end
    local previews, errors = calls()
    assert(previews == 1 and #errors == 1)
    assert(errors[1][1] == "preview geometry" and errors[1][2] == "bad preview")
    assert(state.statusError and not state.statusLabel.hidden)
    assert(state.statusLabel.properties.text == "bad preview")
end

do
    local context, state, calls = setup(16, nil, nil, true)
    local steps = 0
    while state.session.initializing do
        assert(ui.advance(context))
        steps = steps + 1
        assert(steps < 100 and state.buildStage == 1 and state.screen.hidden)
        assert(calls() == 0, "partial session must not enter preview rendering")
    end
    assert(steps > 1 and state.session.draft.panels[16].id == "p16")
    for _ = 1, 15 do
        assert(ui.advance(context))
    end
    assert(state.buildStage == nil and not state.screen.hidden and calls() == 1)
end

do
    local context, state = setup(16, nil, nil, true)
    assert(ui.advance(context) and state.session.initializing)
    ui.close(context, true)
    assert(context.editorUi == nil and state.session.initializing == nil and state.session.cancelled)
end

for stage = 1, 14 do
    local context, state = setup(16)
    for _ = 1, stage do
        assert(ui.advance(context))
    end
    ui.close(context, false)
    assert(context.editorUi == nil and state.screen.hidden and state.screen.cleared)
    assert(not ui.advance(context), "closed partial editor must not resume construction")
end

for target = 1, 6 do
    local context, state, calls = setup(16)
    for _ = 1, 15 do
        assert(ui.advance(context))
    end
    state.session.selected = 1
    EVT_ROT_RIGHT = 9301
    assert(ui.handle(context, EVT_ROT_RIGHT))
    assert(state.renderStage == 1 and calls() == 1, "input queues rendering without synchronizing all slots")
    assert(ui.handle(context, EVT_ROT_RIGHT) and state.session.selected == 3,
        "unfinished painting must not swallow newer input")
    for stage = 1, target do
        assert(state.renderStage == stage)
        assert((ui.renderWorkBound(state) ~= nil) == (stage ~= 1),
            "geometry synchronization must not acquire paint-only eligibility")
        state.exitCommand = { action = "save" }
        assert(ui.renderWorkBound(state) == nil, "higher-priority commands must not use a paint bound")
        state.exitCommand = nil
        assert(ui.advance(context))
        assert(state.renderStage == (stage < 6 and stage + 1 or nil))
    end
    assert(calls() == 2, "one geometry synchronization per requested rendering")
    ui.close(context, false)
    assert(context.editorUi == nil and not ui.advance(context), "closed partial render must not resume")
end

do
    local state = { session = {}, drawerBuild = 1 }
    local context = {
        editorUi = state,
        editorDrawerModule = { workBound = function(candidate)
            assert(candidate == state)
            return 1700
        end },
    }
    assert(ui.drawerWorkBound(context) == 1700)
    for _, key in ipairs({ "previewPending", "previewRefresh", "exitCommand", "renderStage" }) do
        state[key] = true
        assert(ui.drawerWorkBound(context) == nil, "higher-priority work must not borrow a drawer bound")
        state[key] = nil
    end
    state.session.initializing = true
    assert(ui.drawerWorkBound(context) == nil)
    state.session.initializing = nil
    state.drawerBuild = nil
    assert(ui.drawerWorkBound(context) == nil, "ordinary drawer commands have no construction eligibility")
end

do
    local context, state = setup(0)
    for _ = 1, 15 do assert(ui.advance(context)) end
    local opened = 0
    context.editorDrawerModule.open = function(_, actual, mode)
        assert(actual == state and mode == "add")
        opened = opened + 1
    end
    EVT_VIRTUAL_ENTER, EVT_VIRTUAL_EXIT = 9302, 9303
    assert(ui.handle(context, EVT_VIRTUAL_ENTER) and state.drawerOpen.mode == "add")
    assert(opened == 0 and ui.drawerWorkBound(context) == ui.DRAWER_OPEN_BOUNDS.add)
    assert(ui.handle(context, EVT_VIRTUAL_EXIT) and not state.drawerOpen and opened == 0)
    assert(ui.handle(context, EVT_VIRTUAL_ENTER) and ui.advance(context))
    assert(opened == 1 and not state.drawerOpen and state.renderStage == 1)
end

lvgl = previousLvgl
print("editor UI construction: staged geometry/publication, errors, resumed drafts and cancellation passed")
