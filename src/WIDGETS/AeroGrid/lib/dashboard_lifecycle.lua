-- SPDX-License-Identifier: GPL-2.0-only

local module = {
    RUNTIME_API = 1,
    WORK_BOUNDS = {
        cancel = 100,
        panel = 200,
        pending = 200,
        menu = 100,
        page = 200,
        finalize = 100,
        rebuild = 200,
        retire = 250,
        finish = 150,
        settingsDrainOverhead = 300,
        settingsDrain = 2400,
        menuClose = 200,
        reflowBegin = 400,
        reflowFinish = 200,
        reflowSkip = 150,
        reflowWait = 100,
    },
}

--- Bind host operations once; callbacks retain their original work limits.
---@param dependencies table
---@return table
function module.new(dependencies)
    local addError = dependencies.addError
    local showErrors = dependencies.showErrors
    local isFullScreen = dependencies.isFullScreen
    local reservedCorner = dependencies.reservedCorner
    local errorTop = dependencies.errorTop
    local panelRect = dependencies.panelRect

    --- Empty-state decoration belongs to the page, never the layout document.
    ---@param context AeroGridContext
    local function updateEmptyHint(context)
        local hint = context.emptyHint
        local show = context.document
            and #context.document.panels == 0
            and not context.stage
            and not context.reloadState
            and not context.editorUi
            and #context.errors == 0
        if not show then
            if hint and hint.visible then
                for _, object in ipairs(hint.objects) do
                    lvgl.hide(object)
                end
                hint.visible = false
            end
            return
        end
        if not hint then
            hint = { objects = {} }
            context.emptyHint = hint
            for _, key in ipairs({ "title", "instruction", "setupHint" }) do
                hint[key] = lvgl.label(context.page, {
                    text = "",
                    font = function()
                        return SMLSIZE
                    end,
                })
                hint.objects[#hint.objects + 1] = hint[key]
            end
        end
        local w, h = context.zone.w, context.zone.h
        local fullscreen = isFullScreen()
        if hint.w ~= w or hint.h ~= h or hint.fullscreen ~= fullscreen then
            hint.w, hint.h, hint.fullscreen = w, h, fullscreen
            local instruction = fullscreen and "AeroGrid menu > UI setup" or "Long-press for fullscreen"
            local texts = { "Empty dashboard", instruction }
            local keys = { "title", "instruction" }
            if not fullscreen then
                texts[#texts + 1] = "If no EdgeTX logo, press RTN to exit setup"
                keys[#keys + 1] = "setupHint"
            else
                hint.setupHint:set({ text = "", w = 0, h = 0 })
            end
            local lineHeight = context.themeBuilder.fontHeight(SMLSIZE)
            local spacing = 6
            local blockHeight = #texts * lineHeight + (#texts - 1) * spacing
            local top = math.floor((h - blockHeight) / 2)
            for index, key in ipairs(keys) do
                local textWidth = context.themeBuilder.measureText(SMLSIZE, texts[index])
                hint[key]:set({
                    x = math.floor((w - textWidth) / 2),
                    y = top + (index - 1) * (lineHeight + spacing),
                    w = textWidth,
                    h = lineHeight,
                    text = texts[index],
                    color = context.theme.color.textMuted,
                })
            end
        end
        if not hint.visible then
            for _, object in ipairs(hint.objects) do
                lvgl.show(object)
            end
            hint.visible = true
        end
    end

    --- Begin repositioning after EdgeTX changes the host zone.
    --- Like loading, this is spread over callbacks: a full grid costs more than
    --- the instruction budget allows in one call.
    ---@param context AeroGridContext
    local function beginReflow(context)
        if context.reloadState or context.pageRetirement then
            context.reflowIndex, context.reflowEntry = nil, nil
            return
        end
        context.root:set({ w = context.zone.w, h = context.zone.h })
        context.page:set({ w = context.zone.w, h = context.zone.h })
        context.canvas:set({ w = context.zone.w, h = context.zone.h })

        -- A zone that moved may have moved out from under the button, or into it.
        context.reserved = reservedCorner(context.zone)

        if context.errorLabel then
            context.errorLabel:set({
                y = errorTop(context),
                w = math.max(1, context.zone.w - 16),
            })
        end

        context.width = context.zone.w
        context.height = context.zone.h
        context.left = context.zone.xabs or 0
        context.top = context.zone.yabs or 0
        context.fullScreen = isFullScreen()
        context.reflowIndex = 1
        context.reflowEntry = nil
    end

    --- Advance one panel's geometry, without advancing its live refresh.
    ---@param context AeroGridContext
    ---@return boolean busy True while more panels remain.
    local function advanceReflow(context)
        local index = context.reflowIndex
        if not index or context.reloadState or context.pageRetirement then
            context.reflowIndex, context.reflowEntry = nil, nil
            return false
        end
        if index > #context.panels then
            context.reflowIndex, context.reflowEntry = nil, nil
            showErrors(context)
            return false
        end
        local entry = context.panels[index]
        if entry and not entry.failed then
            local rect = panelRect(context, entry.placement)
            if rect then
                entry.container:set({ x = rect.x, y = rect.y, w = rect.w, h = rect.h })
                local staged = type(rawget(entry.module, "reflow")) == "function"
                local ok, dispatchError, done = context.panelHost.dispatch(
                    entry,
                    staged and "reflow" or "update",
                    { x = 0, y = 0, w = rect.w, h = rect.h },
                    entry.settings,
                    nil,
                    entry.placement,
                    context.reflowEntry ~= entry
                )
                if not ok and dispatchError then
                    addError(
                        context,
                        entry.placement.id .. ": " .. (staged and "reflow" or "update") .. ": " .. dispatchError
                    )
                elseif ok and staged and not done then
                    context.reflowEntry = entry
                    return true
                end
            end
        end

        context.reflowEntry = nil
        context.reflowIndex = index + 1
        return true
    end

    local function destroyEntry(context, entry)
        local ok, destroyError = context.panelHost.dispatch(entry, "destroy")
        if not ok and destroyError then
            addError(context, entry.placement.id .. ": destroy: " .. destroyError)
        end
        entry.container:clear()
        lvgl.hide(entry.container)
    end

    --- Rebuild one fullscreen-built panel using the loader's bounded stages.
    --- EdgeTX 2.12 only makes Lua boxes touch-transparent when constructing them
    --- outside fullscreen, so such a panel would swallow the widget's long press.
    --- The retire and build steps are split because a cleared container sweeps
    --- objects created in it during the same callback.
    ---@param context AeroGridContext
    local function advanceAppRebuild(context)
        local job = context.appRebuild
        if not job then
            return
        end
        if
            context.reloadState
            or context.pageRetirement
            or context.stage
            or job.page and (job.page ~= context.page or job.panels ~= context.panels)
        then
            context.appRebuild = nil
            return
        end
        job.page, job.panels = context.page, context.panels
        local entry = job.entry
        local loader = context.dashboardLoader
        if not job.phase then
            job.phase = "retire"
        end
        if job.phase == "retire" then
            job.retired = true
            destroyEntry(context, entry)
            local fullscreenContainers = context.fullscreenContainers
            if not (fullscreenContainers and fullscreenContainers[entry.container]) then
                job.container = entry.container
            end
            for index, current in ipairs(context.panels) do
                if current == entry then
                    if context.refreshOwner == entry then
                        context.refreshOwner = nil
                    end
                    table.remove(context.panels, index)
                    context.panelTasksDirty = true
                    job.index = index
                    break
                end
            end
            job.phase = "prepare"
            return
        end
        if job.phase == "prepare" then
            job.preparation = job.preparation or loader.beginPreparation(context, entry.placement)
            local done, prepared = loader.advancePreparation(context, job.preparation)
            if done then
                job.prepared = prepared
                job.phase = prepared and "build" or "finish"
            end
            return
        end
        if job.phase == "build" then
            job.rebuilt = loader.buildPanel(context, entry.placement, job.container, nil, job.prepared)
            job.partial = context.pendingConstruction
            job.phase = job.partial and "construct" or "finish"
        elseif job.phase == "construct" then
            if context.pendingConstruction ~= job.partial then
                context.appRebuild = nil
                return
            end
            local done, rebuilt = loader.advanceConstruction(context, false)
            job.rebuilt = rebuilt
            if not done then
                return
            end
            job.phase = "finish"
        else
            context.appRebuild = nil
            showErrors(context)
            return
        end
        -- Publication appends to the live registry; restore the original slot
        -- in the same turn so neither scheduler nor input observes a new order.
        if job.rebuilt then
            table.remove(context.panels)
            table.insert(context.panels, math.min(job.index, #context.panels + 1), job.rebuilt)
        end
    end

    local function retirePage(context)
        local job = context.pageRetirement
        if not job then
            context.reloadState = "clear"
            context.reflowIndex, context.reflowEntry = nil, nil
            context.locationDetails, context.locationOverlay = nil, nil
            context.logViewer, context.logOverlay = nil, nil
            context.refreshOwner = nil
            context.appRebuild = nil
            job = { phase = "settings", pending = context.pendingConstruction }
            context.pageRetirement = job
            context.pendingConstruction, context.pendingPanel, context.pendingPlacement = nil, nil, nil
            context.panelPreparation = nil
            return
        end
        if job.phase == "settings" then
            if context.modelSettingsUi and context.modelSettingsUiModule.close(context) == false then
                context.modelSettingsUiModule.advance(context)
                return
            end
            job.phase = "panel"
            return
        elseif job.phase == "panel" then
            local entry = table.remove(context.panels, 1)
            if entry then
                context.panelTasksDirty = true
                destroyEntry(context, entry)
            else
                job.phase = "pending"
            end
            return
        elseif job.phase == "pending" then
            if job.pending then
                destroyEntry(context, job.pending)
                job.pending = nil
            end
            job.phase = "menu"
            return
        elseif job.phase == "menu" then
            if context.nativeDialogsCreated and not isFullScreen() and context.aeroMenuModule
                and context.aerogridMenu then
                context.aeroMenuModule.close(context)
                context.aerogridMenu = nil
            end
            job.phase = "page"
            return
        elseif job.phase == "finalize" then
            context.fullscreenContainers = nil
            context.page, context.canvas, context.emptyHint = nil, nil, nil
            context.panels = {}
            context.rejected, context.errors, context.notices = {}, {}, {}
            context.errorLabel = nil
            context.pageRetirement = nil
            context.reloadState = "rebuild"
            return
        end

        -- Discard the whole page. EdgeTX collects the clear whenever it next runs
        -- callRefs, which is not guaranteed to be this callback: it is skipped
        -- while the widget is off screen, such as behind the settings dialog, and
        -- once an error has been reported. The next page is therefore built as a
        -- fresh child of the root, where this pending cleanup cannot reach it.
        --
        -- Only a firmware fallback creates top-level native dialogs. EdgeTX
        -- keeps those wrappers registered after deleting their windows, and
        -- only a host-wide clear unregisters them.
        if context.nativeDialogsCreated and not isFullScreen() then
            context.chromeRoot, context.aeroMenuParent = nil, nil
            lvgl.clear()
            context.root = nil
            context.nativeDialogsCreated = nil
        elseif context.rootBuiltFullscreen and not isFullScreen() then
            context.root:clear()
            lvgl.hide(context.root)
            context.root = nil
        elseif context.page then
            context.page:clear()
            lvgl.hide(context.page)
        end
        job.phase = "finalize"
    end

    local function rebuildPage(context)
        if context.pageRetirement then
            return
        end
        if not context.root then
            context.root = lvgl.box({ x = 0, y = 0, w = context.zone.w, h = context.zone.h })
            context.rootBuiltFullscreen = isFullScreen()
        end
        context.page = lvgl.box(context.root, {
            x = 0,
            y = 0,
            w = context.zone.w,
            h = context.zone.h,
        })
        context.pageBuiltFullscreen = isFullScreen()
        context.canvas = lvgl.rectangle(context.page, {
            x = 0,
            y = 0,
            w = context.zone.w,
            h = context.zone.h,
            color = context.theme and context.theme.color.canvas or lcd.RGB(0x101316),
            filled = true,
        })
        context.reloadState = nil
    end

    --- Only measured lifecycle atoms are eligible for service co-admission.
    --- Constructors, publication and third-party callbacks need their own proof.
    local function workBound(context, operation)
        if operation == "beginReflow" then
            return module.WORK_BOUNDS.reflowBegin
        elseif operation == "advanceReflow" or operation == "waitReflow" then
            local index = context.reflowIndex
            if not index or context.reloadState or context.pageRetirement then
                return module.WORK_BOUNDS.reflowSkip
            end
            local entry = context.panels[index]
            local bound
            if not entry or entry.failed then
                bound = entry and module.WORK_BOUNDS.reflowSkip or module.WORK_BOUNDS.reflowFinish
            else
                local panel = entry.module
                local callback = rawget(panel, "reflow")
                if type(callback) ~= "function" then
                    callback = rawget(panel, "update")
                end
                local declaration = rawget(panel, "reflowDecl")
                if
                    type(declaration) ~= "table"
                    or type(callback) ~= "function"
                    or rawget(declaration, "callback") ~= callback
                then
                    return nil
                end
                bound = rawget(declaration, "bound")
                if type(bound) ~= "number" or bound <= 0 or bound > 4000 or bound ~= math.floor(bound) then
                    return nil
                end
            end
            return operation == "waitReflow" and module.WORK_BOUNDS.reflowWait or bound
        elseif operation == "rebuildPage" then
            return module.WORK_BOUNDS.rebuild
        elseif operation ~= "retirePage" and operation ~= "advanceAppRebuild" then
            return nil
        end
        local job
        if operation == "retirePage" then
            job = context.pageRetirement
        else
            job = context.appRebuild
        end
        local phase = job and job.phase or (operation == "retirePage" and "cancel" or "retire")
        if phase == "settings" then
            if not context.modelSettingsUi then
                return 100
            end
            local settingsUi = context.modelSettingsUiModule
            if settingsUi and settingsUi.RUNTIME_API == 1 and type(settingsUi.retirementWorkBound) == "function" then
                local bound = settingsUi.retirementWorkBound(context)
                local completeBound = bound and bound + module.WORK_BOUNDS.settingsDrainOverhead
                if completeBound and completeBound <= module.WORK_BOUNDS.settingsDrain then
                    return completeBound
                end
            end
            return nil
        elseif phase == "menu" and context.nativeDialogsCreated and not isFullScreen() and context.aeroMenuModule then
            local menuModule, state = context.aeroMenuModule, context.aerogridMenu
            if state then
                if menuModule.RUNTIME_API == 1 and type(menuModule.closeWorkBound) == "function" then
                    local bound = menuModule.closeWorkBound(state)
                    if bound == module.WORK_BOUNDS.menuClose then
                        return bound
                    end
                end
                return nil
            end
            return module.WORK_BOUNDS.menu
        end
        local entry = phase == "panel" and context.panels[1]
            or phase == "pending" and job and job.pending
            or phase == "retire" and job and job.entry
        if entry and rawget(entry.module, "destroy") ~= nil then
            return nil
        end
        return module.WORK_BOUNDS[phase]
    end

    return {
        WORK_BOUNDS = module.WORK_BOUNDS,
        workBound = workBound,
        updateEmptyHint = updateEmptyHint,
        beginReflow = beginReflow,
        advanceReflow = advanceReflow,
        advanceAppRebuild = advanceAppRebuild,
        retirePage = retirePage,
        rebuildPage = rebuildPage,
    }
end

return module
