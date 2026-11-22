-- SPDX-License-Identifier: GPL-2.0-only

local ui = {}

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
    { key = "countSource", label = "Flight count source", kind = "choice" },
    {
        key = "flightSwitch",
        label = "Flight status switch",
        kind = "choice",
        slots = 2,
        description = "On during a detected flight. Use for your own special functions. Choose a dedicated Sticky logical switch, or None.",
    },
    {
        key = "sessionReset",
        label = "Session reset switch",
        kind = "switch",
        section = "Session reset",
        description = "Clears session data across all dashboards. Keeps flight totals and radio data.",
    },
    {
        key = "liveDangerously",
        label = "Pre-release features",
        kind = "toggle",
        section = "Pre-release",
        description = "Enable pre-release features that are not fully validated yet.",
    },
}

local nativeProperties

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
        and (not state.handlers.modelFilename or state.handlers.modelFilename() == state.modelFilename)
        and (not state.handlers.fullscreen or state.handlers.fullscreen())
end

function ui.close(context)
    local state = context.modelSettingsUi
    if not state then
        return
    end
    context.modelSettingsUi = nil
    state.generation = state.generation + 1
    state.dialog = nil
    context.settingsUiModule.close(state.view)
    state.screen:clear()
    lvgl.hide(state.screen)
end

local function queue(context, state, action)
    if not state.pending and active(context, state) then
        state.pending = action
        return true
    end
    return false
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
        readControls = {},
        width = math.floor(context.zone.w * 0.8) - 16,
        height = lvgl.UI_ELEMENT_HEIGHT or 32,
        screen = lvgl.box(handlers.parent or context.root, { x = 0, y = 0, w = context.zone.w, h = context.zone.h }),
    }
    context.modelSettingsUi = state
    state.view = context.settingsUiModule.open(context, state.screen, {
        title = "Model settings",
        close = function()
            state.dialog = nil
            state.closing = true
        end,
    }, {
        fields = fields,
        rowHeight = state.height + 4,
        controlFraction = 0.52,
        controlWidthFraction = 0.48,
        controlInset = 4,
        gap = 2,
        active = function()
            return active(context, state)
        end,
        enqueue = function(apply, value)
            return queue(context, state, { apply = apply, value = value })
        end,
        nativeProperties = function(field, properties)
            return nativeProperties(state, field, properties)
        end,
    })
    state.dialog = state.view.dialog
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

nativeProperties = function(state, field, properties)
    properties.min, properties.max = field.min, field.max
    properties.get = function()
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
        if field.key == "countSource" then
            return value == "gv9" and 2 or value == "gv8gv9" and 3 or 1
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
    end
    properties.set = function(value)
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
        elseif field.key == "countSource" then
            local sources = { "internal", "gv9", "gv8gv9" }
            if not sources[value] then
                state.status:set({ text = "Choose AeroGrid, GV9 or GV8:GV9" })
                return
            end
            value = sources[value]
        elseif field.key == "flightSwitch" then
            if type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value > 65 or not outputAvailable(value) then
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
    end
    if field.kind == "source" then
        properties.filter = lvgl.SRC_CHANNEL
    elseif field.key == "countSource" then
        properties.title = field.label
        properties.values = { "AeroGrid", "GV9", "GV8:GV9" }
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
    return properties
end

function ui.cost(context)
    local state, capacity = context.modelSettingsUi, context.scheduler.budget.slots
    if state and state.build and not state.closing then
        return context.settingsUiModule.cost(state.view, capacity)
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
        local shared = context.settingsUiModule
        local field, entry = shared.advance(state.view)
        state.build, state.nextY = state.view.build, state.view.nextY
        if field then
            state.controls[field.key], state.readControls[field.key] = entry.object, entry.readNative
            if field.key == "smartDetection" then
                state.smartStatus:set({ y = state.nextY })
                lvgl.show(state.smartStatus)
                state.nextY = state.nextY + state.smartStatusHeight + 4
            end
            state.view.nextY = state.nextY
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
    if command.apply then
        state.pending = nil
        command.apply(command.value)
        return true
    end
    -- Preparing and writing a save each take a callback; pending blocks input between them.
    local ok, saved, result, retry
    if not command.prepared then
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
            ok, saved, result = true, false, table.concat(errors, "; ")
        else
            ok, saved, result =
                pcall(state.handlers.prepare, values, state.revision, state.modelFilename, armed, sessionReset)
            if ok and saved then
                command.prepared, command.values, command.armed, command.sessionReset =
                    result, values, armed, sessionReset
                return true
            end
        end
    else
        ok, saved, result, retry = pcall(state.handlers.commit, command.prepared)
        if ok and retry then
            command.prepared = result
            return true
        end
    end
    state.pending = nil
    if not ok then
        saved, result = false, saved
    end
    if saved then
        state.values, state.armed, state.revision =
            state.config.resolve(result.flight or command.values), command.armed, result.revision
        state.sessionReset = command.sessionReset
        state.readControls[command.key]()
        if state.dialog then
            state.status:set({ text = "" })
        end
        if state.handlers.saved then
            state.handlers.saved(result)
        end
    else
        state.readControls[command.key]()
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
