-- SPDX-License-Identifier: GPL-2.0-only

local module = { RUNTIME_API = 1 }

--- Bind host operations once; callbacks retain their original work limits.
---@param dependencies table
---@return table
function module.new(dependencies)
    local addError = dependencies.addError
    local showErrors = dependencies.showErrors
    local dispatchAll = dependencies.dispatchAll
    local isFullScreen = dependencies.isFullScreen
    local reservedCorner = dependencies.reservedCorner
    local errorTop = dependencies.errorTop
    local panelRect = dependencies.panelRect
    local buildPanel = dependencies.buildPanel

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
            for _, key in ipairs({ "title", "instruction" }) do
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
            local instruction = fullscreen and "Long-press to start editing" or "Long-press for fullscreen"
            local texts = { "Empty dashboard", instruction }
            local keys = { "title", "instruction" }
            local lineHeight = context.themeBuilder.fontHeight(SMLSIZE)
            local blockHeight = lineHeight * 2 + 6
            local top = math.floor((h - blockHeight) / 2)
            for index, key in ipairs(keys) do
                local textWidth = context.themeBuilder.measureText(SMLSIZE, texts[index])
                hint[key]:set({
                    x = math.floor((w - textWidth) / 2),
                    y = top + (index - 1) * (lineHeight + 6),
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

    --- Panels repositioned per widget callback during a reflow.
    ---
    --- Three is the current measurement-based setting. Reflow cost grows with the
    --- number of panels per batch, so larger values can make one callback the
    --- dashboard bottleneck while smaller values take more callbacks to settle.
    --- The suite compares the measured worst reflow callback with the dashboard's
    --- other live callbacks, so this choice is re-evaluated when panel work changes.
    ---
    --- What it costs is passes. Sixteen panels settle in six callbacks rather
    --- than four, and `MainWindow::run` calls `ViewMain::refreshWidgets` once per
    --- `MENU_TASK_PERIOD`, which is 50 ms (`radio/src/tasks.cpp:50`), so a full
    --- reflow takes about 300 ms rather than 200. A reflow only happens when the
    --- host zone moves or resizes, which is a screen change: nobody is reading a
    --- value at that moment.
    ---
    --- The headroom is the real argument. Reflow is the only per-callback cost
    --- that multiplies one panel's work by a constant, so the constant is the
    --- cheapest protection against a future panel being expensive to move. At
    --- 4, a panel costing 3750 to reposition breaches the suite's ceiling; at
    --- 3 it takes 4935 to do the same.
    local REFLOW_BATCH = 2

    --- Begin repositioning after EdgeTX changes the host zone.
    --- Like loading, this is spread over callbacks: a full grid costs more than
    --- the instruction budget allows in one call.
    ---@param context AeroGridContext
    local function beginReflow(context)
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
    end

    --- Reposition the next batch of panels.
    ---@param context AeroGridContext
    ---@return boolean busy True while more panels remain.
    local function advanceReflow(context)
        local index = context.reflowIndex
        local last = math.min(index + REFLOW_BATCH - 1, #context.panels)

        for position = index, last do
            local entry = context.panels[position]
            if entry and not entry.failed then
                local rect = panelRect(context, entry.placement)
                if rect then
                    entry.container:set({ x = rect.x, y = rect.y, w = rect.w, h = rect.h })
                    local ok, dispatchError = context.panelHost.dispatch(
                        entry,
                        "update",
                        { x = 0, y = 0, w = rect.w, h = rect.h },
                        entry.settings
                    )
                    if not ok and dispatchError then
                        addError(context, entry.placement.id .. ": update: " .. dispatchError)
                    end
                end
            end
        end

        if last >= #context.panels then
            context.reflowIndex = nil
            showErrors(context)
            return false
        end

        context.reflowIndex = last + 1
        return true
    end

    --- Rebuild one fullscreen-built panel for App mode, over two callbacks.
    --- EdgeTX 2.12 only makes Lua boxes touch-transparent when constructing them
    --- outside fullscreen, so such a panel would swallow the widget's long press.
    --- The retire and build steps are split because a cleared container sweeps
    --- objects created in it during the same callback.
    ---@param context AeroGridContext
    local function advanceAppRebuild(context)
        local job = context.appRebuild
        local entry = job.entry
        if not job.retired then
            job.retired = true
            local ok, destroyError = context.panelHost.dispatch(entry, "destroy")
            if not ok and destroyError then
                addError(context, entry.placement.id .. ": destroy: " .. destroyError)
            end
            entry.container:clear()
            lvgl.hide(entry.container)
            local fullscreenContainers = context.fullscreenContainers
            if not (fullscreenContainers and fullscreenContainers[entry.container]) then
                job.container = entry.container
            end
            for index, current in ipairs(context.panels) do
                if current == entry then
                    table.remove(context.panels, index)
                    job.index = index
                    break
                end
            end
            return
        end
        context.appRebuild = nil
        local rebuilt = buildPanel(context, entry.placement, job.container)
        if rebuilt then
            table.remove(context.panels)
            table.insert(context.panels, math.min(job.index, #context.panels + 1), rebuilt)
        end
        showErrors(context)
    end

    local function retirePage(context)
        dispatchAll(context, "destroy")

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
        context.fullscreenContainers = nil
        context.appRebuild = nil

        context.page = nil
        context.canvas = nil
        context.emptyHint = nil
        context.panels = {}
        context.rejected = {}
        context.errors = {}
        context.notices = {}
        context.errorLabel = nil
        context.reloadState = "rebuild"
    end

    local function rebuildPage(context)
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

    return {
        updateEmptyHint = updateEmptyHint,
        beginReflow = beginReflow,
        advanceReflow = advanceReflow,
        advanceAppRebuild = advanceAppRebuild,
        retirePage = retirePage,
        rebuildPage = rebuildPage,
    }
end

return module
