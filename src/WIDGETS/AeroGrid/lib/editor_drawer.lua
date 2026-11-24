-- SPDX-License-Identifier: GPL-2.0-only

local drawer = {}

local function queueNative(context, state, generation, apply, value)
    if
        context.editorUi == state
        and generation == state.drawerGeneration
        and not state.nativeInput
        and not state.drawerPending
        and not state.drawerBuild
    then
        state.nativeInput = { apply = apply, value = value, generation = generation }
        return true
    end
    return false
end

local function deferredSetter(context, state, generation, apply)
    return context.settingsUiModule.defer(apply, function(callback, value)
        return queueNative(context, state, generation, callback, value)
    end)
end
drawer.deferredSetter = deferredSetter

function drawer.applyNative(context, state)
    local command = state.nativeInput
    state.nativeInput = nil
    if command and context.editorUi == state and command.generation == state.drawerGeneration then
        local pending = state.drawerPending
        state.drawerPending = nil
        state.applyingNative = true
        command.apply(command.value)
        state.applyingNative = nil
        if pending then
            if state.drawerPending then
                state.drawerDismiss = pending
            else
                state.drawerPending = pending
            end
        end
    end
end

local function current(state, field)
    local placement = state.session.draft.panels[state.session.selected]
    local value = placement and placement.config and placement.config[field.key]
    for _, key in ipairs(field.path or {}) do
        value = type(value) == "table" and value[key] or nil
    end
    if value == nil then
        if field.path then
            return field.value
        end
        return field.default
    end
    return value
end

local function writeField(state, field, value)
    local editor = state.handlers.editor
    if field.path then
        return editor.setPath(state.session, field.key, field.path, value)
    end
    return editor.setValue(state.session, field.key, value)
end

local function enqueue(state, action, generation)
    if
        (state.nativeDrawer or state.applyingNative)
        and (not generation or generation == state.drawerGeneration)
        and not state.drawerPending
        and not state.drawerBuild
    then
        state.drawerPending = action
    end
end
drawer.enqueue = enqueue

local function closeDialog(state)
    state.nativeDrawer = nil
    state.drawerGeneration = (state.drawerGeneration or 0) + 1
    state.drawerBuild = nil
    if state.drawerView then
        state.settingsUi.close(state.drawerView)
        state.drawerView = nil
    end
    state.nativeDrawerHost = nil
end
drawer.closeDialog = closeDialog

local function hostedDialog(context, state, properties)
    local generation = state.drawerGeneration
    local closed = properties.close
    properties.close = function()
        state.nativeDrawerHost = nil
        closed()
    end
    state.settingsUi = context.settingsUiModule
    state.drawerView = state.settingsUi.open(context, state.screen, properties, {
        active = function()
            return context.editorUi == state
                and generation == state.drawerGeneration
                and (
                    not state.drawerPending
                    or state.drawerPending.action == "write"
                    or state.drawerPending.action == "error"
                )
        end,
        enqueue = function(apply, value)
            return queueNative(context, state, generation, apply, value)
        end,
        config = function()
            local _, config = state.handlers.editor.settings(state.session)
            return config
        end,
        fontHeight = function()
            return context.themeBuilder.fontHeight(0)
        end,
    })
    state.nativeDrawerHost = state.drawerView.host
    return state.drawerView.dialog
end
drawer.hostedDialog = hostedDialog

--- Open a settings dialog of `fields` whose controls read and write through
--- `read(field)` and `write(field, value)`. RTN queues `back()`'s command.
function drawer.settingsDialog(context, state, title, fields, read, write, back)
    local generation = state.drawerGeneration
    state.nativeDrawer = assert(
        hostedDialog(context, state, {
            title = title,
            close = function()
                if generation == state.drawerGeneration then
                    state.nativeDrawer, state.drawerBuild = nil, nil
                    local command = back()
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
    local view = state.drawerView
    view.fields, view.build = fields, 1
    view.errorHeight = math.floor((lvgl.UI_ELEMENT_HEIGHT or 32) * 0.56 + 0.5)
    view.errorColor = context.theme.color.critical
    view.read, view.writeValue = read, write
    view.write = function(field, value, control)
        enqueue(state, { action = "write", field = field, value = value, control = control }, generation)
    end
    view.action = function(command)
        enqueue(state, command, generation)
    end
    view.report = function(message, control)
        enqueue(state, { action = "error", message = message, control = control }, generation)
    end
    state.drawerControls, state.drawerBuild = view.controls, 1
end

function drawer.close(state)
    closeDialog(state)
    state.drawerPending = nil
    state.drawerDismiss = nil
    state.nativeInput = nil
end

--- Ask what to do with item `index` of a `count`-item list. The chosen
--- "edit", "up", "down" or "delete" is queued as `command.choice`.
function drawer.itemMenu(context, state, title, index, count, removable, command)
    assert(type(lvgl.menu) == "function", "list items require EdgeTX Lua LVGL menu")
    local choices = { "edit" }
    if index > 1 then
        choices[#choices + 1] = "up"
    end
    if index < count then
        choices[#choices + 1] = "down"
    end
    if removable then
        choices[#choices + 1] = "delete"
    end
    local labels = { edit = "Edit", up = "Move up", down = "Move down", delete = "Delete" }
    local values = {}
    for position, choice in ipairs(choices) do
        values[position] = labels[choice]
    end
    local generation = state.drawerGeneration
    lvgl.menu({
        title = title,
        values = values,
        get = function()
            return 1
        end,
        set = deferredSetter(context, state, generation, function(position)
            if context.editorUi == state and generation == state.drawerGeneration and not state.drawerPending then
                local queued = {}
                for key, value in pairs(command) do
                    queued[key] = value
                end
                queued.choice = choices[position]
                state.drawerPending = queued
            end
        end),
    })
end

local function entrySummary(state, key, index, defaults, path)
    local config = state.session.draft.panels[state.session.selected].config or {}
    local items = config[key] or defaults[key]
    for _, part in ipairs(path or {}) do
        items = items[part]
    end
    local item = items[index]
    if item.states then
        local summaries = {}
        for _, condition in ipairs(item.states) do
            if condition.switch and condition.switch ~= "" then
                summaries[#summaries + 1] = state.settingsUi.switchSummary(condition.switch)
                    .. ": "
                    .. (condition.text and condition.text ~= "" and condition.text or "--")
            else
                summaries[#summaries + 1] = "--"
            end
        end
        return #summaries > 0 and table.concat(summaries, " / ") or "--"
    elseif item.switch then
        return state.settingsUi.switchSummary(item.switch)
            .. ": "
            .. (item.text and item.text ~= "" and item.text or "--")
            .. " ("
            .. (item.background or "normal")
            .. ")"
    end
    local source = item.source
    -- A newly added entry has no source yet; getFieldInfo raises on nil.
    if
        (type(source) == "string" and source ~= "" or type(source) == "number")
        and type(getFieldInfo) == "function"
        and type(getSourceName) == "function"
    then
        local info = getFieldInfo(source)
        source = type(info) == "table" and getSourceName(info.id) or source
    end
    local summary = { (source == nil or source == "") and "--" or tostring(source) }
    if item.unit and item.unit ~= "" then
        summary[#summary + 1] = item.unit
    end
    return table.concat(summary, "  ")
end

local function fieldsFor(state, listKey, itemIndex, itemPath, groupKey)
    local editor = state.handlers.editor
    local fields, fieldError
    if groupKey then
        fields, fieldError = editor.drawerFields(state.session, groupKey)
    else
        fields, fieldError = editor.formFields(state.session)
    end
    if not fields then
        error(fieldError)
    end
    if groupKey then
        return fields
    end
    local result = {}
    local selected = itemPath or (listKey and { itemIndex } or {})
    for _, field in ipairs(fields) do
        local matches = not listKey or field.key == listKey
        for index, part in ipairs(selected) do
            matches = matches and field.path ~= nil and field.path[index] == part
        end
        for index = #selected + 1, #(field.path or {}) do
            if type(field.path[index]) == "number" then
                matches = false
            end
        end
        if matches and field.type == "table-list" then
            local _, config = editor.settings(state.session)
            result[#result + 1] = {
                label = field.entryLabel or string.gsub(field.label, " entries$", ""),
                type = "section",
            }
            local items = config[field.key]
            for _, part in ipairs(field.path or {}) do
                items = items[part]
            end
            for index, item in ipairs(items) do
                local title = item
                if type(item) == "table" then
                    title = item.label
                    if title == nil or title == "" then
                        local summary = entrySummary(state, field.key, index, config, field.path)
                        -- A summary of only placeholders says nothing; use the list position.
                        title = string.find(summary, "[^%-/ ]") and summary or nil
                    end
                end
                if title == nil or title == "" then
                    title = (field.itemLabel or "Entry") .. " " .. index
                end
                local path = editor.clone(field.path or {})
                path[#path + 1] = index
                result[#result + 1] = {
                    label = tostring(title),
                    action = "item",
                    key = field.key,
                    index = index,
                    itemPath = path,
                    path = field.path,
                    count = #items,
                    removable = #items > (field.minItems or 0),
                }
            end
            result[#result + 1] = {
                label = "+",
                action = "append",
                key = field.key,
                path = field.path,
                active = field.value < (field.maxItems or 3),
            }
        elseif matches and (listKey or not field.path) then
            field.label = field.entryLabel or field.label
            result[#result + 1] = field
        end
    end
    if not listKey then
        result[#result + 1] = { label = "Remove panel", action = "remove" }
    end
    return editor.orderFields(result, listKey ~= nil)
end

function drawer.open(context, state, mode, listKey, itemIndex, itemPath, groupKey)
    state.settingsUi = context.settingsUiModule
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
            set = deferredSetter(context, state, generation, function(index)
                if context.editorUi == state and generation == state.drawerGeneration and not state.drawerPending then
                    local item = assert(catalog[index], "invalid panel selection")
                    state.drawerPending = { action = "add", panelType = item.type }
                end
            end),
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
    itemPath = itemPath or (listKey and { itemIndex } or nil)
    if groupKey then
        local _, _, module = state.handlers.editor.settings(state.session)
        for _, group in ipairs(module.drawerGroups or {}) do
            if group.key == groupKey then
                title = title .. " / " .. group.label
                break
            end
        end
    elseif listKey then
        local forms = state.handlers.editor.formFields(state.session) or {}
        for depth, index in ipairs(itemPath) do
            if type(index) == "number" then
                local itemLabel
                for _, field in ipairs(forms) do
                    local path = field.path or {}
                    if field.type == "table-list" and field.key == listKey and #path == depth - 1 then
                        local same = true
                        for part = 1, #path do
                            same = same and path[part] == itemPath[part]
                        end
                        if same then
                            itemLabel = field.itemLabel
                            break
                        end
                    end
                end
                title = title .. " / " .. (itemLabel or "Entry") .. " " .. index
            end
        end
    end
    local fields = fieldsFor(state, listKey, itemIndex, itemPath, groupKey)
    state.drawerListKey, state.drawerItemIndex, state.drawerGroupKey = listKey, itemIndex, groupKey
    state.drawerItemPath = itemPath
    state.drawerFields, state.drawerControls = fields, {}
    state.drawerBuild = 1
    state.drawerControlHeight = lvgl.UI_ELEMENT_HEIGHT or 32
    state.drawerPadding = math.floor(state.drawerControlHeight / 16 + 0.5)
    state.drawerRowHeight = state.drawerControlHeight + state.drawerPadding * 2
    state.drawerNextY = state.drawerPadding * 2
    state.drawerErrorHeight = math.floor(state.drawerControlHeight * 0.56 + 0.5)
    -- Native dialogs supply centering, 80%-screen dimensions, scrolling and RTN.
    drawer.settingsDialog(context, state, title, fields, function(field)
        return current(state, field)
    end, function(field, value)
        return writeField(state, field, value)
    end, function()
        local command = {
            action = (listKey or groupKey) and "parent" or "back",
            key = listKey,
            groupKey = listKey and groupKey or nil,
        }
        if itemPath and #itemPath > 1 then
            command.itemPath = state.handlers.editor.clone(itemPath)
            table.remove(command.itemPath)
            table.remove(command.itemPath)
        end
        return command
    end)
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
    local actions, values = {}, {}
    if not state.handlers.isEmpty(state.handlers.layoutName()) then
        actions[#actions + 1], values[#values + 1] = "save", state.debrief and "Save layout" or "Save"
    end
    actions[#actions + 1], values[#values + 1] = "save-as", state.debrief and "Save layout as..." or "Save as..."
    actions[#actions + 1], values[#values + 1] = "discard", "Discard changes"
    local generation = state.drawerGeneration
    if state.debrief then
        -- No grid stays behind a native menu, so RTN must return to the tile list.
        state.mode = "exit"
        state.nativeDrawer = assert(
            hostedDialog(context, state, {
                title = "Unsaved layout changes",
                close = function()
                    if generation == state.drawerGeneration then
                        state.nativeDrawer = nil
                        state.drawerPending = { action = "list" }
                    end
                end,
            }),
            "cannot open editor dialog"
        )
        local height = lvgl.UI_ELEMENT_HEIGHT or 32
        local width = math.floor(context.zone.w * 0.8) - 16
        for index, value in ipairs(values) do
            lvgl.button(state.nativeDrawer, {
                x = 4,
                y = 4 + (index - 1) * (height + 8),
                w = width,
                h = height,
                text = value,
                active = function()
                    return generation == state.drawerGeneration and not state.exitCommand
                end,
                press = function()
                    exitCommand(context, state, generation, { action = actions[index] })
                end,
            })
        end
        return
    end
    assert(type(lvgl.menu) == "function", "exit dialog requires EdgeTX Lua LVGL menu")
    state.mode = "menu"
    lvgl.menu({
        title = "Unsaved changes",
        values = values,
        get = function()
            return 1
        end,
        set = deferredSetter(context, state, generation, function(index)
            exitCommand(context, state, generation, { action = assert(actions[index], "invalid exit choice") })
        end),
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
                    state.nativeDrawer = nil
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
        text = state.debrief and "Save layout" or "Save",
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

local function relayout(state)
    state.settingsUi.relayout(state.drawerView)
end

local function refreshVisibility(state)
    relayout(state)
    local editor = state.handlers.editor
    for _, entry in ipairs(state.drawerControls or {}) do
        if entry.readNative then
            entry.readNative()
        end
        if entry.field.drawerGroup then
            entry.object:set({ text = editor.drawerSummary(state.session, entry.field.drawerGroup) })
        end
    end
end

local function fieldError(state, control, message)
    state.settingsUi.fieldError(state.drawerView, control, message)
end

--- Apply a queued `write` command of a settings dialog and refresh its controls.
function drawer.applyWrite(state, command)
    local view = state.drawerView
    local ok, err = view.writeValue(command.field, command.value)
    -- Return may dismiss the native dialog before its queued edit runs.
    -- Apply the value, but never refresh controls from a retired dialog.
    if ok and state.nativeDrawer then
        refreshVisibility(state)
    end
    if command.control and state.nativeDrawer then
        if not ok and command.control.readNative then
            command.control.readNative()
        end
        if command.control.kind == "textEdit" then
            command.control.object:set({ value = tostring(view.read(command.field) or "") })
        end
        fieldError(state, command.control, not ok and tostring(err) or nil)
    end
    return ok, err
end

function drawer.advance(context, state)
    if state.drawerBuild ~= nil then
        state.settingsUi.advance(state.drawerView)
        state.drawerBuild = state.drawerView.build
        state.drawerNextY = state.drawerView.nextY
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
        drawer.open(
            context,
            state,
            "configure",
            command.itemPath and command.key,
            nil,
            command.itemPath,
            command.groupKey
        )
    elseif command.action == "group" then
        drawer.open(context, state, "configure", nil, nil, nil, command.drawerGroup)
    elseif command.action == "item" then
        drawer.itemMenu(context, state, command.label, command.index, command.count, command.removable, {
            action = "entry",
            key = command.key,
            index = command.index,
            itemPath = command.itemPath,
            path = command.path,
        })
    elseif command.action == "entry" and command.choice == "edit" then
        drawer.open(context, state, "configure", command.key, command.index, command.itemPath)
    elseif command.action == "write" then
        ok, err = drawer.applyWrite(state, command)
    elseif command.action == "append" or command.action == "entry" then
        if command.action == "append" then
            ok, err = editor.appendItem(state.session, command.key, command.path)
        elseif command.choice == "delete" then
            ok, err = editor.removeItem(state.session, command.key, command.index, command.path)
        else
            ok, err = editor.moveItem(
                state.session,
                command.key,
                command.index,
                command.choice == "up" and -1 or 1,
                command.path
            )
        end
        if ok then
            local parent = command.path and editor.clone(command.path)
            if parent then
                table.remove(parent)
            end
            drawer.open(context, state, "configure", parent and command.key, nil, parent)
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
        state.handlers.logError(command.action .. (command.field and (" setting=" .. command.field.key) or ""), err)
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
