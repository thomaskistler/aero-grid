-- SPDX-License-Identifier: GPL-2.0-only

local drawer = { RUNTIME_API = 1 }
drawer.WORK_BOUNDS = {
    build = 1700, layout = 500, finish = 200,
    write = 1100, error = 500, module = 1500, snapshot = 800, summaries = 300, forms = 1850, items = 400,
    ["add-module"] = 1500, ["add-spans"] = 1000, ["add-cells"] = 600, ["add-place"] = 750, ["add-commit"] = 700, ["add-open"] = 1000,
    append = 1000, ["remove-item"] = 1000, remove = 500, navigate = 400, back = 400,
}
drawer.MEASURED_FORMS = {
    output = true, chart = true, ["flight-counter"] = true, ["flight-mode"] = true,
    ["flight-timer"] = true, ["host-diagnostics"] = true, ["link-status"] = true,
    metric = true, ["model-identity"] = true, navigation = true, ["rx-battery"] = true,
    ["service-probe"] = true, state = true, ["trim-panel"] = true, ["tx-battery"] = true,
}

local function blocked(state)
    return state.handlers.blocked and state.handlers.blocked()
end

local function legacyFields(setting, module)
    return setting and (
        setting.type == "table" and type(setting.fields) ~= "table"
        or setting.key == "sourceType" and #(module.drawerGroups or {}) > 0
    )
end

function drawer.workBound(state)
    if blocked(state) or state.drawerGroupKey or state.drawerUnmeasured then return nil end
    if state.drawerOpening then
        local opening = state.drawerOpening
        if opening.phase == "forms" and not opening.fields
            and legacyFields(opening.job.settings[opening.index], opening.job.module) then return nil end
        if opening.phase == "module" then
            local placement = state.session.draft.panels[state.session.selected]
            if not (placement and drawer.MEASURED_FORMS[placement.type]) then return nil end
        end
        return drawer.WORK_BOUNDS[state.drawerOpening.phase]
    elseif state.drawerRefresh then
        return state.drawerLayout and drawer.WORK_BOUNDS.layout
            or drawer.WORK_BOUNDS[state.drawerRefresh.phase]
    elseif state.drawerLayout then
        return drawer.WORK_BOUNDS.layout
    elseif state.drawerBuild then
        return state.drawerBuild <= #state.drawerFields and drawer.WORK_BOUNDS.build or drawer.WORK_BOUNDS.finish
    elseif state.drawerPending then
        local action = state.drawerPending.action
        if action == "parent" or action == "item" then
            return drawer.WORK_BOUNDS.navigate
        elseif action == "add" then
            local phase = state.drawerPending.phase or "module"
            -- Module validation and default copying scale with an unmeasured custom schema.
            if not drawer.MEASURED_FORMS[state.drawerPending.panelType]
                and (phase == "module" or phase == "commit") then return nil end
            return drawer.WORK_BOUNDS["add-" .. phase]
        end
        return drawer.WORK_BOUNDS[action]
    end
end

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

--- The live value of another field in the same entry, by its key.
---@param state table
---@param field table
---@param leaf string
---@return any
local function sibling(state, field, leaf)
    local path = field.path
    for _, other in ipairs(state.drawerFields or {}) do
        local otherPath = other.path
        if other.key == field.key and otherPath and path and #otherPath == #path and otherPath[#otherPath] == leaf then
            local same = true
            for index = 1, #path - 1 do
                if otherPath[index] ~= path[index] then
                    same = false
                    break
                end
            end
            if same then
                return current(state, other)
            end
        end
    end
    return nil
end

local function enqueue(state, action, generation)
    if
        state.nativeDrawer
        and (not generation or generation == state.drawerGeneration)
        and not state.drawerPending
        and not state.drawerBuild
        and not blocked(state)
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
    state.drawerLayout, state.drawerLayoutY, state.drawerBuildConfig = nil, nil, nil
    state.drawerRefresh = nil
    state.drawerOpening = nil
    state.drawerUnmeasured = nil
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
    state.drawerOpen = nil
    if state.drawerPending then state.drawerPending.job = nil end
    state.drawerPending = nil
    state.drawerDismiss = nil
end

local function firmwareSwitchName(name)
    local physical, position = string.match(name, "^(S[A-Z])([%^v%-])$")
    if physical then
        return physical .. (position == "^" and CHAR_UP or position == "v" and CHAR_DOWN or "-")
    end
    return name
end

local function switchSummary(name)
    assert(type(getSwitchIndex) == "function" and type(getSwitchName) == "function", "switch display APIs unavailable")
    local index = getSwitchIndex(firmwareSwitchName(name))
    if type(index) == "number" and index ~= 0 then
        local displayed = getSwitchName(index)
        if type(displayed) == "string" and displayed ~= "" then
            return displayed
        end
    end
    return name
end

local function entrySummary(item)
    if item.switch then
        return switchSummary(item.switch) .. ": " .. item.text .. " (" .. (item.background or "normal") .. ")"
    end
    local source = item.source
    -- A newly added entry has no source yet, and the firmware's getFieldInfo
    -- raises on nil inside this per-frame text callback.
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

local function fieldsFor(state, listKey, itemIndex, itemPath, groupKey, snapshot, omitRemove)
    local editor = state.handlers.editor
    local selected = itemPath or (listKey and { itemIndex } or {})
    local fields, config
    if groupKey then
        fields, config = editor.drawerFields(state.session, groupKey, snapshot)
    else
        fields, config = editor.formFields(state.session, { key = listKey, path = selected }, snapshot)
    end
    if not fields then
        error(config)
    end
    if groupKey then
        return fields, config
    end
    local result = {}
    for _, field in ipairs(fields) do
        local matches = not listKey or field.key == listKey
        if matches and #selected > 0 then
            for index, part in ipairs(selected) do
                matches = matches and field.path ~= nil and field.path[index] == part
            end
        end
        if matches and field.path then
            for index = #selected + 1, #field.path do
                if type(field.path[index]) == "number" then
                    matches = false
                end
            end
        end
        if matches and field.type == "table-list" then
            result[#result + 1] = {
                label = field.entryLabel or string.gsub(field.label, " entries$", ""),
                type = "section",
            }
            local items = config[field.key]
            for _, part in ipairs(field.path or {}) do
                items = items[part]
            end
            result[#result + 1] = { expandList = field, items = items }
        elseif matches and (listKey or not field.path) then
            field.label = field.entryLabel or field.label
            result[#result + 1] = field
        end
    end
    if omitRemove then
        return result, config
    elseif listKey then
        local path = editor.clone(selected)
        local index = table.remove(path)
        result[#result + 1] = {
            label = #selected > 1 and "Remove state" or "Remove entry",
            action = "remove-item",
            key = listKey,
            index = index,
            path = #path > 0 and path or nil,
        }
    else
        result[#result + 1] = { label = "Remove panel", action = "remove" }
    end
    return editor.orderFields(result, listKey ~= nil), config
end

local function returnCommand(editor, listKey, groupKey, itemPath)
    local command = {
        action = (listKey or groupKey) and "parent" or "back",
        key = listKey, groupKey = listKey and groupKey or nil,
    }
    if itemPath and #itemPath > 1 then
        command.itemPath = editor.clone(itemPath)
        table.remove(command.itemPath)
        table.remove(command.itemPath)
    end
    return command
end

function drawer.open(context, state, mode, listKey, itemIndex, itemPath, groupKey)
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
                if context.editorUi == state and generation == state.drawerGeneration
                    and not state.drawerPending and not blocked(state) then
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
    -- Module lookup/validation is its own charged turn after the dialog opens.
    -- Ineligible group drawers and selection errors keep the synchronous path.
    local snapshot
    if groupKey or not placement then
        local snapshotError
        snapshot, snapshotError = state.handlers.editor.startSettings(state.session)
        assert(snapshot, snapshotError)
    end
    state.drawerUnmeasured = not drawer.MEASURED_FORMS[placement.type]
    local title = placement.type
    for _, item in ipairs(state.handlers.editor.CATALOG) do
        if item.type == placement.type then
            title = item.label
            break
        end
    end
    itemPath = itemPath or (listKey and { itemIndex } or nil)
    if groupKey then
        for _, group in ipairs(snapshot.module.drawerGroups or {}) do
            if group.key == groupKey then
                title = title .. " / " .. group.label
                break
            end
        end
    elseif listKey then
        title = title .. " / " .. listKey .. " " .. itemPath[1]
    end
    if itemPath and #itemPath > 1 then
        title = title .. " / State " .. itemPath[#itemPath]
    end
    state.drawerListKey, state.drawerItemIndex, state.drawerGroupKey = listKey, itemIndex, groupKey
    state.drawerItemPath = itemPath
    state.drawerFields, state.drawerControls = {}, {}
    state.drawerBuild = 1
    state.drawerOpening = { phase = snapshot and "snapshot" or "module", job = snapshot, index = 1 }
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
                    state.drawerLayout, state.drawerLayoutY, state.drawerBuildConfig = nil, nil, nil
                    state.drawerRefresh = nil
                    state.drawerOpening = nil
                    local command = returnCommand(state.handlers.editor, listKey, groupKey, itemPath)
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
local function exitCommand(context, state, generation, command, closing)
    if context.editorUi == state and generation == state.drawerGeneration
        and not state.exitCommand and (closing or not blocked(state)) then
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
                    exitCommand(context, state, generation, { action = "exit" }, true)
                end
            end,
        }),
        "cannot open editor dialog"
    )
    local height = lvgl.UI_ELEMENT_HEIGHT or 32
    local width = math.floor(context.zone.w * 0.8) - 16
    local function active()
        return generation == state.drawerGeneration and state.nativeDrawer ~= nil
            and not state.exitCommand and not blocked(state)
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
            if generation == state.drawerGeneration and not blocked(state) then
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

local function visible(state, field)
    local condition = field.visibleWhen
    if not condition then
        return true
    end
    local config = state.drawerBuild and state.drawerBuildConfig
    if not config then
        local _, resolved = state.handlers.editor.settings(state.session)
        config = resolved
    end
    if type(condition) == "function" then
        return condition(config)
    end
    if type(condition) ~= "table" then
        return true
    end
    local matches = config[condition.key] == condition.value
    if condition.invert then
        return not matches
    end
    return matches
end

local function relayout(state, first, last, y)
    y = y or state.drawerPadding * 2
    local controls = state.drawerControls or {}
    for index = first or 1, last or #controls do
        local entry = controls[index]
        local show = visible(state, entry.field)
        local visibility = show and lvgl.show or lvgl.hide
        visibility(entry.row)
        if show then
            entry.row:set({ y = y })
            y = y + entry.height
        end
        if entry.errorShown and show then
            entry.errorLabel:set({ y = y })
            lvgl.show(entry.errorLabel)
            y = y + state.drawerErrorHeight
        else
            lvgl.hide(entry.errorLabel)
        end
    end
    return y
end

local function refreshVisibility(state)
    state.drawerRefresh = { phase = "snapshot", index = 1 }
    state.drawerBuild = #state.drawerFields + 1
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
                and not blocked(state)
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
        -- A setting may name its stored values for display; YAML keeps the value.
        options.title, options.values = field.label, field.choiceLabels or field.choices
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
                value = firmwareSwitchName(value)
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
            if value == 0 and not field.required then
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
        -- A field bounded by two others, such as a threshold by its range. The
        -- native control fixes its limits when built, so the live bounds are
        -- read on every step instead: one step below the low bound is unset,
        -- and anything outside the bounds shows and stores as unset.
        local function bounds()
            if not field.within then
                return nil
            end
            local low = sibling(state, field, field.within[1])
            local high = sibling(state, field, field.within[2])
            if type(low) ~= "number" or type(high) ~= "number" then
                return nil
            end
            if high < low then
                low, high = high, low
            end
            return math.floor(low * scale + 0.5), math.floor(high * scale + 0.5)
        end
        local function outside(value)
            local low, high = bounds()
            return low ~= nil and (value < low or value > high)
        end
        options.get = function()
            local value = get()
            local low = bounds()
            if value ~= nil then
                value = math.floor(value * scale + 0.5)
            end
            if low and (value == nil or outside(value)) then
                return low - 1
            end
            if value == nil then
                return unset or 0
            end
            return value
        end
        options.set = function(value)
            if unset and (value <= unset or outside(value)) then
                set(nil)
                return
            end
            local step = field.step or (1 / scale)
            set(math.floor(value / scale / step + 0.5) * step)
        end
        if scale ~= 1 or unset then
            options.display = function(value)
                if unset and (value <= unset or outside(value)) then
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
    if options.set then
        local setter = options.set
        options.set = function(value)
            if not blocked(state) then setter(value) end
        end
    end
    control = assert(lvgl[kind](row, options), "cannot create native " .. kind)
    local errorLabel = lvgl.label(state.nativeDrawer, {
        x = 12,
        y = y + rowHeight,
        w = width - 8,
        h = state.drawerErrorHeight,
        text = "",
        font = function() return SMLSIZE end,
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
    if not visible(state, field) then
        lvgl.hide(row)
    end
end

local function fieldError(state, control, message)
    control.errorLabel:set({ text = message or "" })
    if message then
        lvgl.show(control.errorLabel)
    else
        lvgl.hide(control.errorLabel)
    end
    control.errorShown = message ~= nil
    refreshVisibility(state)
end

local function reopen(state, listKey, itemIndex, itemPath, groupKey)
    if state.drawerDismiss then return end
    closeDialog(state)
    state.drawerOpen = {
        mode = "configure", selected = state.session.selected, listKey = listKey,
        itemIndex = itemIndex, itemPath = itemPath, groupKey = groupKey,
        cancel = returnCommand(state.handlers.editor, listKey, groupKey, itemPath),
    }
end

local function appendField(state, opening, field)
    local key = state.drawerListKey and field.path and field.path[#field.path] or field.key
    if key == "label" and not state.drawerGroupKey and not opening.labelFirst then
        table.insert(state.drawerFields, 1, field)
        opening.labelFirst = true
    else
        state.drawerFields[#state.drawerFields + 1] = field
    end
end

local function advanceList(state, opening)
    local list = opening.list
    local field, item = list.field, list.items[list.index]
    if item == nil then
        appendField(state, opening, {
            label = "+", action = "append", key = field.key, path = field.path,
            active = field.value < (field.maxItems or 3),
        })
        opening.list, opening.phase = nil, "forms"
        return
    end
    local summary
    if item.states then
        list.parts, list.stateIndex = list.parts or {}, list.stateIndex or 1
        local condition = item.states[list.stateIndex]
        if condition then
            list.parts[#list.parts + 1] = switchSummary(condition.switch) .. ": " .. condition.text
            list.stateIndex = list.stateIndex + 1
            return
        end
        summary = table.concat(list.parts, " / ")
    else
        summary = entrySummary(item)
    end
    local title = item
    if type(item) == "table" then
        title = item.label
        if title == nil or title == "" then title = item.source end
    end
    if title == nil or title == "" then title = (field.itemLabel or "Entry") .. " " .. list.index end
    local path = state.handlers.editor.clone(field.path or {})
    path[#path + 1] = list.index
    appendField(state, opening, {
        label = tostring(title), text = function() return summary end, action = "item", key = field.key,
        index = list.index, itemPath = path,
    })
    list.index = list.index + 1
    list.parts, list.stateIndex = nil, nil
end

function drawer.advance(context, state)
    if blocked(state) then return false end
    if state.drawerOpening then
        local opening, editor = state.drawerOpening, state.handlers.editor
        if opening.phase == "module" then
            local snapshot, snapshotError = editor.startSettings(state.session)
            if not snapshot then
                closeDialog(state)
                error(snapshotError, 0)
            end
            opening.job, opening.phase = snapshot, "snapshot"
        elseif opening.phase == "snapshot" then
            if editor.advanceSettings(opening.job) then
                opening.phase = "forms"
                state.drawerBuildConfig = opening.job.config
            end
        elseif opening.phase == "forms" then
            if opening.fields then
                local field = opening.fields[opening.fieldIndex]
                if field then
                    opening.fieldIndex = opening.fieldIndex + 1
                    if field.expandList then
                        opening.list = { field = field.expandList, items = field.items, index = 1 }
                        opening.phase = "items"
                    else
                        appendField(state, opening, field)
                    end
                else
                    opening.fields = nil
                    if opening.finishing then state.drawerOpening = nil end
                end
                return true
            end
            local job = opening.job
            local setting
            if state.drawerGroupKey then
                local group = assert(job.groups[state.drawerGroupKey], "unknown settings drawer " .. state.drawerGroupKey)
                local key = (group.fields or {})[opening.index]
                setting = key and job.byKey[key]
                if key and not setting then
                    opening.index = opening.index + 1
                    return true
                end
            else
                setting = job.settings[opening.index]
            end
            local snapshot = {
                config = job.config, module = job.module, groups = job.groups,
                settings = setting and { setting } or {},
                groupIndex = state.drawerGroupKey and opening.index,
            }
            state.drawerUnmeasured = state.drawerUnmeasured or legacyFields(setting, job.module)
            local fields = fieldsFor(
                state, state.drawerListKey, state.drawerItemIndex, state.drawerItemPath, state.drawerGroupKey,
                snapshot, setting ~= nil
            )
            opening.fields, opening.fieldIndex = fields, 1
            if setting then
                opening.index = opening.index + 1
            else
                opening.finishing = true
            end
        elseif opening.phase == "items" then
            advanceList(state, opening)
        else
            error("invalid drawer opening phase: " .. tostring(opening.phase))
        end
        return true
    end
    if state.drawerLayout then
        local last = math.min(#state.drawerControls, state.drawerLayout + 3)
        state.drawerLayoutY = relayout(state, state.drawerLayout, last, state.drawerLayoutY)
        state.drawerLayout = last + 1
        if state.drawerLayout > #state.drawerControls then
            state.drawerLayout, state.drawerLayoutY = nil, nil
            if not state.drawerRefresh then
                state.drawerBuild, state.drawerBuildConfig = nil, nil
            end
        end
        return true
    end
    if state.drawerRefresh then
        local refresh, editor = state.drawerRefresh, state.handlers.editor
        if refresh.phase == "snapshot" then
            if not refresh.job then
                local job, message = editor.startSettings(state.session)
                assert(job, message)
                refresh.job = job
            else
                local done, config, module, groups = editor.advanceSettings(refresh.job)
                if done then
                    state.drawerBuildConfig, refresh.module, refresh.groups = config, module, groups
                    state.drawerLayout, refresh.phase = 1, "summaries"
                    refresh.job = nil
                end
            end
        elseif refresh.phase == "summaries" then
            for _ = 1, 4 do
                local entry = state.drawerControls[refresh.index]
                if not entry then
                    state.drawerRefresh, state.drawerBuild, state.drawerBuildConfig = nil, nil, nil
                    break
                end
                refresh.index = refresh.index + 1
                if entry.field.drawerGroup then
                    entry.object:set({
                        text = editor.drawerSummary(
                            state.session, entry.field.drawerGroup, state.drawerBuildConfig, refresh.module, refresh.groups
                        ),
                    })
                    break
                end
            end
        else
            error("invalid drawer refresh phase: " .. tostring(refresh.phase))
        end
        return true
    end
    if state.drawerBuild ~= nil then
        if state.drawerBuild <= #state.drawerFields then
            addControl(context, state, state.drawerFields[state.drawerBuild], state.drawerBuild)
        else
            state.drawerLayout = 1
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
        reopen(state, command.itemPath and command.key, nil, command.itemPath, command.groupKey)
    elseif command.action == "group" then
        reopen(state, nil, nil, nil, command.drawerGroup)
    elseif command.action == "item" then
        reopen(state, command.key, command.index, command.itemPath)
    elseif command.action == "write" then
        ok, err = writeField(state, command.field, command.value)
        -- Return may dismiss the native dialog before its queued edit runs.
        -- Apply the value, but never refresh controls from a retired dialog.
        if ok and state.nativeDrawer then
            refreshVisibility(state)
        end
        if command.control and state.nativeDrawer then
            if command.control.kind == "textEdit" then
                command.control.object:set({ value = tostring(current(state, command.field) or "") })
            end
            if ok then fieldError(state, command.control, nil) end
        end
    elseif command.action == "append" then
        if not command.job then
            command.job, err = editor.startAppendItem(state.session, command.key, command.path)
            if command.job then
                state.drawerPending = command
                return true
            end
            ok = false
        else
            local done
            done, ok, err = editor.advanceAppendItem(command.job)
            if not done then
                state.drawerPending = command
                return true
            end
            command.job = nil
        end
        if ok then
            local parent = command.path and editor.clone(command.path)
            if parent then
                table.remove(parent)
            end
            reopen(state, parent and command.key, nil, parent)
        end
    elseif command.action == "remove-item" then
        ok, err = editor.removeItem(state.session, command.key, command.index, command.path)
        if ok then
            local parent = command.path and editor.clone(command.path)
            if parent then
                table.remove(parent)
            end
            reopen(state, parent and command.key, nil, parent)
        end
    elseif command.action == "add" then
        local phase, session = command.phase or "module", state.session
        if phase ~= "module" and (session.draft ~= command.draft or #session.draft.panels ~= command.count) then
            ok, err = false, "layout changed while adding a panel"
        elseif phase == "module" then
            command.module, err = editor.addModule(session, command.panelType)
            ok = command.module and true or false
            command.phase, command.draft, command.count = "spans", session.draft, #session.draft.panels
        elseif phase == "spans" then
            command.candidates, ok = editor.addCandidates(session, command.module), true
            command.phase = "cells"
        elseif phase == "cells" then
            ok = true
            if editor.advanceOccupancy(command.candidates, session.draft.panels, 4) then
                command.phase = "place"
            end
        elseif phase == "place" then
            local placement
            placement, err = editor.advancePlacement(command.candidates, 2)
            ok = placement ~= false
            if placement then
                command.placement, command.candidates, command.phase = placement, nil, "commit"
            end
        elseif phase == "commit" then
            ok, err = editor.commitAdd(session, command.panelType, command.module, command.placement)
            command.phase = "open"
            command.count = #session.draft.panels
        else
            drawer.open(context, state, "configure")
            ok = true
            command = nil
        end
        if ok and command then
            state.drawerPending = command
            return true
        end
    elseif command.action == "remove" then
        ok, err = editor.remove(state.session)
        if ok then
            drawer.close(state)
            state.mode = "menu"
            state.previewPending = true
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
