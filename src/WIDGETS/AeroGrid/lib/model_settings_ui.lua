-- SPDX-License-Identifier: GPL-2.0-only

local ui = { RUNTIME_API = 1 }

local fields = {
    {
        key = "armed",
        label = "Arm switch",
        kind = "switch",
        section = "Model arming",
        description = "Used by charts, navigation and flight detection",
    },
    {
        key = "motorSource",
        label = "Motor channel",
        kind = "source",
        section = "Flight detection",
        description = "Detects when a flight begins and ends.",
    },
    { key = "motorReversed", label = "Reverse motor", kind = "toggle" },
    { key = "requireReceiver", label = "Require receiver", kind = "toggle" },
    { key = "minMotorPercent", label = "Motor threshold (%)", kind = "numberEdit", min = 0, max = 99 },
    { key = "minFlightDuration", label = "Start detection window (s)", kind = "numberEdit", min = 1, max = 3600 },
    {
        key = "disarmDuration",
        label = "End detection window (s)",
        kind = "numberEdit",
        min = 1,
        max = 3600,
    },
    { key = "smartDetection", label = "Smart detection", kind = "toggle" },
    {
        key = "flightSwitch",
        label = "Flight status switch",
        kind = "choice",
        description = "On during a detected flight. Use for your own special functions. Choose a dedicated Sticky logical switch, or None.",
    },
    {
        key = "sessionReset",
        label = "Session reset switch",
        kind = "switch",
        section = "Session reset",
        description = "Clears session data across all dashboards. Keeps flight totals and radio data.",
    },
}

local function outputAvailable(index)
    if index == 1 then
        return true
    end
    local definition = model.getLogicalSwitch(index - 2)
    return definition ~= nil and definition.func ~= 0
end

local function active(context, state)
    return context.modelSettingsUi == state
        and state.dialog ~= nil
        and not state.pending
        and (not state.handlers.modelFilename or state.handlers.modelFilename() == state.modelFilename)
        and (not state.handlers.fullscreen or state.handlers.fullscreen())
end

local function retireHost(state)
    if state.host then
        state.host:clear()
        lvgl.hide(state.host)
        state.host = nil
    end
end

function ui.close(context)
    local state = context.modelSettingsUi
    if not state then
        return
    end
    context.modelSettingsUi = nil
    state.generation = state.generation + 1
    local dialog = state.dialog
    state.dialog = nil
    if dialog then
        lvgl.close(dialog)
    end
    retireHost(state)
    state.screen:clear()
    lvgl.hide(state.screen)
end

local function queue(context, state, action)
    if active(context, state) then
        state.pending = action
    end
end

local function dialog(context, state)
    local generation = state.generation
    local properties = {
        title = "Model settings",
        close = function()
            if context.modelSettingsUi == state and state.generation == generation and state.dialog then
                state.dialog:clear()
                state.dialog = nil
                retireHost(state)
                state.closing = true
            end
        end,
    }
    state.host = lvgl.box(state.screen, { x = 0, y = 0, w = 0, h = 0 })
    local attempted, result
    lvgl.box(state.host, {
        x = 0,
        y = 0,
        w = 0,
        h = 0,
        visible = function()
            if not attempted then
                attempted = true
                result = lvgl.dialog(properties)
            end
            return true
        end,
    })
    if not attempted then
        attempted = true
        retireHost(state)
        context.nativeDialogsCreated = true
        result = lvgl.dialog(properties)
    end
    return assert(result, "cannot open Model settings dialog")
end

function ui.open(context, document, handlers)
    ui.close(context)
    local config = assert(handlers.flightConfig or context.flightConfig, "flight configuration helper unavailable")
    local state = {
        modelFilename = document.modelFilename,
        revision = document.revision,
        values = config.resolve(document.flight or {}),
        armed = document.armed,
        sessionReset = document.sessionReset,
        armedConfig = assert(handlers.armedConfig or context.armedConfig, "arming configuration helper unavailable"),
        armControl = handlers.armControl or context.armControl,
        config = config,
        handlers = handlers,
        generation = 1,
        build = 1,
        controls = {},
        width = math.floor(context.zone.w * 0.8) - 16,
        height = lvgl.UI_ELEMENT_HEIGHT or 32,
        screen = lvgl.box(handlers.parent or context.root, { x = 0, y = 0, w = context.zone.w, h = context.zone.h }),
    }
    context.modelSettingsUi = state
    state.dialog = dialog(context, state)
    state.status = lvgl.label(state.dialog, {
        x = 4,
        y = 4,
        w = state.width,
        h = state.height * 2,
        text = document.status or "",
        font = function()
            return SMLSIZE
        end,
    })
    lvgl.hide(state.status)
    local _, lineHeight = lcd.sizeText("Ag", SMLSIZE)
    state.smartStatusHeight = (lineHeight + 2) * 3
    state.smartStatus = lvgl.label(state.dialog, {
        x = 4,
        y = 4,
        w = state.width,
        h = state.smartStatusHeight,
        text = function()
            if not state.values.smartDetection then
                return "Smart off: standard motor detection."
            end
            return (handlers.smartStatus and handlers.smartStatus()) or "Checking Smart detection sensors."
        end,
        font = function()
            return SMLSIZE
        end,
    })
    lvgl.hide(state.smartStatus)
    state.nextY = 4
    return state
end

local function description(state, text)
    local lines, line = {}, ""
    for word in string.gmatch(text, "%S+") do
        local candidate = line == "" and word or line .. " " .. word
        if line ~= "" and lcd.sizeText(candidate, SMLSIZE) > state.width - 4 then
            lines[#lines + 1], line = line, word
        else
            line = candidate
        end
    end
    lines[#lines + 1] = line
    local _, lineHeight = lcd.sizeText("Ag", SMLSIZE)
    local height = #lines * (lineHeight + 2)
    lvgl.label(state.dialog, {
        x = 4,
        y = state.nextY,
        w = state.width,
        h = height,
        text = table.concat(lines, "\n"),
        font = function()
            return SMLSIZE
        end,
    })
    state.nextY = state.nextY + height + 4
end

local function buildField(context, state, field)
    if field.section then
        if state.build > 1 then
            state.nextY = state.nextY + 12
        end
        lvgl.label(state.dialog, {
            x = 4,
            y = state.nextY,
            w = state.width,
            h = state.height,
            text = field.section,
            font = function()
                return _G.BOLD
            end,
        })
        state.nextY = state.nextY + state.height
        description(state, field.description)
    elseif field.description then
        description(state, field.description)
    end
    local row = lvgl.setting(state.dialog, {
        x = 4,
        y = state.nextY,
        w = state.width,
        h = state.height + 4,
        title = field.label,
    })
    local properties = {
        x = math.floor(state.width * 0.52),
        y = 0,
        w = math.floor(state.width * 0.48) - 4,
        h = state.height,
        min = field.min,
        max = field.max,
        active = function()
            return active(context, state) and not state.build
        end,
        get = function()
            if field.kind == "switch" then
                local condition = state[field.key]
                return condition and condition ~= "" and state.armControl:switchIndex(condition) or 0
            end
            local value = state.values[field.key]
            if field.kind == "toggle" then
                return value and 1 or 0
            end
            if field.key == "flightSwitch" then
                return value ~= "" and tonumber(string.sub(value, 2)) + 1 or 1
            end
            if field.kind == "source" then
                if type(value) == "number" then
                    return value
                end
                local info = getFieldInfo(value)
                return type(info) == "table" and info.id or getSourceIndex(value) or 0
            end
            if field.kind == "numberEdit" then
                return math.max(field.min, math.min(field.max, math.floor(value + 0.5)))
            end
            return value
        end,
        set = function(value)
            local function commit(command)
                state.pending = command
            end
            if field.kind == "switch" then
                local ok, name = pcall(state.armedConfig.name, value, state.armControl)
                if ok then
                    commit({ key = field.key, value = name })
                elseif state.dialog then
                    state.status:set({ text = "Choose a physical switch position or logical switch (L01-L64)" })
                end
                return
            end
            if field.kind == "toggle" then
                value = value ~= 0 and value ~= false
            elseif field.key == "flightSwitch" then
                if
                    type(value) ~= "number"
                    or value % 1 ~= 0
                    or value < 1
                    or value > 65
                    or not outputAvailable(value)
                then
                    if state.dialog then
                        state.status:set({ text = "Choose a configured logical switch (L01-L64), or None" })
                    end
                    return
                end
                value = value == 1 and "" or string.format("L%02d", value - 1)
            elseif field.kind == "source" then
                local name
                for channel = 1, 32 do
                    local candidate = "ch" .. channel
                    local info = getFieldInfo(candidate)
                    if type(info) == "table" and info.id == value then
                        name = candidate
                        break
                    end
                end
                if not name then
                    if state.dialog then
                        state.status:set({ text = "Cannot resolve selected motor channel" })
                    end
                    return
                end
                value = string.lower(name)
            elseif field.kind == "numberEdit" then
                value = math.floor(value + 0.5)
            end
            commit({ key = field.key, value = value })
        end,
    }
    if field.kind == "source" then
        properties.filter = lvgl.SRC_CHANNEL
    elseif field.key == "flightSwitch" then
        -- EdgeTX's switch toolbar overlaps on short lists; outputs need no inversion.
        properties.title = field.label
        properties.values = { "None" }
        local available = { true }
        for number = 1, 64 do
            properties.values[number + 1] = string.format("L%02d", number)
            available[number + 1] = outputAvailable(number + 1)
        end
        properties.filter = function(index)
            return available[index] == true
        end
    end
    local apply = properties.set
    properties.set = function(value)
        queue(context, state, { apply = apply, value = value })
    end
    local getValue = properties.get
    local value = getValue()
    properties.get = function()
        return value
    end
    state.readControls = state.readControls or {}
    state.readControls[field.key] = function()
        value = getValue()
    end
    state.controls[field.key] = lvgl[field.kind](row, properties)
    state.nextY = state.nextY + state.height + 6
end

function ui.cost(context)
    local state, capacity = context.modelSettingsUi, context.scheduler.capacity
    local field = state and state.build and fields[state.build]
    -- Switch controls resolve firmware names; the output list also builds 65 choices.
    if
        state
        and state.build
        and not state.closing
        and not (field and (field.kind == "switch" or field.key == "flightSwitch"))
    then
        return math.min(3, capacity)
    end
    return capacity
end

function ui.advance(context)
    local state = context.modelSettingsUi
    if not state then
        return false
    end
    if
        (state.handlers.modelFilename and state.handlers.modelFilename() ~= state.modelFilename)
        or (state.handlers.fullscreen and not state.handlers.fullscreen())
    then
        ui.close(context)
        if state.handlers.cancel then
            state.handlers.cancel()
        end
        return true
    end
    if state.closing and not state.pending then
        ui.close(context)
        if state.handlers.cancel then
            state.handlers.cancel()
        end
        return true
    end
    if state.build then
        local field = fields[state.build]
        if field then
            buildField(context, state, field)
            if field.key == "smartDetection" then
                state.smartStatus:set({ y = state.nextY })
                lvgl.show(state.smartStatus)
                state.nextY = state.nextY + state.smartStatusHeight + 4
            end
            state.build = state.build + 1
        else
            state.nextY = state.nextY + 12
            state.status:set({ y = state.nextY })
            lvgl.show(state.status)
            state.build = nil
        end
        return true
    end
    local command = state.pending
    if not command then
        return false
    end
    state.pending = nil
    if command.apply then
        command.apply(command.value)
        return true
    end
    local values, armed, sessionReset = state.config.resolve(state.values), state.armed, state.sessionReset
    if command.key == "sessionReset" then
        sessionReset = command.value
    elseif command.key == "armed" then
        armed = command.value
    else
        values[command.key] = command.value
    end
    local errors = state.config.validate(values)
    if #errors > 0 then
        local message = table.concat(errors, "; ")
        if state.dialog then
            state.status:set({ text = message })
        end
        if state.handlers.error then
            state.handlers.error(message)
        end
        return true
    end
    local ok, saved, result =
        pcall(state.handlers.save, values, state.revision, state.modelFilename, armed, sessionReset)
    if not ok then
        saved, result = false, saved
    end
    if saved then
        state.values, state.armed, state.revision =
            state.config.resolve(result.flight or values), armed, result.revision
        state.sessionReset = sessionReset
        state.readControls[command.key]()
        if state.dialog then
            state.status:set({ text = "" })
        end
        if state.handlers.saved then
            state.handlers.saved(result)
        end
    else
        if state.dialog then
            state.status:set({ text = tostring(result) })
        end
        if state.handlers.error then
            state.handlers.error(tostring(result))
        end
    end
    return true
end

function ui.handle(context, event)
    local state = context.modelSettingsUi
    if not state then
        return false
    end
    for _, name in ipairs({ "EVT_VIRTUAL_EXIT", "EVT_EXIT_BREAK" }) do
        if _G[name] ~= nil and event == _G[name] then
            state.closing = true
        end
    end
    return true
end

return ui
