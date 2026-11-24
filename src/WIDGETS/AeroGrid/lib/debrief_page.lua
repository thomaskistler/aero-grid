-- SPDX-License-Identifier: GPL-2.0-only

--- The Flight debrief setup page: the tile list, tile settings, and series
--- settings, shown in the shared settings dialogs of the layout editor.

local page = {}

page.FLIGHT_NOTE = "A debrief needs flight detection. Choose Armed in Model settings."
page.SENSOR_HINT = "Run Discover new sensors in Model > Telemetry"
page.FILL_EMPTY = "No dashboard panels map to debrief tiles."

local function tiles(state)
    local section = state.session.draft.debrief
    return section and section.tiles or {}
end

--- Whether a series names a source this model does not have yet.
local function missing(tile)
    for _, series in ipairs(tile.series or {}) do
        local source = series.source
        if type(source) == "string" and source ~= "" and getFieldInfo(source) == nil then
            return true
        end
    end
    return false
end

local function setAvailability(fields, enabled, canAdd)
    for index = 2, #fields do
        local field = fields[index]
        field.active = enabled and (field.action ~= "append" or canAdd)
    end
end

--- Rows of the tile list.
---@param state table Editor state: `session` and `status`.
---@param config table `configured` (flight detection) and `canAdd`.
function page.listFields(state, config)
    local fields = {
        { key = "enabled", label = "Enabled", type = "boolean" },
        {
            key = "size",
            label = "Tile size",
            type = "string",
            choices = { "compact", "wide" },
            choiceLabels = { "Compact", "Wide" },
        },
    }
    for index, tile in ipairs(tiles(state)) do
        fields[#fields + 1] = { action = "item", index = index, label = tile.title }
        if missing(tile) then
            fields[#fields + 1] = { type = "section", label = page.SENSOR_HINT }
        end
    end
    fields[#fields + 1] = { action = "append", label = "+", active = config.canAdd }
    fields[#fields + 1] = { action = "fill", label = "Fill from dashboard" }
    setAvailability(fields, state.session.draft.debrief.enabled ~= false, config.canAdd)
    local notes = {}
    if state.status and state.status ~= "" then
        notes[#notes + 1] = state.status
    end
    if not config.configured then
        notes[#notes + 1] = page.FLIGHT_NOTE
    end
    if #notes > 0 then
        fields[1].description = table.concat(notes, " ")
    end
    return fields
end

--- Rows of one tile's settings.
function page.tileFields(tile, maxSeries)
    local fields = {
        { key = "title", label = "Title", type = "string", required = true },
        { type = "section", label = "Series" },
    }
    for index, series in ipairs(tile.series) do
        local label = series.label or series.statistic or "?"
        fields[#fields + 1] = {
            action = "item",
            series = index,
            label = label,
            text = series.label or label .. ": " .. (series.source or "Choose source"),
        }
    end
    fields[#fields + 1] = { action = "append", label = "+", active = #tile.series < maxSeries }
    return fields
end

--- Rows of one series' settings.
function page.seriesFields(tile, seriesFields)
    local fields = {}
    for index, field in ipairs(seriesFields) do
        fields[index] = field
    end
    return fields
end

local function configured(context)
    local broker = context.flightFactory and context.flightFactory.broker
    return not (broker and broker.view and broker.view.status == "unconfigured")
end

--- Show a page: `{kind = "list"}`, `{kind = "tile", tile = i}`, or
--- `{kind = "series", tile = i, series = j}`.
local function show(context, state, target)
    local drawer, editor = context.editorDrawerModule, state.handlers.editor
    drawer.closeDialog(state)
    state.mode, state.debriefTarget = "debrief", target
    local module = assert(state.session.layout.debrief())
    local tile = tiles(state)[target.tile or 0]
    local fields, title, read, write
    if target.kind == "list" then
        title = "Flight debrief"
        fields = page.listFields(state, {
            configured = configured(context),
            canAdd = module.canAdd(state.session.draft.debrief),
        })
        read = function(field)
            if field.key == "enabled" then
                return state.session.draft.debrief.enabled ~= false
            end
            return module.viewSize(state.session.draft.debrief)
        end
        write = function(field, value)
            if field.key == "enabled" then
                local ok, err = editor.editDebrief(state.session, "setEnabled", value)
                if ok then
                    setAvailability(fields, value, module.canAdd(state.session.draft.debrief))
                end
                return ok, err
            end
            return editor.editDebrief(state.session, "setSize", value)
        end
        state.status = ""
    elseif target.kind == "tile" then
        title = tile.title
        fields = page.tileFields(tile, module.MAX_SERIES)
        read = function(field)
            return tile[field.key]
        end
        write = function(field, value)
            return editor.editDebrief(state.session, "setTileValue", target.tile, field.key, value)
        end
    else
        local series = tile.series[target.series]
        title = tile.title .. " / Series " .. target.series
        fields = page.seriesFields(tile, module.SERIES_FIELDS)
        read = function(field)
            return series[field.key]
        end
        write = function(field, value)
            if value == "" and not field.required then
                value = nil
            end
            return editor.editDebrief(state.session, "setSeriesValue", target.tile, target.series, field.key, value)
        end
    end
    drawer.settingsDialog(context, state, title, fields, read, write, function()
        return { action = "back" }
    end)
end

--- The draft's thresholds, which decide each reading's statistic.
local function thresholds(state)
    local lookup = state.handlers.debriefThresholds
    return lookup and lookup(state.session.draft.panels)
end

--- Open the tile list. A derived debrief follows the draft's panels.
function page.open(context, state)
    state.handlers.editor.deriveDebrief(state.session, thresholds(state))
    show(context, state, { kind = "list" })
end

--- Rebuild the tiles from the dashboard's panels, asking first when that
--- replaces tiles.
local function fill(context, state, confirmed)
    if #tiles(state) > 0 and not confirmed and type(lvgl.confirm) == "function" then
        local generation = state.drawerGeneration
        lvgl.confirm({
            title = "Fill from dashboard?",
            message = "This replaces all debrief tiles.",
            confirm = function()
                if context.editorUi == state and generation == state.drawerGeneration and not state.drawerPending then
                    state.drawerPending = { action = "fill", confirmed = true }
                end
            end,
        })
        return true
    end
    local panels = state.session.draft.panels
    local count, err = state.handlers.editor.editDebrief(state.session, "fill", panels, nil, thresholds(state))
    if not count then
        return count, err
    end
    if count == 0 then
        state.status = page.FILL_EMPTY
    end
    show(context, state, { kind = "list" })
    return true
end

--- Edit, move or delete one tile, or one series of the shown tile.
local function itemCommand(context, state, command)
    local editor, target, choice = state.handlers.editor, state.debriefTarget, command.choice
    local delta = choice == "up" and -1 or 1
    if command.series then
        if choice == "edit" then
            show(context, state, { kind = "series", tile = target.tile, series = command.series })
            return true
        end
        local ok, err
        if choice == "delete" then
            ok, err = editor.editDebrief(state.session, "removeSeries", target.tile, command.series)
        else
            ok, err = editor.editDebrief(state.session, "moveSeries", target.tile, command.series, delta)
        end
        if not ok then
            return ok, err
        end
        show(context, state, { kind = "tile", tile = target.tile })
        return true
    end
    if choice == "edit" then
        show(context, state, { kind = "tile", tile = command.index })
        return true
    end
    local ok, err
    if choice == "delete" then
        ok, err = editor.editDebrief(state.session, "removeTile", command.index)
    else
        ok, err = editor.editDebrief(state.session, "moveTile", command.index, delta)
    end
    if not ok then
        return ok, err
    end
    show(context, state, { kind = "list" })
    return true
end

function page.advance(context, state)
    if state.drawerBuild ~= nil then
        state.settingsUi.advance(state.drawerView)
        state.drawerBuild = state.drawerView.build
        return true
    end
    local command = state.drawerPending
    if not command then
        return false
    end
    state.drawerPending = nil
    local target = state.debriefTarget or { kind = "list" }
    local editor, ok, err = state.handlers.editor, true, nil
    if command.action == "open" then
        page.open(context, state)
    elseif command.action == "list" then
        show(context, state, { kind = "list" })
    elseif command.action == "back" then
        if target.kind == "series" then
            show(context, state, { kind = "tile", tile = target.tile })
        elseif target.kind == "tile" then
            show(context, state, { kind = "list" })
        else
            context.editorDrawerModule.closeDialog(state)
            if state.session.dirty then
                context.editorDrawerModule.openExit(context, state)
            else
                state.handlers.close(false)
            end
        end
    elseif command.action == "item" then
        local list = target.kind == "list" and tiles(state) or tiles(state)[target.tile].series
        local index = command.series or command.index
        context.editorDrawerModule.itemMenu(
            context,
            state,
            command.text or command.label,
            index,
            #list,
            target.kind == "list" or #list > 1,
            { action = "choice", index = command.index, series = command.series }
        )
    elseif command.action == "choice" then
        ok, err = itemCommand(context, state, command)
    elseif command.action == "fill" then
        ok, err = fill(context, state, command.confirmed)
    elseif command.action == "append" and target.kind == "list" then
        ok, err = editor.editDebrief(state.session, "addTile")
        if ok then
            show(context, state, { kind = "tile", tile = ok })
        end
    elseif command.action == "append" then
        ok, err = editor.editDebrief(state.session, "addSeries", target.tile)
        if ok then
            show(context, state, { kind = "series", tile = target.tile, series = ok })
        end
    elseif command.action == "write" then
        ok, err = context.editorDrawerModule.applyWrite(state, command)
    elseif command.action == "error" then
        ok, err = false, command.message
        if command.control and state.nativeDrawer then
            state.settingsUi.fieldError(state.drawerView, command.control, tostring(err))
        end
    end
    if not ok then
        state.handlers.logError("debrief " .. command.action, err)
        if command.action ~= "write" and command.action ~= "error" then
            state.status = tostring(err)
            show(context, state, { kind = "list" })
        end
    end
    if state.drawerDismiss then
        state.drawerPending, state.drawerDismiss = state.drawerDismiss, nil
    end
    return true
end

return page
