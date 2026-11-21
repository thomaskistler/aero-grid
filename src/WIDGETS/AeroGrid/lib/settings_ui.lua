-- SPDX-License-Identifier: GPL-2.0-only

local ui = { RUNTIME_API = 1 }

local function retireHost(view)
    if view.host then
        view.host:clear()
        lvgl.hide(view.host)
        view.host = nil
    end
end

function ui.close(view)
    if not view then
        return
    end
    local dialog = view.dialog
    view.dialog, view.build = nil, nil
    if dialog then
        lvgl.close(dialog)
    end
    retireHost(view)
end

function ui.open(context, parent, properties, options)
    local view = options or {}
    view.controls = {}
    view.height = lvgl.UI_ELEMENT_HEIGHT or 32
    view.width = math.floor(context.zone.w * 0.8) - 16
    view.padding = view.padding or math.floor(view.height / 16 + 0.5)
    view.nextY = view.padding * 2
    view.rowHeight = view.rowHeight or view.height + view.padding * 2
    view.controlFraction = view.controlFraction or 0.48
    view.controlInset = view.controlInset or 8
    view.build = view.fields and 1 or nil
    local closed = properties.close
    properties.close = function()
        if view.dialog then
            -- RTN deletes the native children after this callback.
            view.dialog:clear()
            view.dialog, view.build = nil, nil
            retireHost(view)
            if closed then
                closed()
            end
        end
    end
    view.host = lvgl.box(parent, { x = 0, y = 0, w = 0, h = 0 })
    local attempted, result, failure
    lvgl.box(view.host, {
        x = 0,
        y = 0,
        w = 0,
        h = 0,
        visible = function()
            if not attempted then
                attempted = true
                local ok, value = pcall(lvgl.dialog, properties)
                if ok then
                    result = value
                else
                    failure = value
                end
            end
            return true
        end,
    })
    if failure then
        retireHost(view)
        error(failure, 0)
    end
    if not attempted then
        attempted = true
        retireHost(view)
        context.nativeDialogsCreated = true
        result = lvgl.dialog(properties)
    end
    if not result then
        retireHost(view)
        error("cannot open settings dialog", 0)
    end
    view.dialog = result
    return view
end

function ui.defer(apply, enqueue)
    return function(value)
        return enqueue(apply, value)
    end
end

function ui.control(view, parent, kind, properties)
    local read
    local value
    if properties.get then
        local get = properties.get
        value = get()
        properties.get = function()
            return value
        end
        read = function()
            value = get()
        end
    end
    if properties.set and view.enqueue then
        local apply = properties.set
        properties.set = function(selected)
            if view.enqueue(apply, selected) and kind == "toggle" then
                value = selected ~= 0 and selected ~= false and 1 or 0
            end
        end
    end
    return assert(lvgl[kind](parent, properties), "cannot create native " .. kind), read
end

function ui.description(view, text)
    local lines, line = {}, ""
    for word in string.gmatch(text, "%S+") do
        local candidate = line == "" and word or line .. " " .. word
        if line ~= "" and lcd.sizeText(candidate, SMLSIZE) > view.width - 4 then
            lines[#lines + 1], line = line, word
        else
            line = candidate
        end
    end
    lines[#lines + 1] = line
    local _, lineHeight = lcd.sizeText("Ag", SMLSIZE)
    local height = #lines * (lineHeight + 2)
    lvgl.label(view.dialog, {
        x = 4,
        y = view.nextY,
        w = view.width,
        h = height,
        text = table.concat(lines, "\n"),
        font = function()
            return SMLSIZE
        end,
    })
    view.nextY = view.nextY + height + 4
end

local function shown(view, field, config)
    local condition = field.visibleWhen
    if not condition then
        return true
    end
    if type(condition) == "function" then
        return condition(config)
    end
    if type(condition) ~= "table" then
        return true
    end
    local matches = config[condition.key] == condition.value
    return condition.invert and not matches or not condition.invert and matches
end

local function position(view, entry, config, y)
    local visible = shown(view, entry.field, config)
    if entry.visible ~= visible then
        local visibility = visible and lvgl.show or lvgl.hide
        visibility(entry.row)
        entry.visible = visible
    end
    if visible then
        if entry.y ~= y then
            entry.row:set({ y = y })
            entry.y = y
        end
        y = y + entry.height
    end
    if entry.errorLabel then
        local errorVisible = entry.errorShown == true and visible
        if errorVisible then
            if entry.errorY ~= y then
                entry.errorLabel:set({ y = y })
                entry.errorY = y
            end
        end
        if entry.errorVisible ~= errorVisible then
            local visibility = errorVisible and lvgl.show or lvgl.hide
            visibility(entry.errorLabel)
            entry.errorVisible = errorVisible
        end
        if errorVisible then
            y = y + view.errorHeight
        end
    end
    return y
end

function ui.relayout(view)
    local y, config = view.padding * 2, nil
    for _, entry in ipairs(view.controls) do
        if entry.field.visibleWhen and not config then
            config = view.config()
        end
        y = position(view, entry, config, y)
    end
    view.nextY = y
end

function ui.fieldError(view, entry, message)
    if entry.errorMessage == message then
        return
    end
    entry.errorMessage = message
    entry.errorLabel:set({ text = message or "" })
    local shown = message ~= nil
    if (entry.errorShown == true) ~= shown then
        entry.errorShown = shown
        ui.relayout(view)
    end
end

function ui.row(view, field)
    if field.section then
        if #view.controls > 0 then
            view.nextY = view.nextY + 12
        end
        lvgl.label(view.dialog, {
            x = 4,
            y = view.nextY,
            w = view.width,
            h = view.height,
            text = field.section,
            font = function()
                return _G.BOLD
            end,
        })
        view.nextY = view.nextY + view.height
    end
    if field.description then
        ui.description(view, field.description)
    end
    local fullWidth = field.fullWidth == true
        or field.action == "remove"
        or field.action == "remove-item"
        or field.action == "append"
        or field.action == "fill"
        or field.type == "section"
    local rowHeight = field.type == "section" and math.floor(view.height * 0.625) or view.rowHeight
    local row = lvgl.setting(view.dialog, {
        x = 4,
        y = view.nextY,
        w = view.width,
        h = rowHeight,
        title = (fullWidth or field.action == "item") and "" or field.label,
    })
    local controlX = fullWidth and 0
        or math.floor(view.width * (field.action == "item" and 0.28 or view.controlFraction))
    if field.action == "item" and not fullWidth then
        lvgl.label(row, {
            x = 0,
            y = math.floor((view.height - view.fontHeight()) / 2),
            w = controlX - 8,
            h = view.height,
            text = field.label,
        })
    end
    return {
        row = row,
        field = field,
        height = rowHeight,
        y = view.nextY,
    }, {
        x = controlX,
        y = 0,
        w = (view.controlWidthFraction and math.floor(view.width * view.controlWidthFraction) or view.width - controlX)
            - view.controlInset,
        h = view.height,
        active = function()
            return view.dialog ~= nil and view.build == nil and view.active() and field.active ~= false
        end,
    }
end

function ui.switchName(name)
    local physical, position = string.match(name, "^(S[A-Z])([%^v%-])$")
    if physical then
        return physical .. (position == "^" and CHAR_UP or position == "v" and CHAR_DOWN or "-")
    end
    return name
end

function ui.switchSummary(name)
    assert(type(getSwitchIndex) == "function" and type(getSwitchName) == "function", "switch display APIs unavailable")
    local index = getSwitchIndex(ui.switchName(name))
    if type(index) == "number" and index ~= 0 then
        local displayed = getSwitchName(index)
        if type(displayed) == "string" and displayed ~= "" then
            return displayed
        end
    end
    return name
end

local function sibling(view, field, leaf)
    local path = field.path
    for _, other in ipairs(view.fields) do
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
                return view.read(other)
            end
        end
    end
end

local function fieldProperties(view, field, entry, options)
    local function get()
        return view.read(field)
    end
    local function set(value)
        view.write(field, value, entry)
    end
    local leaf = field.path and field.path[#field.path] or field.key
    local kind
    if field.type == "section" then
        kind = "label"
        options.active, options.text, options.h = nil, field.label, entry.height
        options.font = function()
            return SMLSIZE
        end
    elseif field.action then
        kind = "button"
        options.text = field.text or field.label
        options.press = function()
            view.action(field)
        end
    elseif field.choices then
        kind = "choice"
        options.title, options.values = field.label, field.choiceLabels or field.choices
        options.get = function()
            for index, value in ipairs(field.choices) do
                if value == get() then
                    return index
                end
            end
            return 1
        end
        options.set = function(index)
            set(field.choices[index])
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
        local function fieldId(name)
            local info = getFieldInfo(name)
            return type(info) == "table" and type(info.id) == "number" and info.id or nil
        end
        options.get = function()
            local value = get()
            if value == nil or value == "" then
                return 0
            end
            if kind == "switch" and type(value) == "string" then
                value = ui.switchName(value)
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
                view.report("Cannot resolve selected " .. leaf, entry)
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
                    view.report("Lua cannot read source " .. plain, entry)
                end
            end
        end
        if leaf == "motorSource" then
            options.filter = lvgl.SRC_CHANNEL
        end
    elseif leaf == "timer" then
        kind, options.get, options.set = "timer", get, set
    elseif field.type == "number" and (leaf == "rangeMin" or leaf == "rangeMax") then
        kind, options.value, options.length = "textEdit", tostring(get() or ""), 32
        options.set = function(text)
            if string.match(text, "^%s*$") then
                set(nil)
                return
            end
            local value = tonumber(text)
            if not value or value ~= value or value == math.huge or value == -math.huge then
                view.report(field.label .. " must be a finite number", entry)
                return
            end
            set(value)
        end
    elseif field.type == "number" then
        kind = "numberEdit"
        local scale = field.step and field.step < 1 and math.floor(1 / field.step + 0.5) or 1
        if ((get() or 0) * scale) % 1 ~= 0 then
            scale = 100
        end
        options.min, options.max = math.floor((field.min or -100000) * scale), math.floor((field.max or 100000) * scale)
        local unset = field.empty and options.min - 1
        if unset then
            options.min = unset
        end
        local function bounds()
            if not field.within then
                return nil
            end
            local low, high = sibling(view, field, field.within[1]), sibling(view, field, field.within[2])
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
            local value, low = get(), bounds()
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
            if value == "" and field.path and not field.required then
                value = nil
            end
            set(value)
        end
    end
    return kind, options
end

function ui.add(view, entry, kind, properties)
    entry.kind = kind
    entry.object, entry.readNative = ui.control(view, entry.row, kind, properties)
    if view.errorHeight then
        entry.errorLabel = lvgl.label(view.dialog, {
            x = 12,
            y = view.nextY + entry.height,
            w = view.width - 8,
            h = view.errorHeight,
            text = "",
            font = function()
                return SMLSIZE
            end,
            color = view.errorColor,
        })
        entry.errorY = view.nextY + entry.height
    end
    view.controls[#view.controls + 1] = entry
    local config = entry.field.visibleWhen and view.config() or nil
    view.nextY = position(view, entry, config, view.nextY) + (view.gap or 0)
    return entry
end

function ui.advance(view)
    local field = view.fields[view.build]
    if not field then
        view.build = nil
        return
    end
    local entry, properties = ui.row(view, field)
    local kind
    if view.nativeProperties then
        kind, properties = field.kind, view.nativeProperties(field, properties)
    else
        kind, properties = fieldProperties(view, field, entry, properties)
    end
    ui.add(view, entry, kind, properties)
    view.build = view.build + 1
    return field, entry
end

function ui.cost(view, capacity, finish)
    local field = view.fields[view.build]
    return math.min(field and (field.slots or 1) or finish or 1, capacity)
end

return ui
