-- SPDX-License-Identifier: GPL-2.0-only

local drawer = { RUNTIME_API = 1 }

local function current(state, field)
    local placement = state.session.draft.panels[state.session.selected]
    local value = placement and placement.config and placement.config[field.key]
    for _, key in ipairs(field.path or {}) do
        value = type(value) == "table" and value[key] or nil
    end
    if value == nil then
        return field.value
    end
    return value
end

local function enqueue(state, action, generation)
    if
        state.nativeDrawer
        and (not generation or generation == state.drawerGeneration)
        and not state.drawerPending
        and not state.drawerBuild
    then
        state.drawerPending = action
    end
end

local function closeDialog(state)
    local dialog = state.nativeDrawer
    state.nativeDrawer = nil
    state.drawerGeneration = (state.drawerGeneration or 0) + 1
    state.drawerBuild = nil
    if dialog then
        state.drawerClosing = true
        lvgl.close(dialog)
        state.drawerClosing = nil
    end
end

function drawer.close(state)
    closeDialog(state)
    state.drawerPending = nil
    state.drawerDismiss = nil
end

local function fieldsFor(state, listKey, itemIndex)
    local editor = state.handlers.editor
    local fields, fieldError = editor.formFields(state.session)
    if not fields then
        error(fieldError)
    end
    local result = {}
    if listKey then
        for _, field in ipairs(fields) do
            if field.key == listKey and field.path and field.path[1] == itemIndex then
                field.label = tostring(field.path[#field.path])
                result[#result + 1] = field
            end
        end
        result[#result + 1] = { label = "Remove entry", action = "remove-item", key = listKey, index = itemIndex }
        return result
    end
    local placement = state.session.draft.panels[state.session.selected]
    local sizes, sizeError = editor.sizes(state.session)
    if not sizes then
        error(sizeError)
    end
    result[1] =
        { key = "__size", label = "Size", choices = sizes, value = placement.colSpan .. "x" .. placement.rowSpan }
    result[2] = { key = "__col", label = "Column", type = "number", min = 1, max = 4, value = placement.col + 1 }
    result[3] = { key = "__row", label = "Row", type = "number", min = 1, max = 4, value = placement.row + 1 }
    for _, field in ipairs(fields) do
        if field.type == "table-list" then
            local _, config = editor.settings(state.session)
            for index, item in ipairs(config[field.key]) do
                local title = type(item) == "table" and (item.label or item.source) or item
                result[#result + 1] = {
                    label = (string.gsub(field.label, " entries$", "")) .. " " .. index,
                    text = tostring(title or "Edit entry"),
                    action = "item",
                    key = field.key,
                    index = index,
                }
            end
            result[#result + 1] = {
                label = "Add " .. string.gsub(field.label, " entries$", ""),
                action = "append",
                key = field.key,
                active = field.value < (field.maxItems or 3),
            }
        elseif not field.path then
            result[#result + 1] = field
        end
    end
    result[#result + 1] = { label = "Remove panel", action = "remove" }
    return result
end

function drawer.open(context, state, mode, listKey, itemIndex)
    closeDialog(state)
    for _, name in ipairs({ "dialog", "setting", "button", "choice", "toggle", "numberEdit", "textEdit", "close" }) do
        if type(lvgl[name]) ~= "function" then
            error("configuration drawer requires EdgeTX Lua LVGL " .. name)
        end
    end
    state.mode = mode
    local title, fields
    if mode == "add" then
        title, fields = "Add panel", {}
        for _, item in ipairs(state.handlers.editor.CATALOG) do
            fields[#fields + 1] = { label = item.label, action = "add", panelType = item.type }
        end
    else
        local placement = state.session.draft.panels[state.session.selected]
        title = placement.type
        for _, item in ipairs(state.handlers.editor.CATALOG) do
            if item.type == placement.type then
                title = item.label
                break
            end
        end
        title = title .. (listKey and (" / " .. listKey .. " " .. itemIndex) or "")
        fields = fieldsFor(state, listKey, itemIndex)
    end
    state.drawerListKey, state.drawerItemIndex = listKey, itemIndex
    state.drawerFields, state.drawerControls = fields, {}
    state.drawerBuild = 0
    -- Native dialogs supply centering, 80%-screen dimensions, scrolling and RTN.
    state.nativeDrawer = assert(
        lvgl.dialog({
            title = title,
            close = function()
                if not state.drawerClosing then
                    -- RTN deletes native children; retire their Lua callbacks first.
                    state.nativeDrawer:clear()
                    state.nativeDrawer = nil
                    state.drawerBuild = nil
                    local command = { action = listKey and "parent" or "back" }
                    if state.drawerPending then
                        state.drawerDismiss = command
                    else
                        state.drawerPending = command
                    end
                end
            end,
        }),
        "cannot open editor dialog"
    )
    state.drawerWidth = math.floor(context.zone.w * 0.8)
end

local function writeField(state, field, value)
    local editor = state.handlers.editor
    local placement = state.session.draft.panels[state.session.selected]
    if field.key == "__size" then
        local width, height = string.match(value, "^(%d+)x(%d+)$")
        return editor.resize(state.session, tonumber(width) - placement.colSpan, tonumber(height) - placement.rowSpan)
    elseif field.key == "__col" then
        return editor.move(state.session, value - placement.col - 1, 0)
    elseif field.key == "__row" then
        return editor.move(state.session, 0, value - placement.row - 1)
    elseif field.path then
        return editor.setPath(state.session, field.key, field.path, value)
    end
    return editor.setValue(state.session, field.key, value)
end

local function addControl(context, state, field, index)
    local generation = state.drawerGeneration
    local function queue(command)
        enqueue(state, command, generation)
    end
    local width = state.drawerWidth - 16
    local row =
        lvgl.setting(state.nativeDrawer, { x = 4, y = 40 + (index - 1) * 58, w = width, h = 38, title = field.label })
    local controlX = math.floor(width * 0.48)
    local options = {
        x = controlX,
        y = 4,
        w = width - controlX - 8,
        h = 30,
        active = function()
            return generation == state.drawerGeneration
                and state.nativeDrawer ~= nil
                and state.drawerBuild == nil
                and not state.drawerPending
                and field.active ~= false
        end,
    }
    local function get()
        if field.key == "__size" then
            local p = state.session.draft.panels[state.session.selected]
            return p.colSpan .. "x" .. p.rowSpan
        elseif field.key == "__col" or field.key == "__row" then
            local p = state.session.draft.panels[state.session.selected]
            return (field.key == "__col" and p.col or p.row) + 1
        end
        return current(state, field)
    end
    local function set(value)
        queue({ action = "write", field = field, value = value, control = state.drawerControls[index] })
    end
    local kind, control
    local leaf = field.path and field.path[#field.path] or field.key
    if field.action then
        kind = "button"
        options.text = field.text or field.label
        options.press = function()
            queue(field)
        end
        if field.action == "remove" or field.action == "remove-item" then
            options.textColor = context.theme.color.critical
        end
    elseif field.choices then
        kind = "choice"
        options.title, options.values = field.label, field.choices
        options.get = function()
            for choiceIndex, value in ipairs(field.choices) do
                if value == get() then
                    return choiceIndex
                end
            end
            return 1
        end
        options.set = function(choiceIndex)
            set(field.choices[choiceIndex])
        end
    elseif field.type == "boolean" then
        kind, options.get = "toggle", get
        options.set = function(value)
            set(value ~= 0 and value ~= false)
        end
    elseif leaf == "source" or leaf == "switch" or string.match(leaf, "Source$") or string.match(leaf, "Switch$") then
        kind = (leaf == "source" or string.match(leaf, "Source$")) and "source" or "switch"
        local indexOf = kind == "source" and getSourceIndex or getSwitchIndex
        local nameOf = kind == "source" and getSourceName or getSwitchName
        if type(lvgl[kind]) ~= "function" or type(indexOf) ~= "function" or type(nameOf) ~= "function" then
            error("native " .. leaf .. " picker APIs unavailable")
        end
        options.get = function()
            local value = get()
            if kind == "switch" and type(value) == "string" then
                local physical, position = string.match(value, "^(S[A-Z])([%^v%-])$")
                if physical then
                    value = physical .. (position == "^" and CHAR_UP or position == "v" and CHAR_DOWN or "-")
                end
            end
            return type(value) == "number" and value or indexOf(value or "") or 0
        end
        options.set = function(value)
            local name = nameOf(value)
            if type(name) ~= "string" or name == "" then
                queue({ action = "error", message = "Cannot resolve selected " .. leaf, control = field.control })
            else
                if kind == "switch" then
                    local physical, position = string.match(name, "^(S[A-Z])(.+)$")
                    if physical then
                        name = physical .. (position == CHAR_UP and "^" or position == CHAR_DOWN and "v" or position)
                    end
                end
                set(type(get()) == "number" and value or name)
            end
        end
        if leaf == "motorSource" then
            options.filter = lvgl.SRC_CHANNEL
        end
    elseif leaf == "timer" then
        kind, options.get, options.set = "timer", get, set
    elseif field.type == "number" then
        kind = "numberEdit"
        local scale = (field.step and field.step < 1 or (get() or 0) % 1 ~= 0) and 100 or 1
        options.min = math.floor((field.min or -1000000) * scale)
        options.max = math.floor((field.max or 1000000) * scale)
        options.get = function()
            return math.floor((get() or 0) * scale + 0.5)
        end
        options.set = function(value)
            local step = field.step or 1 / scale
            set(math.floor(value / scale / step + 0.5) * step)
        end
        if scale ~= 1 then
            options.display = function(value)
                return tostring(value / scale)
            end
        end
    else
        kind, options.value, options.length =
            "textEdit", function()
                return tostring(get() or "")
            end, 128
        options.set = set
    end
    control = assert(lvgl[kind](row, options), "cannot create native " .. kind)
    local errorLabel = lvgl.label(state.nativeDrawer, {
        x = 12,
        y = 40 + (index - 1) * 58 + 38,
        w = width - 8,
        h = 18,
        text = "",
        font = SMLSIZE,
        color = context.theme.color.critical,
    })
    lvgl.hide(errorLabel)
    state.drawerControls[index] = { object = control, errorLabel = errorLabel, field = field }
    field.control = state.drawerControls[index]
end

function drawer.advance(context, state)
    if state.drawerBuild ~= nil then
        if state.drawerBuild == 0 then
            local generation = state.drawerGeneration
            state.drawerBack = lvgl.button(state.nativeDrawer, {
                x = 8,
                y = 4,
                w = 36,
                h = 30,
                text = "<",
                press = function()
                    enqueue(state, { action = state.drawerListKey and "parent" or "back" }, generation)
                end,
                active = function()
                    return generation == state.drawerGeneration
                        and state.nativeDrawer ~= nil
                        and state.drawerBuild == nil
                        and not state.drawerPending
                end,
            })
        elseif state.drawerBuild <= #state.drawerFields then
            addControl(context, state, state.drawerFields[state.drawerBuild], state.drawerBuild)
        else
            state.drawerBuild = nil
            return true
        end
        state.drawerBuild = state.drawerBuild + 1
        return true
    end
    local command = state.drawerPending
    if not command then
        return false
    end
    state.drawerPending = nil
    local editor, ok, err = state.handlers.editor
    if command.action == "back" then
        drawer.close(state)
        state.mode = "menu"
    elseif command.action == "parent" then
        drawer.open(context, state, "configure")
    elseif command.action == "item" then
        drawer.open(context, state, "configure", command.key, command.index)
    elseif command.action == "write" then
        ok, err = writeField(state, command.field, command.value)
        if command.control and state.nativeDrawer then
            command.control.errorLabel:set({ text = ok and "" or tostring(err) })
            if ok then
                lvgl.hide(command.control.errorLabel)
            else
                lvgl.show(command.control.errorLabel)
            end
        end
        if ok and not state.drawerDismiss and string.sub(command.field.key, 1, 2) == "__" then
            drawer.open(context, state, "configure")
        end
    elseif command.action == "append" then
        ok, err = editor.appendItem(state.session, command.key)
        if ok then
            drawer.open(context, state, "configure")
        end
    elseif command.action == "remove-item" then
        ok, err = editor.removeItem(state.session, command.key, command.index)
        if ok then
            drawer.open(context, state, "configure")
        end
    elseif command.action == "remove" or command.action == "add" then
        if command.action == "remove" then
            ok, err = editor.remove(state.session)
        else
            ok, err = editor.add(state.session, command.panelType)
        end
        if ok then
            drawer.close(state)
            state.mode = "menu"
        end
    elseif command.action == "error" then
        ok, err = false, command.message
    end
    if ok == false then
        state.status, state.statusError = tostring(err), true
        if command.control and state.nativeDrawer then
            command.control.errorLabel:set({ text = tostring(err) })
            lvgl.show(command.control.errorLabel)
        end
    end
    if state.drawerDismiss then
        state.drawerPending, state.drawerDismiss = state.drawerDismiss, nil
    end
    return true
end

return drawer
