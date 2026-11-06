-- SPDX-License-Identifier: GPL-2.0-only

local uiModule = { RUNTIME_API = 1 }
uiModule.RENDER_BOUNDS = { rows = 1700, finish = 1400 }
uiModule.INPUT_BOUNDS = {
    open = 220, tap = 900, select = 350, modal = 120, release = 220, cancel = 140, first = 800, slide = 240,
}
uiModule.DRAWER_OPEN_BOUNDS = { configure = 1500, add = 350 }
-- Staged preview geometry: a run of unchanged panels, or one changed panel's
-- update or reflow stage. Unlisted panel types remain unmeasured.
-- Each bound fits the type's worst reflow-stage body plus the constant
-- dispatch overhead; every charge stays within the 4000 atom.
uiModule.LAYOUT_BOUNDS = {
    visit = 1500, chart = 2050, ["flight-counter"] = 4000, ["flight-mode"] = 3450, ["flight-timer"] = 3300,
    ["host-diagnostics"] = 2100, ["link-status"] = 3550, metric = 4000, ["model-identity"] = 3000,
    navigation = 3750, output = 2550, ["rx-battery"] = 2550, ["service-probe"] = 2200, state = 3750,
    ["theme-showcase"] = 2950, ["trim-panel"] = 4000, ["tx-battery"] = 2550,
}
uiModule.DRAG_BOUNDS = { module = 1500, settings = 2300, positions = 1700, rects = 1350, apply = 1250 }

local function label(parent, rect, text, color, font)
    return lvgl.label(parent, {
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = rect.h,
        text = text,
        color = color,
        font = function()
            return font or SMLSIZE
        end,
    })
end

local function visible(object, show)
    if show then
        lvgl.show(object)
    else
        lvgl.hide(object)
    end
end

local function matches(event, name)
    return _G[name] ~= nil and event == _G[name]
end

local function keyMatches(event, name)
    local key = _G[name]
    if type(key) ~= "number" then
        return false
    end
    for _, kind in ipairs({ "EVT_KEY_FIRST", "EVT_KEY_REPT" }) do
        if type(_G[kind]) == "function" and event == _G[kind](key) then
            return true
        end
    end
    return false
end

local function inputReady(state)
    -- A released drag applies its last slide before further input.
    return state and not state.buildStage and not state.saving and not state.previewPending
        and not state.previewRefresh and not state.exitCommand and not state.drawerOpen
        and not (state.drag and state.drag.released)
end

local function blocked(state)
    return state and state.handlers and state.handlers.blocked and state.handlers.blocked()
end

function uiModule.dragPending(state)
    return uiModule.dragStage(state) ~= nil
end

function uiModule.inputWorkBound(context, event)
    local state = context.editorUi
    if blocked(state) then return nil end
    if state and state.drawerOpen then
        return matches(event, "EVT_VIRTUAL_EXIT") and uiModule.INPUT_BOUNDS.cancel or nil
    end
    if not inputReady(state) then return nil end
    if state.mode ~= "menu" then
        return uiModule.INPUT_BOUNDS.modal
    elseif matches(event, "EVT_VIRTUAL_ENTER") then
        return uiModule.INPUT_BOUNDS.open
    elseif matches(event, "EVT_TOUCH_TAP") then
        return uiModule.INPUT_BOUNDS.tap
    elseif matches(event, "EVT_VIRTUAL_PREV") or matches(event, "EVT_VIRTUAL_NEXT")
        or matches(event, "EVT_ROT_LEFT") or matches(event, "EVT_ROT_RIGHT") then
        return uiModule.INPUT_BOUNDS.select
    elseif matches(event, "EVT_TOUCH_BREAK") then
        return uiModule.INPUT_BOUNDS.release
    elseif matches(event, "EVT_TOUCH_FIRST") then
        return uiModule.INPUT_BOUNDS.first
    elseif matches(event, "EVT_TOUCH_SLIDE") then
        return uiModule.INPUT_BOUNDS.slide
    end
end

---@return boolean? changed Nil while staged geometry remains.
local function prepareRender(context, state)
    local handlers = state.handlers
    local previewed, previewError
    if handlers.startLayout then
        state.layoutJob = state.layoutJob or handlers.startLayout(state.session.draft)
        local done
        done, previewError = handlers.advanceLayout(state.layoutJob)
        if not done then
            return nil
        end
        state.layoutJob, previewed = nil, previewError == nil
    else
        previewed, previewError = handlers.preview(state.session.draft)
    end
    local placements = state.session.draft.panels
    local changed = state.panelCount ~= #placements
    state.panelCount = #placements
    if not previewed then
        state.status, state.statusError = tostring(previewError), true
        handlers.logError("preview geometry", previewError)
    end
    return changed
end

local function renderPreviews(context, state, first, last)
    local placements, changed = state.session.draft.panels, false
    for index = first, last do
        local preview = state.previews[index]
        local placement = placements[index]
        local existing = placement and state.existing[placement.id] == placement.type
        visible(preview.background, placement ~= nil and not existing)
        visible(preview.text, placement ~= nil and not existing)
        local controls = state.controls[index]
        visible(controls.gearBackground, placement ~= nil and state.mode == "menu")
        if placement then
            local previous = controls.placement
            if
                not previous
                or previous.id ~= placement.id
                or previous.col ~= placement.col
                or previous.row ~= placement.row
                or previous.colSpan ~= placement.colSpan
                or previous.rowSpan ~= placement.rowSpan
            then
                changed = true
                local rect = assert(context.grid.rect(context.zone, placement, 4, 4, 4))
                controls.rect = rect
                controls.placement = {
                    id = placement.id,
                    col = placement.col,
                    row = placement.row,
                    colSpan = placement.colSpan,
                    rowSpan = placement.rowSpan,
                }
                controls.gearBackground:set({ x = rect.x + rect.w - 28, y = rect.y + 4 })
            end
            if not existing then
                local rect = controls.rect
                preview.background:set(rect)
                preview.text:set({
                    x = rect.x + 4,
                    y = rect.y + 4,
                    w = math.max(1, rect.w - 8),
                    h = rect.h - 8,
                    text = "NEW: " .. string.sub(placement.type, 1, 6),
                })
            end
        else
            controls.placement, controls.rect = nil, nil
        end
    end
    return changed
end

local function renderStatus(state)
    state.statusLabel:set({
        text = state.previewError and state.status == state.previewError and "Panel preview failed; see error details."
            or state.status,
    })
    visible(state.statusLabel, state.statusError == true)
end

local function finishRender(context, state, changed)
    if changed then
        local first = state.handlers.editor.availablePositions(state.session, 1, 1)[1]
        state.addRect = first and assert(context.grid.rect(context.zone, first, 4, 4, 4)) or nil
    end
    visible(state.addPanel.root, state.addRect ~= nil and state.mode == "menu")
    if state.addRect then
        context.primitives.resizePanel(state.addPanel, state.addRect)
        state.addLabel:set({
            x = math.floor((state.addRect.w - state.addSymbolWidth) / 2),
            y = math.floor((state.addRect.h - state.addSymbolHeight) / 2),
        })
    end
    renderStatus(state)
end

local function render(_, state)
    state.renderStage, state.renderChanged, state.layoutJob = 1, nil, nil
    renderStatus(state)
end

local function layoutBound(state)
    local handlers = state.handlers
    if not handlers or not handlers.layoutStep then
        return nil
    end
    local step = state.layoutJob and handlers.layoutStep(state.layoutJob) or "visit"
    return uiModule.LAYOUT_BOUNDS[step]
end

function uiModule.renderWorkBound(state)
    if blocked(state) then return nil end
    if
        state.renderStage
        and (state.renderStage ~= 1 or layoutBound(state))
        and not state.session.initializing
        and not state.previewPending
        and not state.previewRefresh
        and not state.exitCommand
        and not state.drawerOpen
        and not uiModule.dragStage(state)
    then
        if state.renderStage == 1 then
            return layoutBound(state)
        end
        return state.renderStage == 6 and uiModule.RENDER_BOUNDS.finish or uiModule.RENDER_BOUNDS.rows
    end
end

function uiModule.drawerWorkBound(context)
    local state = context.editorUi
    if blocked(state) then return nil end
    if state.drawerOpen and not state.session.initializing and not state.previewPending
        and not state.previewRefresh and not state.exitCommand then
        if state.drawerOpen.groupKey then return nil end
        if state.drawerOpen.mode == "configure" then
            local placement = state.session.draft.panels[state.drawerOpen.selected]
            if not placement or not context.editorDrawerModule.MEASURED_FORMS[placement.type] then return nil end
        end
        return uiModule.DRAWER_OPEN_BOUNDS[state.drawerOpen.mode]
    end
    if
        (state.drawerBuild or state.drawerPending)
        and not state.session.initializing
        and not state.previewPending
        and not state.previewRefresh
        and not state.exitCommand
        and not state.renderStage
        and not uiModule.dragStage(state)
    then
        return context.editorDrawerModule.workBound(state)
    end
end

local function advanceRender(context, state)
    local stage = state.renderStage
    if stage == 1 then
        local changed = prepareRender(context, state)
        if changed == nil then
            return
        end
        state.renderChanged = changed
    elseif stage <= 5 then
        local changed = renderPreviews(context, state, (stage - 2) * 4 + 1, (stage - 1) * 4)
        state.renderChanged = state.renderChanged or changed
    else
        finishRender(context, state, state.renderChanged)
        state.renderStage, state.renderChanged = nil, nil
        return
    end
    state.renderStage = stage + 1
end

local function openDrawer(_, state, mode)
    state.drag = nil
    if not state.drawerOpen then
        state.drawerOpen = { mode = mode, selected = state.session.selected }
    end
end

--- Save the draft to `name`, or to this dashboard's own layout when nil.
local function saveAndClose(context, state, name)
    if state.saving then
        return
    end
    if not state.session.dirty and not name then
        state.handlers.close(false)
        return
    end
    if name == state.handlers.layoutName() then
        name = nil
    end
    context.editorDrawerModule.close(state)
    state.previewPending, state.previewRefresh = nil, nil
    state.mode = "menu"
    state.saveFailed = false
    state.saving = { index = 1, accepted = {}, identifiers = {}, name = name }
    state.status, state.statusError = "", false
    render(context, state)
end

function uiModule.open(context, session, handlers)
    local screen = lvgl.box(context.root, { x = 0, y = 0, w = context.zone.w, h = context.zone.h })
    local state = {
        session = session,
        handlers = handlers,
        screen = screen,
        mode = "menu",
        buildStage = 1,
        cells = {},
        previews = {},
        controls = {},
        existing = {},
        status = "",
        statusLabel = label(
            screen,
            { x = 8, y = context.zone.h - 22, w = context.zone.w - 16, h = 20 },
            "",
            context.theme.color.amber
        ),
    }
    for _, entry in ipairs(context.panels) do
        state.existing[entry.placement.id] = entry.placement.type
    end
    lvgl.hide(screen)
    context.editorUi = state
    return state
end

function uiModule.advance(context)
    local state = context.editorUi
    if not state or blocked(state) then
        return false
    end
    if state.session.initializing then
        state.handlers.editor.advanceInitialization(state.session)
        return true
    end
    if state.previewPending then
        state.previewPending = nil
        state.previewRefresh = state.handlers.startPreview(state.session.draft)
        return true
    end
    if state.previewRefresh then
        local done, previewError = state.handlers.advancePreview(state.previewRefresh)
        if done then
            state.previewRefresh = nil
            state.existing = {}
            for _, entry in ipairs(context.panels) do
                state.existing[entry.placement.id] = entry.placement.type
            end
            if state.previewError and state.status == state.previewError then
                state.status, state.statusError = "", false
            end
            local previousError = state.previewError
            state.previewError = previewError
            if previewError then
                state.status, state.statusError = previewError, true
                state.handlers.logError("preview", previewError)
                if previewError ~= previousError then
                    lvgl.message({
                        title = "Panel preview failed",
                        message = "Check the panel settings.",
                        details = previewError,
                    })
                end
            end
            render(context, state)
        end
        return true
    end
    local command = state.exitCommand
    if command then
        state.exitCommand = nil
        local drawerModule, handlers = context.editorDrawerModule, state.handlers
        if command.action == "save" then
            saveAndClose(context, state)
        elseif command.action == "save-as" then
            drawerModule.openName(context, state, handlers.suggestName())
        elseif command.action == "exit" then
            drawerModule.openExit(context, state)
        elseif command.action == "discard" then
            drawerModule.close(state)
            handlers.editor.cancel(state.session)
            handlers.close(false)
        elseif command.action == "name" then
            local valid, nameError = handlers.validName(command.name)
            if not valid then
                drawerModule.openName(context, state, command.name or "", nameError)
            elseif handlers.exists(command.name) then
                drawerModule.confirmOverwrite(context, state, command.name)
            else
                saveAndClose(context, state, command.name)
            end
        elseif command.action == "write" then
            saveAndClose(context, state, command.name)
        end
        return true
    end
    if state.drawerOpen then
        local pending = state.drawerOpen
        state.drawerOpen = nil
        if pending.mode == "configure" then
            assert(state.handlers.editor.select(state.session, pending.selected))
        end
        context.editorDrawerModule.open(
            context, state, pending.mode, pending.listKey, pending.itemIndex, pending.itemPath, pending.groupKey
        )
        render(context, state)
        return true
    end
    if uiModule.dragStage(state) then
        uiModule.advanceDrag(context, state)
        return true
    end
    if state.renderStage then
        advanceRender(context, state)
        return true
    end
    if state.drawerBuild ~= nil or state.drawerPending then
        context.editorDrawerModule.advance(context, state)
        if state.drawerBuild == nil and not state.drawerPending and not state.drawerOpen then
            render(context, state)
        end
        return true
    end
    if state.saving then
        local saving, editor, session = state.saving, state.handlers.editor, state.session
        local function failed(message)
            state.status, state.saveFailed, state.statusError = tostring(message), true, true
            state.handlers.logError("save", message)
            state.saving = nil
            render(context, state)
        end
        if not saving.store then
            local placement = session.draft.panels[saving.index]
            if placement then
                local valid, panelError = session.layout.validatePanel(
                    placement,
                    saving.index,
                    session.grid,
                    saving.accepted,
                    saving.identifiers
                )
                if not valid then
                    failed(panelError)
                    return true
                end
                local single = {}
                for key, value in pairs(session.draft) do
                    single[key] = value
                end
                single.panels = { placement }
                local checked, errors = editor.validate({
                    draft = single,
                    layout = session.layout,
                    grid = session.grid,
                    panelHost = session.panelHost,
                    loadPanel = session.loadPanel,
                    modelArmed = session.modelArmed,
                })
                if not checked then
                    failed(table.concat(errors, "; "))
                    return true
                end
                saving.accepted[#saving.accepted + 1] = placement
                saving.identifiers[placement.id] = true
                saving.index = saving.index + 1
            else
                saving.store = state.handlers.startSave(session.draft, saving.name)
            end
        else
            local done, saved, saveError = state.handlers.advanceSave(saving.store)
            if done then
                state.saving = nil
                if saved and saving.name then
                    -- Lua cannot change widget options, so this dashboard keeps
                    -- its own layout; the new name is listed after a restart.
                    state.handlers.close(false)
                    if type(lvgl.message) == "function" then
                        lvgl.message({
                            title = "Saved as " .. saving.name,
                            message = "Restart the radio, then select "
                                .. saving.name
                                .. " in the widget's Layout setting.",
                        })
                    end
                elseif saved then
                    state.handlers.close(true)
                else
                    failed(saveError)
                end
            end
        end
        return true
    end
    local stage = state.buildStage
    if not stage then
        return false
    end
    if stage <= 4 then
        for index = (stage - 1) * 4 + 1, stage * 4 do
            local col, row = (index - 1) % 4, math.floor((index - 1) / 4)
            state.cells[index] = {
                col = col,
                row = row,
                rect = assert(
                    context.grid.rect(context.zone, { col = col, row = row, colSpan = 1, rowSpan = 1 }, 4, 4, 4)
                ),
            }
        end
    elseif stage <= 8 then
        for index = (stage - 5) * 4 + 1, (stage - 4) * 4 do
            state.previews[index] = {
                background = lvgl.rectangle(state.screen, {
                    x = 0,
                    y = 0,
                    w = 1,
                    h = 1,
                    color = context.theme.color.surface,
                    filled = true,
                }),
                text = label(state.screen, { x = 0, y = 0, w = 1, h = 1 }, "", context.theme.color.text),
            }
            local iconName = context.theme.light and "editor-configure-light.png" or "editor-configure.png"
            local filename = context.path .. "assets/" .. iconName
            if type(fstat) == "function" and not fstat(filename) then
                error("editor icon missing: " .. filename)
            end
            local gearBackground = lvgl.rectangle(state.screen, {
                x = 0,
                y = 0,
                w = 24,
                h = 24,
                color = context.theme.color.surfaceRaised,
                rounded = 12,
                filled = true,
            })
            state.controls[index] = {
                gearBackground = gearBackground,
                gear = lvgl.image(gearBackground, { x = 0, y = 0, w = 24, h = 24, file = filename, fill = false }),
            }
        end
    elseif stage == 9 then
        state.addPanel = context.primitives.panel(
            state.screen,
            { x = 0, y = 0, w = 115, h = 63 },
            context.theme,
            { accent = context.theme.color.textMuted, border = context.theme.color.border, borderWidth = 0 }
        )
        state.addSymbolWidth = context.themeBuilder.measureText(MIDSIZE, "+")
        state.addSymbolHeight = context.themeBuilder.fontHeight(MIDSIZE)
        state.addLabel = label(
            state.addPanel.root,
            { x = 0, y = 0, w = state.addSymbolWidth, h = state.addSymbolHeight },
            "+",
            context.theme.color.textMuted,
            MIDSIZE
        )
    elseif stage == 10 then
        state.initialRenderChanged = prepareRender(context, state)
    elseif stage <= 14 then
        local changed = renderPreviews(context, state, (stage - 11) * 4 + 1, (stage - 10) * 4)
        state.initialRenderChanged = state.initialRenderChanged or changed
    else
        finishRender(context, state, state.initialRenderChanged)
        state.initialRenderChanged = nil
        state.buildStage = nil
        lvgl.show(state.screen)
        -- A resumed draft differs from the committed dashboard just rebuilt.
        state.previewPending = state.handlers.resumed or nil
        return true
    end
    state.buildStage = stage + 1
    return true
end

function uiModule.close(context, discard)
    local state = context.editorUi
    if not state then
        return
    end
    context.editorDrawerModule.close(state)
    if discard then
        state.handlers.editor.cancel(state.session)
    end
    state.screen:clear()
    lvgl.hide(state.screen)
    lvgl.show(context.page)
    context.editorUi = nil
end

function uiModule.saveFailure(context, message)
    local state = context.editorUi
    state.saving = nil
    state.saveFailed, state.statusError = true, true
    state.status = "Cannot save layout: " .. tostring(message)
    state.handlers.logError("save", message)
    state.statusLabel:set({ text = state.status })
    lvgl.show(state.statusLabel)
end

local function hit(rect, x, y)
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h
end

local function coordinates(context, touch)
    if type(touch) ~= "table" or type(touch.x) ~= "number" or type(touch.y) ~= "number" then
        return
    end
    local x, y = touch.x, touch.y
    local left, top = context.left or 0, context.top or 0
    if x >= left and x < left + context.zone.w and y >= top and y < top + context.zone.h then
        x, y = x - left, y - top
    end
    return x, y
end

local function applySlide(context, state, drag, x, y)
    local nearest, distance
    for index, position in ipairs(drag.positions) do
        local rect = drag.rects[index]
        local edgeX = drag.resize and not drag.left and rect.x + rect.w or rect.x
        local edgeY = drag.resize and not drag.top and rect.y + rect.h or rect.y
        local dx, dy = x - drag.offsetX - edgeX, y - drag.offsetY - edgeY
        local candidate = dx * dx + dy * dy
        if not distance or candidate < distance then
            nearest, distance = position, candidate
        end
    end
    if nearest then
        local p = state.session.draft.panels[state.session.selected]
        local moved, err
        if drag.resize then
            moved, err = state.handlers.editor.applyResize(state.session, nearest)
        else
            moved, err = state.handlers.editor.move(state.session, nearest.col - p.col, nearest.row - p.row)
        end
        if not moved then
            state.status, state.statusError = tostring(err), true
            state.handlers.logError(drag.resize and "resize" or "move", err)
        end
        render(context, state)
    end
end

--- The pending drag stage: target enumeration, cached geometry, or applying
--- the latest slide.
function uiModule.dragStage(state)
    local drag = state and state.drag
    if not drag then
        return nil
    elseif drag.job then
        return drag.job.phase
    elseif not drag.positions then
        return nil
    elseif #drag.rects < #drag.positions then
        return "rects"
    elseif drag.x then
        return "apply"
    end
end

function uiModule.dragWorkBound(context)
    local state = context.editorUi
    if blocked(state) or not state or state.session.initializing or state.previewPending
        or state.previewRefresh or state.exitCommand or state.drawerOpen then
        return nil
    end
    local stage = uiModule.dragStage(state)
    if not stage then
        return nil
    end
    -- Resize enumeration runs panel-specific settings validation.
    if state.drag.resize and (stage == "module" or stage == "settings" or stage == "positions") then
        local placement = state.session.draft.panels[state.session.selected]
        if not placement or not context.editorDrawerModule.MEASURED_FORMS[placement.type] then
            return nil
        end
    end
    return uiModule.DRAG_BOUNDS[stage]
end

function uiModule.advanceDrag(context, state)
    local drag, session = state.drag, state.session
    if session.draft ~= drag.draft or #session.draft.panels ~= drag.count or session.selected ~= drag.selected then
        state.drag = nil
        return
    end
    if drag.job then
        local positions, err = state.handlers.editor.advancePositions(session, drag.job, drag.resize and 1 or 2)
        if positions == false then
            state.drag = nil
            state.status, state.statusError = tostring(err), true
            state.handlers.logError(drag.resize and "resize" or "move", err)
            render(context, state)
        elseif positions then
            drag.job, drag.positions = nil, positions
        end
        return
    end
    if #drag.rects < #drag.positions then
        for _ = 1, 4 do
            local position = drag.positions[#drag.rects + 1]
            if not position then
                break
            end
            drag.rects[#drag.rects + 1] = assert(context.grid.rect(context.zone, position, 4, 4, 4))
        end
        return
    end
    local x, y = drag.x, drag.y
    drag.x, drag.y = nil, nil
    if drag.released then
        state.drag = nil
    end
    applySlide(context, state, drag, x, y)
end

local function drag(context, state, event, touch)
    if matches(event, "EVT_TOUCH_BREAK") then
        -- A slide that arrived before targets were ready still applies.
        if state.drag and state.drag.x then
            state.drag.released = true
        else
            state.drag = nil
        end
        return true
    end
    local x, y = coordinates(context, touch)
    if not x then
        return false
    end
    if matches(event, "EVT_TOUCH_FIRST") then
        for index, controls in ipairs(state.controls) do
            local rect = index <= #state.session.draft.panels and controls.rect
            if rect and hit(rect, x, y) then
                if y < rect.y + 32 and x >= rect.x + rect.w - 32 then
                    return false
                end
                state.handlers.editor.select(state.session, index)
                state.keyAdd = false
                local cornerWidth, cornerHeight = math.min(24, rect.w / 3), math.min(24, rect.h / 3)
                local left, right = x < rect.x + cornerWidth, x >= rect.x + rect.w - cornerWidth
                local top, bottom = y < rect.y + cornerHeight, y >= rect.y + rect.h - cornerHeight
                local resize = (left or right) and (top or bottom)
                local job = assert(state.handlers.editor.startPositions(state.session, resize, left, top))
                state.drag = {
                    resize = resize,
                    left = resize and left or nil,
                    top = resize and top or nil,
                    offsetX = x - ((resize and not left) and rect.x + rect.w or rect.x),
                    offsetY = y - ((resize and not top) and rect.y + rect.h or rect.y),
                    job = job,
                    positions = {},
                    rects = {},
                    draft = state.session.draft,
                    count = #state.session.draft.panels,
                    selected = state.session.selected,
                }
                return true
            end
        end
    elseif matches(event, "EVT_TOUCH_SLIDE") and state.drag and not state.drag.released then
        state.drag.x, state.drag.y = x, y
        return true
    end
    return false
end

function uiModule.handle(context, event, touch)
    local state = context.editorUi
    if blocked(state) then return false end
    if state and state.drawerOpen and matches(event, "EVT_VIRTUAL_EXIT") then
        state.drawerPending = state.drawerOpen.cancel
        state.drawerOpen = nil
        return true
    end
    if not inputReady(state) then
        return false
    end
    -- Modal input, including picker/keyboard RTN, belongs to native LVGL.
    if state.mode ~= "menu" then
        return true
    end
    if drag(context, state, event, touch) then
        return true
    end
    if matches(event, "EVT_TOUCH_TAP") then
        local x, y = coordinates(context, touch)
        if not x then
            return false
        end
        for index, controls in ipairs(state.controls) do
            local rect = index <= #state.session.draft.panels and controls.rect
            if rect and hit({ x = rect.x + rect.w - 32, y = rect.y, w = 32, h = 32 }, x, y) then
                state.handlers.editor.select(state.session, index)
                openDrawer(context, state, "configure")
                return true
            end
        end
        if state.addRect and hit(state.addRect, x, y) then
            openDrawer(context, state, "add")
            return true
        end
    elseif matches(event, "EVT_VIRTUAL_EXIT") then
        if state.session.dirty then
            context.editorDrawerModule.openExit(context, state)
        else
            state.handlers.close(false)
        end
        return true
    elseif matches(event, "EVT_VIRTUAL_ENTER") then
        openDrawer(context, state, (state.keyAdd or #state.session.draft.panels == 0) and "add" or "configure")
        return true
    else
        local previous = matches(event, "EVT_VIRTUAL_PREV")
            or matches(event, "EVT_ROT_LEFT")
            or keyMatches(event, "KEY_LEFT")
        local nextPanel = matches(event, "EVT_VIRTUAL_NEXT")
            or matches(event, "EVT_ROT_RIGHT")
            or keyMatches(event, "KEY_RIGHT")
        if previous or nextPanel then
            local count = #state.session.draft.panels
            local total = count + (state.addRect and 1 or 0)
            if total > 0 then
                local index = state.keyAdd and count + 1 or state.session.selected
                index = ((index - 1 + (previous and -1 or 1)) % total) + 1
                state.keyAdd = index > count
                if not state.keyAdd then
                    state.handlers.editor.select(state.session, index)
                end
                state.status = state.keyAdd and "Add panel: ENTER"
                    or (state.session.draft.panels[index].id .. ": ENTER for settings")
                state.statusError = true
                render(context, state)
            end
            return true
        end
    end
    return false
end

return uiModule
