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

local function setup(count, resumed, failure)
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
    local session = { draft = { panels = panels } }
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

for stage = 1, 14 do
    local context, state = setup(16)
    for _ = 1, stage do
        assert(ui.advance(context))
    end
    ui.close(context, false)
    assert(context.editorUi == nil and state.screen.hidden and state.screen.cleared)
    assert(not ui.advance(context), "closed partial editor must not resume construction")
end

lvgl = previousLvgl
print("editor UI construction: staged geometry/publication, errors, resumed drafts and cancellation passed")
