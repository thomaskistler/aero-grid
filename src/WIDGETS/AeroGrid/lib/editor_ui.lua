-- SPDX-License-Identifier: GPL-2.0-only

--- Small custom-screen editor controls built from the radio's LVGL primitives.

local uiModule = { RUNTIME_API = 1 }

local ACTIONS = {
    { id = "previous", text = "Panel -" },
    { id = "next", text = "Panel +" },
    { id = "add", text = "Add panel" },
    { id = "move", text = "Move" },
    { id = "resize", text = "Resize" },
    { id = "configure", text = "Configure" },
    { id = "remove", text = "Remove" },
    { id = "defaults", text = "Defaults" },
    { id = "apply", text = "Apply / Save" },
    { id = "cancel", text = "Cancel" },
}

local CHARACTERS = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-."

local function color(context, name, fallback)
    local colors = context.theme and context.theme.color
    return colors and colors[name] or lcd.RGB(fallback)
end

local function label(parent, rect, text, textColor, font)
    return lvgl.label(parent, {
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = rect.h,
        text = text,
        color = textColor,
        font = function()
            return font or SMLSIZE
        end,
    })
end

local function rectangle(parent, rect, fill)
    return lvgl.rectangle(parent, {
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = rect.h,
        color = fill,
        filled = true,
    })
end

local function setText(object, text)
    object:set({ text = text })
end

local function setVisible(object, visible)
    local changeVisibility = visible and lvgl.show or lvgl.hide
    changeVisibility(object)
end

local function eventMatches(event, name)
    local expected = _G[name]
    return expected ~= nil and event == expected
end

local function keyMatches(event, keyName)
    local key = _G[keyName]
    local first = _G.EVT_KEY_FIRST
    local repeatEvent = _G.EVT_KEY_REPT
    if type(key) ~= "number" then
        return false
    end
    if type(first) == "function" then
        local ok, code = pcall(first, key)
        if ok and event == code then
            return true
        end
    end
    if type(repeatEvent) == "function" then
        local ok, code = pcall(repeatEvent, key)
        if ok and event == code then
            return true
        end
    end
    return false
end

local function isTap(event, touchState)
    return type(touchState) == "table" and eventMatches(event, "EVT_TOUCH_TAP")
end

local function layoutGeometry(context)
    local width, height = context.zone.w, context.zone.h
    local rightX = math.floor(width * 0.4)
    local rowHeight = 22
    local actionsY = 34
    local fieldHeight = math.max(16, math.min(22, math.floor((height - 92) / 9)))
    return {
        width = width,
        height = height,
        cell = width / 4,
        gridX = 0,
        gridY = 0,
        rightX = rightX,
        rightWidth = math.max(24, width - rightX - 8),
        actionsY = actionsY,
        rowHeight = rowHeight,
        fieldHeight = fieldHeight,
        statusY = height - 68,
    }
end

local function addCellObjects(state, context, first, last)
    for index = first, last do
        local col, row = (index - 1) % 4, math.floor((index - 1) / 4)
        local rect = assert(context.grid.rect(context.zone, {
            col = col,
            row = row,
            colSpan = 1,
            rowSpan = 1,
        }, 4, 4, 4))
        local background = lvgl.rectangle(state.screen, {
            x = rect.x,
            y = rect.y,
            w = rect.w,
            h = rect.h,
            color = color(context, "cyan", 0x70D6F3),
            filled = false,
            thickness = 1,
        })
        state.cells[index] = { background = background, rect = rect, col = col, row = row }
    end
end

local function addMainActions(state, context, first, last)
    for index = first, last do
        local action = ACTIONS[index]
        local rect = {
            x = 4 + ((index - 1) % 5) * math.floor((state.geometry.width - 8) / 5),
            y = state.geometry.height - 44 + math.floor((index - 1) / 5) * state.geometry.rowHeight,
            w = math.floor((state.geometry.width - 8) / 5) - 2,
            h = state.geometry.rowHeight - 2,
        }
        local background = rectangle(state.screen, rect, color(context, "surface", 0x212830))
        local text = label(state.screen, rect, action.text, color(context, "text", 0xF4F6F7))
        state.actions[index] =
            { id = action.id, background = background, text = text, rect = rect, title = action.text }
    end
end

local function addFieldRows(state, context, first, last)
    for index = first, last do
        local rect = {
            x = state.geometry.rightX,
            y = state.geometry.actionsY + (index - 1) * state.geometry.fieldHeight,
            w = state.geometry.rightWidth,
            h = state.geometry.fieldHeight - 2,
        }
        local background =
            rectangle(state.screen, rect, color(context, "surface", 0x212830), color(context, "border", 0x3A434B))
        local text = label(state.screen, rect, "", color(context, "text", 0xF4F6F7))
        state.fieldRows[index] = { background = background, text = text, rect = rect }
    end
end

local function createScreen(context, session, handlers)
    local geometry = layoutGeometry(context)
    local screen = lvgl.box(context.root, { x = 0, y = 0, w = geometry.width, h = geometry.height })
    local state = {
        session = session,
        handlers = handlers,
        screen = screen,
        geometry = geometry,
        mode = "menu",
        actionIndex = 1,
        catalogIndex = 1,
        fieldIndex = 1,
        buildStage = 1,
        cells = {},
        previews = {},
        actions = {},
        fieldRows = {},
        catalogRows = {},
        existing = {},
        status = "Select a panel, then edit its layout.",
        title = label(
            screen,
            { x = 8, y = 5, w = geometry.width - 16, h = 25 },
            "EDIT DASHBOARD",
            color(context, "text", 0xF4F6F7),
            SMLSIZE
        ),
        details = label(
            screen,
            { x = 8, y = 27, w = geometry.rightX - 16, h = 26 },
            "",
            color(context, "textMuted", 0xA7B0B6)
        ),
        statusLabel = label(
            screen,
            { x = 8, y = geometry.statusY, w = geometry.width - 16, h = 20 },
            "",
            color(context, "amber", 0xF2B84B)
        ),
    }
    for _, entry in ipairs(context.panels) do
        state.existing[entry.placement.id] = entry.placement.type
    end
    lvgl.hide(screen)
    return state
end

local function addControls(state, context)
    local geometry, screen = state.geometry, state.screen
    state.selection = lvgl.rectangle(screen, {
        x = 0,
        y = 0,
        w = 1,
        h = 1,
        color = color(context, "cyan", 0x70D6F3),
        filled = false,
        thickness = 3,
    })
    state.drawer = rectangle(screen, {
        x = geometry.rightX - 4,
        y = 30,
        w = geometry.rightWidth + 8,
        h = geometry.height - 98,
    }, color(context, "canvas", 0x0A0C0E))
    state.back = {
        background = rectangle(
            screen,
            { x = 4, y = geometry.height - 22, w = geometry.width - 8, h = 20 },
            color(context, "surface", 0x212830)
        ),
        text = label(
            screen,
            { x = 8, y = geometry.height - 22, w = geometry.width - 16, h = 20 },
            "Back to dashboard",
            color(context, "text", 0xF4F6F7)
        ),
    }
    state.navigation = {}
    for index, title in ipairs({ "Previous", "Next", "-", "+", "Delete" }) do
        local rect = {
            x = 4 + (index - 1) * math.floor((geometry.width - 8) / 5),
            y = geometry.height - 44,
            w = math.floor((geometry.width - 8) / 5) - 2,
            h = 20,
        }
        state.navigation[index] = {
            rect = rect,
            background = rectangle(screen, rect, color(context, "surface", 0x212830)),
            text = label(screen, rect, title, color(context, "text", 0xF4F6F7)),
        }
    end
end

local function addCatalogRows(state, context, first, last)
    local geometry, screen = state.geometry, state.screen
    for index = first, last do
        local rect = {
            x = geometry.rightX,
            y = geometry.actionsY + (index - 1) * geometry.fieldHeight,
            w = geometry.rightWidth,
            h = geometry.fieldHeight - 2,
        }
        local background = rectangle(screen, rect, color(context, "surface", 0x212830))
        local text = label(screen, rect, "", color(context, "text", 0xF4F6F7))
        state.catalogRows[index] = { background = background, text = text, rect = rect }
    end
end

local function panelLabel(placement)
    local typeName = placement.type or "?"
    local short = string.gsub(typeName, "%-([%a])", function(letter)
        return string.upper(letter)
    end)
    return string.sub(short, 1, 6)
end

local function valueText(value)
    if value == nil then
        return "(unset)"
    end
    if type(value) == "boolean" then
        return value and "On" or "Off"
    end
    if type(value) == "table" then
        return tostring(#value) .. " entries"
    end
    return tostring(value)
end

local function colorRow(context, row, selected)
    row.background:set({
        color = selected and color(context, "surfaceRaised", 0x2E3841) or color(context, "surface", 0x212830),
    })
end

local function renderCells(context, state)
    local placements = state.session.draft.panels
    local previewed, previewError = state.handlers.preview(state.session.draft)
    if not previewed then
        state.status = tostring(previewError)
    end
    for _, cell in ipairs(state.cells) do
        setVisible(cell.background, state.mode == "move" or state.mode == "resize")
    end
    for index, preview in ipairs(state.previews) do
        local placement = placements[index]
        local existing = placement and state.existing[placement.id] == placement.type
        setVisible(preview.background, placement ~= nil and not existing)
        setVisible(preview.text, placement ~= nil and not existing)
        if placement and not existing then
            local rect = assert(context.grid.rect(context.zone, placement, 4, 4, 4))
            preview.background:set(rect)
            preview.text:set({
                x = rect.x + 4,
                y = rect.y + 4,
                w = math.max(1, rect.w - 8),
                h = rect.h - 8,
                text = "NEW: " .. panelLabel(placement),
            })
        end
    end

    local placement = placements[state.session.selected]
    setVisible(state.selection, placement ~= nil)
    if placement then
        state.selection:set(assert(context.grid.rect(context.zone, placement, 4, 4, 4)))
        setText(
            state.details,
            string.format(
                "%s  %d,%d  %dx%d",
                placement.id,
                placement.col + 1,
                placement.row + 1,
                placement.colSpan,
                placement.rowSpan
            )
        )
    else
        setText(state.details, "No panels yet")
    end
end

local function showRows(rows, visible)
    for index, row in ipairs(rows) do
        local shown = index <= visible
        setVisible(row.background, shown)
        setVisible(row.text, shown)
    end
end

local function renderFields(context, state)
    local fields, fieldError = state.handlers.editor.formFields(state.session)
    state.fields = fields or {}
    if not fields then
        state.status = tostring(fieldError)
    end
    local visible = math.min(
        #state.fieldRows,
        math.floor((state.geometry.statusY - state.geometry.actionsY) / state.geometry.fieldHeight)
    )
    state.visibleFieldRows = visible
    local first = math.max(1, math.min(state.fieldIndex - visible + 1, #state.fields - visible + 1))
    first = math.max(1, first)
    state.fieldOffset = first
    showRows(state.fieldRows, visible)
    for visibleIndex = 1, #state.fieldRows do
        local row = state.fieldRows[visibleIndex]
        local field = state.fields[first + visibleIndex - 1]
        if visibleIndex <= visible and field then
            colorRow(context, row, first + visibleIndex - 1 == state.fieldIndex)
            local title = field.label
            if field.type == "table-list" then
                title = title .. "  " .. valueText(field.value)
            else
                local value = field
                if state.mode == "string" and first + visibleIndex - 1 == state.fieldIndex then
                    local position = state.stringPosition
                    value = {
                        value = string.sub(state.stringBuffer, 1, position - 1) .. "[" .. (string.sub(
                            state.stringBuffer,
                            position,
                            position
                        ) ~= "" and string.sub(state.stringBuffer, position, position) or " ") .. "]" .. string.sub(
                            state.stringBuffer,
                            position + 1
                        ),
                    }
                end
                title = title .. ": " .. valueText(value.value)
            end
            setText(row.text, title)
        else
            setVisible(row.background, false)
            setVisible(row.text, false)
        end
    end
end

local function renderCatalog(context, state)
    local catalog = state.handlers.editor.CATALOG
    local visible = math.min(
        #state.catalogRows,
        math.floor((state.geometry.statusY - state.geometry.actionsY) / state.geometry.fieldHeight)
    )
    state.visibleCatalogRows = visible
    local first = math.max(1, math.min(state.catalogIndex - visible + 1, #catalog - visible + 1))
    first = math.max(1, first)
    state.catalogOffset = first
    showRows(state.catalogRows, visible)
    for visibleIndex = 1, #state.catalogRows do
        local row = state.catalogRows[visibleIndex]
        local item = catalog[first + visibleIndex - 1]
        if visibleIndex <= visible and item then
            colorRow(context, row, first + visibleIndex - 1 == state.catalogIndex)
            setText(row.text, item.label)
        else
            setVisible(row.background, false)
            setVisible(row.text, false)
        end
    end
end

local function render(context, state)
    renderCells(context, state)
    local drawer = state.mode == "add" or state.mode == "configure" or state.mode == "string"
    setVisible(state.drawer, drawer)
    setVisible(state.back.background, drawer)
    setVisible(state.back.text, drawer)
    setText(state.back.text, state.mode == "string" and "Accept text" or "Back to dashboard")
    for index, row in ipairs(state.navigation) do
        local visible = drawer and (index < 5 or state.mode == "string")
        setVisible(row.background, visible)
        setVisible(row.text, visible)
    end
    showRows(state.fieldRows, 0)
    showRows(state.catalogRows, 0)
    if state.mode == "menu" or state.mode == "move" or state.mode == "resize" then
        showRows(state.fieldRows, 0)
        showRows(state.catalogRows, 0)
        for index, row in ipairs(state.actions) do
            setVisible(row.background, true)
            setVisible(row.text, true)
            colorRow(context, row, index == state.actionIndex and state.mode == "menu")
            setText(row.text, row.title)
        end
        setText(
            state.title,
            state.mode == "menu" and "EDIT DASHBOARD"
                or (state.mode == "move" and "MOVE SELECTED PANEL" or "RESIZE FROM TOP-LEFT")
        )
    elseif state.mode == "add" then
        for _, row in ipairs(state.actions) do
            setVisible(row.background, false)
            setVisible(row.text, false)
        end
        renderCatalog(context, state)
        setText(state.title, "ADD PANEL")
    else
        for _, row in ipairs(state.actions) do
            setVisible(row.background, false)
            setVisible(row.text, false)
        end
        if state.mode == "configure" then
            renderFields(context, state)
            setText(state.title, "CONFIGURE PANEL  (LEFT/RIGHT EDIT)")
        elseif state.mode == "string" then
            renderFields(context, state)
            setText(state.title, "EDIT TEXT  (ENTER ACCEPTS, EXIT CANCELS)")
        end
    end
    setText(state.statusLabel, state.status)
end

local function setSelectedAction(context, state, index)
    state.actionIndex = ((index - 1) % #ACTIONS) + 1
    render(context, state)
end

local function setFieldSelection(context, state, index)
    state.fieldIndex = math.max(1, math.min(index, #(state.fields or {})))
    render(context, state)
end

local function updateFieldValue(context, state, field, direction)
    local editor = state.handlers.editor
    local function write(value)
        if field.path then
            return editor.setPath(state.session, field.key, field.path, value)
        end
        return editor.setValue(state.session, field.key, value)
    end
    if field.type == "boolean" then
        return write(not field.value)
    end
    if field.type == "table-list" then
        if direction > 0 then
            return editor.appendItem(state.session, field.key)
        end
        local _, config = editor.settings(state.session)
        local values = config and config[field.key]
        return editor.removeItem(state.session, field.key, type(values) == "table" and #values or 0)
    end
    if field.choices then
        local index = 1
        for position, choice in ipairs(field.choices) do
            if choice == field.value then
                index = position
                break
            end
        end
        index = ((index - 1 + direction) % #field.choices) + 1
        return write(field.choices[index])
    end
    if field.type == "number" then
        local value = field.value
        if type(value) ~= "number" then
            value = field.min or 0
        end
        local step = field.step or 1
        local updated = value + direction * step
        if type(field.min) == "number" then
            updated = math.max(field.min, updated)
        end
        if type(field.max) == "number" then
            updated = math.min(field.max, updated)
        end
        return write(updated)
    end
    if field.type == "string" and field.path then
        return false, "Press ENTER to edit text"
    end
    if field.type == "string" then
        return false, "Press ENTER to edit text"
    end
    return false, "This setting cannot be changed here"
end

local function applyStringCharacter(state, direction)
    local charIndex = state.stringCharIndex
    charIndex = ((charIndex - 1 + direction) % #CHARACTERS) + 1
    state.stringCharIndex = charIndex
    local character = string.sub(CHARACTERS, charIndex, charIndex)
    if state.stringPosition > #state.stringBuffer then
        state.stringBuffer = state.stringBuffer .. character
    else
        state.stringBuffer = string.sub(state.stringBuffer, 1, state.stringPosition - 1)
            .. character
            .. string.sub(state.stringBuffer, state.stringPosition + 1)
    end
end

local function startStringEdit(state, field)
    state.mode = "string"
    state.stringField = field
    state.stringBuffer = tostring(field.value or "")
    state.stringPosition = 1
    local current = string.sub(state.stringBuffer, state.stringPosition, state.stringPosition)
    state.stringCharIndex = math.max(1, string.find(CHARACTERS, current, 1, true) or 1)
    state.status = "Keys: PREV/NEXT change character; LEFT/RIGHT move."
end

local function finishStringEdit(context, state, accept)
    local field = state.stringField
    if accept and field then
        local ok, err
        if field.path then
            ok, err = state.handlers.editor.setPath(state.session, field.key, field.path, state.stringBuffer)
        else
            ok, err = state.handlers.editor.setValue(state.session, field.key, state.stringBuffer)
        end
        if not ok then
            state.status = tostring(err)
        else
            state.status = "Text updated in the working copy."
        end
    else
        state.status = "Text edit cancelled."
    end
    state.mode = "configure"
    state.stringField = nil
    render(context, state)
end

local function saveAndClose(context, state)
    local valid, documentOrErrors = state.handlers.editor.validate(state.session)
    if not valid then
        state.status = table.concat(documentOrErrors, "; ")
        return render(context, state)
    end
    local saved, saveError = state.handlers.save(documentOrErrors)
    if not saved then
        state.status = tostring(saveError)
        return render(context, state)
    end
    state.handlers.editor.apply(state.session)
    state.status = "Layout saved."
    state.handlers.close(true)
end

local function activateAction(context, state, action)
    local editor = state.handlers.editor
    local success, result
    if action == "previous" or action == "next" then
        local delta = action == "previous" and -1 or 1
        local selected = state.session.selected + delta
        success, result = editor.select(state.session, selected)
        if not success then
            state.status = tostring(result)
        end
    elseif action == "add" then
        state.mode = "add"
        state.catalogIndex = 1
        state.status = "Choose a panel type."
    elseif action == "move" then
        state.mode = "move"
        state.status = "Move with arrows or tap a destination cell."
    elseif action == "resize" then
        state.mode = "resize"
        state.status = "Top-left fixed; grow right/down or shrink left/up."
    elseif action == "configure" then
        state.mode = "configure"
        state.fieldIndex = 1
        state.status = "Select a value; LEFT/RIGHT changes it."
    elseif action == "remove" then
        success, result = editor.remove(state.session)
        state.status = success and "Panel removed from the working copy." or tostring(result)
    elseif action == "defaults" then
        local default, defaultError = state.handlers.loadDefault()
        if not default then
            state.status = table.concat(defaultError or { "cannot load the default layout" }, "; ")
        else
            success, result = editor.restoreDefault(state.session, default)
            state.status = success and "Default restored in the working copy." or tostring(result)
        end
    elseif action == "apply" then
        return saveAndClose(context, state)
    elseif action == "cancel" then
        editor.cancel(state.session)
        state.handlers.close(false)
        return
    end
    render(context, state)
end

local function activate(context, state)
    if state.mode == "menu" then
        activateAction(context, state, ACTIONS[state.actionIndex].id)
    elseif state.mode == "add" then
        local item = state.handlers.editor.CATALOG[state.catalogIndex]
        if item then
            local added, addError = state.handlers.editor.add(state.session, item.type)
            state.status = added and (item.label .. " added.") or tostring(addError)
            if added then
                state.mode = "menu"
            end
            render(context, state)
        end
    elseif state.mode == "move" or state.mode == "resize" then
        state.mode = "menu"
        state.status = "Placement mode finished."
        render(context, state)
    elseif state.mode == "configure" then
        local field = state.fields and state.fields[state.fieldIndex]
        if field then
            if field.type == "string" and not field.choices then
                startStringEdit(state, field)
            else
                local changed, changeError = updateFieldValue(context, state, field, 1)
                state.status = changed and "Setting updated in the working copy." or tostring(changeError)
            end
            render(context, state)
        end
    elseif state.mode == "string" then
        finishStringEdit(context, state, true)
    end
end

local function direction(context, state, horizontal, amount)
    if state.mode == "move" then
        local col = horizontal and amount or 0
        local row = horizontal and 0 or amount
        local moved, moveError = state.handlers.editor.move(state.session, col, row)
        state.status = moved and "Panel moved." or tostring(moveError)
    elseif state.mode == "resize" then
        local col = horizontal and amount or 0
        local row = horizontal and 0 or amount
        local resized, resizeError = state.handlers.editor.resize(state.session, col, row)
        state.status = resized and "Panel resized." or tostring(resizeError)
    elseif state.mode == "configure" then
        local field = state.fields and state.fields[state.fieldIndex]
        if field then
            local changed, changeError = updateFieldValue(context, state, field, amount)
            state.status = changed and "Setting updated in the working copy." or tostring(changeError)
        end
    elseif state.mode == "add" then
        local catalog = state.handlers.editor.CATALOG
        state.catalogIndex = math.max(1, math.min(#catalog, state.catalogIndex + amount))
    elseif state.mode == "menu" then
        setSelectedAction(context, state, state.actionIndex + amount)
        return
    end
    render(context, state)
end

local function vertical(context, state, amount)
    if state.mode == "configure" then
        setFieldSelection(context, state, state.fieldIndex + amount)
    elseif state.mode == "add" then
        local catalog = state.handlers.editor.CATALOG
        state.catalogIndex = math.max(1, math.min(#catalog, state.catalogIndex + amount))
        render(context, state)
    elseif state.mode == "string" then
        applyStringCharacter(state, amount)
        render(context, state)
    elseif state.mode == "move" then
        local moved, moveError = state.handlers.editor.move(state.session, 0, amount)
        state.status = moved and "Panel moved." or tostring(moveError)
        render(context, state)
    elseif state.mode == "resize" then
        local resized, resizeError = state.handlers.editor.resize(state.session, 0, amount)
        state.status = resized and "Panel resized." or tostring(resizeError)
        render(context, state)
    elseif state.mode == "menu" then
        setSelectedAction(context, state, state.actionIndex + amount)
    end
end

local function coordinates(state, context, touchState)
    if type(touchState) ~= "table" or type(touchState.x) ~= "number" or type(touchState.y) ~= "number" then
        return nil, nil
    end
    local x, y = touchState.x, touchState.y
    local left, top = context.left or 0, context.top or 0
    if x >= left and x < left + state.geometry.width and y >= top and y < top + state.geometry.height then
        x, y = x - left, y - top
    end
    return x, y
end

local function hit(rect, x, y)
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h
end

local function touch(context, state, touchState)
    local x, y = coordinates(state, context, touchState)
    if not x then
        return false
    end
    local geometry = state.geometry
    if state.mode == "menu" or state.mode == "move" or state.mode == "resize" then
        for index, action in ipairs(state.actions) do
            if hit(action.rect, x, y) then
                state.actionIndex = index
                state.mode = "menu"
                activateAction(context, state, action.id)
                return true
            end
        end
    elseif y >= geometry.height - 22 then
        if state.mode == "string" then
            finishStringEdit(context, state, true)
        else
            state.mode = "menu"
            state.status = "Returned to dashboard editing."
            render(context, state)
        end
        return true
    elseif y >= geometry.height - 44 then
        for index, navigation in ipairs(state.navigation) do
            if hit(navigation.rect, x, y) then
                if state.mode == "string" then
                    if index <= 2 then
                        local delta = index == 1 and -1 or 1
                        state.stringPosition =
                            math.max(1, math.min(#state.stringBuffer + 1, state.stringPosition + delta))
                        local current = string.sub(state.stringBuffer, state.stringPosition, state.stringPosition)
                        state.stringCharIndex = math.max(1, string.find(CHARACTERS, current, 1, true) or 1)
                    elseif index <= 4 then
                        applyStringCharacter(state, index == 3 and -1 or 1)
                    else
                        state.stringBuffer = string.sub(state.stringBuffer, 1, state.stringPosition - 1)
                            .. string.sub(state.stringBuffer, state.stringPosition + 1)
                    end
                elseif index <= 2 then
                    vertical(context, state, index == 1 and -1 or 1)
                elseif state.mode == "configure" and index <= 4 then
                    direction(context, state, true, index == 3 and -1 or 1)
                end
                render(context, state)
                return true
            end
        end
        return true
    end
    if not (state.mode == "add" or state.mode == "configure" or state.mode == "string") then
        local col, row
        for _, cell in ipairs(state.cells) do
            if hit(cell.rect, x, y) then
                col, row = cell.col, cell.row
                break
            end
        end
        if col == nil then
            return false
        end
        if state.mode == "menu" then
            for index, placement in ipairs(state.session.draft.panels) do
                if
                    col >= placement.col
                    and col < placement.col + placement.colSpan
                    and row >= placement.row
                    and row < placement.row + placement.rowSpan
                then
                    state.handlers.editor.select(state.session, index)
                    state.status = "Panel selected."
                    render(context, state)
                    return true
                end
            end
        elseif state.mode == "move" then
            local placement = state.session.draft.panels[state.session.selected]
            if placement then
                local moved, moveError =
                    state.handlers.editor.move(state.session, col - placement.col, row - placement.row)
                state.status = moved and "Panel moved." or tostring(moveError)
                render(context, state)
            end
            return true
        elseif state.mode == "resize" then
            local placement = state.session.draft.panels[state.session.selected]
            if placement then
                local resized, resizeError = state.handlers.editor.resize(
                    state.session,
                    col - placement.col + 1 - placement.colSpan,
                    row - placement.row + 1 - placement.rowSpan
                )
                state.status = resized and "Panel resized." or tostring(resizeError)
                render(context, state)
            end
            return true
        end
    end

    if state.mode == "add" then
        for index, row in ipairs(state.catalogRows) do
            local catalogIndex = state.catalogOffset + index - 1
            if
                index <= state.visibleCatalogRows
                and hit(row.rect, x, y)
                and state.handlers.editor.CATALOG[catalogIndex]
            then
                state.catalogIndex = catalogIndex
                activate(context, state)
                return true
            end
        end
    elseif state.mode == "configure" then
        for index, row in ipairs(state.fieldRows) do
            local fieldIndex = state.fieldOffset + index - 1
            local field = state.fields and state.fields[fieldIndex]
            if index <= state.visibleFieldRows and hit(row.rect, x, y) and field then
                state.fieldIndex = fieldIndex
                local delta = x > row.rect.x + row.rect.w * 0.66 and 1
                    or (x < row.rect.x + row.rect.w * 0.33 and -1 or 0)
                if delta ~= 0 then
                    local changed, changeError = updateFieldValue(context, state, field, delta)
                    state.status = changed and "Setting updated in the working copy." or tostring(changeError)
                elseif field.type == "string" and not field.choices then
                    startStringEdit(state, field)
                else
                    local changed, changeError = updateFieldValue(context, state, field, 1)
                    state.status = changed and "Setting updated in the working copy." or tostring(changeError)
                end
                render(context, state)
                return true
            end
        end
    end
    return false
end

function uiModule.open(context, session, handlers)
    local state = createScreen(context, session, handlers)
    context.editorUi = state
    return state
end

function uiModule.advance(context)
    local state = context.editorUi
    local stage = state and state.buildStage
    if not stage then
        return false
    end
    -- Build bounded groups while the overlay is hidden; reveal it only when complete.
    if stage <= 4 then
        addCellObjects(state, context, (stage - 1) * 4 + 1, stage * 4)
    elseif stage <= 8 then
        for index = (stage - 5) * 4 + 1, (stage - 4) * 4 do
            local rect = { x = 0, y = 0, w = 1, h = 1 }
            state.previews[index] = {
                background = rectangle(state.screen, rect, color(context, "surface", 0x212830)),
                text = label(state.screen, rect, "", color(context, "text", 0xF4F6F7)),
            }
        end
    elseif stage == 9 then
        addControls(state, context)
    elseif stage <= 11 then
        addMainActions(state, context, (stage - 10) * 5 + 1, (stage - 9) * 5)
    elseif stage <= 14 then
        addFieldRows(state, context, (stage - 12) * 4 + 1, (stage - 11) * 4)
    elseif stage <= 17 then
        addCatalogRows(state, context, (stage - 15) * 4 + 1, (stage - 14) * 4)
    else
        render(context, state)
        state.buildStage = nil
        lvgl.show(state.screen)
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
    if discard then
        state.handlers.editor.cancel(state.session)
    end
    state.screen:clear()
    lvgl.hide(state.screen)
    lvgl.show(context.page)
    context.editorUi = nil
end

function uiModule.handle(context, event, touchState)
    local state = context.editorUi
    if not state or state.buildStage then
        return false
    end
    if isTap(event, touchState) then
        return touch(context, state, touchState)
    end

    if eventMatches(event, "EVT_VIRTUAL_EXIT") then
        if state.mode == "string" then
            finishStringEdit(context, state, false)
        elseif state.mode ~= "menu" then
            state.mode = "menu"
            state.status = "Returned to the editor."
            render(context, state)
        else
            state.handlers.editor.cancel(state.session)
            state.handlers.close(false)
        end
        return true
    end
    if eventMatches(event, "EVT_VIRTUAL_ENTER") then
        activate(context, state)
        return true
    end
    if eventMatches(event, "EVT_VIRTUAL_PREV") or eventMatches(event, "EVT_ROT_LEFT") then
        if state.mode == "string" then
            applyStringCharacter(state, -1)
            render(context, state)
        else
            direction(context, state, true, -1)
        end
        return true
    end
    if eventMatches(event, "EVT_VIRTUAL_NEXT") or eventMatches(event, "EVT_ROT_RIGHT") then
        if state.mode == "string" then
            applyStringCharacter(state, 1)
            render(context, state)
        else
            direction(context, state, true, 1)
        end
        return true
    end
    if keyMatches(event, "KEY_LEFT") then
        if state.mode == "string" then
            state.stringPosition = math.max(1, state.stringPosition - 1)
            local current = string.sub(state.stringBuffer, state.stringPosition, state.stringPosition)
            state.stringCharIndex = math.max(1, string.find(CHARACTERS, current, 1, true) or 1)
            render(context, state)
        else
            direction(context, state, true, -1)
        end
        return true
    end
    if keyMatches(event, "KEY_RIGHT") then
        if state.mode == "string" then
            state.stringPosition = math.min(32, state.stringPosition + 1)
            local current = string.sub(state.stringBuffer, state.stringPosition, state.stringPosition)
            state.stringCharIndex = math.max(1, string.find(CHARACTERS, current, 1, true) or 1)
            render(context, state)
        else
            direction(context, state, true, 1)
        end
        return true
    end
    if keyMatches(event, "KEY_UP") then
        vertical(context, state, -1)
        return true
    end
    if keyMatches(event, "KEY_DOWN") then
        vertical(context, state, 1)
        return true
    end
    if state.mode == "string" and eventMatches(event, "EVT_VIRTUAL_MENU") then
        state.stringBuffer = string.sub(state.stringBuffer, 1, state.stringPosition - 1)
            .. string.sub(state.stringBuffer, state.stringPosition + 1)
        render(context, state)
        return true
    end
    return false
end

return uiModule
