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
---@field services table Shared objects handed to panels.
---@field rejected table[] Placements that would not build, with the reason.
---@field layoutPath? string
---@field layoutOrigin? string Which filename answered: user, shipped, default, none.
---@field modelFilename? string Current model filename, for diagnostics.
---@field themeSource? string Theme selection source.
---@field errorLabel? any
---@field page any Container holding one generation of the dashboard.
---@field reloadState? "clear"|"rebuild"
---@field stage? "theme-read"|"theme-validate"|"read"|"tokenize"|"header"|"header-migrate"|"header-finalize"|"services"|"panels"|"panel-migrate"|"panel-validate"|"panel-build" Staged loader position.
---@field servicesModule? table Loaded lib/services.lua registry module.
---@field packageInfo? table Package identity and compatibility versions.
---@field serviceRuntime? table Registry holding every constructed service.
---@field serviceIndex? integer Next service definition to construct.
---@field source? string Layout text held between the read and tokenize steps.
---@field tokens? table Tokens held between the tokenize and parse steps.
---@field pending? table[] Validated placements still awaiting construction.
---@field pendingIndex? integer Next placement to build.
---@field scheduler table Slot scheduler that runs panels and services.
---@field dashboardLoader table Staged layout and panel construction.
---@field dashboardLifecycle table Page retirement, reflow, and rebuild.
---@field editorController table Dashboard preview and editor coordination.
---@field editorModule? table On-radio layout editor, loaded only on demand.
---@field editorUiModule? table LVGL editor controls, loaded only on demand.
---@field editorSession? table Uncommitted editor working copy.
---@field editorUi? table Active editor screen state.

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
local labels = {}
for _, definition in ipairs(startupThemeCatalog and startupThemeCatalog.themes or {}) do
    if type(definition.name) == "string" then
        labels[definition.name] = definition.label
    end
end
labels["modern-dark"] = labels["modern-dark"] or "Modern Dark"
labels["modern-light"] = labels["modern-light"] or "Modern Light"
for _, name in ipairs(THEME_MODES) do
    themeLabels[#themeLabels + 1] = labels[name] or name
end

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
local flightFactories = {}

local function newScheduler(context, schedulerModule)
    local ok, scheduler = pcall(schedulerModule.new, {
        fail = function(task, message)
            local owner = task.owner
            if task.flightWork then
                task.broker:error("detection", message)
            elseif task.hostWork then
                context.runtimeFailed = true
                if task.name == "initialize" then
                    local member = context.flightFactory.members[context]
                    if member then
                        member.pending, member.error = false, message
                        context.flightFactory.revision = (context.flightFactory.revision or 0) + 1
                    end
                end
            elseif task.service then
                owner.failed = true
            elseif not owner.failed then
                owner.failed, owner.error = true, message
            end
            addError(context, task.name .. ": " .. message)
            context.schedulerFailed = true
        end,
        charge = function(task, spent)
            local stats = context.schedulerStats
            local window = stats and stats.window
            if window then
                window[task.owner] = (window[task.owner] or 0) + spent
            end
        end,
    })
    if not ok or type(scheduler) ~= "table" then
        addError(context, "lib/scheduler.lua: " .. tostring(ok and "constructor did not return a table" or scheduler))
        return nil
    end
    for _, operation in ipairs({ "add", "clear", "run" }) do
        if type(rawget(scheduler, operation)) ~= "function" then
            addError(context, "lib/scheduler.lua: missing operation " .. operation)
            return nil
        end
    end
    return scheduler
end

local initialize

--- Create one AeroGrid host instance for an EdgeTX custom-screen zone.
---@param zone AeroGridZone
---@param widgetOptions AeroGridWidgetOptions
---@param path string Absolute widget directory supplied by EdgeTX.
---@return AeroGridContext
local function create(zone, widgetOptions, path)
    local flightFactory = flightFactories[path or WIDGET_PATH]
    if not flightFactory then
        flightFactory = { members = setmetatable({}, { __mode = "k" }) }
        flightFactories[path or WIDGET_PATH] = flightFactory
    end
    local context = {
        zone = zone,
        path = path,
        layoutName = layoutName(widgetOptions.Layout),
        themeMode = themeModeOf(widgetOptions.Theme),
        legacyWidgetArmed = widgetOptions.Armed or 0,
        flightFactory = flightFactory,
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
    if not context.scheduler then
        context.runtimeFailed = true
        context.root = lvgl.box({ x = 0, y = 0, w = zone.w, h = zone.h })
        context.page = lvgl.box(context.root, { x = 0, y = 0, w = zone.w, h = zone.h })
        context.canvas = lvgl.rectangle(context.page, {
            x = 0,
            y = 0,
            w = zone.w,
            h = zone.h,
            color = lcd.RGB(0x101316),
            filled = true,
        })
        showErrors(context)
        return context
    end
    context.initializing, context.stage = true, "initialize"
    context.initializationTask = {
        name = "initialize",
        owner = "initialize",
        host = context,
        hostWork = true,
        cost = context.scheduler.capacity,
        step = function()
            context.initializing = nil
            initialize(context)
        end,
    }
    return context
end

initialize = function(context)
    local path, zone, flightFactory = context.path, context.zone, context.flightFactory
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
        context.layoutValidator = runtimeModule("lib/layout.lua")
        context.layoutStore = runtimeModule("lib/layout_store.lua")
        context.flightConfig = runtimeModule("lib/flight_config.lua")
        context.aeroMenuModule = runtimeModule("lib/aerogrid_menu.lua")
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
        context.panelHost = runtimeModule("lib/panel_host.lua")
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
            }, { "beginLoad", "advanceLoad", "panelRect", "buildPanel" })
        end
        if context.panelHost then
            context.panelHost.SLOTS = context.scheduler.capacity
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
                buildPanel = context.dashboardLoader.buildPanel,
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
                updateEmptyHint = context.dashboardLifecycle.updateEmptyHint,
            }, { "restorePreview", "openEditor", "advanceEditor", "editorEntryHit" })
        end
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
    context.rootBuiltFullscreen = isFullScreen()
    local info = model and model.getInfo and model.getInfo()
    flightFactory.members[context] = {
        modelFilename = info and info.filename,
        layoutName = context.layoutName,
        pending = true,
    }
    flightFactory.revision = (flightFactory.revision or 0) + 1

    -- The canvas must be a filled rectangle. A box ignores `color`, leaving the
    -- radio's own screen background, including its logo, visible behind us.
    -- Everything the dashboard draws lives inside a page, so a reload can
    -- discard the page wholesale and build the next one somewhere the discarded
    -- one's deferred cleanup cannot reach. The root is normally retained.
    context.page = lvgl.box(context.root, { x = 0, y = 0, w = zone.w, h = zone.h })
    context.pageBuiltFullscreen = isFullScreen()

    context.canvas = lvgl.rectangle(context.page, {
        x = 0,
        y = 0,
        w = zone.w,
        h = zone.h,
        color = lcd.RGB(0x101316),
        filled = true,
    })

    if
        not context.packageInfo
        or not context.grid
        or not context.yaml
        or not context.layoutValidator
        or not context.layoutStore
        or not context.flightConfig
        or not context.configureFlight
        or not context.aeroMenuModule
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
        context.dashboardLoader.beginLoad(context)
    end
end

--- Apply native host options; changing Layout or Theme rebuilds safely.
---@param context AeroGridContext
---@param widgetOptions AeroGridWidgetOptions
local function update(context, widgetOptions)
    local name = layoutName(widgetOptions.Layout)
    local themeMode = themeModeOf(widgetOptions.Theme)

    -- Without a runtime there is nothing to rebuild, and restaging would fail.
    if context.runtimeFailed then
        return
    end

    if name ~= context.layoutName or themeMode ~= context.themeMode then
        context.optionsRequest = { layoutName = name, themeMode = themeMode }
    else
        context.optionsRequest = nil
    end
end

local function optionsStep(task)
    local context = task.host
    local request = context.optionsRequest
    context.optionsRequest = nil
    local member = context.flightFactory.members[context]
    member.pending = true
    context.flightFactory.revision = (context.flightFactory.revision or 0) + 1
    context.editorStash, context.editorTransitionRequest, context.modelSettingsRequest = nil, nil, nil
    context.logOpenRequest = nil
    if context.locationRequest and context.locationRequest.kind == "open" then
        context.locationRequest = nil
    end
    if context.editorUi then
        context.editorUiModule.close(context, true)
        context.editorController.restorePreview(context)
        context.editorSession = nil
    end
    context.layoutName, context.themeMode = request.layoutName, request.themeMode
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
        return context.locationDetailsModule.handle(context, widgetEvent)
    end
    if context.logViewer then
        return context.logViewerModule.handle(context, widgetEvent, touchState)
    end
    if context.editorController.editorEntryHit(context, widgetEvent, touchState) then
        context.editorTransitionRequest = "open"
        return true
    end

    if widgetEvent == _G.EVT_TOUCH_FIRST then
        context.panelTouchSlid = false
    elseif widgetEvent == _G.EVT_TOUCH_SLIDE then
        context.panelTouchSlid = true
    elseif widgetEvent == _G.EVT_TOUCH_TAP and touchState and not context.panelTouchSlid and isFullScreen() then
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
    context.inputQueue[#context.inputQueue + 1] = input
    return true
end

--- Task steps that adapt the panel and service contracts to the scheduler.
--- Each task's `owner` is the service instance or panel entry it runs for.
local function serviceReady(task)
    local instance = task.owner
    return task.host.scheduledServices and not instance.failed and instance.count ~= 0
end

local function serviceStep(task, now, slots)
    local instance, registry = task.owner, task.registry
    instance.due = now + instance.interval
    registry.updates = registry.updates + 1
    local used = instance:update(now, slots)
    if instance.updateCost == "variable" and not task.host.servicesModule.consumption(used, slots) then
        error("update consumption must be whole slots within the grant", 0)
    end
    instance.revision = instance.revision + 1
    return used
end

local function refreshReady(task, _, hidden)
    local entry, owner = task.owner, task.host.refreshOwner
    return task.host.scheduledPanels
        and not hidden
        and not entry.failed
        and not (owner and entry ~= owner and entry.module.id == owner.module.id)
end

local function backgroundReady(task, _, hidden)
    return task.host.scheduledPanels and hidden and not task.owner.failed
end

local function panelStep(task, now, granted)
    local context, entry, eventName = task.host, task.owner, task.event
    local ok, message, _, unfinished, used = context.panelHost.dispatch(entry, eventName, false, granted)
    if task.cost ~= "variable" then
        used = granted
    end
    if ok and not context.servicesModule.consumption(used, granted) then
        ok, message = false, "refresh consumption must be whole slots within the grant"
        entry.failed, entry.error = true, message
    end
    if eventName == "refresh" then
        entry.nextRefresh = now + entry.interval
        if ok and unfinished and not rawget(entry.module, "independentRefresh") then
            context.refreshOwner = entry
        elseif context.refreshOwner == entry then
            context.refreshOwner = nil
        end
    end
    if not ok then
        error(message or "panel failed", 0)
    end
    return used
end

--- Enrol the live services and panels, in that order, for one run.
--- Membership is read from the host's own tables on every callback, so a panel
--- added, replaced or retired by the loader or editor needs no registration.
---@param context AeroGridContext
local function enrolTasks(context, registry)
    local scheduler = context.scheduler
    local order = registry.order
    for index = 1, #order do
        local instance = order[index]
        local task = instance.task
        if not task or task.registry ~= registry then
            task = {
                name = instance.id,
                verb = "update",
                owner = instance,
                service = true,
                registry = registry,
                host = context,
                step = serviceStep,
                ready = serviceReady,
            }
            instance.task = task
        end
        task.cost, task.due, task.failed = instance.updateCost, instance.due, instance.failed
        scheduler.add(task)
    end
    local panels = context.panels
    for index = 1, #panels do
        local entry = panels[index]
        local module = entry.module
        if type(rawget(module, "refresh")) == "function" then
            local task = entry.refreshTask
            if not task then
                task = {
                    name = entry.placement.id .. ": refresh",
                    owner = entry,
                    host = context,
                    event = "refresh",
                    step = panelStep,
                    ready = refreshReady,
                }
                entry.refreshTask = task
            end
            task.cost = rawget(entry.instance, "refreshCost") or rawget(module, "refreshCost") or 1
            task.due, task.failed = entry.nextRefresh or 0, entry.failed
            scheduler.add(task)
        end
        if type(rawget(module, "background")) == "function" then
            local task = entry.backgroundTask
            if not task then
                task = {
                    name = entry.placement.id .. ": background",
                    owner = entry,
                    host = context,
                    event = "background",
                    cost = 1,
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

--- Run flight, host work, services and panels in one fair queue.
local function runTasks(context, hidden, flightTask, hostTask)
    local registry, support = context.serviceRuntime, context.servicesModule
    local scheduler = context.scheduler
    scheduler.clear()
    if flightTask then
        scheduler.add(flightTask)
    end
    if hostTask then
        scheduler.add(hostTask)
    end
    if not hostTask and registry and support then
        enrolTasks(context, registry)
    end

    local now = getTime()
    local stats = context.schedulerStats
    local window = stats and stats.window
    if stats and not window then
        window = {}
        stats.window = window
    end
    local used, requested, denied = scheduler.run(now, scheduler.capacity, hidden or false)
    scheduler.clear()
    context.remainingSlots = scheduler.capacity - used

    if stats then
        stats.callbacks = stats.callbacks + 1
        stats.used = stats.used + scheduler.capacity - context.remainingSlots
        stats.requested, stats.denied = stats.requested + requested, stats.denied + denied
        if now - stats.started >= 100 then
            stats.utilization = stats.used * 100 / (stats.callbacks * scheduler.capacity)
            stats.deferrals = stats.requested > 0 and stats.denied * 100 / stats.requested or 0
            stats.revision = stats.revision + 1
            stats.consumers, stats.window = window, nil
            stats.capacity, stats.seconds = stats.callbacks * scheduler.capacity, (now - stats.started) / 100
            stats.started, stats.callbacks, stats.used, stats.requested, stats.denied = now, 0, 0, 0, 0
        end
    end
    if context.schedulerFailed then
        context.schedulerFailed = nil
        showErrors(context)
    end
end

local function pumpFlight(task, now, granted)
    local context, inputPending = task.host, task.host.inputPending
    local owner = context.flightFactory and context.flightFactory.broker
    if not owner then
        return false
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
        return false
    end
    if filename ~= owner.filename then
        owner:reset(filename)
        task.cost = context.scheduler.capacity
        context.scheduledServices, context.scheduledPanels = false, false
        if granted < context.scheduler.capacity then
            return nil, true
        end
    end
    if not owner.documentLoaded then
        if not owner.store then
            local storeModule, storeError = loadModule(context.path, "lib/model_settings_store.lua", 1)
            if not storeModule then
                owner.loadError, owner.documentLoaded = storeError, true
                context.scheduledServices, context.scheduledPanels = false, false
                return
            end
            local created, store = pcall(storeModule.new, context.path, context.yaml, {
                modelFilename = function()
                    return owner:identity()
                end,
                flightConfig = context.flightConfig,
                armedConfig = owner.modules.armed,
            })
            if not created then
                owner.loadError, owner.documentLoaded = tostring(store), true
                context.scheduledServices, context.scheduledPanels = false, false
                return
            end
            owner.store = store
        end
        local document, info = owner.store:load(filename)
        if document then
            owner:setDocument(document)
            if type(info) == "table" and info.recovered then
                addNotice(context, "warning", "Recovered previous model settings; review and save Model settings.")
            end
        else
            owner.loadError, owner.documentLoaded = tostring(info), true
        end
        context.scheduledServices, context.scheduledPanels = false, false
        return
    end
    local resetConfigured = owner.document and owner.document.sessionReset and owner.document.sessionReset ~= ""
    if (context.stage or context.reloadState) and not owner.session and not resetConfigured then
        return false
    end
    if resetConfigured or owner.resetRuntime or owner.errors.reset then
        local resetOk, resetError = pcall(owner.pollReset, owner, now)
        if not resetOk then
            owner:error("reset", resetError)
        end
    end
    if not owner.session and owner.dormantRevision == context.flightFactory.revision then
        if not owner.state.resetError and not context.flightErrorText then
            return false
        end
    end
    if owner.smartRuntime then
        if inputPending or context.flightDashboardDue then
            context.flightDashboardDue = nil
            return false
        end
        if owner.lastTick and now >= owner.lastTick and now < (owner.nextPumpAt or 0) then
            return false
        end
    end
    local ok, message = pcall(owner.tick, owner, now, filename)
    if not ok then
        owner:error("detection", message)
    end
    -- Share ordinary polling capacity, not whole chart callbacks. Construction
    -- still needs its own slice, with a fair turn for each widget's UI work.
    local reserved = false
    if owner.smartRuntime then
        context.flightPolled = true
        owner.nextPumpAt = now + 10
        reserved = not not (
            context.stage
            or context.reloadState
            or context.editorUi
            or context.modelSettingsUi
            or context.logViewer
            or context.appRebuild
            or context.reflowIndex
        )
        context.flightDashboardDue = reserved or nil
        if reserved then
            context.scheduledServices, context.scheduledPanels = false, false
        end
    end
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
        "outputError",
        "persistenceError",
        "resetError",
    }) do
        if state[key] then
            messages[#messages + 1] = "flight: " .. state[key]
        end
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
        save = function(values, revision, modelFilename, armedCondition, sessionReset)
            local ok, message = pcall(function()
                owner:validateOutput(values.flightSwitch, armedCondition, sessionReset)
            end)
            if not ok then
                return false, tostring(message)
            end
            return owner.store:save(modelFilename, revision, values, armedCondition, sessionReset)
        end,
        saved = function(saved)
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

local function prepareAeroMenu(context)
    if context.editorUi and context.aeroMenuModal == true and isFullScreen() then
        return false
    end
    if context.chromeRoot then
        if isFullScreen() then
            lvgl.show(context.chromeRoot)
        else
            lvgl.hide(context.chromeRoot)
        end
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
    if not isFullScreen() and not context.chromeRoot then
        return false
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
                context.editorTransitionRequest = "open"
            end,
            modal = function()
                return context.modelSettingsUi ~= nil
                    or context.locationDetails ~= nil
                    or context.logViewer ~= nil
                    or context.editorUi ~= nil
            end,
        }
    end
    if not context.chromeRoot then
        context.chromeRoot = lvgl.box({ x = 0, y = 0, w = context.zone.w, h = context.zone.h })
        context.aeroMenuParent = nil
    end
    context.aeroMenuHandlers.parent = context.chromeRoot
    local fullscreen, modal = isFullScreen(), context.aeroMenuHandlers.modal()
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
        -- Keep mask construction separate from idle reload work without dropping input.
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
        context.refreshOwner = nil
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

local function sessionResetReady(task)
    local context = task.host
    return context.sessionResetPending
        and not context.stage
        and not context.reloadState
        and not context.modelArmingReload
end

local function sessionResetStep(task)
    local context = task.host
    pumpSessionReset(context)
    return nil, context.sessionResetPending == true
end

--- Advance the staged loader, then keep geometry and panels synchronized.
--- At most one loading step runs per call, so the instruction budget is never
--- exceeded no matter how large the layout is.
---@param context AeroGridContext
local function advanceForeground(context)
    if suspendArmingEditor(context) then
        return
    end
    if context.modelSettingsUi then
        context.uiRequest = "model settings"
        return
    end
    if context.runtimeFailed then
        context.root:set({ w = context.zone.w, h = context.zone.h })
        context.page:set({ w = context.zone.w, h = context.zone.h })
        context.canvas:set({ w = context.zone.w, h = context.zone.h })
        context.reserved = reservedCorner(context.zone)
        if context.errorLabel then
            context.errorLabel:set({ y = errorTop(context), w = math.max(1, context.zone.w - 16) })
        end
        return
    end

    if context.locationDetails and (not isFullScreen() or context.reloadState) then
        context.locationRequest = { kind = "close", state = context.locationDetails }
        return
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
        return
    end

    -- Leaving fullscreen neither saves nor discards. Editor boxes built in
    -- fullscreen would swallow the long press in App mode, so the editor is
    -- torn down and a changed draft is set aside until fullscreen returns.
    -- A save already running finishes first, in `background`.
    if context.editorUi and not isFullScreen() and not context.editorUi.saving then
        context.editorTransitionRequest = "leave"
        return
    elseif
        context.editorStash
        and not context.editorUi
        and isFullScreen()
        and not context.stage
        and not context.reloadState
        and context.document
    then
        context.editorTransitionRequest = "open"
        return
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
        return
    end

    if context.reloadState == "rebuild" then
        context.lifecycleRequest = "rebuild"
        return
    end

    if context.stage then
        context.lifecycleRequest = "load"
        return
    end

    context.dashboardLifecycle.updateEmptyHint(context)

    if not isFullScreen() then
        context.editorPress = nil
    end

    if
        context.editorUi
        and (
            context.editorUi.buildStage
            or context.editorUi.saving
            or context.editorUi.drawerBuild ~= nil
            or context.editorUi.drawerPending
            or context.editorUi.nativeInput
            or context.editorUi.exitCommand
            or context.editorUi.previewPending
            or context.editorUi.previewRefresh
        )
    then
        context.uiRequest = "editor"
        return
    end

    if context.logViewer then
        if context.logViewer.prepareIndex or context.logViewer.closing or context.logViewer.inputs then
            context.uiRequest = "log viewer"
        end
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

--- Keep panels updated while the dashboard screen is not visible.
--- Services keep running here too, so flight timers do not develop
--- a hole whenever the pilot looks at another screen.
---@param context AeroGridContext
local function advanceHidden(context)
    if suspendArmingEditor(context) then
        return
    end
    if context.modelSettingsUi then
        context.uiRequest = "model settings"
        return
    end
    if context.editorUi and context.editorUi.saving then
        context.uiRequest = "editor"
        return
    end
    if context.reloadState == "clear" then
        context.lifecycleRequest = "retire"
        return
    elseif context.reloadState == "rebuild" then
        context.lifecycleRequest = "rebuild"
        return
    elseif context.stage then
        context.lifecycleRequest = "load"
        return
    elseif context.reflowIndex then
        return
    end
end

local function menuWorkNeeded(context, fullscreen)
    local editor, menu = context.editorUi, context.aerogridMenu
    if context.chromeRoot and context.menuVisibleFullscreen ~= fullscreen then
        return true
    end
    if context.runtimeFailed or context.stage or context.reloadState then
        return false
    end
    if editor and context.aeroMenuModal == true and fullscreen then
        return false
    end
    local modal = context.modelSettingsUi ~= nil
        or context.locationDetails ~= nil
        or context.logViewer ~= nil
        or editor ~= nil
    return context.theme
        and (
            not context.aeroMenuModule
            or fullscreen and not context.chromeRoot
            or context.chromeRoot and (context.aeroMenuParent ~= context.root or context.aeroMenuHeight ~= buttonHeight() or context.aeroMenuWidth ~= context.zone.w or context.aeroMenuZoneHeight ~= context.zone.h or context.aeroMenuFullscreen ~= fullscreen or context.aeroMenuModal ~= modal)
            or menu
                and (menu.pending or menu.action or menu.dismiss or menu.selectionDirty or context.flightFactory and context.flightFactory.broker and menu.modelFilename ~= context.flightFactory.broker.filename)
        )
end

local function menuReady(task, _, hidden)
    local context = task.host
    return not hidden
        and not context.modelArmingReload
        and not context.sessionResetPending
        and menuWorkNeeded(context, isFullScreen())
end

local function menuStep(task)
    prepareAeroMenu(task.host)
    task.host.menuVisibleFullscreen = isFullScreen()
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

local function inputReady(task, _, hidden)
    local context = task.host
    return not hidden
        and isFullScreen()
        and not context.modelArmingReload
        and not (context.sessionResetPending and not (context.stage or context.reloadState))
        and (context.modelSettingsUi or not context.stage and not context.reloadState)
        and not editorWorkNeeded(context.editorUi)
        and (context.inputPending or context.editorPress and getTime() - context.editorPress.started >= 60)
        and not menuWorkNeeded(context, true)
end

local function inputStep(task)
    local context = task.host
    local widgetEvent, touchState = context.widgetEvent, context.touchState
    context.inputHandled = context.inputPending
    if context.modelSettingsUi then
        context.modelSettingsUiModule.handle(context, widgetEvent, touchState)
        context.uiRequest = "model settings"
        return
    end
    if context.aeroMenuModule and context.aeroMenuModule.handle(context, widgetEvent, touchState) then
        context.editorPress = nil
        return
    end
    -- Hold timing uses arrival time, not the deferred grant's time.
    if not context.editorUi and not context.locationDetails and not context.logViewer then
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
        return context.modelArmingReload and not (state and state.saving)
    end
    if
        hidden
        or context.modelArmingReload
        or context.sessionResetPending and not (context.stage or context.reloadState)
        or context.modelSettingsUi
    then
        return false
    end
    if request == "leave" then
        return state ~= nil and not state.saving and not isFullScreen()
    end
    return request == "open"
        and not state
        and not context.stage
        and not context.reloadState
        and not context.logViewer
        and not context.locationDetails
        and context.document ~= nil
        and isFullScreen()
end

local function editorTransitionStep(task)
    local context = task.host
    local request, state = context.editorTransitionRequest, context.editorUi
    context.editorTransitionRequest = nil
    if request == "open" then
        context.editorController.openEditor(context)
    else
        if state then
            local session = context.editorSession
            local keep = request == "suspend" or session and session.dirty and not state.buildStage
            context.editorUiModule.close(context, false)
            context.editorController.restorePreview(context)
            context.editorSession = nil
            context.editorPreviewContainers = nil
            context.editorStash = keep and session or nil
        end
        if request == "suspend" then
            context.modelArmingReload = nil
        end
    end
end

local function uiField(kind)
    if kind == "model settings" then
        return "modelSettingsUi"
    elseif kind == "editor" then
        return "editorUi"
    end
    return "logViewer"
end

local function uiReady(task, _, hidden)
    local context = task.host
    if task.kind == "editor" then
        local state = context.editorUi
        if not state or state ~= task.ui or not editorWorkNeeded(state) then
            return false
        end
        if context.modelArmingReload then
            return state.saving ~= nil
        end
        return not (context.sessionResetPending and not (context.stage or context.reloadState))
            and not context.modelSettingsUi
            and (hidden and state.saving ~= nil or not hidden and (isFullScreen() or state.saving ~= nil))
            and (hidden or not menuWorkNeeded(context, isFullScreen()))
    end
    if
        context.modelArmingReload
        or context.sessionResetPending and not (context.stage or context.reloadState)
        or not hidden and menuWorkNeeded(context, isFullScreen())
    then
        return false
    end
    if task.kind == "model settings" then
        return task.ui ~= nil and context.modelSettingsUi == task.ui
    end
    local viewer = context.logViewer
    return not hidden
        and (not context.inputPending or viewer and viewer.closing)
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
                and (viewer.prepareIndex ~= nil or viewer.inputs ~= nil)
        )
end

local function uiStep(task, _, _, hidden)
    local context = task.host
    context.uiRequest = nil
    if task.kind == "editor" then
        context.editorController.advanceEditor(context)
        if editorWorkNeeded(context.editorUi) then
            context.uiRequest = task.kind
        end
    elseif task.kind == "model settings" then
        context.modelSettingsUiModule.advance(context)
        local state = context.modelSettingsUi
        if state and (state.build or state.pending or state.closing) then
            context.uiRequest = task.kind
        end
    else
        local state = context.logViewer
        if state.closing or state.inputs then
            context.logViewerModule.advanceInput(context)
            state = context.logViewer
            if state and (state.inputs or state.prepareIndex) then
                context.uiRequest = task.kind
            end
            return
        end
        context.logViewerModule.advance(context)
        if context.logViewer and context.logViewer.prepareIndex then
            context.uiRequest = task.kind
            return nil, true
        end
    end
end

local function lifecycleReady(task, _, hidden)
    local context, kind = task.host, task.kind
    if
        context.modelArmingReload
        or context.sessionResetPending and not (context.stage or context.reloadState)
        or context.modelSettingsUi
        or context.editorUi and (hidden and context.editorUi.saving or not hidden)
        or not hidden
            and not (context.stage or context.reloadState)
            and (context.inputPending or context.editorPress and getTime() - context.editorPress.started >= 60)
    then
        return false
    end
    if not hidden then
        local fullscreen, menu = isFullScreen(), context.aerogridMenu
        if
            menu and (menu.pending or menu.action or menu.dismiss or menu.selectionDirty)
            or context.locationDetails and (not fullscreen or context.reloadState)
            or context.logViewer and (not fullscreen or context.reloadState or context.logViewer.width ~= context.zone.w - 16 or context.logViewer.height ~= context.zone.h)
            or context.editorStash and fullscreen and context.document and not (context.stage or context.reloadState)
            or not fullscreen
                and not context.reloadState
                and (context.pageBuiltFullscreen or context.rootBuiltFullscreen or context.nativeDialogsCreated)
        then
            return false
        end
    end
    if kind == "retire" then
        return context.reloadState == "clear"
    elseif kind == "rebuild" then
        return context.reloadState == "rebuild"
    elseif kind == "load" then
        return not context.reloadState and context.stage ~= nil
    elseif kind == "reflow" then
        return not hidden and not context.reloadState and not context.stage and not context.logViewer
    end
    return not hidden and not context.reloadState and not context.stage and context.appRebuild ~= nil
end

local function lifecycleStep(task)
    local context, kind = task.host, task.kind
    context.lifecycleRequest = nil
    if kind == "retire" then
        context.dashboardLifecycle.retirePage(context)
        context.lifecycleRequest = "rebuild"
    elseif kind == "rebuild" then
        context.dashboardLifecycle.rebuildPage(context)
        context.dashboardLoader.beginLoad(context)
        context.lifecycleRequest = "load"
    elseif kind == "load" then
        context.dashboardLoader.advanceLoad(context)
        if context.stage then
            context.lifecycleRequest = "load"
            return nil, true
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

--- Until individual host operations are split, reserve the whole callback for
--- their existing staged flow. Idle callbacks only inspect state here.
local function hostWorkNeeded(context, hidden, widgetEvent, fullscreen)
    if
        context.optionsRequest
        or context.modelSettingsRequest
        or context.logOpenRequest
        or context.locationRequest
        or context.lifecycleRequest
        or context.uiRequest
        or context.editorTransitionRequest
        or context.modelArmingReload
        or context.sessionResetPending and not (context.stage or context.reloadState)
        or context.reloadState
        or context.stage
    then
        return true
    end
    local editor = context.editorUi
    if hidden then
        return context.modelSettingsUi ~= nil or editor and editor.saving ~= nil
    end
    if
        widgetEvent and widgetEvent ~= 0
        or context.editorPress
        or context.runtimeFailed
        or context.reflowIndex
        or context.appRebuild
        or context.width ~= context.zone.w
        or context.height ~= context.zone.h
        or context.left ~= (context.zone.xabs or 0)
        or context.top ~= (context.zone.yabs or 0)
        or context.fullScreen ~= fullscreen
    then
        return true
    end
    if
        context.locationDetails and not fullscreen
        or context.logViewer and (not fullscreen or context.logViewer.prepareIndex or context.logViewer.closing or context.logViewer.inputs or context.logViewer.width ~= context.zone.w - 16 or context.logViewer.height ~= context.zone.h)
        or editor and (not fullscreen or editor.buildStage or editor.saving or editor.drawerBuild ~= nil or editor.drawerPending or editor.nativeInput or editor.exitCommand or editor.previewPending or editor.previewRefresh)
        or context.editorStash and not editor and fullscreen and context.document
        or not fullscreen
            and (context.pageBuiltFullscreen or context.rootBuiltFullscreen or context.nativeDialogsCreated)
    then
        return true
    end
    if context.modelSettingsUi then
        local settings = context.modelSettingsUi
        if
            settings.build
            or settings.pending
            or settings.closing
            or context.flightFactory and context.flightFactory.broker and context.flightFactory.broker.filename ~= settings.modelFilename
            or not fullscreen
        then
            return true
        end
    end
    if menuWorkNeeded(context, fullscreen) then
        return true
    end
    local hint = context.emptyHint
    local show = context.document and #context.document.panels == 0 and not editor and #context.errors == 0
    if
        show
            and (not hint or not hint.visible or hint.w ~= context.zone.w or hint.h ~= context.zone.h or hint.fullscreen ~= fullscreen)
        or not show and hint and hint.visible
    then
        return true
    end
    if not fullscreen and not editor then
        for _, entry in ipairs(context.panels) do
            if entry.builtFullscreen then
                return true
            end
        end
    end
    return false
end

local function advanceHost(task, _, _, hidden)
    local context = task.host
    -- Mutations may replace or retire enrolled owners; dashboard work resumes
    -- with freshly enrolled tasks on the next callback.
    context.scheduledServices, context.scheduledPanels = false, false
    if hidden then
        advanceHidden(context)
    else
        advanceForeground(context)
    end
    context.scheduledServices, context.scheduledPanels = false, false
end

local function runCallback(context, hidden, widgetEvent, touchState)
    if context.initializing then
        if not hidden then
            event(context, widgetEvent, touchState)
        end
        local scheduler = context.scheduler
        scheduler.add(context.initializationTask)
        context.remainingSlots = scheduler.capacity - scheduler.run(getTime(), scheduler.capacity, hidden)
        scheduler.clear()
        if context.schedulerFailed then
            if not context.root then
                context.root = lvgl.box({ x = 0, y = 0, w = context.zone.w, h = context.zone.h })
            end
            if not context.page then
                context.page = lvgl.box(context.root, { x = 0, y = 0, w = context.zone.w, h = context.zone.h })
            end
            if not context.canvas then
                context.canvas = lvgl.rectangle(context.page, {
                    x = 0,
                    y = 0,
                    w = context.zone.w,
                    h = context.zone.h,
                    color = lcd.RGB(0x101316),
                    filled = true,
                })
            end
            showErrors(context)
        end
        return
    end
    if not context.scheduler or context.runtimeFailed then
        if not hidden then
            advanceForeground(context)
        end
        return
    end
    local scheduler = context.scheduler
    local fullscreen = not hidden and isFullScreen()
    context.inputHandled = nil
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
    context.flightPolled = nil
    local hostNeeded = hostWorkNeeded(context, hidden, context.widgetEvent, fullscreen)
    context.scheduledServices = not hostNeeded and not (hidden and context.reflowIndex)
    context.scheduledPanels = not hostNeeded
        and not (hidden and context.reflowIndex)
        and not (not hidden and (context.modelSettingsUi or context.logViewer))
    local flightTask
    local owner = context.flightFactory and context.flightFactory.broker
    if owner then
        flightTask = context.flightTask
        if not flightTask or flightTask.broker ~= owner then
            flightTask = {
                name = "flight",
                owner = "flight",
                flightWork = true,
                broker = owner,
                host = context,
                step = pumpFlight,
            }
            context.flightTask = flightTask
        end
        flightTask.cost = owner.documentLoaded and 1 or scheduler.capacity
    end
    local hostTask
    if hostNeeded then
        if context.optionsRequest then
            hostTask = context.optionsTask
            if not hostTask then
                hostTask = {
                    name = "native options",
                    owner = "native options",
                    host = context,
                    hostWork = true,
                    step = optionsStep,
                }
                context.optionsTask = hostTask
            end
        elseif
            context.sessionResetPending
            and not context.stage
            and not context.reloadState
            and not context.modelArmingReload
        then
            hostTask = context.sessionResetTask
            if not hostTask then
                hostTask = {
                    name = "session reset",
                    owner = "session reset",
                    host = context,
                    hostWork = true,
                    step = sessionResetStep,
                    ready = sessionResetReady,
                }
                context.sessionResetTask = hostTask
            end
        else
            if not hidden and not context.modelArmingReload and menuWorkNeeded(context, fullscreen) then
                hostTask = context.menuTask
                if not hostTask then
                    hostTask = {
                        name = "menu",
                        owner = "menu",
                        host = context,
                        hostWork = true,
                        step = menuStep,
                        ready = menuReady,
                    }
                    context.menuTask = hostTask
                end
            end
            if not hostTask and (context.inputPending or context.editorPress) then
                local task = context.inputTask
                if not task then
                    task = {
                        name = "input",
                        owner = "input",
                        host = context,
                        hostWork = true,
                        step = inputStep,
                        ready = inputReady,
                    }
                    context.inputTask = task
                end
                if inputReady(task, nil, hidden) then
                    hostTask = task
                end
            end
            if not hostTask and context.modelSettingsRequest then
                local task = context.modelSettingsOpenTask
                if not task then
                    task = {
                        name = "model settings open",
                        owner = "model settings open",
                        host = context,
                        hostWork = true,
                        step = modelSettingsOpenStep,
                        ready = modelSettingsOpenReady,
                    }
                    context.modelSettingsOpenTask = task
                end
                if modelSettingsOpenReady(task, nil, hidden) then
                    hostTask = task
                elseif not hidden and (not fullscreen or context.modelSettingsUi) then
                    context.modelSettingsRequest = nil
                elseif context.editorUi and context.editorUi.saving then
                    context.uiRequest = "editor"
                end
            end
            if not hostTask and context.editorTransitionRequest then
                local task = context.editorTransitionTask
                if not task then
                    task = {
                        name = "editor transition",
                        owner = "editor transition",
                        host = context,
                        hostWork = true,
                        step = editorTransitionStep,
                        ready = editorTransitionReady,
                    }
                    context.editorTransitionTask = task
                end
                if editorTransitionReady(task, nil, hidden) then
                    hostTask = task
                elseif not hidden then
                    context.editorTransitionRequest = nil
                end
            end
            if not hostTask and context.logOpenRequest then
                local request = context.logOpenRequest
                local info = model and model.getInfo and model.getInfo()
                if
                    request.page ~= context.page
                    or request.modelFilename ~= (info and info.filename)
                    or context.reloadState
                    or context.stage
                    or context.modelSettingsUi
                    or context.editorUi
                    or not hidden and not fullscreen
                then
                    context.logOpenRequest = nil
                elseif not hidden then
                    hostTask = context.logOpenTask
                    if not hostTask then
                        hostTask = {
                            name = "log open",
                            owner = "log open",
                            host = context,
                            hostWork = true,
                            step = logOpenStep,
                        }
                        context.logOpenTask = hostTask
                    end
                end
            end
            if not hostTask and context.locationRequest then
                local request = context.locationRequest
                local info = model and model.getInfo and model.getInfo()
                local stale = request.kind == "close" and context.locationDetails ~= request.state
                    or request.kind == "open"
                        and (request.page ~= context.page or request.modelFilename ~= (info and info.filename) or context.reloadState or context.stage or context.modelSettingsUi or context.editorUi or context.logViewer or not hidden and not fullscreen)
                if stale then
                    context.locationRequest = nil
                elseif not hidden then
                    hostTask = context.locationTask
                    if not hostTask then
                        hostTask = {
                            name = "location details",
                            owner = "location details",
                            host = context,
                            hostWork = true,
                            step = locationStep,
                        }
                        context.locationTask = hostTask
                    end
                end
            end
            local kind = context.lifecycleRequest
            if not hostTask and kind then
                local tasks = context.lifecycleTasks
                if not tasks then
                    tasks = {}
                    context.lifecycleTasks = tasks
                end
                local task = tasks[kind]
                if not task then
                    task = {
                        name = kind,
                        owner = kind,
                        kind = kind,
                        host = context,
                        hostWork = true,
                        step = lifecycleStep,
                        ready = lifecycleReady,
                    }
                    tasks[kind] = task
                end
                if lifecycleReady(task, nil, hidden) then
                    hostTask = task
                else
                    context.lifecycleRequest = nil
                end
            end
            if not hostTask and context.uiRequest then
                local kind = context.uiRequest
                local tasks = context.uiTasks
                if not tasks then
                    tasks = {}
                    context.uiTasks = tasks
                end
                local ui = context[uiField(kind)]
                local task = tasks[kind]
                if ui and (not task or task.ui ~= ui) then
                    task = {
                        name = kind,
                        owner = kind,
                        kind = kind,
                        ui = ui,
                        host = context,
                        hostWork = true,
                        step = uiStep,
                        ready = uiReady,
                    }
                    tasks[kind] = task
                elseif task and task.ui ~= ui then
                    task.ui = nil
                end
                if ui and uiReady(task, nil, hidden) then
                    hostTask = task
                else
                    context.uiRequest = nil
                end
            end
            hostTask = hostTask or context.hostTask
            if not hostTask then
                hostTask = {
                    name = "host",
                    owner = "host",
                    host = context,
                    hostWork = true,
                    step = advanceHost,
                }
                context.hostTask = hostTask
            end
        end
        hostTask.cost = scheduler.capacity
    end
    runTasks(context, hidden, flightTask, hostTask)
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
