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

-- EdgeTX keeps a dismissed dialog's Lua wrapper registered after deleting its
-- native window, and a later refresh dereferences that window. Clearing the
-- dialog's registration parent unregisters the wrapper without touching it.
local function retireDialogHost(state)
    local host = state.nativeDrawerHost
    state.nativeDrawerHost = nil
    if host then
        host:clear()
        lvgl.hide(host)
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
    retireDialogHost(state)
end

-- Objects created while EdgeTX constructs a parented object are registered
-- under that parent, so the dialog is created from a child's visibility probe.
local function hostedDialog(context, state, properties)
    local host = lvgl.box(state.screen, { x = 0, y = 0, w = 0, h = 0 })
    local dialog, failure, attempted
    lvgl.box(host, {
        x = 0,
        y = 0,
        w = 0,
        h = 0,
        visible = function()
            if not attempted then
                attempted = true
                local ok, result = pcall(lvgl.dialog, properties)
                if ok then
                    dialog = result
                else
                    failure = result
                end
            end
            return true
        end,
    })
    if failure then
        host:clear()
        lvgl.hide(host)
        error(failure, 0)
    end
    if not attempted then
        -- Firmware without construction-time probes registers dialogs at top
        -- level; only the host-wide reload on App return can retire those.
        host:clear()
        lvgl.hide(host)
        context.nativeDialogsCreated = true
        return lvgl.dialog(properties)
    end
    state.nativeDrawerHost = host
    return dialog
end

function drawer.close(state)
    closeDialog(state)
    state.drawerPending = nil
    state.drawerDismiss = nil
end

local function entrySummary(state, key, index, defaults)
    local config = state.session.draft.panels[state.session.selected].config or {}
    local item = (config[key] or defaults[key])[index]
    local source = item.source
    if type(getFieldInfo) == "function" and type(getSourceName) == "function" then
        local info = getFieldInfo(source)
        source = type(info) == "table" and getSourceName(info.id) or source
    end
    local summary = { tostring(source or "--") }
    if key == "texts" then
        local positions = item.positions or {}
        for _, position in ipairs({ "up", "middle", "down" }) do
            summary[#summary + 1] = positions[position] or "--"
        end
    else
        if item.unit and item.unit ~= "" then
            summary[#summary + 1] = item.unit
        end
        summary[#summary + 1] = config.visual or defaults.visual or "bar"
    end
    return table.concat(summary, "  ")
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
                field.label = field.entryLabel or tostring(field.path[#field.path])
                result[#result + 1] = field
            end
        end
        result[#result + 1] = { label = "Remove entry", action = "remove-item", key = listKey, index = itemIndex }
        return result
    end
    for _, field in ipairs(fields) do
        if field.type == "table-list" then
            local _, config = editor.settings(state.session)
            result[#result + 1] = {
                label = string.gsub(field.label, " entries$", ""),
                type = "section",
            }
            for index, item in ipairs(config[field.key]) do
                local title = type(item) == "table" and (item.label or item.source) or item
                result[#result + 1] = {
                    label = tostring(title or ("Entry " .. index)),
                    text = function()
                        return entrySummary(state, field.key, index, config)
                    end,
                    action = "item",
                    key = field.key,
                    index = index,
                }
            end
            result[#result + 1] = {
                label = "+",
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
    if mode == "add" then
        assert(type(lvgl.menu) == "function", "panel selection requires EdgeTX Lua LVGL menu")
        local catalog, values = state.handlers.editor.CATALOG, {}
        for index, item in ipairs(catalog) do
            values[index] = item.label
        end
        local generation = state.drawerGeneration
        -- Native menus own input and cancellation; no drawer state needs unwinding.
        state.mode = "menu"
        lvgl.menu({
            title = "Select panel",
            values = values,
            get = function()
                return 1
            end,
            set = function(index)
                if context.editorUi == state and generation == state.drawerGeneration and not state.drawerPending then
                    local item = assert(catalog[index], "invalid panel selection")
                    state.drawerPending = { action = "add", panelType = item.type }
                end
            end,
        })
        return
    end
    for _, name in ipairs({ "dialog", "setting", "button", "choice", "toggle", "numberEdit", "textEdit", "close" }) do
        if type(lvgl[name]) ~= "function" then
            error("configuration drawer requires EdgeTX Lua LVGL " .. name)
        end
    end
    state.mode = mode
    local placement = state.session.draft.panels[state.session.selected]
    local title = placement.type
    for _, item in ipairs(state.handlers.editor.CATALOG) do
        if item.type == placement.type then
            title = item.label
            break
        end
    end
    title = title .. (listKey and (" / " .. listKey .. " " .. itemIndex) or "")
    local fields = fieldsFor(state, listKey, itemIndex)
    state.drawerListKey, state.drawerItemIndex = listKey, itemIndex
    state.drawerFields, state.drawerControls = fields, {}
    state.drawerBuild = 1
    state.drawerControlHeight = lvgl.UI_ELEMENT_HEIGHT or 32
    state.drawerPadding = math.floor(state.drawerControlHeight / 16 + 0.5)
    state.drawerRowHeight = state.drawerControlHeight + state.drawerPadding * 2
    state.drawerNextY = state.drawerPadding * 2
    state.drawerErrorHeight = math.floor(state.drawerControlHeight * 0.56 + 0.5)
    -- Native dialogs supply centering, 80%-screen dimensions, scrolling and RTN.
    state.nativeDrawer = assert(
        hostedDialog(context, state, {
            title = title,
            close = function()
                if not state.drawerClosing then
                    -- RTN deletes native children; retire their Lua callbacks first.
                    state.nativeDrawer:clear()
                    state.nativeDrawer = nil
                    retireDialogHost(state)
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

--- Queue an exit-flow command from a native callback of this generation.
local function exitCommand(context, state, generation, command)
    if context.editorUi == state and generation == state.drawerGeneration and not state.exitCommand then
        state.exitCommand = command
    end
end

--- Offer Save, Save As and Discard for a changed draft. RTN keeps editing.
function drawer.openExit(context, state)
    closeDialog(state)
    assert(type(lvgl.menu) == "function", "exit dialog requires EdgeTX Lua LVGL menu")
    local actions, values = {}, {}
    if not state.handlers.isEmpty(state.handlers.layoutName()) then
        actions[#actions + 1], values[#values + 1] = "save", "Save"
    end
    actions[#actions + 1], values[#values + 1] = "save-as", "Save as..."
    actions[#actions + 1], values[#values + 1] = "discard", "Discard changes"
    local generation = state.drawerGeneration
    state.mode = "menu"
    lvgl.menu({
        title = "Unsaved changes",
        values = values,
        get = function()
            return 1
        end,
        set = function(index)
            exitCommand(context, state, generation, { action = assert(actions[index], "invalid exit choice") })
        end,
    })
end

--- Ask for the Save As name; RTN returns to the exit menu.
function drawer.openName(context, state, name, message)
    closeDialog(state)
    for _, kind in ipairs({ "dialog", "textEdit", "button", "label", "confirm" }) do
        if type(lvgl[kind]) ~= "function" then
            error("save as requires EdgeTX Lua LVGL " .. kind)
        end
    end
    state.mode = "name"
    state.saveAsName = name
    local generation = state.drawerGeneration
    state.nativeDrawer = assert(
        hostedDialog(context, state, {
            title = "Save layout as",
            close = function()
                if not state.drawerClosing then
                    state.nativeDrawer:clear()
                    state.nativeDrawer = nil
                    retireDialogHost(state)
                    exitCommand(context, state, generation, { action = "exit" })
                end
            end,
        }),
        "cannot open editor dialog"
    )
    local height = lvgl.UI_ELEMENT_HEIGHT or 32
    local width = math.floor(context.zone.w * 0.8) - 16
    local function active()
        return generation == state.drawerGeneration and state.nativeDrawer ~= nil and not state.exitCommand
    end
    lvgl.textEdit(state.nativeDrawer, {
        x = 4,
        y = 4,
        w = width,
        h = height,
        value = name,
        length = 32,
        active = active,
        set = function(value)
            if generation == state.drawerGeneration then
                state.saveAsName = value
            end
        end,
    })
    lvgl.label(state.nativeDrawer, {
        x = 8,
        y = height + 8,
        w = width - 8,
        h = math.floor(height * 0.56 + 0.5),
        text = message or "",
        font = function()
            return SMLSIZE
        end,
        color = context.theme.color.critical,
    })
    lvgl.button(state.nativeDrawer, {
        x = 4,
        y = math.floor(height * 1.8) + 8,
        w = width,
        h = height,
        text = "Save",
        active = active,
        press = function()
            exitCommand(context, state, generation, { action = "name", name = state.saveAsName })
        end,
    })
end

--- Ask before replacing an existing layout; Back keeps the name dialog open.
function drawer.confirmOverwrite(context, state, name)
    local generation = state.drawerGeneration
    lvgl.confirm({
        title = "Overwrite " .. name .. "?",
        message = "A layout named " .. name .. " already exists.",
        confirm = function()
            exitCommand(context, state, generation, { action = "write", name = name })
        end,
    })
end

local function writeField(state, field, value)
    local editor = state.handlers.editor
    if field.path then
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
    local y = state.drawerNextY
    local rowHeight = field.type == "section" and math.floor(state.drawerControlHeight * 0.625) or state.drawerRowHeight
    state.drawerNextY = y + rowHeight
    local fullWidth = field.action == "remove"
        or field.action == "remove-item"
        or field.action == "append"
        or field.type == "section"
    local row = lvgl.setting(state.nativeDrawer, {
        x = 4,
        y = y,
        w = width,
        h = rowHeight,
        title = (fullWidth or field.action == "item") and "" or field.label,
    })
    local controlX = fullWidth and 0 or math.floor(width * (field.action == "item" and 0.28 or 0.48))
    if field.action == "item" then
        lvgl.label(row, {
            x = 0,
            y = math.floor((state.drawerControlHeight - context.themeBuilder.fontHeight(0)) / 2),
            w = controlX - 8,
            h = state.drawerControlHeight,
            text = field.label,
        })
    end
    local options = {
        x = controlX,
        y = 0,
        w = width - controlX - 8,
        h = state.drawerControlHeight,
        active = function()
            return generation == state.drawerGeneration
                and state.nativeDrawer ~= nil
                and state.drawerBuild == nil
                and not state.drawerPending
                and field.active ~= false
        end,
    }
    local function get()
        return current(state, field)
    end
    local function set(value)
        queue({ action = "write", field = field, value = value, control = state.drawerControls[index] })
    end
    local kind, control
    local leaf = field.path and field.path[#field.path] or field.key
    if field.type == "section" then
        kind = "label"
        options.active = nil
        options.text = field.label
        options.h = rowHeight
        options.font = function()
            return SMLSIZE
        end
    elseif field.action then
        kind = "button"
        options.text = field.text or field.label
        options.press = function()
            queue(field)
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
        kind = "toggle"
        options.get = function()
            return get() and 1 or 0
        end
        options.set = function(value)
            set(value ~= 0 and value ~= false)
        end
    elseif leaf == "source" or leaf == "switch" or string.match(leaf, "Source$") or string.match(leaf, "Switch$") then
        kind = (leaf == "source" or string.match(leaf, "Source$")) and "source" or "switch"
        local indexOf = kind == "source" and getSourceIndex or getSwitchIndex
        local nameOf = kind == "source" and getSourceName or getSwitchName
        if
            type(lvgl[kind]) ~= "function"
            or type(indexOf) ~= "function"
            or type(nameOf) ~= "function"
            or kind == "source" and type(getFieldInfo) ~= "function"
        then
            error("native " .. leaf .. " picker APIs unavailable")
        end
        -- Panels read sources through getFieldInfo, whose names ("gvar1", "ch3",
        -- "sf") differ from the menu names the picker shows ("GV1:Thr", "CH3").
        -- Both share one index, so a name is stored only if it maps back to it.
        local function fieldId(name)
            local info = getFieldInfo(name)
            return type(info) == "table" and type(info.id) == "number" and info.id or nil
        end
        options.get = function()
            local value = get()
            if kind == "switch" and type(value) == "string" then
                local physical, position = string.match(value, "^(S[A-Z])([%^v%-])$")
                if physical then
                    value = physical .. (position == "^" and CHAR_UP or position == "v" and CHAR_DOWN or "-")
                end
            end
            if type(value) == "number" then
                return value
            end
            if kind == "source" and type(value) == "string" and value ~= "" then
                local id = fieldId(value)
                if id then
                    return id
                end
            end
            return indexOf(value or "") or 0
        end
        options.set = function(value)
            local name = nameOf(value)
            if kind == "source" and value == 0 and not field.required then
                set("")
            elseif type(name) ~= "string" or name == "" then
                queue({ action = "error", message = "Cannot resolve selected " .. leaf, control = field.control })
            elseif type(get()) == "number" then
                set(value)
            elseif kind == "switch" then
                local physical, position = string.match(name, "^(S[A-Z])(.+)$")
                if physical then
                    name = physical .. (position == CHAR_UP and "^" or position == CHAR_DOWN and "v" or position)
                end
                set(name)
            else
                local info = getFieldInfo(value)
                local plain = string.match(name, "^\194[\128-\191](.+)$") or name
                local readable
                for _, candidate in ipairs({
                    type(info) == "table" and info.name or nil,
                    plain,
                    string.lower(plain),
                }) do
                    if type(candidate) == "string" and candidate ~= "" and fieldId(candidate) == value then
                        readable = candidate
                        break
                    end
                end
                if readable then
                    set(readable)
                else
                    queue({
                        action = "error",
                        message = "Lua cannot read source " .. plain,
                        control = field.control,
                    })
                end
            end
        end
        if leaf == "motorSource" then
            options.filter = lvgl.SRC_CHANNEL
        end
    elseif leaf == "timer" then
        kind, options.get, options.set = "timer", get, set
    elseif field.type == "number" then
        kind = "numberEdit"
        local scale = field.step and field.step < 1 and math.floor(1 / field.step + 0.5) or 1
        if ((get() or 0) * scale) % 1 ~= 0 then
            scale = 100
        end
        options.min = math.floor((field.min or -100000) * scale)
        options.max = math.floor((field.max or 100000) * scale)
        -- An optional field without a default is shown below its minimum as
        -- "unset", and choosing that entry removes the field again.
        local unset = field.empty and options.min - 1
        if unset then
            options.min = unset
        end
        options.get = function()
            local value = get()
            if value == nil then
                return unset or 0
            end
            return math.floor(value * scale + 0.5)
        end
        options.set = function(value)
            if unset and value <= unset then
                set(nil)
                return
            end
            local step = field.step or (1 / scale)
            set(math.floor(value / scale / step + 0.5) * step)
        end
        if scale ~= 1 or unset then
            options.display = function(value)
                if unset and value <= unset then
                    return field.empty
                end
                return tostring(value / scale)
            end
        end
    else
        kind, options.value, options.length = "textEdit", tostring(get() or ""), 128
        options.set = function(value)
            -- Clearing an optional text removes it, so the panel's own
            -- fallback applies again.
            if value == "" and field.path and not field.required then
                value = nil
            end
            set(value)
        end
    end
    control = assert(lvgl[kind](row, options), "cannot create native " .. kind)
    local errorLabel = lvgl.label(state.nativeDrawer, {
        x = 12,
        y = y + rowHeight,
        w = width - 8,
        h = state.drawerErrorHeight,
        text = "",
        font = SMLSIZE,
        color = context.theme.color.critical,
    })
    lvgl.hide(errorLabel)
    state.drawerControls[index] = {
        object = control,
        row = row,
        height = rowHeight,
        errorLabel = errorLabel,
        field = field,
        kind = kind,
    }
    field.control = state.drawerControls[index]
end

local function fieldError(state, control, message)
    control.errorLabel:set({ text = message or "" })
    if message then
        lvgl.show(control.errorLabel)
    else
        lvgl.hide(control.errorLabel)
    end
    local shown = message ~= nil
    if (control.errorShown == true) == shown then
        return
    end
    control.errorShown = shown
    local y = state.drawerPadding * 2
    for _, entry in ipairs(state.drawerControls) do
        entry.row:set({ y = y })
        y = y + entry.height
        entry.errorLabel:set({ y = y })
        if entry.errorShown then
            y = y + state.drawerErrorHeight
        end
    end
end

function drawer.advance(context, state)
    if state.drawerBuild ~= nil then
        if state.drawerBuild <= #state.drawerFields then
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
    local editor = state.handlers.editor
    local ok, err
    if command.action == "back" then
        drawer.close(state)
        state.mode = "menu"
        state.previewPending = true
    elseif command.action == "parent" then
        drawer.open(context, state, "configure")
    elseif command.action == "item" then
        drawer.open(context, state, "configure", command.key, command.index)
    elseif command.action == "write" then
        ok, err = writeField(state, command.field, command.value)
        if command.control and state.nativeDrawer then
            if command.control.kind == "textEdit" then
                command.control.object:set({ value = tostring(current(state, command.field) or "") })
            end
            fieldError(state, command.control, not ok and tostring(err) or nil)
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
            if command.action == "add" then
                drawer.open(context, state, "configure")
            else
                drawer.close(state)
                state.mode = "menu"
                state.previewPending = true
            end
        end
    elseif command.action == "error" then
        ok, err = false, command.message
    end
    if ok == false then
        state.status, state.statusError = tostring(err), true
        if command.control and state.nativeDrawer then
            fieldError(state, command.control, tostring(err))
        end
    end
    if state.drawerDismiss then
        state.drawerPending, state.drawerDismiss = state.drawerDismiss, nil
    end
    return true
end

return drawer
