-- SPDX-License-Identifier: GPL-2.0-only

local ui = { RUNTIME_API = 1 }

local fields = {
    { key = "motorSource", label = "Motor channel", kind = "source" },
    { key = "motorReversed", label = "Reverse motor", kind = "toggle" },
    { key = "minMotorPercent", label = "Motor threshold (%)", kind = "numberEdit", min = 0, max = 99.99 },
    { key = "minFlightDuration", label = "Qualification (s)", kind = "numberEdit", min = 0.01, max = 3600 },
    { key = "smartDetection", label = "Smart detection", kind = "toggle" },
    { key = "disarmDuration", label = "Disarm grace (s)", kind = "numberEdit", min = 0.01, max = 3600 },
    { key = "announcements", label = "Announce flights", kind = "toggle" },
    { key = "history", label = "CSV history", kind = "toggle" },
    { key = "flightSwitch", label = "Flight-active Sticky", kind = "numberEdit", min = 0, max = 64 },
}

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
                state.pending = { action = "cancel" }
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
        draft = config.resolve(document.flight or {}),
        config = config,
        handlers = handlers,
        generation = 1,
        build = 1,
        controls = {},
        width = math.floor(context.zone.w * 0.8) - 16,
        height = lvgl.UI_ELEMENT_HEIGHT or 32,
        screen = lvgl.box(handlers.parent or context.root, { x = 0, y = 0, w = context.zone.w, h = context.zone.h }),
    }
    if document.choices and #document.choices > 0 then
        state.choices = {}
        for _, choice in ipairs(document.choices) do
            state.choices[#state.choices + 1] = { label = choice.label, flight = config.resolve(choice.flight or {}) }
        end
    end
    context.modelSettingsUi = state
    state.dialog = dialog(context, state)
    state.status = lvgl.label(state.dialog, {
        x = 4,
        y = 4,
        w = state.width,
        h = state.height * 2,
        text = document.status
            or "Armed is configured in native widget settings. Output: none or a dedicated Sticky L01-L64.",
        font = function()
            return SMLSIZE
        end,
    })
    state.smartStatus = lvgl.label(state.dialog, {
        x = 4,
        y = state.height * 2 + 8,
        w = state.width,
        h = state.height * 3,
        text = function()
            if not state.draft.smartDetection then
                return "Smart off: standard motor detection."
            end
            return (handlers.smartStatus and handlers.smartStatus()) or "Save to enable Smart sensor detection."
        end,
        font = function()
            return SMLSIZE
        end,
    })
    state.nextY = state.height * 5 + 16
    return state
end

local function buildField(context, state, field)
    local scale = field.kind == "numberEdit" and field.key ~= "flightSwitch" and 100 or 1
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
        min = field.min and math.floor(field.min * scale + 0.5),
        max = field.max and math.floor(field.max * scale + 0.5),
        active = function()
            return active(context, state) and not state.build
        end,
        get = function()
            local value = state.draft[field.key]
            if field.kind == "toggle" then
                return value and 1 or 0
            end
            if field.key == "flightSwitch" then
                return tonumber(string.match(value or "", "^L(%d%d)$")) or 0
            end
            if field.kind == "source" then
                if type(value) == "number" then
                    return value
                end
                local info = getFieldInfo(value)
                return type(info) == "table" and info.id or getSourceIndex(value) or 0
            end
            return scale ~= 1 and math.floor(value * scale + 0.5) or value
        end,
        set = function(value)
            if not active(context, state) then
                return
            end
            if field.kind == "toggle" then
                value = value ~= 0 and value ~= false
            elseif field.key == "flightSwitch" then
                value = value == 0 and "" or string.format("L%02d", value)
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
                    state.status:set({ text = "Cannot resolve selected motor channel" })
                    return
                end
                value = string.lower(name)
            elseif scale ~= 1 then
                value = value / scale
            end
            state.draft[field.key] = value
        end,
    }
    if field.kind == "source" then
        properties.filter = lvgl.SRC_CHANNEL
    elseif field.key == "flightSwitch" then
        properties.display = function(value)
            return value == 0 and "None" or string.format("L%02d", value)
        end
    elseif scale ~= 1 then
        properties.display = function(value)
            return tostring(value / scale)
        end
    end
    state.controls[field.key] = lvgl[field.kind](row, properties)
    state.nextY = state.nextY + state.height + 6
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
    if state.pending and state.pending.action == "cancel" then
        ui.close(context)
        if state.handlers.cancel then
            state.handlers.cancel()
        end
        return true
    end
    if state.build then
        if state.choices then
            local choices = state.choices
            local values = { "Defaults" }
            for _, choice in ipairs(choices) do
                values[#values + 1] = choice.label
            end
            state.choice = 1
            local row = lvgl.setting(state.dialog, {
                x = 4,
                y = state.nextY,
                w = state.width,
                h = state.height + 4,
                title = "Legacy detector",
            })
            state.legacyChoice = lvgl.choice(row, {
                x = math.floor(state.width * 0.52),
                y = 0,
                w = math.floor(state.width * 0.48) - 4,
                h = state.height,
                title = "Legacy detector",
                values = values,
                get = function()
                    return state.choice
                end,
                set = function(index)
                    if active(context, state) then
                        local choice = choices[index - 1]
                        state.choice = index
                        state.draft = state.config.resolve(choice and choice.flight or {})
                    end
                end,
            })
            state.nextY = state.nextY + state.height + 6
            state.choices = nil
            return true
        end
        local field = fields[state.build]
        if field then
            buildField(context, state, field)
            state.build = state.build + 1
        else
            local width = math.floor((state.width - 8) / 2)
            state.save = lvgl.button(state.dialog, {
                x = 4,
                y = state.nextY,
                w = width,
                h = state.height,
                text = "Save",
                press = function()
                    queue(context, state, { action = "save" })
                end,
            })
            state.cancel = lvgl.button(state.dialog, {
                x = width + 12,
                y = state.nextY,
                w = width,
                h = state.height,
                text = "Cancel",
                press = function()
                    queue(context, state, { action = "cancel" })
                end,
            })
            state.build = nil
        end
        return true
    end
    local command = state.pending
    if not command then
        return false
    end
    state.pending = nil
    if command.action == "cancel" then
        ui.close(context)
        if state.handlers.cancel then
            state.handlers.cancel()
        end
        return true
    end
    local errors = state.config.validate(state.draft)
    if #errors > 0 then
        state.status:set({ text = table.concat(errors, "; ") })
        return true
    end
    local ok, saved, result =
        pcall(state.handlers.save, state.config.resolve(state.draft), state.revision, state.modelFilename)
    if not ok then
        saved, result = false, saved
    end
    if saved then
        ui.close(context)
        if state.handlers.saved then
            state.handlers.saved(result)
        end
    else
        state.status:set({ text = tostring(result) })
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
            queue(context, state, { action = "cancel" })
        end
    end
    return true
end

return ui
