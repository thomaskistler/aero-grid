-- SPDX-License-Identifier: GPL-2.0-only

local uiModule = { RUNTIME_API = 1 }

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

local function render(context, state)
    local placements = state.session.draft.panels
    local changed = state.panelCount ~= #placements
    state.panelCount = #placements
    local previewed, previewError = state.handlers.preview(state.session.draft)
    if not previewed then
        state.status, state.statusError = tostring(previewError), true
    end
    for index, preview in ipairs(state.previews) do
        local placement = placements[index]
        local existing = placement and state.existing[placement.id] == placement.type
        visible(preview.background, placement ~= nil and not existing)
        visible(preview.text, placement ~= nil and not existing)
        local controls = state.controls[index]
        visible(controls.gear, placement ~= nil and state.mode == "menu")
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
                controls.gear:set({ x = rect.x + rect.w - 28, y = rect.y + 4 })
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
    state.statusLabel:set({ text = state.status })
    visible(state.statusLabel, state.statusError == true)
end

local function openDrawer(context, state, mode)
    state.drag = nil
    context.editorDrawerModule.open(context, state, mode)
    render(context, state)
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
    if not state then
        return false
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
            state.previewError = previewError
            if previewError then
                state.status, state.statusError = previewError, true
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
    if state.drawerBuild ~= nil or state.drawerPending then
        context.editorDrawerModule.advance(context, state)
        if state.drawerBuild == nil then
            render(context, state)
        end
        return true
    end
    if state.saving then
        local saving, editor, session = state.saving, state.handlers.editor, state.session
        local function failed(message)
            state.status, state.saveFailed, state.statusError = tostring(message), true, true
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
            local filename = context.path .. "assets/editor-configure.png"
            if type(fstat) == "function" and not fstat(filename) then
                error("editor icon missing: " .. filename)
            end
            state.controls[index] = {
                gear = lvgl.image(state.screen, { x = 0, y = 0, w = 24, h = 24, file = filename, fill = false }),
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
    else
        render(context, state)
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

local function drag(context, state, event, touch)
    if matches(event, "EVT_TOUCH_BREAK") then
        state.drag = nil
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
                if (left or right) and (top or bottom) then
                    local positions, err = state.handlers.editor.resizePositions(state.session, left, top)
                    if not positions then
                        state.status, state.statusError = tostring(err), true
                        render(context, state)
                        return true
                    end
                    state.drag = {
                        resize = true,
                        left = left,
                        top = top,
                        offsetX = x - (left and rect.x or rect.x + rect.w),
                        offsetY = y - (top and rect.y or rect.y + rect.h),
                        positions = positions,
                    }
                    return true
                end
                state.drag = {
                    offsetX = x - rect.x,
                    offsetY = y - rect.y,
                    positions = assert(state.handlers.editor.movePositions(state.session)),
                }
                return true
            end
        end
    elseif matches(event, "EVT_TOUCH_SLIDE") and state.drag then
        local nearest, distance
        for _, position in ipairs(state.drag.positions) do
            local rect = assert(context.grid.rect(context.zone, position, 4, 4, 4))
            local edgeX = state.drag.resize and not state.drag.left and rect.x + rect.w or rect.x
            local edgeY = state.drag.resize and not state.drag.top and rect.y + rect.h or rect.y
            local dx, dy = x - state.drag.offsetX - edgeX, y - state.drag.offsetY - edgeY
            local candidate = dx * dx + dy * dy
            if not distance or candidate < distance then
                nearest, distance = position, candidate
            end
        end
        if nearest then
            local p = state.session.draft.panels[state.session.selected]
            local moved, err
            if state.drag.resize then
                moved, err = state.handlers.editor.resize(
                    state.session,
                    nearest.colSpan - p.colSpan,
                    nearest.rowSpan - p.rowSpan,
                    nearest.col,
                    nearest.row
                )
            else
                moved, err = state.handlers.editor.move(state.session, nearest.col - p.col, nearest.row - p.row)
            end
            if not moved then
                state.status, state.statusError = tostring(err), true
            end
            render(context, state)
        end
        return true
    end
    return false
end

function uiModule.handle(context, event, touch)
    local state = context.editorUi
    if
        not state
        or state.buildStage
        or state.saving
        or state.previewPending
        or state.previewRefresh
        or state.exitCommand
    then
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
