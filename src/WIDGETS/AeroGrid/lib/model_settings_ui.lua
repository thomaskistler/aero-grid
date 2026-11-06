-- SPDX-License-Identifier: GPL-2.0-only

local ui = {
    RUNTIME_API = 1,
    WORK_BOUNDS = {
        heading = 400, wrap = 400, field = 1500, finish = 300, idle = 300, command = 800,
        ["publish-start"] = 450, publish = 400, ["save-error"] = 350, closing = 300,
    },
}

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
        description = "Detects when a flight begins and ends using live telemetry data.",
    },
    { key = "motorReversed", label = "Reverse motor", kind = "toggle" },
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
        key = "sessionReset",
        label = "Session reset switch",
        kind = "switch",
        section = "Session reset",
        description = "Clears session data across all dashboards. Keeps flight totals and radio data.",
    },
    {
        key = "flightSwitch",
        label = "Flight status switch",
        kind = "choice",
        section = "Flight status output",
        description = "On during a detected flight. Use for your own special functions. Choose a dedicated Sticky logical switch, or None.",
    },
}

function ui.stageOf(state)
    if state.saving then
        if state.saving.phase == "publish" and state.saving.publication.stage then
            return "publish_" .. state.saving.publication.stage
        end
        return state.saving.phase == "store" and "save_" .. state.saving.job.stage or state.saving.phase
    elseif state.pending and state.handlers.startSave and not state.build then
        return "command"
    elseif state.closing then
        return "closing"
    elseif state.pending then
        return "pending"
    elseif not state.build then
        return "idle"
    elseif state.description then
        return "wrap"
    elseif not fields[state.build] then
        return "finish"
    elseif fields[state.build].section and not state.fieldReady then
        return "heading"
    end
    return "field"
end

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
        and not state.saving
        and (not state.handlers.modelFilename or state.handlers.modelFilename() == state.modelFilename)
        and (not state.handlers.fullscreen or state.handlers.fullscreen())
end

local function exitEvent(event)
    for _, name in ipairs({ "EVT_VIRTUAL_EXIT", "EVT_EXIT_BREAK" }) do
        if _G[name] ~= nil and event == _G[name] then return true end
    end
    return false
end

function ui.workBound(context, event)
    local state = context.modelSettingsUi
    if state and state.saving then
        if state.saving.phase == "store" and state.handlers.saveWorkBound then
            local bound = state.handlers.saveWorkBound(state.saving.job)
            return bound and bound + 200
        end
        if state.saving.phase == "publish-start" and not state.handlers.startPublication then
            return nil
        end
        return ui.WORK_BOUNDS[state.saving.phase]
    end
    if state and state.pending and state.handlers.startSave and not state.build
        and (not state.handlers.modelFilename or state.handlers.modelFilename() == state.modelFilename)
        and (not state.handlers.fullscreen or state.handlers.fullscreen()) then
        return ui.WORK_BOUNDS.command
    end
    if state and (
        state.handlers.modelFilename and state.handlers.modelFilename() ~= state.modelFilename
        or state.handlers.fullscreen and not state.handlers.fullscreen()
        or not state.pending and (state.closing or exitEvent(event))
    ) then
        return ui.WORK_BOUNDS.closing
    end
    if state and active(context, state) and not state.closing then
        return ui.WORK_BOUNDS[ui.stageOf(state)]
    end
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
    if state.saving then
        state.closing = true
        return false
    end
    context.modelSettingsUi = nil
    state.generation = state.generation + 1
    state.description, state.fieldReady = nil, nil
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
        retireHost(state)
        context.nativeDialogsCreated = true
        result = lvgl.dialog(properties)
    end
    return assert(result, "cannot open Model settings dialog")
end

function ui.open(context, document, handlers)
    assert(ui.close(context) ~= false, "Model settings save is still in progress")
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
    state.smartStatus = lvgl.label(state.dialog, {
        x = 4,
        y = 4,
        w = state.width,
        h = state.height * 3,
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

local function advanceDescription(state)
    local job = state.description
    local word = job.nextWord()
    if word then
        local candidate = job.line == "" and word or job.line .. " " .. word
        if job.line ~= "" and lcd.sizeText(candidate, SMLSIZE) > state.width - 4 then
            job.lines[#job.lines + 1], job.line = job.line, word
        else
            job.line = candidate
        end
        return
    end
    job.lines[#job.lines + 1] = job.line
    local _, lineHeight = lcd.sizeText("Ag", SMLSIZE)
    local height = #job.lines * (lineHeight + 2)
    lvgl.label(state.dialog, {
        x = 4,
        y = state.nextY,
        w = state.width,
        h = height,
        text = table.concat(job.lines, "\n"),
        font = function()
            return SMLSIZE
        end,
    })
    state.nextY = state.nextY + height + 4
    state.description, state.fieldReady = nil, true
end

local function startField(state, field)
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
    state.description = { nextWord = string.gmatch(field.description, "%S+"), lines = {}, line = "" }
end

local function buildField(context, state, field)
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
            if not active(context, state) then
                return
            end
            if field.kind == "switch" then
                local ok, name = pcall(state.armedConfig.name, value, state.armControl)
                if ok then
                    queue(context, state, { key = field.key, value = name })
                else
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
                    state.status:set({ text = "Choose a configured logical switch (L01-L64), or None" })
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
                    state.status:set({ text = "Cannot resolve selected motor channel" })
                    return
                end
                value = string.lower(name)
            elseif field.kind == "numberEdit" then
                value = math.floor(value + 0.5)
            end
            queue(context, state, { key = field.key, value = value })
        end,
    }
    if field.kind == "source" then
        properties.filter = lvgl.SRC_CHANNEL
    elseif field.key == "flightSwitch" then
        -- EdgeTX's switch toolbar overlaps on short lists; outputs need no inversion.
        properties.title = field.label
        properties.values = { "None" }
        for number = 1, 64 do
            properties.values[number + 1] = string.format("L%02d", number)
        end
        properties.filter = outputAvailable
    end
    state.controls[field.key] = lvgl[field.kind](row, properties)
    state.nextY = state.nextY + state.height + 6
end

local function reportError(state, message)
    if state.dialog then
        state.status:set({ text = tostring(message) })
    end
    if state.handlers.error then
        state.handlers.error(tostring(message))
    end
end

local function committed(state, document)
    state.values = state.config.resolve(document.flight)
    state.armed, state.sessionReset, state.revision = document.armed, document.sessionReset, document.revision
end

local function advanceSave(state)
    local saving, handlers = state.saving, state.handlers
    local function failed(message)
        saving.phase, saving.error = "save-error", tostring(message)
    end
    if saving.phase == "store" then
        local ok, done, saved, result = pcall(handlers.advanceSave, saving.job)
        if not ok then
            failed(done)
        elseif done then
            if saved then
                committed(state, result)
                saving.document, saving.job, saving.phase = result, nil, "publish-start"
            else
                failed(result)
            end
        end
    elseif saving.phase == "publish-start" then
        if handlers.modelFilename and handlers.modelFilename() ~= state.modelFilename then
            failed("Model changed; saved settings cannot be applied to another model")
        elseif handlers.startPublication then
            local ok, job, message = pcall(handlers.startPublication, saving.document)
            if ok and job then
                saving.publication, saving.phase = job, "publish"
            else
                failed(ok and message or job)
            end
        else
            local ok, message = true
            if handlers.saved then
                ok, message = pcall(handlers.saved, saving.document)
            end
            if not ok then
                failed(message)
            else
                state.saving = nil
                if state.dialog then state.status:set({ text = "" }) end
            end
        end
    elseif saving.phase == "publish" then
        local ok, done, saved, message = pcall(handlers.advancePublication, saving.publication)
        if not ok then
            failed(done)
        elseif done then
            if saved then
                state.saving = nil
                if state.dialog then state.status:set({ text = "" }) end
            else
                failed(message)
            end
        end
    elseif saving.phase == "save-error" then
        reportError(state, saving.error)
        state.saving = nil
    else
        error("invalid Model settings save phase: " .. tostring(saving.phase))
    end
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
        if state.saving then
            state.closing = true
        else
            ui.close(context)
            if state.handlers.cancel then
                state.handlers.cancel()
            end
            return true
        end
    end
    if state.closing and not state.pending and not state.saving then
        ui.close(context)
        if state.handlers.cancel then
            state.handlers.cancel()
        end
        return true
    end
    if state.saving then
        advanceSave(state)
        return true
    end
    if state.build then
        local field = fields[state.build]
        if state.description then
            advanceDescription(state)
        elseif field and field.section and not state.fieldReady then
            startField(state, field)
        elseif field then
            buildField(context, state, field)
            state.build = state.build + 1
            state.fieldReady = nil
        else
            state.smartStatus:set({ y = state.nextY })
            lvgl.show(state.smartStatus)
            state.nextY = state.nextY + state.height * 3 + 8
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
        if state.handlers.startSave then
            state.saving = { phase = "save-error", error = message }
        else
            reportError(state, message)
        end
        return true
    end
    if state.handlers.startSave then
        local ok, job, message = pcall(state.handlers.startSave,
            values, state.revision, state.modelFilename, armed, sessionReset)
        state.saving = ok and job and { phase = "store", job = job }
            or { phase = "save-error", error = tostring(ok and message or job) }
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
    if exitEvent(event) then state.closing = true end
    return true
end

return ui
