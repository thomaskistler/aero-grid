-- SPDX-License-Identifier: GPL-2.0-only
---@simulate Layout1x1AM zone=0

--- AeroGrid's EdgeTX widget entry point and panel host.

---@class AeroGridZone
---@field x integer Always zero; a widget draws in its own coordinates.
---@field y integer Always zero.
---@field w integer
---@field h integer
---@field xabs? integer Absolute screen position of the zone's left edge.
---@field yabs? integer Absolute screen position of the zone's top edge.

---@class AeroGridWidgetOptions
---@field DashID string
---@field Theme string

---@class AeroGridContext
---@field zone AeroGridZone Live zone table maintained by EdgeTX.
---@field path string Absolute widget directory path.
---@field dashboardId string Layout identity selected in native widget settings.
---@field panels AeroGridPanelEntry[]
---@field errors string[] Failures, shown on the overlay.
---@field notices table[] `{severity, text}` records of the host adapting.
---@field width integer Last rendered zone width.
---@field height integer Last rendered zone height.
---@field left integer Last rendered absolute zone left edge.
---@field top integer Last rendered absolute zone top edge.
---@field reserved? table Corner covered by the EdgeTX menu button, or nil.
---@field root any Root LVGL container.
---@field grid table
---@field yaml table
---@field layoutValidator table
---@field layoutStore table
---@field panelHost table
---@field themeBuilder table
---@field primitives table
---@field theme AeroGridTheme Active resolved theme passed to every panel.
---@field themeMode string Mode selected in native widget settings.
---@field services table Shared objects handed to panels.
---@field rejected table[] Placements that would not build, with the reason.
---@field layoutPath? string
---@field layoutOrigin? string Which filename answered: model, dashboard, default, none.
---@field modelFilename? string Model filename the layout name was derived from.
---@field themeSource? string Whether the layout or the widget option chose the mode.
---@field errorLabel? any
---@field page any Container holding one generation of the dashboard.
---@field reloadState? "clear"|"rebuild"
---@field stage? "read"|"tokenize"|"header"|"services"|"panels" Staged loader position.
---@field servicesModule? table Loaded lib/services.lua registry module.
---@field packageInfo? table Package identity and compatibility versions.
---@field serviceRuntime? table Registry holding every constructed service.
---@field serviceIndex? integer Next service definition to construct.
---@field source? string Layout text held between the read and tokenize steps.
---@field tokens? table Tokens held between the tokenize and parse steps.
---@field pending? table[] Validated placements still awaiting construction.
---@field pendingIndex? integer Next placement to build.
---@field editorModule? table On-radio layout editor, loaded only on demand.
---@field editorUiModule? table LVGL editor controls, loaded only on demand.
---@field editorSession? table Uncommitted editor working copy.
---@field editorUi? table Active editor screen state.
---@field editButton? any Fullscreen affordance for entering the editor.
---@field editButtonLabel? any Fullscreen affordance label.

local options = {
    { "DashID", STRING, "main" },
    { "Theme", STRING, "modern" },
}

--- Join a widget directory and package-relative path.
---@param base string
---@param relative string
---@return string
local function joinPath(base, relative)
    if string.sub(base, -1) == "/" then
        return base .. relative
    end
    return base .. "/" .. relative
end

--- Load and execute a Lua module while containing compile/runtime failures.
---@param base string
---@param relative string
---@param runtimeApi? integer Required internal module API.
---@return table? module
---@return string? error
local function loadModule(base, relative, runtimeApi)
    local chunk, loadError = loadScript(joinPath(base, relative))
    if not chunk then
        return nil, loadError
    end

    local ok, module = pcall(chunk)
    if not ok then
        return nil, module
    end
    if type(module) ~= "table" then
        return nil, relative .. " did not return a module table"
    end
    if runtimeApi and rawget(module, "RUNTIME_API") ~= runtimeApi then
        return nil, relative .. ": incompatible runtime API; copy the complete AeroGrid package"
    end

    return module
end

--- Append a user-visible runtime error.
---@param context AeroGridContext
---@param message any
local function addError(context, message)
    context.errors[#context.errors + 1] = tostring(message)
end

--- Notices retained for diagnostics; older ones are dropped rather than grown.
local NOTICE_LIMIT = 16

--- Record the host adapting as designed, which is not a failure.
---
--- An error is something that did not work: a module that would not load, a
--- layout key that is invalid, a panel that raised. Those belong on the
--- overlay, because the dashboard is not doing what it was told. A notice is
--- the host doing its job: correcting a token for contrast, or falling back to
--- the Modern palette when the radio will not hand over its own. Putting those
--- on the overlay would leave a permanent banner on every radio running a
--- derived theme, reporting that the legibility pass worked.
---
--- They are kept rather than discarded because milestone 9's diagnostics view
--- is where they belong.
---@param context AeroGridContext
---@param severity "info"|"warning"
---@param message any
local function addNotice(context, severity, message)
    local notices = context.notices
    if #notices >= NOTICE_LIMIT then
        table.remove(notices, 1)
    end
    notices[#notices + 1] = { severity = severity, text = tostring(message) }
end

--- Menu button height on a 480 x 272 display, used when the radio will not say.
local BUTTON_HEIGHT = 45

--- Ratio between the firmware's button height and the width it keeps clear.
--- EdgeTX scales both per display class, as MENU_HEADER_HEIGHT 45 and
--- MENU_HEADER_BUTTONS_LEFT 47, and rounding the ratio reproduces the
--- firmware's own values exactly at 320, 480, and 800 pixels wide.
local BUTTON_WIDTH_RATIO = 47 / 45

--- Read the height EdgeTX draws its menu button at.
---
--- The firmware does publish this to Lua, but registers MENU_HEADER_HEIGHT
--- beside the colour constants and so passes it through COLOR2FLAGS, which
--- shifts a value left by sixteen bits (radio/src/lua/api_general.cpp). The
--- global therefore reads 2949120 on a TX16S rather than 45. Shifting it back
--- is worth the trouble because the firmware scales the real constant per
--- display class, so a radio whose button is not 45 px tall still gets the
--- right answer instead of this file's guess.
---@return integer
local function buttonHeight()
    local raw = MENU_HEADER_HEIGHT
    if type(raw) ~= "number" then
        return BUTTON_HEIGHT
    end

    if raw >= 65536 then
        raw = math.floor(raw / 65536)
    end
    -- A value outside this range is not a button height, whatever it is.
    if raw < 1 or raw > 200 then
        return BUTTON_HEIGHT
    end

    return raw
end

--- Whether EdgeTX has taken this widget fullscreen.
---
--- Read through `pcall` and a type test like every other firmware call here,
--- because a radio too old to carry `isFullScreen` must read as "not
--- fullscreen" rather than as an error -- the widget then behaves exactly as
--- it did before, which is the safe direction: a corner reserved for a
--- button that is drawn.
---@return boolean
local function isFullScreen()
    if type(lvgl) ~= "table" or type(lvgl.isFullScreen) ~= "function" then
        return false
    end
    local ok, value = pcall(lvgl.isFullScreen)
    return ok and value == true
end

--- Report the part of our zone that EdgeTX's menu button covers.
---
--- In App mode the button is the only route to the radio's menus, so it cannot
--- be hidden, and `ViewMain` deliberately creates it after the screen it sits
--- on: view_main.cpp carries the comment "create last to be on top". Anything
--- the dashboard draws underneath it is simply not visible.
---
--- Only App mode overlaps. `ViewMain::updateTopbarVisibility` shows the button
--- when `hasTopbar(view) or isAppMode(view)`, and a layout that has a top bar
--- puts the widget below it: `ViewMainDecoration::getWidgetsZone` starts the
--- widget zone at MENU_HEADER_HEIGHT whenever the bar is shown. A layout with
--- neither hides the button altogether.
---
--- **And the button goes away when the widget goes fullscreen**, which this
--- used to reserve for anyway. `ViewMain::onLongPress` calls
--- `setFullscreen(true)` on an App-mode screen
--- (radio/src/gui/colorlcd/mainview/view_main.cpp:313), `Widget::setFullscreen`
--- runs `ViewMain::instance()->show(!enable)`
--- (radio/src/gui/colorlcd/mainview/widget.cpp:224), and `ViewMain::show`
--- passes that straight to `setEdgeTxButtonVisible(visible and ...)`
--- (view_main.cpp:327). So in fullscreen there is no button, and a corner
--- reserved for one costs that panel a font size for nothing.
---
--- `lvgl.isAppMode` cannot see it: `LayoutAppMode::isAppMode` returns a
--- constant `true` (layout1x1AppMode.cpp:40) and the screen is still that
--- layout. `lvgl.isFullScreen` can, and is asked here.
---
--- **The name is `isFullScreen`, with a capital S.** The C function is
--- `luaLvglIsFullscreen` (api_colorlcd_lvgl.cpp:402) but the name it is
--- registered under is `isFullScreen` (api_colorlcd_lvgl.cpp:447) -- and a
--- misspelling would not fail here, it would read as nil, take the
--- `type(...) == "function"` branch away, and silently keep reserving the
--- corner. Which is the defect, unchanged.
---@param zone AeroGridZone
---@return table? reserved Width and height of the covered corner.
local function reservedCorner(zone)
    local appMode = false
    if type(lvgl) == "table" and type(lvgl.isAppMode) == "function" then
        local ok, value = pcall(lvgl.isAppMode)
        appMode = ok and value == true
    end
    if not appMode then
        return nil
    end
    if isFullScreen() then
        return nil
    end

    local height = buttonHeight()
    local width = math.floor(height * BUTTON_WIDTH_RATIO + 0.5)

    -- A widget's own x and y are always zero; xabs and yabs carry where the zone
    -- actually sits on the screen (radio/src/lua/lua_widget_factory.cpp). The
    -- button is drawn at the screen origin, so what it takes from us is whatever
    -- of it reaches into the zone.
    local left = zone.xabs or 0
    local top = zone.yabs or 0
    if left >= width or top >= height then
        return nil
    end

    return { w = width - left, h = height - top }
end

--- Where the error overlay may start without disappearing under the button.
---@param context AeroGridContext
---@return integer y
local function errorTop(context)
    local reserved = context.reserved
    if not reserved then
        return 8
    end
    return reserved.h + 4
end

--- Render accumulated runtime errors over the dashboard.
--- Reuses the existing label so failures raised after creation stay visible.
---
--- The overlay starts below the region EdgeTX's menu button covers. Drawn at
--- the zone's own origin it lands underneath that button in App mode, which is
--- the deployment this dashboard is primarily built for, so a panel could
--- fail and the radio would show nothing at all.
---@param context AeroGridContext
local function showErrors(context)
    if #context.errors == 0 then
        return
    end

    local text = table.concat(context.errors, "\n")
    if context.errorLabel then
        context.errorLabel:set({ text = text })
        return
    end

    -- Errors can precede theme resolution, so fall back to the Modern critical red.
    local color = context.theme and context.theme.color.critical or lcd.RGB(0xF05252)

    context.errorLabel = lvgl.label(context.page or context.root, {
        x = 8,
        y = errorTop(context),
        w = math.max(1, context.zone.w - 16),
        h = 0,
        text = text,
        color = color,
        font = function()
            return SMLSIZE
        end,
    })
end

--- Show or hide the fullscreen-only editor entry affordance.
---@param context AeroGridContext
local function updateEditorButton(context)
    local width = math.min(72, math.max(1, context.zone.w - 8))
    local x = math.max(4, context.zone.w - width - 6)
    local shown = context.editButton ~= nil
        and not context.editorUi
        and not context.runtimeFailed
        and context.stage == nil
        and context.reloadState == nil
        and context.document ~= nil
        and isFullScreen()
    if context.editButton then
        if context.editButtonX ~= x or context.editButtonWidth ~= width then
            context.editButton:set({ x = x, y = 4, w = width })
            context.editButtonLabel:set({ x = x, y = 4, w = width })
            context.editButtonX = x
            context.editButtonWidth = width
        end
    end
    if context.editButton and context.editorButtonVisible ~= shown then
        local visibility = shown and lvgl.show or lvgl.hide
        visibility(context.editButton)
        visibility(context.editButtonLabel)
        context.editorButtonVisible = shown
    end
end

--- Dispatch one lifecycle callback to every live panel in isolation.
--- A panel that raises is disabled and reported without affecting the others.
---@param context AeroGridContext
---@param event string
---@param ... any
local function dispatchAll(context, event, ...)
    local failures = false

    for _, entry in ipairs(context.panels) do
        if not entry.failed then
            local ok, dispatchError = context.panelHost.dispatch(entry, event, ...)
            if not ok and dispatchError then
                addError(context, entry.placement.id .. ": " .. event .. ": " .. dispatchError)
                failures = true
            end
        end
    end

    if failures then
        showErrors(context)
    end
end

--- Advance to the next layout candidate after a read or parse failure.
---@param context AeroGridContext
---@param reason string
---@return boolean recovered
local function recoverLayout(context, reason)
    local candidates = context.loadCandidates
    if type(candidates) ~= "table" then
        return false
    end

    local index = context.loadCandidateIndex or 0
    local nextIndex = index + 1
    local candidate = candidates[nextIndex]
    if not candidate then
        return false
    end

    context.recoveryCandidate = {
        candidate = candidate,
        index = nextIndex,
        reason = context.recoveryReason or reason,
    }
    context.recoveryReason = context.recoveryCandidate.reason
    context.reloadState = "clear"
    return true
end

--- Enter the editor while preserving the current dashboard until Apply succeeds.
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

    local created, session, sessionError = pcall(
        context.editorModule.new,
        context.document,
        context.grid,
        context.layoutValidator,
        context.panelHost,
        loadPanel
    )
    if not created or not session then
        addError(context, "editor: " .. tostring(sessionError or session))
        showErrors(context)
        return false
    end

    lvgl.hide(context.page)
    context.editorSession = session
    local handlers = {
        editor = context.editorModule,
        loadDefault = function()
            return context.layoutStore.loadDefault(
                context.path,
                context.yaml,
                context.layoutValidator,
                context.grid
            )
        end,
        save = function(document)
            local saved, saveError, filename = context.layoutStore.save(
                context.path,
                context.modelFilename or "default",
                context.dashboardId,
                document,
                context.yaml,
                context.layoutValidator,
                context.grid
            )
            if saved then
                context.layoutPath = filename
                context.layoutOrigin = "model"
            end
            return saved, saveError
        end,
        close = function(saved)
            context.editorUiModule.close(context, false)
            context.editorSession = nil
            if saved then
                context.reloadState = "clear"
            end
            updateEditorButton(context)
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
    updateEditorButton(context)
    return true
end

--- Whether an event or touch activates the fullscreen editor affordance.
---@param context AeroGridContext
---@param widgetEvent any
---@param touchState any
---@return boolean
local function editorEntryHit(context, widgetEvent, touchState)
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
    local enter = rawget(_G, "EVT_VIRTUAL_ENTER")
    if enter ~= nil and widgetEvent == enter then
        return true
    end
    if
        widgetEvent ~= rawget(_G, "EVT_TOUCH_TAP")
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
    local width = math.min(72, math.max(1, context.zone.w - 8))
    local x0 = math.max(4, context.zone.w - width - 6)
    return x >= x0 and x < x0 + width and y >= 4 and y < 30
end

--- The rectangle one placement occupies inside the host zone.
--- Both building and reflow go through this, so the two cannot drift apart.
---@param context AeroGridContext
---@param placement table
---@return AeroGridRect? rect
---@return string? error
local function panelRect(context, placement)
    return context.grid.rect(context.zone, placement, 4, 4, 4)
end

--- The part of one placement's own rectangle the menu button covers.
---
--- Expressed in the panel's coordinates, because a panel is handed a
--- container-local rectangle and can neither see nor reach the zone. On a
--- 480 x 272 display only a placement at column zero, row zero can overlap,
--- but that is a property of the arithmetic rather than a rule, so the
--- intersection is computed rather than assumed.
---@param context AeroGridContext
---@param placement table
---@return table? reserved
local function reservedFor(context, placement)
    local reserved = context.reserved
    if not reserved then
        return nil
    end

    local rect = panelRect(context, placement)
    if not rect then
        return nil
    end

    local width = reserved.w - rect.x
    local height = reserved.h - rect.y
    if width <= 0 or height <= 0 then
        return nil
    end

    return {
        w = width < rect.w and width or rect.w,
        h = height < rect.h and height or rect.h,
        side = placement.rowSpan == 1,
    }
end

--- Assemble the shared objects handed to one panel.
--- Typography depends on the panel's span, so services are built per
--- placement rather than shared across the dashboard. The data services
--- themselves are dashboard-wide singletons and are passed through by
--- reference, so two panels naming the same source share one poll.
---@param context AeroGridContext
---@param placement table
---@return table services
local function buildServices(context, placement)
    local builder = context.themeBuilder
    local theme = context.theme
    local registry = context.serviceRuntime
    local byId = registry and registry.byId or {}

    -- Where the radio paints over us, the theme builder this panel sees
    -- resolves its panel frame around that corner. Binding it here rather than
    -- adding an argument to every panel means a panel written by
    -- someone else is laid out correctly too, without knowing any of this
    -- exists. The reservation is read on each call, not captured, so a zone
    -- that moves is picked up by the update that follows it.
    if context.reserved then
        builder = setmetatable({
            frame = function(resolved, rect, fonts, reserved, badgeText)
                return context.themeBuilder.frame(resolved, rect, fonts, reservedFor(context, placement), badgeText)
            end,
        }, { __index = context.themeBuilder })
    end

    return {
        theme = theme,
        -- The flight session belongs to the dashboard, not to a panel, so it
        -- is handed down rather than configured per panel.
        session = context.session or {},
        primitives = context.primitives,
        themeBuilder = builder,
        fonts = builder.typography(placement.colSpan, placement.rowSpan),
        span = { colSpan = placement.colSpan, rowSpan = placement.rowSpan },
        state = function(name, accentName)
            return builder.state(theme, name, accentName)
        end,
        clock = getTime,
        -- The host's own state, for the diagnostics view and nothing else.
        --
        -- The live context, not a copy. A diagnostics view reporting on a
        -- snapshot assembled for it would be reporting on a world built
        -- separately from the one the dashboard is using, and would be
        -- confidently wrong at exactly the moment it is being trusted. Handing it
        -- over costs one table field per panel and nothing else; a panel
        -- that abuses it is isolated like any other.
        host = context,
        -- Shared data services. Any of these may be absent when its module failed
        -- to load, so a panel must tolerate nil rather than assume.
        telemetry = byId.telemetry,
        model = byId.model,
        control = byId.control,
        extrema = byId.extrema,
        navigation = byId.navigation,
    }
end

--- Load, validate, and instantiate every panel in the selected layout.
--- Instantiate one validated placement.
---@param context AeroGridContext
---@param placement table
local function buildPanel(context, placement)
    local host = context.panelHost

    --- Record a placement that will not be built, and why.
    ---
    --- A panel that never constructs leaves nothing behind but an error in
    --- a banner that may have scrolled, and it is absent from `panels`
    --- because there is no instance to put there. So the reason is kept where
    --- it is known. Without this the diagnostics view could report every panel
    --- that works and no panel that does not, which is the wrong half.
    local function reject(reason)
        addError(context, placement.id .. ": " .. tostring(reason))
        context.rejected[#context.rejected + 1] = {
            placement = placement,
            reason = tostring(reason),
        }
    end

    local panel, panelError = loadModule(context.path, "panels/" .. placement.type .. ".lua")
    local contractValid, contractError

    if panel then
        contractValid, contractError = host.validateModule(panel, placement.type)
    end

    if not panel then
        reject(panelError)
        return
    end
    if not contractValid then
        reject(contractError)
        return
    end
    if not host.supportsSpan(panel, placement.colSpan, placement.rowSpan) then
        reject("panel does not support span " .. host.spanName(placement.colSpan, placement.rowSpan))
        return
    end

    local rect, rectError = panelRect(context, placement)
    if not rect then
        reject(rectError)
        return
    end

    local settings, warnings =
        host.resolveSettings(panel, placement.config, { colSpan = placement.colSpan, rowSpan = placement.rowSpan })
    for _, warning in ipairs(warnings) do
        addError(context, placement.id .. ": " .. warning)
    end

    -- Each panel draws inside its own container, so it cannot reach the
    -- dashboard root or paint over a neighbour. The container is deliberately
    -- unpainted; the panel's own panel fills it.
    local container = lvgl.box(context.page, {
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = rect.h,
    })

    local services = buildServices(context, placement)
    local ok, instance = pcall(panel.create, container, { x = 0, y = 0, w = rect.w, h = rect.h }, settings, services)

    -- A heading too long for its column is cut to fit, because the alternative
    -- is LVGL wrapping it down over the reading. Cutting a name the author
    -- chose is a loss, so it is reported rather than done quietly: being told
    -- is what makes it an abbreviation instead of a corruption, and the author
    -- can pick a shorter heading.
    --
    -- Collected from the primitive that did the cutting rather than read back
    -- off the label. A label is userdata on a radio and answers no questions
    -- about itself, so asking it produced nil there and the truth here.
    --
    -- Drained whether or not the panel survived. A panel that raises after
    -- drawing its header leaves a report behind, and a report left behind is
    -- one the next panel would be blamed for.
    local reports = context.primitives.headingReports
    if #reports > 0 then
        for _, report in ipairs(reports) do
            addNotice(
                context,
                "warning",
                placement.id
                    .. ": heading "
                    .. tostring(report.requested)
                    .. " does not fit this panel and is drawn as "
                    .. tostring(report.drawn)
            )
        end
        context.primitives.headingReports = {}
    end

    if ok then
        local interval = host.refreshInterval(panel)
        context.panels[#context.panels + 1] = {
            placement = placement,
            module = panel,
            instance = instance,
            settings = settings,
            container = container,
            interval = interval,
            -- Stagger panels that share an interval so they do not all fall
            -- due on the same frame.
            nextRefresh = getTime() + host.phaseOffset(interval, #context.panels + 1),
        }
    else
        -- Discard whatever the failed panel managed to build.
        container:clear()
        reject(instance)
    end
end

--- Lines tokenized per widget callback.
local TOKENIZE_LINES = 24

--- Advance the staged loader by exactly one step.
--- EdgeTX allows roughly 20000 VM instructions per widget callback, and a
--- whole dashboard costs far more than that, so loading is spread over
--- consecutive calls. Every stage is bounded by a fixed amount of work rather
--- than by the size of the layout: the file is tokenized a fixed number of
--- lines at a time, and each panel is parsed, validated, and built in its
--- own callback. A layout that fills the grid therefore costs more callbacks,
--- never a larger callback.
---@param context AeroGridContext
---@return boolean busy True while more work remains.
local function advanceLoad(context)
    local stage = context.stage

    --- Abandon the load, reporting why.
    local function fail(message)
        if stage ~= "services" and recoverLayout(context, tostring(message)) then
            return true
        end
        addError(context, context.recoveryReason or message)
        context.stage = nil
        context.tokens = nil
        context.source = nil
        context.loadCandidates = nil
        context.loadCandidateIndex = nil
        updateEditorButton(context)
        showErrors(context)
        return false
    end

    if stage == "read" then
        -- The runtime may have failed to load; refuse rather than index nil.
        if not context.layoutStore then
            return fail("AeroGrid runtime module failed to load")
        end

        local modelInfo = model.getInfo()
        local content, readError, filename, origin, candidates
        local recoveryIndex
        if context.recoveryCandidate then
            local recovery = context.recoveryCandidate
            context.recoveryCandidate = nil
            context.recoveryReason = recovery.reason
            local candidate = recovery.candidate
            content, readError = context.layoutStore.readCandidate(candidate.filename)
            filename, origin = candidate.filename, candidate.origin
            candidates = context.layoutStore.candidates(
                context.path,
                modelInfo and modelInfo.filename or "default",
                context.dashboardId
            )
            recoveryIndex = recovery.index
        elseif type(context.layoutStore.readCandidates) == "function" then
            content, readError, filename, origin, candidates = context.layoutStore.readCandidates(
                context.path,
                modelInfo and modelInfo.filename or "default",
                context.dashboardId
            )
        else
            content, readError, filename, origin = context.layoutStore.read(
                context.path,
                modelInfo and modelInfo.filename or "default",
                context.dashboardId
            )
        end

        if content or context.layoutPath == nil then
            context.layoutPath = filename
            context.layoutOrigin = origin
        end
        context.modelFilename = modelInfo and modelInfo.filename or nil
        context.loadCandidates = candidates
        context.loadCandidateIndex = recoveryIndex
        if candidates and not recoveryIndex then
            for index, candidate in ipairs(candidates) do
                if candidate.filename == filename then
                    context.loadCandidateIndex = index
                    break
                end
            end
            if not context.loadCandidateIndex and origin == "none" then
                context.loadCandidateIndex = #candidates
            end
        end
        if not content then
            return fail(readError)
        end

        context.source = content
        context.tokens = {}
        context.readPosition = 1
        context.readLine = 1
        context.stage = "tokenize"
        return true
    end

    if stage == "tokenize" then
        local position, line, tokenError = context.yaml.tokenizeChunk(
            context.source,
            context.readPosition,
            context.readLine,
            TOKENIZE_LINES,
            context.tokens
        )

        if tokenError then
            return fail(tokenError)
        end

        context.readLine = line
        if position then
            context.readPosition = position
            return true
        end

        context.source = nil
        context.stage = "header"
        return true
    end

    if stage == "header" then
        local tokens = context.tokens
        if not tokens then
            return fail("layout tokens are missing")
        end
        -- Split the panel sequence out so the document itself stays small.
        local header, panelsIndex, panelsIndent = {}, nil, nil
        local index = 1

        while index <= #tokens do
            local token = tokens[index]
            if token.indent == 0 and string.match(token.content, "^panels:") then
                panelsIndex = index + 1
                index = index + 1
                -- Skip the sequence body; it is parsed one entry at a time later.
                while index <= #tokens and tokens[index].indent > 0 do
                    panelsIndent = panelsIndent or tokens[index].indent
                    index = index + 1
                end
            else
                header[#header + 1] = token
                index = index + 1
            end
        end

        if not panelsIndex then
            return fail("panels must be a sequence")
        end

        local document, buildError = context.yaml.build(header)
        if not document then
            return fail(buildError)
        end

        local validated, headerErrors = context.layoutValidator.validateDocument(document)
        if not validated or #(headerErrors or {}) > 0 then
            local reason = table.concat(headerErrors or { "unsupported layout header" }, "; ")
            if recoverLayout(context, reason) then
                return true
            end
            if context.recoveryReason then
                addError(context, context.recoveryReason)
            else
                for _, headerError in ipairs(headerErrors or {}) do
                    addError(context, headerError)
                end
            end
            context.stage = nil
            context.tokens = nil
            context.loadCandidates = nil
            context.loadCandidateIndex = nil
            updateEditorButton(context)
            showErrors(context)
            return false
        end

        -- A layout may pin its own theme; otherwise the native option decides.
        local themeConfig = validated.theme or {}
        -- Which of the two asked for this palette. The resolved theme records the
        -- mode it settled on and not where the request came from, and the widget
        -- option was inert for a while while looking exactly like a working one.
        context.themeSource = themeConfig.mode and "layout" or "option"
        context.theme = context.themeBuilder.build(themeConfig.mode or context.themeMode, themeConfig.overrides)
        for _, warning in ipairs(context.theme.warnings) do
            addError(context, "theme: " .. warning)
        end
        for _, notice in ipairs(context.theme.notices) do
            addNotice(context, notice.severity, "theme: " .. notice.text)
        end
        context.canvas:set({ color = context.theme.color.canvas })

        context.session = validated.session or {}
        context.document = validated
        context.itemIndex = panelsIndex
        context.itemIndent = panelsIndent or 2
        context.itemNumber = 0
        context.identifiers = {}
        context.serviceIndex = 0
        context.stage = "services"
        return true
    end

    if stage == "services" then
        -- Services are staged for the same reason panels are: each module has
        -- to be compiled and run, and the whole set does not fit in one callback.
        -- They are built before any panel, so a panel can subscribe from
        -- inside its own create call.
        local index = context.serviceIndex

        if index == 0 then
            local support, supportError = loadModule(context.path, "lib/services.lua", context.packageInfo.runtimeApi)
            if not support then
                -- A dashboard without services still renders: every panel sees
                -- nil and must degrade to an unavailable presentation.
                addError(context, "services: " .. tostring(supportError))
                context.serviceIndex = nil
                context.stage = "panels"
                return true
            end

            context.servicesModule = support
            context.serviceRuntime = support.runtime(support.environment())
            context.serviceIndex = 1
            return true
        end

        local definition = context.servicesModule.DEFINITIONS[index]
        if not definition then
            context.serviceIndex = nil
            context.stage = "panels"
            return true
        end

        context.serviceIndex = index + 1

        local module, moduleError = loadModule(context.path, definition.file, context.packageInfo.runtimeApi)
        local constructor = module and rawget(module, "new") or nil
        if type(constructor) == "function" then
            local runtime = context.serviceRuntime
            if not runtime then
                return fail("service runtime is missing")
            end
            local ok, instance = pcall(constructor, runtime.env, context.servicesModule, runtime)
            if ok and type(instance) == "table" then
                context.servicesModule.register(runtime, instance, getTime())
            else
                addError(context, definition.id .. ": " .. tostring(instance))
            end
        else
            addError(context, definition.id .. ": " .. tostring(moduleError or "service module has no constructor"))
        end

        return true
    end

    if stage == "panels" then
        local tokens = context.tokens
        local index = context.itemIndex

        if not tokens then
            return fail("layout tokens are missing")
        end
        local token = index and tokens[index] or nil
        if not index or not token or token.indent < context.itemIndent then
            context.tokens = nil
            context.stage = nil
            context.loadCandidates = nil
            context.loadCandidateIndex = nil
            if context.recoveryReason then
                addNotice(context, "warning", "layout recovered after: " .. context.recoveryReason)
                context.recoveryReason = nil
            end
            updateEditorButton(context)
            showErrors(context)
            return false
        end

        local placement, nextIndex, itemError = context.yaml.itemAt(tokens, index, context.itemIndent)
        if itemError then
            return fail(itemError)
        end

        context.itemIndex = nextIndex
        context.itemNumber = context.itemNumber + 1

        local valid, panelError = context.layoutValidator.validatePanel(
            placement,
            context.itemNumber,
            context.grid,
            context.document.panels,
            context.identifiers
        )

        if valid then
            context.identifiers[placement.id] = true
            context.document.panels[#context.document.panels + 1] = placement
            buildPanel(context, placement)
        else
            addError(context, panelError)
        end

        return true
    end

    return false
end

--- Begin a staged load, discarding anything already on screen.
---@param context AeroGridContext
local function beginLoad(context)
    context.panels = {}
    context.rejected = {}
    context.errors = {}
    context.notices = {}
    context.errorLabel = nil
    context.tokens = nil
    context.source = nil
    context.document = nil
    context.identifiers = nil
    context.itemIndex = nil
    context.loadCandidates = nil
    context.loadCandidateIndex = nil
    context.itemNumber = 0
    -- Subscriptions belong to the panels that made them, so the registry is
    -- rebuilt with the dashboard rather than reused across a reload.
    context.serviceRuntime = nil
    context.serviceIndex = nil
    context.stage = "read"
end

--- Create one AeroGrid host instance for an EdgeTX custom-screen zone.
---@param zone AeroGridZone
---@param widgetOptions AeroGridWidgetOptions
---@param path string Absolute widget directory supplied by EdgeTX.
---@return AeroGridContext
local function create(zone, widgetOptions, path)
    local context = {
        zone = zone,
        path = path,
        dashboardId = widgetOptions.DashID,
        themeMode = widgetOptions.Theme,
        panels = {},
        rejected = {},
        errors = {},
        notices = {},
        width = zone.w,
        height = zone.h,
        left = zone.xabs or 0,
        top = zone.yabs or 0,
        -- Resolved before any module is loaded, because the overlay that reports a
        -- failed module load is itself placed against this.
        reserved = reservedCorner(zone),
        -- Held so the reflow trigger has something to compare against. Read
        -- here rather than left nil, because nil against false is a difference
        -- and would reflow the whole grid once on the first callback of every
        -- panel's life.
        fullScreen = isFullScreen(),
    }

    local package, packageError = loadModule(path, "lib/package.lua")
    if
        package
        and (
            type(package.version) ~= "string"
            or package.version == ""
            or package.runtimeApi ~= 1
            or package.panelApi ~= 1
            or package.layoutVersion ~= 1
        )
    then
        package = nil
        packageError = "incompatible package contract; copy the complete AeroGrid package"
    end
    context.packageInfo = package
    if not package then
        addError(context, "package: " .. tostring(packageError))
    else
        local function runtimeModule(relative)
            local module, err = loadModule(path, relative, package.runtimeApi)
            if not module then
                addError(context, relative .. ": " .. tostring(err))
            end
            return module
        end
        context.grid = runtimeModule("lib/grid.lua")
        context.yaml = runtimeModule("lib/yaml.lua")
        context.layoutValidator = runtimeModule("lib/layout.lua")
        context.layoutStore = runtimeModule("lib/layout_store.lua")
        context.panelHost = runtimeModule("lib/panel_host.lua")
        context.themeBuilder = runtimeModule("lib/theme.lua")
        context.primitives = runtimeModule("lib/primitives.lua")
        if context.panelHost and context.panelHost.API_VERSION ~= package.panelApi then
            addError(context, "panel host: incompatible panel API")
            context.panelHost = nil
        end
    end

    context.root = lvgl.box({
        x = 0,
        y = 0,
        w = zone.w,
        h = zone.h,
    })

    -- The canvas must be a filled rectangle. A box ignores `color`, leaving the
    -- radio's own screen background, including its logo, visible behind us.
    -- Everything the dashboard draws lives inside a page, so a reload can
    -- discard the page wholesale and build the next one somewhere the discarded
    -- one's deferred cleanup cannot reach. The root itself is never cleared.
    context.page = lvgl.box(context.root, { x = 0, y = 0, w = zone.w, h = zone.h })

    context.canvas = lvgl.rectangle(context.page, {
        x = 0,
        y = 0,
        w = zone.w,
        h = zone.h,
        color = lcd.RGB(0x101316),
        filled = true,
    })

    context.editButton = lvgl.rectangle(context.root, {
        x = math.max(4, zone.w - 78),
        y = 4,
        w = math.min(72, math.max(1, zone.w - 8)),
        h = 26,
        color = lcd.RGB(0x212830),
        filled = true,
    })
    context.editButtonLabel = lvgl.label(context.root, {
        x = math.max(4, zone.w - 78),
        y = 4,
        w = math.min(72, math.max(1, zone.w - 8)),
        h = 26,
        text = "EDIT",
        color = lcd.RGB(0xF4F6F7),
        font = function()
            return SMLSIZE
        end,
    })
    updateEditorButton(context)

    if
        not context.packageInfo
        or not context.grid
        or not context.yaml
        or not context.layoutValidator
        or not context.layoutStore
        or not context.panelHost
        or not context.themeBuilder
        or not context.primitives
    then
        -- Nothing can be loaded without the runtime, and an option change must not
        -- be able to restage a load that would then index a missing module.
        context.runtimeFailed = true
        addError(context, "AeroGrid runtime module failed to load")
        showErrors(context)
    else
        -- Loading is deliberately deferred to refresh(). Doing it here would
        -- exceed EdgeTX's per-callback instruction budget on a full dashboard.
        beginLoad(context)
        updateEditorButton(context)
    end

    return context
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
    updateEditorButton(context)
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

--- Apply native host options; changing Dashboard ID or Theme rebuilds safely.
---@param context AeroGridContext
---@param widgetOptions AeroGridWidgetOptions
local function update(context, widgetOptions)
    local dashboardId = widgetOptions.DashID
    local themeMode = widgetOptions.Theme

    -- Without a runtime there is nothing to rebuild, and restaging would fail.
    if context.runtimeFailed then
        return
    end

    if dashboardId ~= context.dashboardId or themeMode ~= context.themeMode then
        context.dashboardId = dashboardId
        context.themeMode = themeMode
        context.reloadState = "clear"
    end
end
--- Translate compact native option keys into user-facing labels.
---@param name string
---@return string
local function translate(name)
    if name == "DashID" then
        return "Dashboard ID"
    end
    if name == "Theme" then
        return "Theme"
    end
    return name
end

--- Offer an input event to panels until one consumes it.
---@param context AeroGridContext
---@param widgetEvent any
---@return boolean consumed
local function event(context, widgetEvent, touchState)
    if context.editorUi then
        return context.editorUiModule.handle(context, widgetEvent, touchState)
    end
    if editorEntryHit(context, widgetEvent, touchState) then
        openEditor(context)
        return true
    end

    for _, entry in ipairs(context.panels) do
        if not entry.failed then
            local ok, dispatchError, consumed = context.panelHost.dispatch(entry, "event", widgetEvent)
            if not ok and dispatchError then
                addError(context, entry.placement.id .. ": event: " .. dispatchError)
                showErrors(context)
            elseif consumed then
                return true
            end
        end
    end

    return false
end

--- Panels refreshed per frame at most, regardless of how many fall due.
--- Phase staggering normally keeps the number well below this; the cap is a
--- guarantee for layouts that defeat staggering, such as many panels all
--- asking to refresh every frame.
local REFRESH_CAP = 6

--- Dispatch `refresh` to the panels that are due, newest cursor first.
--- Returns the number dispatched so tests can observe the scheduling.
---@param context AeroGridContext
---@return integer dispatched
local function dispatchDue(context)
    local panels = context.panels
    local count = #panels
    if count == 0 then
        return 0
    end

    local now = getTime()
    local cursor = context.refreshCursor or 1
    if cursor > count then
        cursor = 1
    end

    local dispatched, failures, examined = 0, false, 0

    while examined < count and dispatched < REFRESH_CAP do
        local entry = panels[cursor]
        examined = examined + 1

        if entry and not entry.failed and now >= (entry.nextRefresh or 0) then
            -- Advance from now, so a panel starved by the cap does not
            -- accumulate a backlog of missed deadlines.
            entry.nextRefresh = now + entry.interval
            dispatched = dispatched + 1

            local ok, dispatchError = context.panelHost.dispatch(entry, "refresh")
            if not ok and dispatchError then
                addError(context, entry.placement.id .. ": refresh: " .. dispatchError)
                failures = true
            end
        end

        cursor = cursor % count + 1
    end

    -- Resume from where we stopped so every panel is served in turn.
    context.refreshCursor = cursor
    if failures then
        showErrors(context)
    end

    return dispatched
end

--- Advance the shared data services by at most one service per callback.
--- Services are charged to the same instruction budget as everything else, so
--- polling all five every cycle is not affordable. Each service declares its
--- own interval and caps how much it reads in one update, and the registry
--- serves whichever due service is next in rotation.
---@param context AeroGridContext
---@return string? id Service updated, for tests and error reporting.
local function updateServices(context)
    local registry = context.serviceRuntime
    if not registry then
        return nil
    end

    local id, serviceError = context.servicesModule.update(registry, getTime())
    if serviceError then
        addError(context, id .. ": " .. serviceError)
        showErrors(context)
    end

    return id
end

--- Advance the staged loader, then keep geometry and panels synchronized.
--- At most one loading step runs per call, so the instruction budget is never
--- exceeded no matter how large the layout is.
---@param context AeroGridContext
---@param widgetEvent? number Fullscreen input supplied by EdgeTX.
---@param touchState? table
local function refresh(context, widgetEvent, touchState)
    if context.editorUi and not isFullScreen() then
        context.editorUiModule.close(context, true)
        context.editorSession = nil
    end

    -- A reload takes two callbacks on purpose. EdgeTX defers the cleanup that
    -- follows `clear()` until after the callback returns, and that cleanup
    -- invalidates every object in the cleared object's child list, including
    -- ones created after the clear in the same callback. Anything rebuilt here
    -- would therefore be swept before it was ever drawn.
    if context.reloadState == "clear" then
        dispatchAll(context, "destroy")

        -- Discard the whole page. EdgeTX collects the clear whenever it next runs
        -- callRefs, which is not guaranteed to be this callback: it is skipped
        -- while the widget is off screen, such as behind the settings dialog, and
        -- once an error has been reported. The next page is therefore built as a
        -- fresh child of the root, where this pending cleanup cannot reach it.
        context.page:clear()
        lvgl.hide(context.page)

        context.page = nil
        context.canvas = nil
        context.panels = {}
        context.rejected = {}
        context.errors = {}
        context.notices = {}
        context.errorLabel = nil
        context.reloadState = "rebuild"
        return
    end

    if context.reloadState == "rebuild" then
        context.page = lvgl.box(context.root, {
            x = 0,
            y = 0,
            w = context.zone.w,
            h = context.zone.h,
        })
        context.canvas = lvgl.rectangle(context.page, {
            x = 0,
            y = 0,
            w = context.zone.w,
            h = context.zone.h,
            color = context.theme and context.theme.color.canvas or lcd.RGB(0x101316),
            filled = true,
        })
        context.reloadState = nil
        beginLoad(context)
        return
    end

    if context.stage then
        advanceLoad(context)
        return
    end

    -- EdgeTX delivers fullscreen input through refresh, not an event callback.
    if widgetEvent ~= nil and widgetEvent ~= 0 and isFullScreen() then
        event(context, widgetEvent, touchState)
        if context.reloadState then
            return
        end
    end

    -- A zone change repositions every panel, which a full grid cannot
    -- afford in one callback, so it is batched like loading. The absolute
    -- position matters as well as the size, because it decides whether the
    -- EdgeTX menu button reaches into us.
    --
    -- **And so does going fullscreen, which moves nothing.** On the App-mode
    -- layout this dashboard ships on, the widget's zone is already the whole
    -- screen, so `Widget::setFullscreen` changes none of the four numbers
    -- above -- it hides `ViewMain` and the menu button with it. A reflow keyed
    -- on geometry alone therefore never fires, and the panel in the corner
    -- keeps a reservation for a button that is no longer drawn.
    --
    -- It is a poll rather than an event, because there is no event to have:
    -- entering fullscreen calls the widget's `update` (widget.cpp:265) and
    -- *leaving* it does not, that call being guarded by `if (fullscreen)`.
    -- `refreshWidgets` keeps calling `foreground` on a fullscreen widget
    -- (widgets_container.cpp:91), so the change is seen on the next callback,
    -- which is one `MENU_TASK_PERIOD` -- 50 ms (radio/src/tasks.cpp:50).
    if
        context.width ~= context.zone.w
        or context.height ~= context.zone.h
        or context.left ~= (context.zone.xabs or 0)
        or context.top ~= (context.zone.yabs or 0)
        or context.fullScreen ~= isFullScreen()
    then
        beginReflow(context)
    end
    updateEditorButton(context)
    if context.reflowIndex then
        advanceReflow(context)
        return
    end

    -- Services are refreshed before panels so every panel rendering this
    -- cycle sees the same set of readings.
    updateServices(context)
    dispatchDue(context)
end

--- Keep panels updated while the dashboard screen is not visible.
--- Services keep running here too, so flight extrema and timers do not develop
--- a hole whenever the pilot looks at another screen.
---@param context AeroGridContext
local function background(context)
    if context.stage or context.reloadState or context.reflowIndex then
        return
    end
    updateServices(context)
    dispatchAll(context, "background")
end

return {
    name = "AeroGrid",
    options = options,
    create = create,
    update = update,
    refresh = refresh,
    background = background,
    event = event,
    translate = translate,
    useLvgl = true,
}
