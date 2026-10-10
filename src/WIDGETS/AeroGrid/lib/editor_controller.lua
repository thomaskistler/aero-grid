-- SPDX-License-Identifier: GPL-2.0-only

local module = { RUNTIME_API = 1 }

--- Bind host operations once; callbacks retain their original work limits.
---@param dependencies table
---@return table
function module.new(dependencies)
    local addError = dependencies.addError
    local showErrors = dependencies.showErrors
    local loadModule = dependencies.loadModule
    local isFullScreen = dependencies.isFullScreen
    local buildPanel = dependencies.buildPanel
    local updateEmptyHint = dependencies.updateEmptyHint

    local function previewLayout(context, document)
        local placements = {}
        for _, placement in ipairs(document.panels) do
            placements[placement.id] = placement
        end
        for _, entry in ipairs(context.panels) do
            local placement = placements[entry.placement.id]
            local visible = placement ~= nil and placement.type == entry.placement.type
            if entry.editorVisible ~= visible then
                local visibility = visible and lvgl.show or lvgl.hide
                visibility(entry.container)
                entry.editorVisible = visible
            end
            if visible and not entry.failed then
                local previous = entry.editorPlacement or entry.placement
                if
                    previous.col ~= placement.col
                    or previous.row ~= placement.row
                    or previous.colSpan ~= placement.colSpan
                    or previous.rowSpan ~= placement.rowSpan
                then
                    local rect, rectError = context.grid.rect(context.zone, placement, 4, 4, 4)
                    if not rect then
                        return false, rectError
                    end
                    entry.container:set({ x = rect.x, y = rect.y, w = rect.w, h = rect.h })
                    local ok, updateError = context.panelHost.dispatch(
                        entry,
                        "update",
                        { x = 0, y = 0, w = rect.w, h = rect.h },
                        entry.settings
                    )
                    if not ok then
                        return false, entry.placement.id .. ": preview: " .. tostring(updateError)
                    end
                    entry.editorPlacement = {
                        col = placement.col,
                        row = placement.row,
                        colSpan = placement.colSpan,
                        rowSpan = placement.rowSpan,
                    }
                end
            end
        end
        return true
    end

    local function restorePreview(context)
        if context.editorPreviewChanged then
            context.editorPreviewChanged = nil
            context.reloadState = "clear"
            return
        end
        local restored, restoreError = previewLayout(context, context.document)
        if not restored then
            addError(context, restoreError)
            showErrors(context)
        end
        for _, entry in ipairs(context.panels) do
            entry.editorPlacement = nil
            entry.editorVisible = nil
        end
    end

    local function sameConfig(left, right)
        if type(left) ~= "table" or type(right) ~= "table" then
            return left == right
        end
        for key, value in pairs(left) do
            if not sameConfig(value, right[key]) then
                return false
            end
        end
        for key in pairs(right) do
            if left[key] == nil then
                return false
            end
        end
        return true
    end

    --- Keep the previewed dashboard after a save instead of reloading it.
    --- Returns false whenever the preview is not exactly what a reload would build.
    local function adoptSavedLayout(context, document)
        local current = context.document
        if not document or not current or context.stage or #context.errors > 0 or #context.rejected > 0 then
            return false
        end
        for key, value in pairs(document) do
            if key ~= "panels" and not sameConfig(value, current[key]) then
                return false
            end
        end
        for key in pairs(current) do
            if key ~= "panels" and document[key] == nil then
                return false
            end
        end
        if #document.panels ~= #context.panels then
            return false
        end
        local entries = {}
        for _, entry in ipairs(context.panels) do
            if entry.failed or entry.editorVisible == false then
                return false
            end
            entries[entry.placement.id] = entry
        end
        local ordered = {}
        for index, placement in ipairs(document.panels) do
            local entry = entries[placement.id]
            if
                not entry
                or entry.placement.type ~= placement.type
                or not sameConfig(placement.config, entry.placement.config)
            then
                return false
            end
            local shown = entry.editorPlacement or entry.placement
            if
                shown.col ~= placement.col
                or shown.row ~= placement.row
                or shown.colSpan ~= placement.colSpan
                or shown.rowSpan ~= placement.rowSpan
            then
                return false
            end
            -- Settings can depend on span, so a resized panel must resolve to the
            -- same settings a reload would give it.
            if entry.placement.colSpan ~= placement.colSpan or entry.placement.rowSpan ~= placement.rowSpan then
                local resolved, warnings = context.panelHost.resolveSettings(
                    entry.module,
                    placement.config,
                    { colSpan = placement.colSpan, rowSpan = placement.rowSpan }
                )
                if #warnings > 0 or not sameConfig(resolved, entry.settings) then
                    return false
                end
            end
            ordered[index] = entry
        end
        -- The saved draft is owned by the closing editor session, which is
        -- discarded, so it becomes the active document without a copy.
        -- Panel services captured the live placement table, so it is updated in
        -- place and becomes the document's entry.
        for index, entry in ipairs(ordered) do
            local placement = entry.placement
            for key in pairs(placement) do
                placement[key] = nil
            end
            for key, value in pairs(document.panels[index]) do
                placement[key] = value
            end
            document.panels[index] = placement
            entry.editorPlacement = nil
            entry.editorVisible = nil
        end
        context.panels = ordered
        context.document = document
        return true
    end

    local function startPanelPreview(context, document)
        local placements, existing, actions = {}, {}, {}
        for _, placement in ipairs(document.panels) do
            placements[placement.id] = placement
        end
        for _, entry in ipairs(context.panels) do
            local placement = placements[entry.placement.id]
            existing[entry.placement.id] = true
            if
                not placement
                or placement.type ~= entry.placement.type
                or not sameConfig(placement.config, entry.placement.config)
            then
                actions[#actions + 1] = { entry = entry, placement = placement }
            end
        end
        for _, placement in ipairs(document.panels) do
            if not existing[placement.id] then
                actions[#actions + 1] = { placement = placement }
            end
        end
        return { actions = actions, index = 1 }
    end

    local function advancePanelPreview(context, job)
        local action = job.actions[job.index]
        if not action then
            return true
        end
        if not action.retired then
            context.editorPreviewChanged = true
            local entry = action.entry
            if entry then
                -- Retire callbacks before rebuilding, in a separate foreground callback.
                local ok, destroyError = context.panelHost.dispatch(entry, "destroy")
                if not ok and destroyError then
                    return true, entry.placement.id .. ": preview destroy: " .. destroyError
                end
                entry.container:clear()
                lvgl.hide(entry.container)
                context.editorPreviewContainers = context.editorPreviewContainers or {}
                context.editorPreviewContainers[#context.editorPreviewContainers + 1] = entry.container
                for index, current in ipairs(context.panels) do
                    if current == entry then
                        table.remove(context.panels, index)
                        break
                    end
                end
            end
            action.retired = true
            if not action.placement then
                job.index = job.index + 1
            end
            return false
        end
        local pool = context.editorPreviewContainers or {}
        local container = table.remove(pool)
        local placement = context.editorModule.clone(action.placement)
        local entry, buildError, failedContainer = buildPanel(context, placement, container, true)
        job.index = job.index + 1
        if not entry then
            if failedContainer or container then
                context.editorPreviewContainers = pool
                pool[#pool + 1] = failedContainer or container
            end
            return true, placement.id .. ": preview: " .. tostring(buildError)
        end
        return false
    end

    --- Enter the editor while preserving the current dashboard until saving succeeds.
    ---@param context AeroGridContext
    ---@return boolean opened
    local function openEditor(context)
        if not isFullScreen() or context.stage or context.reloadState or not context.document then
            return false
        end
        local runtimeApi = context.packageInfo and context.packageInfo.runtimeApi or 1
        if not context.editorModule then
            local module, moduleError = loadModule(context.path, "lib/editor.lua", runtimeApi)
            if not module then
                addError(context, "editor: " .. tostring(moduleError))
                showErrors(context)
                return false
            end
            context.editorModule = module
        end
        if not context.editorUiModule then
            local module, moduleError = loadModule(context.path, "lib/editor_ui.lua", runtimeApi)
            if not module then
                addError(context, "editor UI: " .. tostring(moduleError))
                showErrors(context)
                return false
            end
            context.editorUiModule = module
        end
        if not context.editorDrawerModule then
            local module, moduleError = loadModule(context.path, "lib/editor_drawer.lua", runtimeApi)
            if not module then
                addError(context, "editor drawer: " .. tostring(moduleError))
                showErrors(context)
                return false
            end
            context.editorDrawerModule = module
        end

        context.editorPanelCache = context.editorPanelCache or {}
        local function loadPanel(typeName)
            if context.editorPanelCache[typeName] then
                return context.editorPanelCache[typeName]
            end
            if type(typeName) ~= "string" or not string.match(typeName, "^[%w_-]+$") then
                return nil, "invalid panel type"
            end
            local panel, panelError = loadModule(context.path, "panels/" .. typeName .. ".lua")
            if panel then
                context.editorPanelCache[typeName] = panel
            end
            return panel, panelError
        end

        -- A draft set aside when fullscreen was left resumes where it stopped.
        local resumed = context.editorStash
        context.editorStash = nil
        local created, session, sessionError = true, resumed, nil
        if not resumed then
            created, session, sessionError = pcall(
                context.editorModule.new,
                context.document,
                context.grid,
                context.layoutValidator,
                context.panelHost,
                loadPanel
            )
        end
        if not created or not session then
            addError(context, "editor: " .. tostring(sessionError or session))
            showErrors(context)
            return false
        end

        context.editorSession = session
        local handlers = {
            editor = context.editorModule,
            resumed = resumed ~= nil,
            preview = function(document)
                return previewLayout(context, document)
            end,
            startPreview = function(document)
                return startPanelPreview(context, document)
            end,
            advancePreview = function(job)
                return advancePanelPreview(context, job)
            end,
            layoutName = function()
                return context.layoutName
            end,
            isEmpty = function(name)
                return context.layoutStore.isEmpty(name)
            end,
            validName = function(name)
                return context.layoutStore.validName(name)
            end,
            exists = function(name)
                return context.layoutStore.exists(context.path, name)
            end,
            suggestName = function()
                local info = model and model.getInfo and model.getInfo()
                return context.layoutStore.suggestName(context.path, info and info.name)
            end,
            startSave = function(document, name)
                name = name or context.layoutName
                context.editorSavedDocument = document
                local state = context.layoutStore.startSave(
                    context.path,
                    name,
                    document,
                    context.yaml,
                    context.layoutValidator,
                    context.grid
                )
                state.name = name
                return state
            end,
            advanceSave = function(state)
                local done, saved, saveError = context.layoutStore.advanceSave(state)
                if saved and state.name == context.layoutName then
                    context.layoutPath = state.filename
                    context.layoutOrigin = "user"
                end
                return done, saved, saveError
            end,
            --- `saved` is true only when the dashboard's own layout was written;
            --- after Save As this dashboard keeps showing its committed layout.
            close = function(saved)
                context.editorUiModule.close(context, false)
                if not saved then
                    restorePreview(context)
                end
                context.editorSession = nil
                context.editorPreviewContainers = nil
                if saved then
                    context.editorPreviewChanged = nil
                    if not adoptSavedLayout(context, context.editorSavedDocument) then
                        context.reloadState = "clear"
                    end
                end
                context.editorSavedDocument = nil
            end,
        }
        local opened, openError = pcall(context.editorUiModule.open, context, session, handlers)
        if not opened then
            if context.editorUi then
                pcall(context.editorUiModule.close, context, true)
            end
            context.editorSession = nil
            lvgl.show(context.page)
            addError(context, "editor UI: " .. tostring(openError))
            showErrors(context)
            return false
        end
        context.touchTapHandled = true
        context.editorPress = nil
        updateEmptyHint(context)
        return true
    end

    --- Advance editor setup or saving without discarding a failed save's draft.
    local function advanceEditor(context)
        local saving = context.editorUi.saving ~= nil
        local advanced, advanceError = pcall(context.editorUiModule.advance, context)
        if not advanced then
            if saving then
                context.editorUiModule.saveFailure(context, advanceError)
            else
                context.editorUiModule.close(context, true)
                restorePreview(context)
                context.editorPreviewContainers = nil
                context.editorSession = nil
                addError(context, "editor UI: " .. tostring(advanceError))
                showErrors(context)
            end
        end
    end

    --- Whether input starts fullscreen editing.
    ---@param context AeroGridContext
    ---@param widgetEvent any
    ---@param touchState any
    ---@return boolean
    local function editorEntryHit(context, widgetEvent, touchState, held)
        if
            not isFullScreen()
            or context.stage
            or context.reloadState
            or context.editorUi
            or context.runtimeFailed
            or not context.document
        then
            return false
        end
        local enter = _G.EVT_VIRTUAL_ENTER
        if enter ~= nil and widgetEvent == enter then
            return true
        end
        if
            (not held and (not _G.EVT_TOUCH_LONG or widgetEvent ~= _G.EVT_TOUCH_LONG))
            or type(touchState) ~= "table"
            or type(touchState.x) ~= "number"
            or type(touchState.y) ~= "number"
        then
            return false
        end
        local x, y = touchState.x, touchState.y
        local left, top = context.left or 0, context.top or 0
        if x >= left and x < left + context.zone.w and y >= top and y < top + context.zone.h then
            x, y = x - left, y - top
        end
        for _, entry in ipairs(context.panels) do
            local rect = context.grid.rect(context.zone, entry.placement, 4, 4, 4)
            if rect and x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
                return true
            end
        end
        -- An empty dashboard must still offer a way to start adding panels.
        return #context.panels == 0 and x >= 0 and x < context.zone.w and y >= 0 and y < context.zone.h
    end

    return {
        restorePreview = restorePreview,
        openEditor = openEditor,
        advanceEditor = advanceEditor,
        editorEntryHit = editorEntryHit,
    }
end

return module
