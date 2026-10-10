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
---@field stage? "theme-read"|"theme-validate"|"read"|"tokenize"|"header"|"services"|"panels" Staged loader position.
---@field servicesModule? table Loaded lib/services.lua registry module.
---@field packageInfo? table Package identity and compatibility versions.
---@field serviceRuntime? table Registry holding every constructed service.
---@field serviceIndex? integer Next service definition to construct.
---@field source? string Layout text held between the read and tokenize steps.
---@field tokens? table Tokens held between the tokenize and parse steps.
---@field pending? table[] Validated placements still awaiting construction.
---@field pendingIndex? integer Next placement to build.
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

--- Load and execute a Lua module while containing compile/runtime failures.
---@param base string
---@param relative string
---@param runtimeApi? integer Required internal module API.
---@param ... table Composition dependencies passed to the module chunk.
---@return table? module
---@return string? error
local function loadModule(base, relative, runtimeApi, ...)
    local chunk, loadError = loadScript(joinPath(base, relative))
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

--- Create one AeroGrid host instance for an EdgeTX custom-screen zone.
---@param zone AeroGridZone
---@param widgetOptions AeroGridWidgetOptions
---@param path string Absolute widget directory supplied by EdgeTX.
---@return AeroGridContext
local function create(zone, widgetOptions, path)
    local context = {
        zone = zone,
        path = path,
        layoutName = layoutName(widgetOptions.Layout),
        themeMode = themeModeOf(widgetOptions.Theme),
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
        local function runtimeModule(relative, ...)
            local module, err = loadModule(path, relative, package.runtimeApi, ...)
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
        or not context.panelHost
        or not context.themeBuilder
        or not context.primitives
        or not context.dashboardLoader
        or not context.dashboardLifecycle
        or not context.editorController
    then
        -- Nothing can be loaded without the runtime, and an option change must not
        -- be able to restage a load that would then index a missing module.
        context.runtimeFailed = true
        addError(context, "AeroGrid runtime module failed to load")
        showErrors(context)
    else
        context.dashboardLoader.beginLoad(context)
    end

    return context
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
        context.editorStash = nil
        if context.editorUi then
            context.editorUiModule.close(context, true)
            context.editorController.restorePreview(context)
            context.editorSession = nil
        end
        context.layoutName = name
        context.themeMode = themeMode
        context.reloadState = "clear"
    end
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
local function event(context, widgetEvent, touchState)
    if context.runtimeFailed then
        return false
    end
    if context.editorUi then
        return context.editorUiModule.handle(context, widgetEvent, touchState)
    end
    if context.editorController.editorEntryHit(context, widgetEvent, touchState) then
        context.editorController.openEditor(context)
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

    -- Leaving fullscreen neither saves nor discards. Editor boxes built in
    -- fullscreen would swallow the long press in App mode, so the editor is
    -- torn down and a changed draft is set aside until fullscreen returns.
    -- A save already running finishes first, in `background`.
    if context.editorUi and not isFullScreen() and not context.editorUi.saving then
        local session = context.editorSession
        local keep = session and session.dirty and not context.editorUi.buildStage
        context.editorUiModule.close(context, false)
        context.editorController.restorePreview(context)
        context.editorSession = nil
        context.editorPreviewContainers = nil
        context.editorStash = keep and session or nil
    elseif
        context.editorStash
        and not context.editorUi
        and isFullScreen()
        and not context.stage
        and not context.reloadState
        and context.document
    then
        context.editorController.openEditor(context)
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
        context.dashboardLifecycle.retirePage(context)
        return
    end

    if context.reloadState == "rebuild" then
        context.dashboardLifecycle.rebuildPage(context)
        context.dashboardLoader.beginLoad(context)
        return
    end

    if context.stage then
        context.dashboardLoader.advanceLoad(context)
        return
    end

    context.dashboardLifecycle.updateEmptyHint(context)

    -- EdgeTX reports FIRST/BREAK but does not forward LVGL's long-press event.
    if not context.editorUi and isFullScreen() then
        if
            widgetEvent == _G.EVT_TOUCH_FIRST
            and context.editorController.editorEntryHit(context, widgetEvent, touchState, true)
        then
            context.editorPress = { started = getTime() }
        elseif
            widgetEvent ~= nil
            and (
                widgetEvent == _G.EVT_TOUCH_BREAK
                or widgetEvent == _G.EVT_TOUCH_SLIDE
                or widgetEvent == _G.EVT_TOUCH_TAP
            )
        then
            context.editorPress = nil
        end
        if context.editorPress and getTime() - context.editorPress.started >= 60 then
            context.editorPress = nil
            context.editorController.openEditor(context)
            return
        end
    elseif not isFullScreen() then
        context.editorPress = nil
    end

    if
        context.editorUi
        and (
            context.editorUi.buildStage
            or context.editorUi.saving
            or context.editorUi.drawerBuild ~= nil
            or context.editorUi.drawerPending
            or context.editorUi.exitCommand
            or context.editorUi.previewPending
            or context.editorUi.previewRefresh
        )
    then
        context.editorController.advanceEditor(context)
        return
    end

    -- EdgeTX delivers fullscreen input through refresh, not an event callback.
    if widgetEvent ~= nil and widgetEvent ~= 0 and isFullScreen() then
        if widgetEvent == _G.EVT_TOUCH_FIRST then
            context.touchTapHandled = false
        end
        -- LVGL bubbling can enqueue multiple taps for the same physical press.
        if widgetEvent ~= _G.EVT_TOUCH_TAP or not context.touchTapHandled then
            if widgetEvent == _G.EVT_TOUCH_TAP then
                context.touchTapHandled = true
            end
            event(context, widgetEvent, touchState)
        end
        if context.reloadState then
            return
        end
        -- Input rendering gets its own callback budget, separate from live panels.
        if context.editorUi then
            return
        end
    end

    if context.editorUi then
        updateServices(context)
        dispatchDue(context)
        return
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
        context.dashboardLifecycle.beginReflow(context)
    end
    if context.reflowIndex then
        context.dashboardLifecycle.advanceReflow(context)
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
        context.dashboardLifecycle.advanceAppRebuild(context)
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
    if context.editorUi and context.editorUi.saving then
        context.editorController.advanceEditor(context)
        return
    end
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
