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
---@field Layout integer|string Position in the layout registry, or a layout name.
---@field Theme integer|string Position in the theme catalog; or a theme name.

---@class AeroGridContext
---@field zone AeroGridZone Live zone table maintained by EdgeTX.
---@field path string Absolute widget directory path.
---@field layoutName string Layout name selected in native widget settings.
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
---@field themeMode string Name selected in native widget settings.
---@field radioBackground boolean Whether the radio theme shows through the canvas.
---@field panelOpacity integer Panel fill opacity, from 0 to 255.
---@field services table Shared objects handed to panels.
---@field rejected table[] Placements that would not build, with the reason.
---@field layoutPath? string
---@field layoutOrigin? string Which filename answered: user, shipped, default, none.
---@field modelFilename? string Current model filename, for diagnostics.
---@field themeSource? string Theme selection source.
---@field errorLabel? any
---@field page any Container holding one generation of the dashboard.
---@field reloadState? "clear"|"rebuild"
---@field stage? "theme-read"|"theme-validate"|"read"|"tokenize"|"header"|"header-migrate"|"header-finalize"|"glass"|"services"|"panels"|"debrief"|"panel-migrate"|"panel-validate"|"panel-build"|"load-complete" Staged loader position.
---@field foreground? boolean Whether the latest callback was visible.
---@field firstRefreshUntil? integer Bounded foreground priority until a regular panel refresh.
---@field servicesModule? table Loaded lib/services.lua registry module.
---@field packageInfo? table Package identity and compatibility versions.
---@field serviceRuntime? table Registry holding every constructed service.
---@field serviceIndex? integer Next service definition to construct.
---@field source? string Layout text held between the read and tokenize steps.
---@field tokens? table Tokens held between the tokenize and parse steps.
---@field pending? table[] Validated placements still awaiting construction.
---@field pendingIndex? integer Next placement to build.
---@field loadConfigured? boolean Layout validation and flight registration have completed.
---@field scheduler table Slot scheduler that runs panels and services.
---@field dashboardLoader table Staged layout and panel construction.
---@field dashboardLifecycle table Page retirement, reflow, and rebuild.
---@field editorController table Dashboard preview and editor coordination.
---@field editorModule? table On-radio layout editor, loaded only on demand.
---@field editorUiModule? table LVGL editor controls, loaded only on demand.
---@field editorSession? table Uncommitted editor working copy.
---@field editorUi? table Active editor screen state.
---@field editorDebriefRequest? boolean Open the Flight debrief page (true) or the grid (false).
---@field debriefPageModule? table Flight debrief setup page, loaded only on demand.
---@field debriefGenerated? boolean The document's debrief was derived from its panels, not loaded.
---@field derivedDebrief? table The derived debrief section, while it is the document's.
---@field debriefDeriving? table|boolean The load derives a debrief: true, then its loaded module.

local WIDGET_PATH = "/WIDGETS/AeroGrid/"

local function directory(path)
    return string.sub(path, -1) == "/" and path or path .. "/"
end

local function themePaths(base, name)
    local folder = directory(base)
    local root = string.match(folder, "^(.*/)WIDGETS/[^/]+/$") or folder
    local filename = name .. ".yml"
    return root .. "AEROGRID/themes/" .. filename, folder .. "themes/" .. filename
end

--- Read one user theme, falling back to its shipped definition.
---@param base string Widget directory.
---@param name string Theme file stem.
---@param parser table YAML parser.
---@param pickerOnly? boolean Read only the name and label during widget registration.
---@return table? definition
---@return string? error
local function readThemeDefinition(base, name, parser, pickerOnly)
    if type(name) ~= "string" or not string.match(name, "^[%w_-]+$") then
        return nil, "invalid theme name"
    end
    local userFile, shippedFile = themePaths(base, name)
    for _, filename in ipairs({ userFile, shippedFile }) do
        local info = type(fstat) == "function" and fstat(filename) or nil
        local size = type(info) == "table" and info.size or nil
        if type(size) == "number" and size > 0 then
            local handle, openError = io.open(filename, "r")
            if not handle then
                return nil, openError or ("cannot open " .. filename)
            end
            -- EdgeTX exposes io.read(handle, size), unlike standard Lua.
            ---@diagnostic disable-next-line: param-type-mismatch
            local content = io.read(handle, size)
            io.close(handle)
            if type(content) ~= "string" then
                return nil, "cannot read " .. filename
            end
            if pickerOnly then
                -- Registration has one instruction budget for every installed theme.
                -- Parse only picker metadata here; the staged loader validates palettes.
                local fields = {}
                for line in string.gmatch("\n" .. content, "\n([^%s#][^\r\n]*)") do
                    if string.match(line, "^name%s*:") or string.match(line, "^label%s*:") then
                        fields[#fields + 1] = line
                    end
                end
                content = table.concat(fields, "\n")
            end
            local definition, parseError = parser.parse(content)
            if not definition then
                return nil, filename .. ": " .. tostring(parseError)
            end
            if type(definition) ~= "table" or definition.name ~= name then
                return nil, filename .. ": theme name must match the filename"
            end
            return definition
        end
    end
    return nil, "theme file is missing: " .. name .. ".yml"
end

--- Load an ordered set of per-theme YAML files as the theme builder catalog.
---@param base string Widget directory.
---@param names string[]
---@param selected string?
---@param parser table YAML parser.
---@param pickerOnly? boolean
---@return table? document
---@return string? error
local function readThemeCatalog(base, names, selected, parser, pickerOnly)
    local definitions = {}
    local included = {}
    local ordered = {}
    for _, name in ipairs(names) do
        if not included[name] then
            included[name] = true
            ordered[#ordered + 1] = name
        end
    end
    if selected and not included[selected] then
        ordered[#ordered + 1] = selected
    end
    if not included["modern-dark"] then
        table.insert(ordered, 1, "modern-dark")
    end

    for _, name in ipairs(ordered) do
        local definition, err = readThemeDefinition(base, name, parser, pickerOnly)
        if definition then
            definitions[#definitions + 1] = definition
        elseif err ~= "theme file is missing: " .. name .. ".yml" then
            return nil, err
        end
    end
    return { version = 1, themes = definitions }
end

local function loadYamlParser(base)
    local folder = directory(base)
    local chunk, loadError = loadScript(folder .. "lib/yaml.lua")
    if not chunk then
        return nil, loadError
    end
    local loaded, module = pcall(chunk)
    if not loaded or type(module) ~= "table" then
        return nil, loaded and "lib/yaml.lua did not return a module table" or module
    end
    return module
end

local themeRegistry
local themeRegistryChunk = type(loadScript) == "function" and loadScript(WIDGET_PATH .. "lib/theme_registry.lua") or nil
if themeRegistryChunk then
    local ok, module = pcall(themeRegistryChunk)
    if ok and type(module) == "table" then
        themeRegistry = module
    end
end

local themeYamlParser = loadYamlParser(WIDGET_PATH)
local themeModes = { "modern-dark", "modern-light" }
if themeRegistry and type(dir) == "function" then
    local ok, names = pcall(themeRegistry.load, WIDGET_PATH)
    if ok and type(names) == "table" and #names > 0 then
        themeModes = names
    end
end
local startupThemeCatalog
if themeRegistry and themeYamlParser then
    startupThemeCatalog = readThemeCatalog(WIDGET_PATH, themeModes, nil, themeYamlParser, true)
end

--- Layout names behind the native CHOICE option, built once at script load.
--- Without `dir` (an older firmware, or a host test) only Empty is offered.
local layoutNames = { "Empty" }
if type(dir) == "function" and type(loadScript) == "function" then
    local chunk = loadScript(WIDGET_PATH .. "lib/layout_registry.lua")
    local loaded, registry = pcall(chunk or error)
    if loaded and type(registry) == "table" then
        local listed, names = pcall(registry.load, "/", WIDGET_PATH)
        if listed and type(names) == "table" and #names > 0 then
            layoutNames = names
        end
    end
end

--- Theme names and labels behind the native CHOICE option.
local THEME_MODES, themeLabels = themeModes, {}
-- Keep the virtual mode outside the custom theme filename namespace.
local GLASS_THEME = "@glass"
local labels = {}
for _, definition in ipairs(startupThemeCatalog and startupThemeCatalog.themes or {}) do
    if type(definition.name) == "string" then
        labels[definition.name] = definition.label
    end
end
labels["modern-dark"] = "Dark"
labels["modern-light"] = "Light"
for _, name in ipairs(THEME_MODES) do
    themeLabels[#themeLabels + 1] = labels[name] or name
end
THEME_MODES[#THEME_MODES + 1], themeLabels[#themeLabels + 1] = GLASS_THEME, "Glass"

local options = {
    { "Layout", CHOICE, 1, layoutNames },
    { "Theme", CHOICE, 1, themeLabels },
}

--- Resolve the Layout option to a name. A stale position selects Empty.
---@param value any
---@return string
local function layoutName(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return layoutNames[tonumber(value) or 1] or layoutNames[1]
end

--- Resolve the Theme option to a catalog name. An unknown position selects modern-dark.
---@param value any
---@return string
local function themeModeOf(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return THEME_MODES[tonumber(value) or 1] or "modern-dark"
end

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

-- Every instance shares one copy of each compiled module (about 1 MiB of
-- bytecode) instead of loading its own; EdgeTX's Lua heap is capped at 6 MiB.
-- Only the compiled chunk is shared. Each instance still runs it to get fresh
-- module state. The cost is that edited files are not re-read until EdgeTX
-- restarts this Lua state.
local chunkCache = {}

--- Load a compiled module chunk once per Lua state; failures are not cached.
---@param filename string
---@return function? chunk
---@return string? error
local function loadChunk(filename)
    local chunk = chunkCache[filename]
    if chunk then
        return chunk
    end
    local loadError
    chunk, loadError = loadScript(filename)
    if chunk then
        chunkCache[filename] = chunk
    end
    return chunk, loadError
end

--- Load and execute a Lua module while containing compile/runtime failures.
---@param base string
---@param relative string
---@param runtimeApi? integer Required internal module API.
---@param ... table Composition dependencies passed to the module chunk.
---@return table? module
---@return string? error
local function loadModule(base, relative, runtimeApi, ...)
    local chunk, loadError = loadChunk(joinPath(base, relative))
    if not chunk then
        return nil, loadError
    end

    local ok, module = pcall(chunk, ...)
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

local ERROR_LOG_LIMIT = 64

local function logError(context, message)
    local text = "[AeroGrid] ERROR layout="
        .. tostring(context.layoutName or "--")
        .. " model="
        .. tostring(context.modelFilename or "--")
        .. ": "
        .. tostring(message)
    local history = context.errorLog
    if not history then
        history = { messages = {}, order = {}, next = 1 }
        context.errorLog = history
    end
    if history.messages[text] then
        return
    end
    -- Keep deduplication bounded, and retain it across this widget's reloads.
    local expired = history.order[history.next]
    if expired then
        history.messages[expired] = nil
    end
    history.messages[text] = true
    history.order[history.next] = text
    history.next = history.next % ERROR_LOG_LIMIT + 1
    print(text)
end

--- Append a user-visible runtime error and mirror it to the firmware console.
---@param context AeroGridContext
---@param message any
local function addError(context, message)
    context.errors[#context.errors + 1] = tostring(message)
    logError(context, message)
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
--- Fullscreen hides the native button. AeroGrid replaces it with its own menu
--- using the same button dimensions, so the reservation remains unchanged.
---@param zone AeroGridZone
---@return table? reserved Width and height of the covered corner.
local function reservedCorner(zone)
    local appMode = false
    if type(lvgl) == "table" and type(lvgl.isAppMode) == "function" then
        local ok, value = pcall(lvgl.isAppMode)
        appMode = ok and value == true
    end
    if not appMode and not isFullScreen() then
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
    if #context.errors == 0 and not context.flightErrorText then
        if context.errorLabel then
            context.errorLabel:set({ text = "" })
        end
        return
    end

    local text = table.concat(context.errors, "\n")
    if context.flightErrorText then
        text = text == "" and context.flightErrorText or text .. "\n" .. context.flightErrorText
    end
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

local sharedDiagnosticsLog
-- One telemetry publisher for every AeroGrid widget, so derived counters
-- advance once however many dashboards report the same flight.
local sharedTelemetry = {}
local flightFactories = {}

--- Failure handlers: each task's `onError` records a failure on its owner.
local function hostError(task)
    task.host.runtimeFailed = true
end

local function initializeError(task, message)
    local context = task.host
    context.runtimeFailed = true
    local member = context.flightFactory.members[context]
    if member then
        member.pending, member.error = false, message
        context.flightFactory.revision = (context.flightFactory.revision or 0) + 1
    end
end

local function flightError(task, message)
    task.broker:error("detection", message)
end

local function serviceError(task)
    task.owner.failed = true
end

local function panelError(task, message)
    local context, entry = task.host, task.owner
    if not entry.failed then
        entry.failed, entry.error = true, message
    end
end

local function newScheduler(context, schedulerModule)
    local ok, scheduler = pcall(schedulerModule.new, {
        fail = function(task, message)
            task.onError(task, message)
            addError(context, task.name .. ": " .. message)
            context.schedulerFailed = true
        end,
    })
    if not ok or type(scheduler) ~= "table" then
        addError(context, "lib/scheduler.lua: " .. tostring(ok and "constructor did not return a table" or scheduler))
        return nil
    end
    for _, operation in ipairs({ "add", "clear", "run", "state", "stats" }) do
        if type(rawget(scheduler, operation)) ~= "function" then
            addError(context, "lib/scheduler.lua: missing operation " .. operation)
            return nil
        end
    end
    return scheduler
end

local initialize

--- The debrief body and its leading bar share one moving sheet above the panels.
---@param context AeroGridContext
local function addPageLayers(context, zone)
    context.panelLayer = lvgl.box(context.page, { x = 0, y = 0, w = zone.w, h = zone.h, scrollDir = 0 })
    context.debriefOverlay = lvgl.box(context.page, { x = 0, y = zone.h, w = zone.w, h = zone.h, scrollDir = 0 })
    context.debriefViewport = lvgl.box(context.debriefOverlay, {
        x = 0,
        y = 0,
        w = zone.w,
        h = zone.h,
        scrollDir = 0,
    })
    context.pillLayer = lvgl.box(context.debriefViewport, { x = 0, y = 0, w = 1, h = 1, scrollDir = 0 })
    lvgl.hide(context.debriefOverlay)
    lvgl.hide(context.pillLayer)
end

--- Build whatever part of the bare page shell is missing, so errors have
--- somewhere to be shown.
---@param context AeroGridContext
local function ensureShell(context)
    local zone = context.zone
    if not context.root then
        context.root = lvgl.box({ x = 0, y = 0, w = zone.w, h = zone.h, scrollDir = 0 })
    end
    if not context.page then
        context.page = lvgl.box(context.root, { x = 0, y = 0, w = zone.w, h = zone.h, scrollDir = 0 })
    end
    if not context.canvas then
        context.canvas = lvgl.rectangle(context.page, {
            x = 0,
            y = 0,
            w = zone.w,
            h = zone.h,
            color = lcd.RGB(0x101316),
            filled = true,
            opacity = context.radioBackground and 0 or 255,
        })
    end
    if not context.panelLayer then
        addPageLayers(context, zone)
    end
end

--- Create one AeroGrid host instance for an EdgeTX custom-screen zone.
---@param zone AeroGridZone
---@param widgetOptions AeroGridWidgetOptions
---@param path string Absolute widget directory supplied by EdgeTX.
---@return AeroGridContext
local function create(zone, widgetOptions, path)
    local themeMode = themeModeOf(widgetOptions.Theme)
    local flightFactory = flightFactories[path or WIDGET_PATH]
    if not flightFactory then
        flightFactory = { members = setmetatable({}, { __mode = "k" }), startupThemes = {} }
        flightFactories[path or WIDGET_PATH] = flightFactory
    end
    local context = {
        zone = zone,
        path = path,
        layoutName = layoutName(widgetOptions.Layout),
        themeMode = themeMode,
        radioBackground = themeMode == GLASS_THEME,
        panelOpacity = themeMode == GLASS_THEME and 204 or 255,
        legacyWidgetArmed = widgetOptions.Armed or 0,
        flightFactory = flightFactory,
        startupThemes = flightFactory.startupThemes,
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

    local schedulerModule, schedulerError = loadModule(path, "lib/scheduler.lua", 1)
    if schedulerModule and type(rawget(schedulerModule, "new")) == "function" then
        context.scheduler = newScheduler(context, schedulerModule)
    else
        addError(context, "lib/scheduler.lua: " .. tostring(schedulerError or "module has no constructor"))
    end
    if context.scheduler then
        -- Construct the presentation shell before firmware paints its own menu.
        -- Runtime loading remains deferred, but this bounded work is still charged.
        context.scheduler.add({
            name = "startup background",
            owner = "startup background",
            host = context,
            onError = hostError,
            cost = 1,
            step = function()
                context.root = lvgl.box({ x = 0, y = 0, w = zone.w, h = zone.h, scrollDir = 0 })
                context.rootBuiltFullscreen = isFullScreen()
                context.page = lvgl.box(context.root, { x = 0, y = 0, w = zone.w, h = zone.h, scrollDir = 0 })
                context.pageBuiltFullscreen = isFullScreen()
                context.canvas = lvgl.rectangle(context.page, {
                    x = 0,
                    y = 0,
                    w = zone.w,
                    h = zone.h,
                    color = lcd.RGB(0x101316),
                    filled = true,
                    opacity = context.radioBackground and 0 or 255,
                })
                addPageLayers(context, zone)
            end,
        })
        context.scheduler.run(getTime(), context.scheduler.budget.capacity, false)
        context.scheduler.clear()
    end
    if not context.scheduler then
        context.runtimeFailed = true
        ensureShell(context)
        showErrors(context)
        return context
    end
    context.initializing, context.stage = true, "initialize"
    context.initializationTask = {
        name = "initialize",
        owner = "initialize",
        host = context,
        onError = initializeError,
        cost = context.scheduler.budget.slots,
        step = function()
            context.initializing = nil
            initialize(context)
        end,
    }
    return context
end

--- Whether the model's settings are already known, so the layout can load
--- under the right callback budget.
local function modelSettingsKnown(context)
    local factory = context.flightFactory
    local member = factory and factory.members[context]
    if not member or not member.modelFilename then
        return true
    end
    local owner, preload = factory.broker, factory.preload
    return (owner and owner.filename == member.modelFilename and owner.documentLoaded)
        or (preload and preload.modelFilename == member.modelFilename)
        or false
end

--- Read the model's settings document ahead of the layout: one callback builds
--- the store and the next parses the file. Failures are ignored here because the
--- flight broker reports them when it loads the document itself.
local function advanceModelSettings(context)
    if modelSettingsKnown(context) then
        context.modelSettingsPreload = nil
        context.stage = "theme-read"
        return
    end
    local factory, path = context.flightFactory, context.path
    local filename = factory.members[context].modelFilename
    local store = context.modelSettingsPreload
    if not store then
        local ok, created = pcall(function()
            local storeModule = assert(loadModule(path, "lib/model_settings_store.lua", 1))
            return storeModule.new(path, context.yaml, {
                modelFilename = function()
                    return filename
                end,
                flightConfig = context.flightConfig,
                getOutput = context.serviceRuntime.env.getOutput,
            })
        end)
        if ok and created then
            context.modelSettingsPreload = created
            return
        end
    else
        local ok, document, info = pcall(store.load, store, filename)
        if ok and document then
            local flight = document.flight
            factory.preload = {
                modelFilename = filename,
                document = document,
                info = info,
                liveDangerously = type(flight) == "table" and flight.liveDangerously == true,
            }
        end
    end
    context.modelSettingsPreload = nil
    context.stage = "theme-read"
end

--- Begin a staged load, first reading the model's settings if they are unknown.
local function startLoad(context)
    context.dashboardLoader.beginLoad(context)
    context.modelSettingsPreload = nil
    if not modelSettingsKnown(context) then
        context.stage = "model-settings"
    end
end

initialize = function(context)
    local path, flightFactory = context.path, context.flightFactory
    context.stage = nil
    local package, packageError = loadModule(path, "lib/package.lua")
    if
        package
        and (
            type(package.version) ~= "string"
            or package.version == ""
            or package.runtimeApi ~= 1
            or package.panelApi ~= 1
            or package.layoutVersion ~= 5
        )
    then
        package = nil
        packageError = "incompatible package contract; copy the complete AeroGrid package"
    end
    context.packageInfo = package
    if not package then
        addError(context, "package: " .. tostring(packageError))
    else
        local function runtimeModule(relative, ...)
            local module, err = loadModule(path, relative, package.runtimeApi, ...)
            if not module then
                addError(context, relative .. ": " .. tostring(err))
            end
            return module
        end
        if not sharedDiagnosticsLog then
            local log = runtimeModule("lib/diagnostics_log.lua")
            if log then
                sharedDiagnosticsLog = log.new()
            end
        end
        context.diagnosticsLog = sharedDiagnosticsLog
        if sharedDiagnosticsLog then
            sharedDiagnosticsLog:register(context)
        end
        context.grid = runtimeModule("lib/grid.lua")
        context.yaml = runtimeModule("lib/yaml.lua")
        context.layoutValidator = runtimeModule("lib/layout.lua", function()
            return loadModule(path, "lib/debrief_config.lua", package.runtimeApi)
        end)
        context.layoutStore = runtimeModule("lib/layout_store.lua")
        context.flightConfig = runtimeModule("lib/flight_config.lua")
        context.armedConfig = runtimeModule("lib/armed_service.lua")
        context.nativeBudget = runtimeModule("lib/native_budget.lua")
        context.aeroMenuModule = runtimeModule("lib/aerogrid_menu.lua")
        context.gesture = runtimeModule("lib/gesture.lua")
        local flightRegistration = runtimeModule("lib/flight_registration.lua")
        if flightRegistration then
            context.configureFlight = function(host)
                local ok, message = pcall(flightRegistration.configure, host)
                if not ok then
                    local member = host.flightFactory.members[host]
                    member.pending, member.error = false, tostring(message)
                    host.flightFactory.revision = (host.flightFactory.revision or 0) + 1
                    addError(host, "flight: " .. tostring(message))
                end
            end
        end
        --- Hand the debrief recorder the layout's debrief and each tile's width.
        --- A layout that has never had a debrief gets one derived from its
        --- panels; it stays out of the file until the pilot edits it. The
        --- recorder is loaded on first use, so a dashboard without debrief
        --- tiles spends no load step or heap on it.
        context.deriveDebrief = function(host, module)
            local document = host.document
            local telemetry = host.serviceRuntime and host.serviceRuntime.byId.telemetry
            local thresholds = telemetry and telemetry:thresholdMap()
            document.debrief = module.fromPanels(document.panels, nil, thresholds)
            host.derivedDebrief = document.debrief
        end
        context.configureDebrief = function(host)
            local registry = host.serviceRuntime
            if not registry then
                return
            end
            local document = host.document
            if document and document.debrief == nil then
                local module = host.layoutValidator and host.layoutValidator.debrief()
                if module then
                    host.deriveDebrief(host, module)
                end
            end
            local section = document and document.debrief
            host.debriefGenerated = section ~= nil and section == host.derivedDebrief
            if not host.debriefGenerated then
                host.derivedDebrief = nil
            end
            local service = registry.byId.debrief
            if not service then
                if not (section and section.tiles and #section.tiles > 0) then
                    return
                end
                local module, moduleError =
                    loadModule(host.path, "lib/debrief_service.lua", host.packageInfo.runtimeApi)
                local ok, instance = false, moduleError
                if module then
                    ok, instance = pcall(module.new, registry.env, host.servicesModule, registry)
                end
                if not ok then
                    addError(host, "debrief: " .. tostring(instance))
                    return
                end
                host.servicesModule.register(registry, instance, getTime())
                service = instance
            end
            local widths, bySize = {}, {}
            for index, tile in ipairs(section and section.tiles or {}) do
                local size = tile.colSpan * 8 + tile.rowSpan
                local width = bySize[size]
                if not width then
                    local span = { col = 0, row = 0, colSpan = tile.colSpan, rowSpan = tile.rowSpan }
                    local rect = host.grid.rect(host.zone, span, 4, 4, 4)
                    local fonts = host.themeBuilder.typography(tile.colSpan, tile.rowSpan)
                    width = host.themeBuilder.frame(host.theme, rect, fonts).content
                    bySize[size] = width
                end
                widths[index] = width
            end
            service:configure(section, widths)
        end
        context.panelHost = runtimeModule("lib/panel_host.lua")
        if context.panelHost and context.scheduler then
            context.panelHost.SLOTS = context.scheduler.budget.slots
        end
        context.chartColumns = runtimeModule("lib/chart_columns.lua")
        context.chartColumnsRenderer = runtimeModule("lib/chart_columns_renderer.lua")
        local typography = runtimeModule("lib/typography.lua")
        local panelLayout = runtimeModule("lib/panel_layout.lua")
        local reading = runtimeModule("lib/reading.lua")
        if typography and panelLayout then
            context.themeBuilder = runtimeModule("lib/theme.lua", typography, panelLayout)
        end
        if reading then
            context.primitives = runtimeModule("lib/primitives.lua", reading)
        end
        local loader = runtimeModule("lib/dashboard_loader.lua")
        local lifecycle = runtimeModule("lib/dashboard_lifecycle.lua")
        local controller = runtimeModule("lib/editor_controller.lua")
        local function bindHost(module, relative, dependencies, operations)
            local constructor = module and rawget(module, "new")
            if type(constructor) ~= "function" then
                addError(context, relative .. ": module has no constructor")
                return nil
            end
            local ok, bound = pcall(constructor, dependencies)
            if not ok or type(bound) ~= "table" then
                addError(context, relative .. ": " .. tostring(ok and "constructor did not return a table" or bound))
                return nil
            end
            for _, operation in ipairs(operations) do
                if type(rawget(bound, operation)) ~= "function" then
                    addError(context, relative .. ": missing operation " .. operation)
                    return nil
                end
            end
            return bound
        end
        if loader and lifecycle and controller then
            context.dashboardLoader = bindHost(loader, "lib/dashboard_loader.lua", {
                addError = addError,
                addNotice = addNotice,
                showErrors = showErrors,
                loadModule = loadModule,
                isFullScreen = isFullScreen,
                readThemeDefinition = readThemeDefinition,
                sharedTelemetry = sharedTelemetry,
            }, { "beginLoad", "advanceLoad", "panelRect", "reservedFor", "buildPanel" })
        end
        if context.dashboardLoader then
            context.dashboardLifecycle = bindHost(lifecycle, "lib/dashboard_lifecycle.lua", {
                addError = addError,
                showErrors = showErrors,
                dispatchAll = dispatchAll,
                isFullScreen = isFullScreen,
                reservedCorner = reservedCorner,
                errorTop = errorTop,
                panelRect = context.dashboardLoader.panelRect,
                reservedFor = context.dashboardLoader.reservedFor,
                buildPanel = context.dashboardLoader.buildPanel,
                addPageLayers = addPageLayers,
            }, {
                "updateEmptyHint",
                "beginReflow",
                "advanceReflow",
                "advanceAppRebuild",
                "retirePage",
                "rebuildPage",
            })
        end
        if context.dashboardLifecycle then
            context.editorController = bindHost(controller, "lib/editor_controller.lua", {
                addError = addError,
                logError = logError,
                showErrors = showErrors,
                loadModule = loadModule,
                isFullScreen = isFullScreen,
                buildPanel = context.dashboardLoader.buildPanel,
                registerThresholds = context.dashboardLoader.registerThresholds,
                updateEmptyHint = context.dashboardLifecycle.updateEmptyHint,
            }, { "restorePreview", "openEditor", "advanceEditor", "editorEntryHit" })
        end
        if context.panelHost and context.panelHost.API_VERSION ~= package.panelApi then
            addError(context, "panel host: incompatible panel API")
            context.panelHost = nil
        end
    end

    local info = model and model.getInfo and model.getInfo()
    flightFactory.members[context] = {
        modelFilename = info and info.filename,
        layoutName = context.layoutName,
        pending = true,
    }
    flightFactory.revision = (flightFactory.revision or 0) + 1

    -- A rectangle supplies the solid canvas; zero opacity exposes the radio
    -- theme instead. A box ignores `color` and cannot provide the solid mode.
    -- Everything the dashboard draws lives inside a page, so a reload can
    -- discard the page wholesale and build the next one somewhere the discarded
    -- one's deferred cleanup cannot reach. The root is normally retained.
    if
        context.runtimeFailed
        or not context.packageInfo
        or not context.grid
        or not context.yaml
        or not context.layoutValidator
        or not context.layoutStore
        or not context.flightConfig
        or not context.configureFlight
        or not context.aeroMenuModule
        or not context.gesture
        or not context.panelHost
        or not context.scheduler
        or not context.themeBuilder
        or not context.primitives
        or not context.dashboardLoader
        or not context.dashboardLifecycle
        or not context.editorController
        or not context.diagnosticsLog
    then
        -- Nothing can be loaded without the runtime, and an option change must not
        -- be able to restage a load that would then index a missing module.
        context.runtimeFailed = true
        local member = context.flightFactory.members[context]
        member.pending, member.error = false, "Flight configuration unavailable: restore the complete AeroGrid package"
        context.flightFactory.revision = (context.flightFactory.revision or 0) + 1
        addError(context, "AeroGrid runtime module failed to load")
        showErrors(context)
    else
        startLoad(context)
    end
end

--- Apply native host options; changing layout or appearance rebuilds safely.
---@param context AeroGridContext
---@param widgetOptions AeroGridWidgetOptions
local function update(context, widgetOptions)
    local name = layoutName(widgetOptions.Layout)
    local themeMode = themeModeOf(widgetOptions.Theme)

    -- Without a runtime there is nothing to rebuild, and restaging would fail.
    if context.runtimeFailed then
        return
    end
    -- EdgeTX calls update as it enters fullscreen, before it redraws without
    -- its own icon. Showing the built button here, outside the scheduler,
    -- is the one native call update makes, and only on that entry.
    if context.aerogridMenu and context.chromeRoot and isFullScreen() and context.menuVisibleFullscreen ~= true then
        lvgl.show(context.chromeRoot)
        context.aeroMenuModule.sync(context)
        context.menuVisibleFullscreen = true
    end

    if name ~= context.layoutName or themeMode ~= context.themeMode then
        context.optionsRequest = {
            layoutName = name,
            themeMode = themeMode,
        }
    else
        context.optionsRequest = nil
    end
end

--- Stop dashboard services and panels for the rest of this callback. Host
--- work that may replace or retire their owners calls this; they are enrolled
--- afresh on the next callback.
---@param context AeroGridContext
local function closeDashboard(context)
    context.dashboardClosed, context.servicesHold, context.panelsHold = true, true, true
end

local function optionsStep(task)
    local context = task.host
    local request = context.optionsRequest
    context.optionsRequest = nil
    closeDashboard(context)
    local member = context.flightFactory.members[context]
    member.pending = true
    context.flightFactory.revision = (context.flightFactory.revision or 0) + 1
    context.editorStash, context.editorTransitionRequest, context.modelSettingsRequest = nil, nil, nil
    context.editorDebriefRequest = nil
    context.logOpenRequest = nil
    context.debrief, context.debriefRequest = nil, nil
    if context.locationRequest and context.locationRequest.kind == "open" then
        context.locationRequest = nil
    end
    if context.editorUi then
        context.editorUiModule.close(context, true)
        context.editorController.restorePreview(context)
        context.editorSession = nil
    end
    context.layoutName, context.themeMode = request.layoutName, request.themeMode
    context.radioBackground = request.themeMode == GLASS_THEME
    context.panelOpacity = context.radioBackground and 204 or 255
    context.reloadState = "clear"
end
--- Translate compact native option keys into user-facing labels.
---@param name string
---@return string
local function translate(name)
    if name == "Layout" then
        return "Layout"
    end
    if name == "Theme" then
        return "Theme"
    end
    return name
end

--- The latest flight debrief, or nil.
local function debriefResult(context)
    local runtime = context.serviceRuntime
    local service = runtime and runtime.byId and runtime.byId.debrief
    return service and service:result() or nil
end

local function debriefShown(context)
    return context.debrief ~= nil and context.debrief.shown
end

--- Whether the debrief view is fully built for the latest debrief.
local function debriefReady(context)
    local state = context.debrief
    return state ~= nil and state.result == debriefResult(context) and context.debriefModule.ready(state)
end

--- Keep the sheet's leading bar visible whenever a debrief is available.
local function debriefPillWanted(context)
    if
        not context.page
        or context.stage
        or context.reloadState
        or context.editorUi
        or context.modelSettingsUi
        or context.logViewer
        or context.locationDetails
        or not context.debrief
        or context.debrief.stale
        or context.debrief.result ~= debriefResult(context)
        or context.debriefFailure == context.debrief.result
    then
        return nil
    end
    return isFullScreen()
end

local function debriefPillStale(context)
    local pill = context.debriefPill
    if not pill and not context.debrief then
        return false
    end
    local wanted, zone = debriefPillWanted(context), context.zone
    if wanted == nil then
        return pill ~= nil and pill.fullscreen ~= nil
    end
    return not pill or pill.fullscreen ~= wanted or pill.w ~= zone.w or pill.h ~= zone.h
end

local function debriefFailed(context, message)
    if context.debriefModule then
        pcall(context.debriefModule.destroy, context)
    end
    context.debriefFailure = context.debrief and context.debrief.result or debriefResult(context)
    addError(context, "debrief: " .. tostring(message))
    showErrors(context)
end

--- Whether a fullscreen touch is an upward drag that should reveal the debrief.
local function debriefPull(context, widgetEvent, touchState)
    if
        widgetEvent ~= _G.EVT_TOUCH_SLIDE
        or type(touchState) ~= "table"
        or not isFullScreen()
        or not debriefReady(context)
    then
        return false
    end
    if touchState.swipeUp then
        return true
    end
    local x, y, startX, startY = touchState.x, touchState.y, touchState.startX, touchState.startY
    if type(y) ~= "number" or type(startY) ~= "number" then
        return false
    end
    local rise = startY - y
    local across = type(x) == "number" and type(startX) == "number" and math.abs(startX - x) or 0
    return rise > 2 * context.gesture.SLOP and rise > across
end

--- Offer an input event to panels until one consumes it.
---@param context AeroGridContext
---@param widgetEvent any
---@return boolean consumed
local function handleEvent(context, widgetEvent, touchState)
    if context.runtimeFailed then
        return false
    end
    if context.editorUi then
        return context.editorUiModule.handle(context, widgetEvent, touchState)
    end
    if context.locationDetails then
        return context.locationDetailsModule.handle(context, widgetEvent, touchState)
    end
    if context.logViewer then
        return context.logViewerModule.handle(context, widgetEvent, touchState)
    end
    if debriefShown(context) then
        return context.debriefModule.handle(context, widgetEvent, touchState)
    end
    if context.editorController.editorEntryHit(context, widgetEvent, touchState) then
        context.editorTransitionRequest = "open"
        return true
    end
    if debriefPull(context, widgetEvent, touchState) then
        local request = {
            page = context.page,
            y = touchState.y,
            startY = touchState.startY,
            swipe = touchState.swipeUp and true or nil,
            follow = true,
        }
        local ok, message = pcall(context.debriefModule.open, context, debriefResult(context), request)
        if not ok then
            debriefFailed(context, message)
        end
        context.panelPress = context.gesture.cancel(context.panelPress)
        return true
    end
    if context.debriefRequest and (widgetEvent == _G.EVT_TOUCH_BREAK or widgetEvent == _G.EVT_TOUCH_TAP) then
        context.debriefRequest.released = true
    end

    local tap
    context.panelPress, tap = context.gesture.track(context.panelPress, widgetEvent, touchState)
    if tap and isFullScreen() then
        if context.debriefModule and context.debriefModule.barHit(context, tap) then
            context.debriefRequest = { page = context.page, swipe = true, released = true }
            context.panelPress = context.gesture.cancel(context.panelPress)
            return true
        end
        local touchState = tap
        for _, entry in ipairs(context.panels) do
            local logPanel = entry.placement.type == "host-diagnostics" and entry.settings.section == "log"
            if not entry.failed and (entry.placement.type == "navigation" or logPanel) then
                local rect = context.dashboardLoader.panelRect(context, entry.placement)
                if
                    rect
                    and touchState.x >= rect.x
                    and touchState.x < rect.x + rect.w
                    and touchState.y >= rect.y
                    and touchState.y < rect.y + rect.h
                then
                    if logPanel then
                        local info = model and model.getInfo and model.getInfo()
                        context.logOpenRequest = { page = context.page, modelFilename = info and info.filename }
                        return true
                    end
                    if not entry.instance.feed or not entry.instance.feed.fix then
                        return true
                    end
                    local view = entry.instance.feed
                    local info = model and model.getInfo and model.getInfo()
                    context.locationRequest = {
                        kind = "open",
                        page = context.page,
                        modelFilename = info and info.filename,
                        accent = entry.settings.accent,
                        view = {
                            fix = view.fix,
                            state = view.state,
                            latitude = view.latitude,
                            longitude = view.longitude,
                        },
                    }
                    return true
                end
            end
        end
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

local SWIPES = { "swipeLeft", "swipeRight", "swipeUp", "swipeDown" }

--- Accept input, not synchronous consumption; EdgeTX supplies it through refresh.
local function event(context, widgetEvent, touchState)
    if context.runtimeFailed or not isFullScreen() or widgetEvent == nil or widgetEvent == 0 then
        return false
    end
    local input = { event = widgetEvent, now = getTime() }
    if touchState then
        input.touch = {
            x = touchState.x,
            y = touchState.y,
            startX = touchState.startX,
            startY = touchState.startY,
            slideX = touchState.slideX,
            slideY = touchState.slideY,
            tapCount = touchState.tapCount,
            swipeLeft = touchState.swipeLeft,
            swipeRight = touchState.swipeRight,
            swipeUp = touchState.swipeUp,
            swipeDown = touchState.swipeDown,
        }
    end
    context.inputQueue = context.inputQueue or {}
    local queue = context.inputQueue
    local last = queue[#queue]
    -- One input is handled per callback, so a drag would trail the finger;
    -- a queued slide instead absorbs the next one.
    if widgetEvent == _G.EVT_TOUCH_SLIDE and last and last.event == widgetEvent and input.touch and last.touch then
        local merged, previous = input.touch, last.touch
        if type(merged.slideX) == "number" and type(previous.slideX) == "number" then
            merged.slideX = previous.slideX + merged.slideX
        end
        if type(merged.slideY) == "number" and type(previous.slideY) == "number" then
            merged.slideY = previous.slideY + merged.slideY
        end
        for _, name in ipairs(SWIPES) do
            merged[name] = merged[name] or previous[name]
        end
        last.touch, last.now = merged, input.now
        return true
    end
    queue[#queue + 1] = input
    return true
end

local function editorWorkNeeded(state)
    return state
        and (
            state.buildStage
            or state.saving
            or state.drawerBuild ~= nil
            or state.drawerPending
            or state.nativeInput
            or state.exitCommand
            or state.previewPending
            or state.previewRefresh
        )
end

--- Whether pending host work may replace the owners of services and panels:
--- options, arming reloads, session resets, loading and reloading wait for no
--- stale owner to run in between.
local function servicesHeld(context, hidden)
    return context.dashboardClosed
        or context.optionsRequest ~= nil
        or context.modelArmingReload
        or context.sessionResetPending
        or context.stage ~= nil
        or context.reloadState ~= nil
        or hidden and context.reflowIndex ~= nil
end

--- Panels also wait while their placement or previews change, stay behind a
--- visible modal overlay, and yield callbacks with queued fullscreen input
--- to the surface that input targets.
local function panelsHeld(context, hidden)
    return not hidden and context.inputPending
        or context.lifecycleRequest ~= nil
        or context.editorTransitionRequest ~= nil
        or context.reflowIndex ~= nil
        or context.appRebuild ~= nil
        or context.editorRestore ~= nil
        or editorWorkNeeded(context.editorUi)
        or not hidden and (context.modelSettingsUi ~= nil or context.logViewer ~= nil or debriefShown(context))
end

--- A session reset waits for a load or reload to finish, then runs before other host work.
local function sessionResetDue(context)
    return context.sessionResetPending and not (context.stage or context.reloadState)
end

--- Lifecycle steps wait for arming reloads, due session resets, open modals
--- and editors, and for the foreground surface to settle.
local function lifecycleHeld(context, hidden)
    if
        context.modelArmingReload
        or sessionResetDue(context)
        or context.modelSettingsUi
        or context.editorRestore and not (context.stage or context.reloadState)
        or context.editorUi and (hidden and context.editorUi.saving or not hidden)
    then
        return true
    end
    if hidden then
        return false
    end
    local menu = context.aerogridMenu
    if menu and (menu.pending or menu.action or menu.dismiss or menu.selectionDirty) then
        return true
    end
    local built = not context.reloadState
        and (context.pageBuiltFullscreen or context.rootBuiltFullscreen or context.nativeDialogsCreated)
    local debrief = debriefShown(context)
    if not (context.locationDetails or context.logViewer or debrief or context.editorStash or built) then
        return false
    end
    local fullscreen = isFullScreen()
    return context.locationDetails and (not fullscreen or context.reloadState)
        or debrief and (not fullscreen or context.reloadState)
        or context.logViewer and (not fullscreen or context.reloadState or context.logViewer.width ~= context.zone.w - 16 or context.logViewer.height ~= context.zone.h)
        or context.editorStash and fullscreen and context.document and not (context.stage or context.reloadState)
        or built and not fullscreen
end

--- Decide the holds once per callback and again after every step that may
--- change them, so each task's readiness only reads a flag. `pruneRequests`
--- decides the lifecycle barrier at callback start, so `runCallback` skips it.
local function updateHolds(context, hidden, keepLifecycle)
    local services = servicesHeld(context, hidden)
    context.servicesHold = services
    context.panelsHold = services or panelsHeld(context, hidden)
    if not keepLifecycle then
        context.lifecycleHold = context.lifecycleRequest ~= nil and lifecycleHeld(context, hidden)
    end
end

--- Task steps that adapt the panel and service contracts to the scheduler.
--- Each task's `owner` is the service instance or panel entry it runs for.
local function serviceReady(task, _, hidden)
    local instance = task.owner
    task.cost, task.minCost = instance.updateCost, instance.updateMinCost
    return not task.host.servicesHold and not instance.failed and instance.count ~= 0
end

--- Whether a panel's finishing work is ready now; it then runs before refreshes resume.
local function finishPending(context, entry)
    local module = entry.module
    local pending = rawget(module, "finishPending")
    if type(pending) ~= "function" then
        return false
    end
    local ok, message, result, minimum = context.panelHost.dispatch(entry, "finishPending")
    if not ok then
        addError(context, entry.placement.id .. ": finishPending: " .. tostring(message))
        context.schedulerFailed = true
        return false
    end
    return result, minimum
end

local function instanceField(entry, key)
    if type(entry.instance) == "table" then
        return rawget(entry.instance, key)
    end
end

local function refreshReady(task, _, hidden)
    local entry = task.owner
    if hidden or entry.failed or task.host.panelsHold then
        return false
    end
    task.cost = instanceField(entry, "refreshCost") or rawget(entry.module, "refreshCost") or 1
    task.minCost = instanceField(entry, "refreshMinCost") or rawget(entry.module, "refreshMinCost")
    local pending = finishPending(task.host, entry)
    return not entry.failed and not pending
end

local function finishReady(task, _, hidden)
    local entry = task.owner
    if hidden or entry.failed or task.host.panelsHold then
        return false
    end
    local pending, minimum = finishPending(task.host, entry)
    if entry.failed or not pending then
        return false
    end
    -- The next stage may need more than the module's default minimum.
    task.minCost = minimum or rawget(entry.module, "finishMinCost")
    return true
end

local function backgroundReady(task, _, hidden)
    local entry = task.owner
    if not hidden or entry.failed or task.host.panelsHold then
        return false
    end
    -- A panel that declares a minimum is charged what it reports.
    local minimum = instanceField(entry, "backgroundMinCost") or rawget(entry.module, "backgroundMinCost")
    task.cost, task.minCost = minimum and "variable" or 1, minimum
    return true
end

local function panelStep(task, now, granted)
    local context, entry, eventName = task.host, task.owner, task.event
    local ok, message, interval, again, used = context.panelHost.dispatch(entry, eventName, false, granted)
    if eventName == "finish" then
        -- Ending a cycle sets when the next refresh is due.
        if ok and type(interval) == "number" then
            entry.nextRefresh = now + entry.interval
            if entry.refreshTask then
                entry.refreshTask.due = entry.nextRefresh
            end
        end
    elseif eventName == "refresh" then
        entry.nextRefresh = now + entry.interval
    elseif eventName == "background" and ok and type(interval) == "number" then
        -- A background hook that returns an interval sleeps that many ticks.
        task.due = now + interval
    end
    if not ok then
        error(message or "panel failed", 0)
    end
    if eventName == "refresh" then
        context.firstRefreshUntil = nil
    end
    return used, again
end

local NONE = {}

--- Enrol the services that have subscribers and the live panels, in that
--- order, for one run. Membership is read from the host's own tables on every
--- callback, so a panel added, replaced or retired by the loader or editor
--- needs no registration, and a service gains its first subscriber's turn on
--- the next callback.
--- Held owners wait for the next callback; a hold that starts later in the
--- callback is seen by the ready checks.
---@param context AeroGridContext
local function enrolTasks(context, registry, support)
    local scheduler = context.scheduler
    local order = context.servicesHold and NONE or registry.order
    for index = 1, #order do
        local instance = order[index]
        if instance.count ~= 0 then
            local task = instance.task
            if not task or task.registry ~= registry then
                task = {
                    name = instance.id,
                    owner = instance,
                    onError = serviceError,
                    registry = registry,
                    host = context,
                    step = support.step,
                    ready = serviceReady,
                }
                instance.task = task
            end
            task.due, task.failed = instance.due, instance.failed
            scheduler.add(task)
        end
    end
    local panels = context.panelsHold and NONE or context.panels
    for index = 1, #panels do
        local entry = panels[index]
        local module = entry.module
        if type(rawget(module, "refresh")) == "function" then
            local task = entry.refreshTask
            if not task then
                task = {
                    name = entry.placement.id .. ": refresh",
                    owner = entry,
                    onError = panelError,
                    host = context,
                    event = "refresh",
                    step = panelStep,
                    ready = refreshReady,
                }
                entry.refreshTask = task
            end
            task.due, task.failed = entry.nextRefresh or 0, entry.failed
            scheduler.add(task)
        end
        if type(rawget(module, "finish")) == "function" then
            local task = entry.finishTask
            if not task then
                task = {
                    name = entry.placement.id .. ": finish",
                    owner = entry,
                    onError = panelError,
                    host = context,
                    event = "finish",
                    cost = "variable",
                    step = panelStep,
                    ready = finishReady,
                }
                entry.finishTask = task
            end
            task.failed = entry.failed
            scheduler.add(task)
        end
        if type(rawget(module, "background")) == "function" then
            local task = entry.backgroundTask
            if not task then
                task = {
                    name = entry.placement.id .. ": background",
                    owner = entry,
                    onError = panelError,
                    host = context,
                    event = "background",
                    step = panelStep,
                    ready = backgroundReady,
                }
                entry.backgroundTask = task
            end
            task.failed = entry.failed
            scheduler.add(task)
        end
    end
end

-- Further segments of scheduler capacity a callback may run past EdgeTX's
-- 20000-instruction limit when the model enables "Pre-release features".
local EXTENDED_SEGMENTS = 4

local function liveDangerously(context)
    if context.liveDangerouslyFailed or not context.nativeBudget then
        return false
    end
    local factory = context.flightFactory
    local owner = factory and factory.broker
    if owner and owner.documentLoaded then
        local flight = owner.document and owner.document.flight
        return type(flight) == "table" and flight.liveDangerously == true
    end
    -- Before the flight broker has its document, use the copy read ahead of the layout.
    local preload, member = factory and factory.preload, factory and factory.members[context]
    return preload ~= nil
        and member ~= nil
        and preload.modelFilename == member.modelFilename
        and preload.liveDangerously == true
end

--- Run the enrolled tasks for one callback in `1 + segments` segments, then
--- release them and show any failure.
local function runScheduled(context, hidden, segments)
    local scheduler = context.scheduler
    local _, _, _, failure = scheduler.run(getTime(), scheduler.budget.capacity, hidden or false, {
        segments = segments,
        cross = context.nativeBudget and context.nativeBudget.cross,
    })
    context.remainingSlots = scheduler.remaining
    if failure then
        context.liveDangerouslyFailed = true
        addError(context, "extended callback budget: " .. failure)
        context.schedulerFailed = true
    end
    scheduler.clear()
    if context.schedulerFailed then
        context.schedulerFailed = nil
        ensureShell(context)
        showErrors(context)
    end
end

--- Add services and panels after the tasks already enrolled, and run them
--- all in one fair ring.
local function runTasks(context, hidden)
    local registry, support = context.serviceRuntime, context.servicesModule
    if registry and support then
        enrolTasks(context, registry, support)
    end

    -- Extra segments run past EdgeTX's per-callback limit in the same
    -- callback; only pending and deferred work continues.
    runScheduled(context, hidden, liveDangerously(context) and EXTENDED_SEGMENTS or 0)
end

local function flightReady(task)
    local owner = task.broker
    local linking = owner.settingsAdoption and owner:settingsDisarmed()
    task.cost = (not owner.documentLoaded or linking) and task.host.scheduler.budget.slots or 1
    return true
end

local function pumpFlight(task, now, granted)
    local context = task.host
    local owner = context.flightFactory and context.flightFactory.broker
    if not owner then
        return
    end
    local identityOk, filename = pcall(owner.identity, owner)
    if not identityOk then
        local text = "flight: " .. tostring(filename)
        if context.flightErrorText ~= text then
            context.flightErrorText = text
            logError(context, text)
            showErrors(context)
        end
        context.flightReportedRevision = nil
        return
    end
    if filename ~= owner.filename then
        owner:reset(filename)
        closeDashboard(context)
        if granted < context.scheduler.budget.slots then
            return nil, true
        end
    end
    if not owner.documentLoaded then
        if not owner.store then
            local storeModule, storeError = loadModule(context.path, "lib/model_settings_store.lua", 1)
            if not storeModule then
                owner.loadError, owner.documentLoaded = storeError, true
                closeDashboard(context)
                return nil, true
            end
            local created, store = pcall(storeModule.new, context.path, context.yaml, {
                modelFilename = function()
                    return owner:identity()
                end,
                flightConfig = context.flightConfig,
                armedConfig = owner.modules.armed,
                getOutput = owner.env.getOutput,
                setOutput = owner.env.setOutput,
                getTime = owner.env.getTime,
                isDisarmed = function(proposed)
                    return owner:settingsDisarmed(proposed)
                end,
            })
            if not created then
                owner.loadError, owner.documentLoaded = tostring(store), true
                closeDashboard(context)
                return nil, true
            end
            owner.store = store
        end
        local preload = context.flightFactory.preload
        local document, info
        if preload and preload.document and preload.modelFilename == filename then
            -- Already parsed ahead of the layout; reuse it once.
            document, info = preload.document, preload.info
            preload.document, preload.info = nil, nil
        else
            document, info = owner.store:load(filename)
        end
        if document then
            owner:setDocument(document)
            owner.settingsAdoption = type(info) == "table" and info.foreign and { document = document, info = info }
                or nil
            if type(info) == "table" and info.blocked then
                addNotice(context, "warning", info.notice)
            end
            if type(info) == "table" and info.recovered then
                addNotice(context, "warning", "Recovered previous model settings; review and save Model settings.")
            end
        else
            owner.loadError, owner.documentLoaded = tostring(info), true
        end
        closeDashboard(context)
        return nil, true
    end
    local adoption = owner.settingsAdoption
    if adoption and owner:settingsDisarmed() then
        if granted < context.scheduler.budget.slots then
            return nil, true
        end
        local saved, result, deferred = owner.store:adopt(filename, adoption.document, adoption.info)
        if saved then
            owner.settingsAdoption = nil
            owner:setDocument(result)
        elseif not deferred then
            owner.settingsAdoption = nil
            owner.settingsError = "Cannot link model settings: " .. tostring(result)
            owner:error("persistence", owner.settingsError)
        end
    end
    local resetConfigured = owner.document and owner.document.sessionReset and owner.document.sessionReset ~= ""
    if
        (context.stage and not context.loadConfigured or context.reloadState)
        and not owner.session
        and not resetConfigured
    then
        return
    end
    -- The broker's own tasks poll and decide after this setup.
    owner:setup(now, owner.session or owner.dormantRevision ~= context.flightFactory.revision)
    local state = owner.view
    if
        context.flightReportedRevision == (state.diagnosticRevision or 0)
        and context.flightReportedEpoch == state.epoch
    then
        return
    end
    context.flightReportedRevision, context.flightReportedEpoch = state.diagnosticRevision or 0, state.epoch
    local messages = {}
    for _, key in ipairs({
        "configurationError",
        "detectionError",
        "countError",
        "sourceError",
        "outputError",
        "persistenceError",
        "resetError",
    }) do
        if state[key] then
            messages[#messages + 1] = "flight: " .. state[key]
        end
    end
    if state.importNotice and context.flightImportNotice ~= state.importNotice then
        context.flightImportNotice = state.importNotice
        addNotice(context, "warning", state.importNotice)
    end
    local text = #messages > 0 and table.concat(messages, "\n") or nil
    if text ~= context.flightErrorText then
        context.flightErrorText = text
        if text then
            logError(context, text)
        end
        showErrors(context)
    end
    return
end

--- Flight may reset the model identity or request an arming reload or a
--- session reset, which hold the dashboard for the rest of the callback.
local function flightStep(task, now, granted, hidden)
    local used, again = pumpFlight(task, now, granted)
    updateHolds(task.host, hidden)
    return used, again
end

local function openModelSettings(context)
    local owner = context.flightFactory.broker
    if not owner or not owner.documentLoaded or owner.loadError then
        addError(
            context,
            "Model settings are unavailable: " .. tostring(owner and owner.loadError or "flight service is loading")
        )
        showErrors(context)
        return
    end
    if not context.settingsUiModule then
        local module, message = loadModule(context.path, "lib/settings_ui.lua", 1)
        if not module then
            addError(context, "Settings UI: " .. tostring(message))
            showErrors(context)
            return
        end
        context.settingsUiModule = module
    end
    if not context.modelSettingsUiModule then
        local module, message = loadModule(context.path, "lib/model_settings_ui.lua", 1)
        if not module then
            addError(context, "Model settings: " .. tostring(message))
            showErrors(context)
            return
        end
        context.modelSettingsUiModule = module
    end
    local latest, loadError = owner.store:load(owner.filename)
    if not latest then
        addError(context, "Model settings: " .. tostring(loadError))
        showErrors(context)
        return
    end
    owner:setDocument(latest)
    local document = {
        modelFilename = owner.filename,
        revision = owner.document and owner.document.revision or 0,
        flight = owner.document and owner.document.flight,
        armed = owner.document and owner.document.armed,
        sessionReset = owner.document and owner.document.sessionReset,
    }
    if document.armed == nil then
        local selections = {}
        for host in pairs(owner.members) do
            if host.legacyWidgetArmed and host.legacyWidgetArmed ~= 0 then
                selections[host.legacyWidgetArmed] = true
            end
        end
        local count = 0
        for _ in pairs(selections) do
            count = count + 1
        end
        document.status = count > 1
                and "Conflicting old widget Armed selections were not imported. Choose one model switch."
            or count == 1 and "Old widget Armed was not imported. Choose the model switch."
            or "No model Armed set. Legacy panel switches remain until changed; None disables arming model-wide."
    end
    local suspended = context.editorUi ~= nil
    if suspended then
        context.editorStash = context.editorSession
        context.editorUiModule.close(context, false)
        context.editorController.restorePreview(context)
        context.editorSession = nil
    end
    local function resume()
        if suspended and owner:identity() ~= document.modelFilename then
            context.editorStash = nil
        end
    end
    local opened, message = pcall(context.modelSettingsUiModule.open, context, document, {
        modelFilename = function()
            return owner:identity()
        end,
        fullscreen = isFullScreen,
        flightConfig = context.flightConfig,
        armedConfig = context.serviceRuntime.modules.armed,
        armControl = context.serviceRuntime.byId.control,
        smartStatus = function()
            return owner.view.smartStatus
        end,
        prepare = function(values, revision, modelFilename, armedCondition, sessionReset)
            local ok, message = pcall(function()
                owner:validateOutput(values.flightSwitch, armedCondition, sessionReset)
            end)
            if not ok then
                return false, tostring(message)
            end
            return owner.store:prepare(modelFilename, revision, values, armedCondition, sessionReset)
        end,
        commit = function(prepared)
            if owner.document.flightCount ~= prepared.baseCount then
                local ok, latest = owner.store:prepare(
                    prepared.filename,
                    prepared.baseRevision,
                    prepared.document.flight,
                    prepared.document.armed,
                    prepared.document.sessionReset
                )
                if not ok then
                    return false, latest
                end
                return false, latest, true
            end
            return owner.store:commit(prepared)
        end,
        saved = function(saved)
            owner.settingsAdoption = nil
            owner:setDocument(saved)
        end,
        error = function(message)
            addError(context, "Model settings: " .. message)
            showErrors(context)
        end,
        cancel = resume,
    })
    if not opened then
        resume()
        addError(context, "Model settings: " .. tostring(message))
        showErrors(context)
    end
end

local function syncChrome(context, fullscreen)
    if fullscreen then
        lvgl.show(context.chromeRoot)
        context.aeroMenuModule.sync(context)
    else
        lvgl.hide(context.chromeRoot)
    end
end

local function prepareAeroMenu(context)
    if context.editorUi and context.aeroMenuModal == true and isFullScreen() then
        return false
    end
    if context.chromeRoot then
        syncChrome(context, isFullScreen())
    end
    if not context.theme or context.runtimeFailed or context.stage or context.reloadState then
        return false
    end
    if not context.aeroMenuModule then
        local module, message = loadModule(context.path, "lib/aerogrid_menu.lua", 1)
        if not module then
            addError(context, "AeroGrid menu: " .. tostring(message))
            return
        end
        context.aeroMenuModule = module
        return true
    end
    local height = buttonHeight()
    if not context.aeroMenuHandlers then
        context.aeroMenuHandlers = {
            fullscreen = isFullScreen,
            modelFilename = function()
                local info = model and model.getInfo and model.getInfo()
                return info and info.filename
            end,
            modelSettings = function()
                context.modelSettingsRequest = { modelFilename = context.aeroMenuHandlers.modelFilename() }
            end,
            uiSetup = function()
                context.editorDebriefRequest = false
                context.editorTransitionRequest = "open"
            end,
            debrief = function()
                context.editorDebriefRequest = true
                context.editorTransitionRequest = "open"
            end,
            modal = function()
                return context.modelSettingsUi ~= nil
                    or context.locationDetails ~= nil
                    or context.logViewer ~= nil
                    or debriefShown(context)
            end,
            editing = function()
                return context.editorUi ~= nil
            end,
        }
    end
    if not context.chromeRoot then
        context.chromeRoot = lvgl.box({ x = 0, y = 0, w = context.zone.w, h = context.zone.h })
        if not isFullScreen() then
            lvgl.hide(context.chromeRoot)
        end
        context.aeroMenuParent = nil
    end
    context.aeroMenuHandlers.parent = context.chromeRoot
    local handlers = context.aeroMenuHandlers
    local fullscreen, modal = isFullScreen(), handlers.modal() or handlers.editing()
    if
        context.aeroMenuParent ~= context.root
        or context.aeroMenuHeight ~= height
        or context.aeroMenuWidth ~= context.zone.w
        or context.aeroMenuZoneHeight ~= context.zone.h
        or context.aeroMenuFullscreen ~= fullscreen
        or context.aeroMenuModal ~= modal
    then
        local _, created = context.aeroMenuModule.ensure(
            context,
            { w = math.floor(height * BUTTON_WIDTH_RATIO + 0.5), h = height },
            context.aeroMenuHandlers
        )
        context.aeroMenuParent, context.aeroMenuHeight = context.root, height
        context.aeroMenuWidth, context.aeroMenuZoneHeight = context.zone.w, context.zone.h
        context.aeroMenuFullscreen, context.aeroMenuModal = fullscreen, modal
        context.chromeRoot:set({ w = context.zone.w, h = context.zone.h })
        -- Keep icon construction separate from idle reload work without dropping input.
        if created then
            return true
        end
    end
    context.aeroMenuModule.advance(context)
    if not fullscreen then
        lvgl.hide(context.chromeRoot)
    end
    return false
end

local function suspendArmingEditor(context)
    if context.modelArmingReload then
        if context.editorUi and context.editorUi.saving then
            context.uiRequest = "editor"
            return true
        end
        context.editorTransitionRequest = "suspend"
        return true
    end
    return false
end

local function pumpSessionReset(context)
    if not context.sessionResetPending then
        return false
    end
    if context.reloadState or context.stage then
        return false
    end
    local job = context.sessionResetJob
    if not job then
        job = { service = 1, item = 1, panel = 1, now = getTime() }
        context.sessionResetJob = job
    end
    local runtime = context.serviceRuntime
    local service = runtime and runtime.order[job.service]
    while service do
        if service.resetSession and not service.failed then
            for _ = 1, 8 do
                local ok, nextItem = pcall(service.resetSession, service, job.now, job.item)
                if not ok then
                    service.failed = true
                    addError(context, service.id .. ": reset: " .. tostring(nextItem))
                    showErrors(context)
                elseif nextItem then
                    job.item = nextItem
                end
                if not ok or not nextItem then
                    service.revision = service.revision + 1
                    service.due = job.now
                    job.service, job.item = job.service + 1, 1
                    return true
                end
            end
            return true
        end
        job.service, job.item = job.service + 1, 1
        service = runtime.order[job.service]
    end
    local entry = context.panels[job.panel]
    while entry do
        if not entry.failed and rawget(entry.module, "resetSession") then
            local ok, message, _, unfinished = context.panelHost.dispatch(entry, "resetSession", job.now)
            if not ok and message then
                addError(context, entry.placement.id .. ": reset: " .. message)
                showErrors(context)
            end
            entry.nextRefresh = job.now
            if not unfinished then
                job.panel = job.panel + 1
            end
            return true
        end
        job.panel = job.panel + 1
        entry = context.panels[job.panel]
    end
    context.sessionResetPending, context.sessionResetJob = nil, nil
    return true
end

--- A session reset runs before other host work.
local function sessionResetReady(task)
    local context = task.host
    return sessionResetDue(context) and not context.modelArmingReload
end

local function sessionResetStep(task)
    local context = task.host
    closeDashboard(context)
    pumpSessionReset(context)
    return nil, context.sessionResetPending == true
end

-- Routing records intent only; native work still needs its own task grant.
local function routeHost(context, hidden)
    if context.editorRestore and not (context.stage or context.reloadState) then
        return true
    end
    if suspendArmingEditor(context) then
        return true
    end
    if context.modelSettingsUi then
        local state = context.modelSettingsUi
        local broker = context.flightFactory and context.flightFactory.broker
        if
            state.build
            or state.pending
            or state.closing
            or broker and broker.filename ~= state.modelFilename
            or not isFullScreen()
        then
            context.uiRequest = "model settings"
        end
        return true
    end
    if context.stage == "retained-release" then
        context.lifecycleRequest = "load"
        return true
    end
    if hidden then
        if context.editorUi and context.editorUi.saving then
            context.uiRequest = "editor"
        elseif context.reloadState == "clear" then
            context.lifecycleRequest = "retire"
        elseif context.reloadState == "rebuild" then
            context.lifecycleRequest = "rebuild"
        elseif context.stage then
            context.lifecycleRequest = "load"
        end
        return true
    end
    if context.locationDetails and (not isFullScreen() or context.reloadState) then
        context.locationRequest = { kind = "close", state = context.locationDetails }
        return true
    end
    if
        context.logViewer
        and (
            not isFullScreen()
            or context.reloadState
            or context.logViewer.width ~= context.zone.w - 16
            or context.logViewer.height ~= context.zone.h
        )
    then
        context.logViewer.closing = true
        context.uiRequest = "log viewer"
        return true
    end
    local debrief = context.debrief
    if debrief then
        local zone = context.zone
        if
            debrief.result ~= debriefResult(context)
            or debrief.document ~= context.document
            or debrief.width ~= zone.w
            or debrief.height ~= zone.h
        then
            debrief.stale = true
            context.uiRequest = "debrief"
            return true
        elseif debrief.shown and (not isFullScreen() or context.reloadState) then
            debrief.closing = true
            context.uiRequest = "debrief"
            return true
        end
    end

    -- Leaving fullscreen neither saves nor discards. Editor boxes built in
    -- fullscreen would swallow the long press in App mode, so the editor is
    -- torn down and a changed draft is set aside until fullscreen returns.
    -- A save already running finishes first, in `background`.
    if context.editorUi and not isFullScreen() and not context.editorUi.saving then
        context.editorTransitionRequest = "leave"
        return true
    elseif
        context.editorStash
        and not context.editorUi
        and isFullScreen()
        and not context.stage
        and not context.reloadState
        and context.document
    then
        context.editorTransitionRequest = "open"
        return true
    end

    -- EdgeTX 2.12 only makes Lua boxes touch-transparent when constructing
    -- them in App mode. Fullscreen-built boxes otherwise consume the native
    -- widget's long press after exit; the Lua API cannot change that flag.
    if
        not isFullScreen()
        and not context.editorUi
        and not context.reloadState
        and (context.pageBuiltFullscreen or context.rootBuiltFullscreen or context.nativeDialogsCreated)
    then
        context.reloadState = "clear"
    end

    -- A reload takes two callbacks on purpose. EdgeTX defers the cleanup that
    -- follows `clear()` until after the callback returns, and that cleanup
    -- invalidates every object in the cleared object's child list, including
    -- ones created after the clear in the same callback. Anything rebuilt here
    -- would therefore be swept before it was ever drawn.
    if context.reloadState == "clear" then
        context.lifecycleRequest = "retire"
        return true
    end

    if context.reloadState == "rebuild" then
        context.lifecycleRequest = "rebuild"
        return true
    end

    if context.stage then
        context.lifecycleRequest = "load"
        return true
    end
    return false
end

--- Record the next host request from the current state. Routing only reads
--- state and records intent; each request's task does the native work.
local function routeForeground(context)
    if routeHost(context, false) then
        return
    end

    if not isFullScreen() then
        context.editorPress = nil
    end

    if editorWorkNeeded(context.editorUi) then
        context.uiRequest = "editor"
        return
    end

    if context.logViewer then
        if context.logViewer.prepareIndex or context.logViewer.closing then
            context.uiRequest = "log viewer"
        end
        return
    end

    if debriefShown(context) then
        return
    end

    if context.editorUi then
        return
    end

    -- A zone change repositions every panel, which a full grid cannot
    -- afford in one callback, so it is batched like loading. The absolute
    -- position matters as well as the size, because it decides whether the
    -- EdgeTX menu button reaches into us.
    --
    -- Fullscreen can change without changing geometry. Reflow still updates
    -- the corner reservation when AeroGrid replaces the native menu button.
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
        context.lifecycleRequest = "reflow"
        return
    end
    if context.reflowIndex then
        context.lifecycleRequest = "reflow"
        return
    end
    if not context.appRebuild and not isFullScreen() and not context.editorUi then
        for index, entry in ipairs(context.panels) do
            if entry.builtFullscreen then
                context.appRebuild = { entry = entry, index = index }
                break
            end
        end
    end
    if context.appRebuild then
        context.lifecycleRequest = "app rebuild"
        return
    end
end

--- Whether the empty-dashboard hint differs from what the page should show.
local function emptyHintStale(context)
    local hint = context.emptyHint
    local show = context.document
        and #context.document.panels == 0
        and not context.stage
        and not context.reloadState
        and not context.editorUi
        and #context.errors == 0
    if show then
        return not hint
            or not hint.visible
            or hint.w ~= context.zone.w
            or hint.h ~= context.zone.h
            or hint.fullscreen ~= isFullScreen()
    end
    return hint ~= nil and hint.visible
end

local function hintReady(task, _, hidden)
    return not hidden and not task.host.lifecycleRequest and emptyHintStale(task.host)
end

local function hintStep(task)
    task.host.dashboardLifecycle.updateEmptyHint(task.host)
end

--- Foreground work without a scheduler: only a failed runtime's error page.
local function advanceForeground(context)
    if context.runtimeFailed then
        context.root:set({ w = context.zone.w, h = context.zone.h })
        context.page:set({ w = context.zone.w, h = context.zone.h })
        context.canvas:set({ w = context.zone.w, h = context.zone.h })
        context.panelLayer:set({ w = context.zone.w, h = context.zone.h })
        context.reserved = reservedCorner(context.zone)
        if context.errorLabel then
            context.errorLabel:set({ y = errorTop(context), w = math.max(1, context.zone.w - 16) })
        end
        return
    end
    routeForeground(context)
    context.dashboardLifecycle.updateEmptyHint(context)
end

local function menuWorkNeeded(context, fullscreen)
    local editor, menu = context.editorUi, context.aerogridMenu
    if context.chromeRoot and context.menuVisibleFullscreen ~= fullscreen then
        return true
    end
    if
        context.runtimeFailed
        or context.stage
        or context.reloadState
        or not fullscreen and (context.lifecycleRequest or emptyHintStale(context))
    then
        return false
    end
    if editor and context.aeroMenuModal == true and fullscreen then
        return false
    end
    local modal = context.modelSettingsUi ~= nil
        or context.locationDetails ~= nil
        or context.logViewer ~= nil
        or debriefShown(context)
        or editor ~= nil
    return context.theme
        and (
            not context.aeroMenuModule
            or not context.chromeRoot
            or context.chromeRoot and (context.aeroMenuParent ~= context.root or context.aeroMenuHeight ~= buttonHeight() or context.aeroMenuWidth ~= context.zone.w or context.aeroMenuZoneHeight ~= context.zone.h or context.aeroMenuFullscreen ~= fullscreen or context.aeroMenuModal ~= modal)
            or menu
                and (menu.pending or menu.action or menu.dismiss or menu.selectionDirty or context.flightFactory and context.flightFactory.broker and menu.modelFilename ~= context.flightFactory.broker.filename)
        )
end

--- A screen change first only shows or hides the built button. That costs
--- no slot, so it replaces EdgeTX's own in the same callback even when
--- flight work has spent the budget.
local function chromeOnly(context)
    return context.chromeRoot and context.aerogridMenu and context.menuVisibleFullscreen ~= isFullScreen()
end

--- Building the button or the popup is costly; re-syncing a built menu,
--- running an action or moving the selection takes well under a slot.
local function menuCost(context)
    if chromeOnly(context) then
        return 0
    end
    local menu = context.aerogridMenu
    if
        not menu
        or not context.aeroMenuModule
        or not context.chromeRoot
        or context.aeroMenuParent ~= context.root
        or context.aeroMenuHeight ~= buttonHeight()
        or context.aeroMenuWidth ~= context.zone.w
        or context.aeroMenuZoneHeight ~= context.zone.h
        or menu.pending and not menu.screen
    then
        return context.scheduler.budget.slots
    end
    return 1
end

local function menuReady(task, _, hidden)
    task.cost = menuCost(task.host)
    return not hidden and task.host.menuDue
end

local function menuStep(task)
    local context = task.host
    if chromeOnly(context) then
        syncChrome(context, isFullScreen())
    else
        prepareAeroMenu(context)
    end
    context.menuVisibleFullscreen = isFullScreen()
end

-- Slots the editor's next step reserves: small build stages are cheap.
local function editorCost(context)
    local state = context.editorUi
    local pending = state and state.drawerPending
    if
        state
        and state.debrief
        and pending
        and (pending.action == "open" or pending.action == "list")
        and not state.drawerBuild
        and not state.nativeInput
        and not state.previewPending
        and not state.previewRefresh
        and not state.exitCommand
        and not state.saving
    then
        -- Opening the debrief list only creates its dialog; rows follow.
        return math.min(3, context.scheduler.budget.slots)
    end
    if
        state
        and not state.nativeInput
        and not state.previewPending
        and not state.previewRefresh
        and not state.exitCommand
        and not state.drawerPending
        and not state.saving
    then
        local capacity = context.scheduler.budget.slots
        if state.drawerBuild then
            -- Finalization also renders the editor; only individual rows are
            -- cheap. The debrief page has no editor to render.
            return context.settingsUiModule.cost(state.drawerView, capacity, state.debrief and 1 or capacity)
        elseif state.buildStage and state.buildStage <= 9 then
            return math.min(3, capacity)
        end
    end
    return context.scheduler.budget.slots
end

-- Pure construction can continue; operations that retire native objects keep
-- their callback boundary.
local function editorContinues(state)
    return state
        and (state.buildStage or state.saving or state.drawerBuild)
        and not state.nativeInput
        and not state.previewPending
        and not state.previewRefresh
        and not state.exitCommand
        and not state.drawerPending
end

--- Queued input, or a held long press, that the input task has yet to handle.
local function inputWaiting(context, hidden)
    return not hidden
        and (context.inputPending or context.editorPress and getTime() - context.editorPress.started >= 60)
end

local function inputReady(task, _, hidden)
    local context = task.host
    -- Settings input only records a close request; services share the rest.
    task.cost = context.modelSettingsUi and 1 or context.scheduler.budget.slots
    return inputWaiting(context, hidden)
        and isFullScreen()
        and not context.modelArmingReload
        and not sessionResetDue(context)
        and (context.modelSettingsUi or not context.stage and not context.reloadState)
        and not editorWorkNeeded(context.editorUi)
end

local function inputStep(task)
    local context = task.host
    local widgetEvent, touchState = context.widgetEvent, context.touchState
    context.inputHandled = context.inputPending
    if context.modelSettingsUi then
        context.modelSettingsUiModule.handle(context, widgetEvent, touchState)
        local state = context.modelSettingsUi
        if state and (state.build or state.pending or state.closing) then
            context.uiRequest = "model settings"
        end
        return
    end
    if context.aeroMenuModule and context.aeroMenuModule.handle(context, widgetEvent, touchState) then
        context.editorPress = nil
        return
    end
    -- Hold timing uses arrival time, not the deferred grant's time.
    if not context.editorUi and not context.locationDetails and not context.logViewer and not debriefShown(context) then
        if
            widgetEvent == _G.EVT_TOUCH_FIRST
            and context.editorController.editorEntryHit(context, widgetEvent, touchState, true)
        then
            context.editorPress = { started = context.inputTime or getTime() }
        elseif widgetEvent ~= nil and (widgetEvent == _G.EVT_TOUCH_BREAK or widgetEvent == _G.EVT_TOUCH_TAP) then
            context.editorPress = nil
        end
        if
            context.editorPress
            and not (context.inputQueue and #context.inputQueue > 1)
            and (context.inputTime or getTime()) - context.editorPress.started >= 60
        then
            context.editorPress = nil
            context.editorTransitionRequest = "open"
            return
        end
    end
    if widgetEvent == nil then
        return
    end
    if widgetEvent == _G.EVT_TOUCH_FIRST then
        context.touchTapHandled = false
    end
    if widgetEvent ~= _G.EVT_TOUCH_TAP or not context.touchTapHandled then
        if widgetEvent == _G.EVT_TOUCH_TAP then
            context.touchTapHandled = true
        end
        handleEvent(context, widgetEvent, touchState)
    end
end

local function modelSettingsOpenReady(task, _, hidden)
    local context = task.host
    return context.modelSettingsRequest
        and not hidden
        and isFullScreen()
        and not context.modelArmingReload
        and not context.sessionResetPending
        and not context.stage
        and not context.reloadState
        and not context.modelSettingsUi
        and not (context.editorUi and context.editorUi.saving)
end

local function modelSettingsOpenStep(task)
    local context = task.host
    local request, owner = context.modelSettingsRequest, context.flightFactory.broker
    context.modelSettingsRequest = nil
    if owner and (owner.filename ~= request.modelFilename or owner:identity() ~= request.modelFilename) then
        return
    end
    openModelSettings(context)
end

local function debriefOpenReady(task, _, hidden)
    return not hidden and task.host.debriefRequest ~= nil and debriefReady(task.host)
end

local function debriefOpenStep(task)
    local context = task.host
    local request, result = context.debriefRequest, debriefResult(context)
    context.debriefRequest = nil
    if not result or not debriefReady(context) then
        return
    end
    local ok, openError = pcall(context.debriefModule.open, context, result, request)
    if not ok then
        debriefFailed(context, openError)
        return
    end
end

local function debriefPillReady(task, _, hidden)
    local context = task.host
    return not hidden and not context.lifecycleRequest and debriefPillStale(context)
end

local function debriefPillStep(task)
    local context = task.host
    local ok, pillError = pcall(context.debriefModule.pill, context, debriefPillWanted(context))
    if not ok then
        debriefFailed(context, pillError)
    end
end

-- Lua instructions per scheduler slot, as the load stage costs assume.
local DEBRIEF_SLOT_INSTRUCTIONS = 2000
-- Slots per debrief build step: one tile (about 10k instructions) or curves.
local DEBRIEF_SLOTS = 5
-- Slots per pill update: a few measured texts and objects.
local DEBRIEF_PILL_SLOTS = 2

--- Whether the latest debrief's view still has to be built. Building starts
--- as soon as a debrief exists, so the view opens complete.
local function debriefBuildDue(context)
    local result, state = debriefResult(context), context.debrief
    if not result or context.debriefFailure == result then
        return false
    end
    if not state then
        return true
    end
    return state.result == result and not state.stale and not state.closing and context.debriefModule.pending(state)
end

local function debriefBuildReady(task, _, hidden)
    local context = task.host
    -- Objects created under the overlay in the callback that cleared it are
    -- swept by EdgeTX after the callback; see the reload comment above.
    return not hidden
        and context.page ~= nil
        and not context.debriefCleared
        and not context.reloadState
        and not context.stage
        and not context.modelSettingsUi
        and not context.editorUi
        and debriefBuildDue(context)
end

local function debriefBuildStep(task, _, granted)
    local context = task.host
    if not context.debriefModule then
        local loaded, message = loadModule(context.path, "lib/debrief_view.lua", 1)
        if not loaded then
            debriefFailed(context, message)
            return
        end
        context.debriefModule = loaded
    end
    local module = context.debriefModule
    local ok, buildError = pcall(function()
        if not context.debrief then
            context.debrief = module.new(context, debriefResult(context))
        end
        module.advance(context, granted * DEBRIEF_SLOT_INSTRUCTIONS)
    end)
    if not ok then
        debriefFailed(context, buildError)
    end
end

local function logOpenReady(task, _, hidden)
    return not hidden and task.host.logOpenRequest ~= nil
end

local function logOpenStep(task)
    local context = task.host
    context.logOpenRequest = nil
    local module = context.logViewerModule
    local message
    if not module then
        module, message = loadModule(context.path, "lib/log_viewer.lua", 1)
    end
    if not module then
        addError(context, "diagnostics log: " .. tostring(message))
        showErrors(context)
        return
    end
    context.logViewerModule = module
    local ok, openError = pcall(module.open, context)
    if not ok then
        module.close(context)
        addError(context, "diagnostics log: " .. tostring(openError))
        showErrors(context)
    end
end

local function locationReady(task, _, hidden)
    local request = task.host.locationRequest
    task.cost = request and request.kind == "close" and 1 or task.host.scheduler.budget.slots
    return not hidden and request ~= nil
end

local function locationStep(task)
    local context = task.host
    local request = context.locationRequest
    context.locationRequest = nil
    if request.kind == "close" then
        if context.locationDetails == request.state then
            context.locationDetailsModule.close(context)
        end
        return
    end
    local module = context.locationDetailsModule
    local message
    if not module then
        module, message = loadModule(context.path, "lib/location_details.lua", 1)
    end
    if not module then
        addError(context, "location details: " .. tostring(message))
        showErrors(context)
        return
    end
    context.locationDetailsModule = module
    local ok, openError = pcall(module.open, context, request.view, request.accent)
    if not ok then
        module.close(context)
        addError(context, "location details: " .. tostring(openError))
        showErrors(context)
    end
end

local function editorTransitionReady(task, _, hidden)
    local context = task.host
    local request, state = context.editorTransitionRequest, context.editorUi
    if request == "suspend" then
        return context.modelArmingReload
            and not (context.editorRestore and not (context.stage or context.reloadState))
            and not (state and state.saving)
    end
    if hidden or context.modelArmingReload or sessionResetDue(context) or context.modelSettingsUi then
        return false
    end
    if request == "leave" then
        return state ~= nil and not state.saving and not isFullScreen()
    end
    return request == "open"
        and not state
        and not context.stage
        and not context.reloadState
        and not context.editorRestore
        and not context.logViewer
        and not context.locationDetails
        and not debriefShown(context)
        and context.document ~= nil
        and isFullScreen()
end

local ARMING_SERVICES = { "armed", "navigation", "history" }

local function rebindArming(context)
    if context.stage or context.reloadState or not context.serviceRuntime or #context.rejected > 0 then
        context.retainForReload = true
        context.reloadState = "clear"
        context.modelArmingReload = nil
        context.armingRebind = nil
        return
    end
    local runtime = context.serviceRuntime
    local job = context.armingRebind
    if not job then
        context.modelArmed = context.flightFactory.broker.document.armed
        context.armGeneration = (context.armGeneration or 0) + 1
        runtime.modelArmed, runtime.armGeneration = context.modelArmed, context.armGeneration
        context.navigationHomes = {}
        runtime.navigationHomes = context.navigationHomes
        job = { service = 1, panel = 1 }
        context.armingRebind = job
    end
    local id = ARMING_SERVICES[job.service]
    if id then
        local previous = runtime.byId[id]
        if previous then
            if previous.destroy then
                previous:destroy()
            end
            local replacement = runtime.modules[id].new(runtime.env, context.servicesModule, runtime)
            for index, instance in ipairs(runtime.order) do
                if instance == previous then
                    runtime.order[index] = replacement
                    break
                end
            end
            runtime.byId[id] = replacement
        end
        job.service = job.service + 1
        return
    end
    local entry = context.panels[job.panel]
    if entry then
        if not entry.failed and rawget(entry.module, "rebindArming") then
            local ok, message = context.panelHost.dispatch(entry, "rebindArming", runtime.byId)
            if not ok then
                addError(context, entry.placement.id .. ": rebindArming: " .. tostring(message))
                showErrors(context)
            end
            entry.nextRefresh = 0
        end
        job.panel = job.panel + 1
        return
    end
    context.armingRebind = nil
    if context.modelArmed == context.flightFactory.broker.document.armed then
        context.configureFlight(context)
        context.configureDebrief(context)
        context.modelArmingReload = nil
    end
end

local function editorTransitionStep(task)
    local context = task.host
    local request, state = context.editorTransitionRequest, context.editorUi
    context.editorTransitionRequest = nil
    closeDashboard(context)
    if request == "open" then
        context.editorController.openEditor(context)
    else
        context.editorDebriefRequest = nil
        if state then
            local session = context.editorSession
            local keep = request == "suspend" or session and session.dirty and not state.buildStage
            context.editorUiModule.close(context, false)
            context.editorController.restorePreview(context)
            context.editorSession = nil
            context.editorStash = keep and session or nil
        end
        if request == "suspend" then
            if not state then
                rebindArming(context)
            end
        end
    end
end

local function editorRestoreReady(task, _, hidden)
    local context = task.host
    -- Reused containers need a foreground paint between clear and construction.
    return not hidden and context.editorRestore ~= nil and not (context.stage or context.reloadState)
end

local function editorRestoreStep(task)
    task.host.editorController.advanceRestore(task.host)
end

local function uiField(kind)
    if kind == "model settings" then
        return "modelSettingsUi"
    elseif kind == "editor" then
        return "editorUi"
    elseif kind == "debrief" then
        return "debrief"
    end
    return "logViewer"
end

local function uiCost(task)
    local context, slots = task.host, task.host.scheduler.budget.slots
    if task.kind == "editor" then
        return editorCost(context)
    elseif task.kind == "model settings" then
        local cost = context.modelSettingsUiModule.cost
        return cost and math.min(cost(context), slots) or slots
    elseif task.kind == "debrief" then
        return 1
    end
    return context.logViewer and context.logViewer.closing and 1 or slots
end

local function uiReady(task, _, hidden)
    local context = task.host
    task.cost = uiCost(task)
    if task.kind == "editor" then
        local state = context.editorUi
        if not state or state ~= task.ui or not editorWorkNeeded(state) then
            return false
        end
        if context.modelArmingReload then
            return state.saving ~= nil
        end
        return not sessionResetDue(context)
            and not context.modelSettingsUi
            and (hidden and state.saving ~= nil or not hidden and (isFullScreen() or state.saving ~= nil))
    end
    if context.modelArmingReload or sessionResetDue(context) then
        return false
    end
    if task.kind == "model settings" then
        return task.ui ~= nil and context.modelSettingsUi == task.ui
    end
    if task.kind == "debrief" then
        local state = context.debrief
        return not hidden
            and not context.modelSettingsUi
            and not context.stage
            and state ~= nil
            and state == task.ui
            and (state.stale or state.closing)
    end
    local viewer = context.logViewer
    return not hidden
        and not context.modelSettingsUi
        and not context.stage
        and viewer ~= nil
        and viewer == task.ui
        and (
            viewer.closing
            or not context.reloadState
                and isFullScreen()
                and viewer.width == context.zone.w - 16
                and viewer.height == context.zone.h
                and viewer.prepareIndex ~= nil
        )
end

local function uiStep(task, _, _, hidden)
    local context = task.host
    context.uiRequest = nil
    if task.kind == "editor" then
        local continues = editorContinues(context.editorUi)
        context.editorController.advanceEditor(context)
        if editorWorkNeeded(context.editorUi) then
            context.uiRequest = task.kind
            if continues and editorContinues(context.editorUi) then
                return nil, true
            end
        end
    elseif task.kind == "model settings" then
        context.modelSettingsUiModule.advance(context)
        local state = context.modelSettingsUi
        if state and (state.build or state.pending or state.closing) then
            context.uiRequest = task.kind
            -- Fields only create controls; commands and closing keep their boundary.
            if state.build and not state.pending and not state.closing then
                return nil, true
            end
        end
    elseif task.kind == "debrief" then
        local state, module = context.debrief, context.debriefModule
        if state.stale then
            module.destroy(context)
        else
            module.hide(context)
        end
    else
        if context.logViewer.closing then
            context.logViewerModule.close(context)
            return
        end
        context.logViewerModule.advance(context)
        if context.logViewer and context.logViewer.prepareIndex then
            context.uiRequest = task.kind
            return nil, true
        end
    end
end

-- Slots reserved per load stage, from peak mocked-VM instruction counts at
-- about 2000 instructions per slot; stages not listed reserve a full segment.
local LOAD_STAGE_COST = {
    ["header-migrate"] = 1,
    ["panel-migrate"] = 1,
    ["panel-validate"] = 1,
    ["model-settings"] = 2,
    ["read"] = 2,
    ["services"] = 2,
    ["header"] = 2,
    ["header-finalize"] = 2,
    ["panels"] = 2,
    ["debrief"] = 3,
    ["load-complete"] = 2,
    ["tokenize"] = 3,
    ["theme-validate"] = 4,
}

local function lifecycleWanted(context, kind, hidden)
    if kind == "retire" then
        return context.reloadState == "clear"
    elseif kind == "rebuild" then
        return context.reloadState == "rebuild" and not context.retireBoundary
    elseif kind == "load" then
        if context.stage == "retained-release" then
            return true
        end
        local broker = context.flightFactory and context.flightFactory.broker
        if context.stage == "services" and broker and not broker.documentLoaded then
            return false
        end
        if hidden and context.stage == "panel-build" and context.loadConfigured then
            for peer in pairs(context.flightFactory.members) do
                if
                    peer ~= context
                    and peer.foreground
                    and not peer.runtimeFailed
                    and (
                        peer.initializing
                        or peer.stage
                        or peer.reloadState
                        or peer.firstRefreshUntil and getTime() < peer.firstRefreshUntil
                    )
                then
                    return false
                end
            end
        end
        return not context.reloadState and context.stage ~= nil
    elseif kind == "reflow" then
        return not hidden
            and not context.reloadState
            and not context.stage
            and not context.logViewer
            and not debriefShown(context)
    end
    return not hidden and not context.reloadState and not context.stage and context.appRebuild ~= nil
end

--- Each lifecycle step checks its own work, then the shared lifecycle hold
--- and any input it must not run ahead of.
local function lifecycleReady(task, _, hidden)
    local context, kind = task.host, task.kind
    if context.lifecycleHold or not lifecycleWanted(context, kind, hidden) then
        return false
    end
    local slots = context.scheduler.budget.slots
    if kind == "load" then
        task.cost = math.min(LOAD_STAGE_COST[context.stage] or slots, slots)
    elseif kind == "rebuild" then
        task.cost = 1
    else
        task.cost = slots
    end
    return context.stage or context.reloadState or not inputWaiting(context, hidden)
end

local function lifecycleStep(task, _, _, hidden)
    local context, kind = task.host, task.kind
    context.lifecycleRequest = nil
    closeDashboard(context)
    if kind == "retire" then
        context.dashboardLifecycle.retirePage(context)
        context.retireBoundary = true
        context.lifecycleRequest = "rebuild"
    elseif kind == "rebuild" then
        context.dashboardLifecycle.rebuildPage(context)
        startLoad(context)
        context.lifecycleRequest = "load"
    elseif kind == "load" then
        local firstPanel = not hidden and #context.panels == 0
        if context.stage == "model-settings" then
            advanceModelSettings(context)
        else
            context.dashboardLoader.advanceLoad(context, hidden)
        end
        if context.stage then
            context.lifecycleRequest = "load"
            -- Let firmware paint the first panel before another construction burst.
            return nil, not (firstPanel and #context.panels > 0)
        end
    elseif kind == "reflow" then
        if
            context.width ~= context.zone.w
            or context.height ~= context.zone.h
            or context.left ~= (context.zone.xabs or 0)
            or context.top ~= (context.zone.yabs or 0)
            or context.fullScreen ~= isFullScreen()
        then
            context.dashboardLifecycle.beginReflow(context)
        end
        if context.reflowIndex then
            context.dashboardLifecycle.advanceReflow(context)
        end
        if context.reflowIndex then
            context.lifecycleRequest = "reflow"
            return nil, true
        end
    else
        context.dashboardLifecycle.advanceAppRebuild(context)
        if context.appRebuild then
            context.lifecycleRequest = "app rebuild"
        end
    end
end

--- Host tasks share only real ordering barriers: options and due session
--- resets preempt unrelated work; visible menu changes precede dependent work;
--- input cannot be overtaken by work that replaces its target; and page rebuilds
--- wait one native callback after retirement.
local function hostReady(task, now, hidden)
    local context = task.host
    if context.optionsRequest and task ~= context.optionsTask then
        return false
    end
    if
        sessionResetDue(context)
        and not context.modelArmingReload
        and task ~= context.optionsTask
        and task ~= context.sessionResetTask
    then
        return false
    end
    if context.menuDue and task ~= context.menuTask and not context.menuChromeOnly then
        return false
    end
    local first = task.inputFirst
    if first and (first == true or first(task)) and inputWaiting(context, hidden) then
        return false
    end
    return task.gate(task, now, hidden)
end

local function hostStep(task, now, granted, hidden)
    local context = task.host
    local used, again = task.run(task, now, granted, hidden)
    updateHolds(context, hidden)
    return used, again
end

local function hostTask(context, field, name, gate, run, fields)
    local task = context[field]
    if not task then
        task = {
            name = name,
            owner = name,
            host = context,
            onError = hostError,
            cost = context.scheduler.budget.slots,
            gate = gate,
            run = run,
            ready = hostReady,
            step = hostStep,
        }
        for key, value in pairs(fields or {}) do
            task[key] = value
        end
        context[field] = task
    end
    return task
end

local function kindTask(context, field, kind, gate, run, ui)
    local tasks = context[field]
    if not tasks then
        tasks = {}
        context[field] = tasks
    end
    local task = tasks[kind]
    if not task or ui and task.ui ~= ui then
        task = {
            name = kind,
            owner = kind,
            kind = kind,
            ui = ui,
            host = context,
            onError = hostError,
            gate = gate,
            run = run,
            ready = hostReady,
            step = hostStep,
        }
        if kind == "model settings" or kind == "log viewer" then
            task.inputFirst = function(self)
                local host = self.host
                return not (self.kind == "log viewer" and host.logViewer and host.logViewer.closing)
            end
        end
        tasks[kind] = task
    end
    return task
end

local function optionsReady(task)
    return task.host.optionsRequest ~= nil
end

local function editorOpening(task)
    return task.host.editorTransitionRequest == "open"
end

local function locationOpening(task)
    local request = task.host.locationRequest
    return request ~= nil and request.kind == "open"
end

--- Drop requests whose target has gone, so routing can record new ones.
local function pruneRequests(context, hidden, fullscreen)
    local filename
    if context.logOpenRequest or context.locationRequest then
        local info = model and model.getInfo and model.getInfo()
        filename = info and info.filename
    end
    if context.modelSettingsRequest then
        local task = hostTask(
            context,
            "modelSettingsOpenTask",
            "model settings open",
            modelSettingsOpenReady,
            modelSettingsOpenStep,
            { inputFirst = true }
        )
        if not modelSettingsOpenReady(task, nil, hidden) then
            if not hidden and (not fullscreen or context.modelSettingsUi) then
                context.modelSettingsRequest = nil
            elseif context.editorUi and context.editorUi.saving then
                context.uiRequest = "editor"
            end
        end
    end
    if context.editorTransitionRequest and not hidden then
        local task = hostTask(
            context,
            "editorTransitionTask",
            "editor transition",
            editorTransitionReady,
            editorTransitionStep,
            { inputFirst = editorOpening }
        )
        if not editorTransitionReady(task, nil, hidden) then
            context.editorTransitionRequest, context.editorDebriefRequest = nil, nil
        end
    end
    local request = context.logOpenRequest
    if
        request
        and (
            request.page ~= context.page
            or request.modelFilename ~= filename
            or context.reloadState
            or context.stage
            or context.modelSettingsUi
            or context.editorUi
            or not hidden and not fullscreen
        )
    then
        context.logOpenRequest = nil
    end
    request = context.debriefRequest
    if
        request
        and (
            request.page ~= context.page
            or context.reloadState
            or context.stage
            or context.modelSettingsUi
            or context.editorUi
            or context.logViewer
            or context.locationDetails
            or debriefShown(context)
            or not hidden and not fullscreen
            or not debriefResult(context)
        )
    then
        context.debriefRequest = nil
    end
    request = context.locationRequest
    if
        request
        and (
            request.kind == "close" and context.locationDetails ~= request.state
            or request.kind == "open"
                and (request.page ~= context.page or request.modelFilename ~= filename or context.reloadState or context.stage or context.modelSettingsUi or context.editorUi or context.logViewer or not hidden and not fullscreen)
        )
    then
        context.locationRequest = nil
    end
    local kind = context.lifecycleRequest
    -- The cached barrier is from the previous callback; judge with a fresh one.
    context.lifecycleHold = kind ~= nil and lifecycleHeld(context, hidden)
    if
        kind
        and not lifecycleReady(kindTask(context, "lifecycleTasks", kind, lifecycleReady, lifecycleStep), nil, hidden)
    then
        context.lifecycleRequest = nil
    end
    kind = context.uiRequest
    if kind then
        local ui = context[uiField(kind)]
        if not ui or not uiReady(kindTask(context, "uiTasks", kind, uiReady, uiStep, ui), nil, hidden) then
            context.uiRequest = nil
        end
    end
end

--- Enrol the host tasks with work outstanding, in a fixed order.
local function enrolHost(context, hidden)
    local add = context.scheduler.add
    if context.optionsRequest then
        add(hostTask(context, "optionsTask", "native options", optionsReady, optionsStep))
    end
    if context.sessionResetPending then
        add(hostTask(context, "sessionResetTask", "session reset", sessionResetReady, sessionResetStep))
    end
    if context.menuDue then
        add(hostTask(context, "menuTask", "menu", menuReady, menuStep))
    end
    if context.inputPending or context.editorPress then
        add(hostTask(context, "inputTask", "input", inputReady, inputStep))
    end
    if context.modelSettingsRequest then
        add(
            hostTask(
                context,
                "modelSettingsOpenTask",
                "model settings open",
                modelSettingsOpenReady,
                modelSettingsOpenStep,
                { inputFirst = true }
            )
        )
    end
    if context.editorRestore then
        add(hostTask(context, "editorRestoreTask", "editor restore", editorRestoreReady, editorRestoreStep))
    end
    if context.editorTransitionRequest then
        add(
            hostTask(
                context,
                "editorTransitionTask",
                "editor transition",
                editorTransitionReady,
                editorTransitionStep,
                { inputFirst = editorOpening }
            )
        )
    end
    if context.logOpenRequest then
        add(hostTask(context, "logOpenTask", "log open", logOpenReady, logOpenStep, { inputFirst = true }))
    end
    if debriefBuildDue(context) then
        add(
            hostTask(
                context,
                "debriefBuildTask",
                "debrief build",
                debriefBuildReady,
                debriefBuildStep,
                { inputFirst = true, cost = DEBRIEF_SLOTS }
            )
        )
    end
    if context.debriefRequest then
        add(
            hostTask(
                context,
                "debriefOpenTask",
                "debrief open",
                debriefOpenReady,
                debriefOpenStep,
                { inputFirst = true }
            )
        )
    end
    if context.locationRequest then
        add(
            hostTask(
                context,
                "locationTask",
                "location details",
                locationReady,
                locationStep,
                { inputFirst = locationOpening }
            )
        )
    end
    local kind = context.lifecycleRequest
    if kind then
        add(kindTask(context, "lifecycleTasks", kind, lifecycleReady, lifecycleStep))
    end
    kind = context.uiRequest
    if kind then
        add(kindTask(context, "uiTasks", kind, uiReady, uiStep, context[uiField(kind)]))
    end
    if not hidden and emptyHintStale(context) then
        add(hostTask(context, "hostTask", "host", hintReady, hintStep, { inputFirst = true }))
    end
    if not hidden and debriefPillStale(context) then
        add(
            hostTask(
                context,
                "debriefPillTask",
                "debrief pill",
                debriefPillReady,
                debriefPillStep,
                { inputFirst = true, cost = DEBRIEF_PILL_SLOTS }
            )
        )
    end
end

local function runCallback(context, hidden, widgetEvent, touchState)
    context.foreground = not hidden
    if context.initializing then
        if not hidden then
            event(context, widgetEvent, touchState)
        end
        -- The first callback reads the model's settings in one segment;
        -- later callbacks follow them.
        context.scheduler.add(context.initializationTask)
        runScheduled(context, hidden, 0)
        return
    end
    if not context.scheduler or context.runtimeFailed then
        if not hidden then
            advanceForeground(context)
        end
        return
    end
    local fullscreen = not hidden and isFullScreen()
    context.inputHandled, context.dashboardClosed, context.retireBoundary, context.menuChromeOnly = nil, nil, nil, nil
    context.debriefCleared = nil
    if not hidden then
        event(context, widgetEvent, touchState)
    end
    if not hidden and not fullscreen then
        context.inputQueue = nil
    end
    local input = not hidden and context.inputQueue and context.inputQueue[1]
    context.widgetEvent, context.touchState = input and input.event, input and input.touch
    context.inputTime = input and input.now
    context.inputPending = not not input
    if
        not context.optionsRequest
        and not context.lifecycleRequest
        and not context.uiRequest
        and not context.editorTransitionRequest
        and not context.locationRequest
    then
        if hidden then
            routeHost(context, true)
        else
            routeForeground(context)
        end
    end
    pruneRequests(context, hidden, fullscreen)
    context.menuDue = not hidden
        and not context.optionsRequest
        and not context.modelArmingReload
        and not context.sessionResetPending
        and menuWorkNeeded(context, fullscreen)
    context.menuChromeOnly = context.menuDue and chromeOnly(context)
    updateHolds(context, hidden, true)
    local flightTask
    local owner = context.flightFactory and context.flightFactory.broker
    if owner then
        flightTask = context.flightTask
        if not flightTask or flightTask.broker ~= owner then
            flightTask = {
                name = "flight",
                owner = "flight",
                onError = flightError,
                broker = owner,
                host = context,
                step = flightStep,
                ready = flightReady,
            }
            context.flightTask = flightTask
        end
    end
    context.scheduler.clear()
    if flightTask then
        context.scheduler.add(flightTask)
        local tasks = owner:tasks()
        for index = 1, #tasks do
            context.scheduler.add(tasks[index])
        end
    end
    enrolHost(context, hidden)
    runTasks(context, hidden)
    if context.uiTasks then
        for kind, task in pairs(context.uiTasks) do
            local ui = context[uiField(kind)]
            if task.ui ~= ui then
                task.ui = nil
            end
        end
    end
    if not hidden and context.inputQueue and context.inputHandled then
        table.remove(context.inputQueue, 1)
        if #context.inputQueue == 0 then
            context.inputQueue = nil
        end
    end
    if input then
        context.widgetEvent, context.touchState, context.inputPending, context.inputTime = nil, nil, nil, nil
    end
end

local function refresh(context, widgetEvent, touchState)
    runCallback(context, false, widgetEvent, touchState)
end

local function background(context)
    runCallback(context, true)
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
