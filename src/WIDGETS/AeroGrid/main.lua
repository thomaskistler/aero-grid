-- SPDX-License-Identifier: GPL-2.0-only
---@type WidgetScript
---@simulate Layout1x1AM zone=0

--- AeroGrid's EdgeTX widget entry point and component host.

---@class AeroGridZone
---@field x integer
---@field y integer
---@field w integer
---@field h integer

---@class AeroGridWidgetOptions
---@field DashID string
---@field Theme string

---@class AeroGridContext
---@field zone AeroGridZone Live zone table maintained by EdgeTX.
---@field path string Absolute widget directory path.
---@field dashboardId string Layout identity selected in native widget settings.
---@field components AeroGridComponentEntry[]
---@field errors string[]
---@field width integer Last rendered zone width.
---@field height integer Last rendered zone height.
---@field root any Root LVGL container.
---@field grid table
---@field yaml table
---@field layoutValidator table
---@field layoutStore table
---@field componentHost table
---@field themeBuilder table
---@field primitives table
---@field theme AeroGridTheme Active resolved theme passed to every component.
---@field themeMode string Mode selected in native widget settings.
---@field services table Shared objects handed to components.
---@field layoutPath? string
---@field errorLabel? any
---@field reloadState? "clear"
---@field stage? "read"|"tokenize"|"parse"|"components" Staged loader position.
---@field source? string Layout text held between the read and tokenize steps.
---@field tokens? table Tokens held between the tokenize and parse steps.
---@field pending? table[] Validated placements still awaiting construction.
---@field pendingIndex? integer Next placement to build.

local options = {
  {"DashID", STRING, "main"},
  {"Theme", STRING, "modern"},
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
---@return table? module
---@return string? error
local function loadModule(base, relative)
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

  return module
end

--- Append a user-visible runtime error.
---@param context AeroGridContext
---@param message any
local function addError(context, message)
  context.errors[#context.errors + 1] = tostring(message)
end

--- Render accumulated runtime errors over the dashboard.
--- Reuses the existing label so failures raised after creation stay visible.
---@param context AeroGridContext
local function showErrors(context)
  if #context.errors == 0 then return end

  local text = table.concat(context.errors, "\n")
  if context.errorLabel then
    context.errorLabel:set({text = text})
    return
  end

  -- Errors can precede theme resolution, so fall back to the Modern critical red.
  local color = context.theme and context.theme.color.critical or lcd.RGB(0xF05252)

  context.errorLabel = lvgl.label(context.root, {
      x = 8,
      y = 8,
      w = math.max(1, context.zone.w - 16),
      h = 0,
      text = text,
      color = color,
      font = function() return SMLSIZE end,
  })
end

--- Dispatch one lifecycle callback to every live component in isolation.
--- A component that raises is disabled and reported without affecting the others.
---@param context AeroGridContext
---@param event string
---@param ... any
local function dispatchAll(context, event, ...)
  local failures = false

  for _, entry in ipairs(context.components) do
    if not entry.failed then
      local ok, dispatchError = context.componentHost.dispatch(entry, event, ...)
      if not ok and dispatchError then
        addError(context, entry.placement.id .. ": " .. event .. ": " .. dispatchError)
        failures = true
      end
    end
  end

  if failures then showErrors(context) end
end

--- Assemble the shared objects handed to one component.
--- Typography depends on the component's span, so services are built per
--- placement rather than shared across the dashboard.
---@param context AeroGridContext
---@param placement table
---@return table services
local function buildServices(context, placement)
  local builder = context.themeBuilder
  local theme = context.theme

  return {
    theme = theme,
    primitives = context.primitives,
    themeBuilder = builder,
    fonts = builder.typography(placement.colSpan, placement.rowSpan),
    span = {colSpan = placement.colSpan, rowSpan = placement.rowSpan},
    state = function(name, accentName)
      return builder.state(theme, name, accentName)
    end,
  }
end

--- Load, validate, and instantiate every component in the selected layout.
---@param context AeroGridContext
--- Instantiate one validated placement.
---@param context AeroGridContext
---@param placement table
local function buildComponent(context, placement)
  local host = context.componentHost
  local component, componentError = loadModule(
    context.path, "components/" .. placement.type .. ".lua")
  local contractValid, contractError

  if component then
    contractValid, contractError = host.validateModule(component, placement.type)
  end

  if not component then
    addError(context, placement.id .. ": " .. tostring(componentError))
    return
  end
  if not contractValid then
    addError(context, placement.id .. ": " .. tostring(contractError))
    return
  end
  if not host.supportsSpan(component, placement.colSpan, placement.rowSpan) then
    addError(context, placement.id .. ": component does not support span "
      .. host.spanName(placement.colSpan, placement.rowSpan))
    return
  end

  local rect, rectError = context.grid.rect(context.zone, placement, 4, 4, 4)
  if not rect then
    addError(context, placement.id .. ": " .. tostring(rectError))
    return
  end

  local settings, warnings = host.resolveSettings(component, placement.config)
  for _, warning in ipairs(warnings) do
    addError(context, placement.id .. ": " .. warning)
  end

  -- Each component draws inside its own container, so it cannot reach the
  -- dashboard root or paint over a neighbour. The container is deliberately
  -- unpainted; the component's own panel fills it.
  local container = lvgl.box(context.root, {
    x = rect.x,
    y = rect.y,
    w = rect.w,
    h = rect.h,
  })

  local services = buildServices(context, placement)
  local ok, instance = pcall(component.create, container,
    {x = 0, y = 0, w = rect.w, h = rect.h}, settings, services)

  if ok then
    context.components[#context.components + 1] = {
      placement = placement,
      module = component,
      instance = instance,
      settings = settings,
      container = container,
    }
  else
    -- Discard whatever the failed component managed to build.
    container:clear()
    addError(context, placement.id .. ": " .. tostring(instance))
  end
end

--- Advance the staged loader by exactly one step.
--- EdgeTX allows roughly 20000 VM instructions per widget callback, and a
--- whole dashboard costs far more than that, so loading is spread over
--- consecutive calls: read, tokenize, build and validate, then one component
--- per call. Each step stays well inside the budget regardless of layout size.
---@param context AeroGridContext
---@return boolean busy True while more work remains.
local function advanceLoad(context)
  local stage = context.stage

  if stage == "read" then
    local modelInfo = model.getInfo()
    local content, readError, filename = context.layoutStore.read(
      context.path, modelInfo and modelInfo.filename or "default",
      context.dashboardId)

    context.layoutPath = filename
    if not content then
      addError(context, readError)
      context.stage = nil
      showErrors(context)
      return false
    end

    context.source = content
    context.stage = "tokenize"
    return true
  end

  if stage == "tokenize" then
    local tokens, tokenError = context.yaml.tokenize(context.source)
    context.source = nil
    if not tokens then
      addError(context, tokenError)
      context.stage = nil
      showErrors(context)
      return false
    end

    context.tokens = tokens
    context.stage = "parse"
    return true
  end

  if stage == "parse" then
    local document, parseError = context.yaml.build(context.tokens)
    context.tokens = nil
    if not document then
      addError(context, parseError)
      context.stage = nil
      showErrors(context)
      return false
    end

    local validated, layoutErrors = context.layoutValidator.validate(
      document, context.grid)
    for _, layoutError in ipairs(layoutErrors or {}) do addError(context, layoutError) end
    if not validated then
      context.stage = nil
      showErrors(context)
      return false
    end

    -- A layout may pin its own theme; otherwise the native option decides.
    local themeConfig = validated.theme or {}
    context.theme = context.themeBuilder.build(
      themeConfig.mode or context.themeMode, themeConfig.overrides)
    for _, warning in ipairs(context.theme.warnings) do
      addError(context, "theme: " .. warning)
    end
    context.canvas:set({color = context.theme.color.canvas})

    context.pending = validated.components
    context.pendingIndex = 1
    context.stage = "components"
    return true
  end

  if stage == "components" then
    local placement = context.pending[context.pendingIndex]
    if not placement then
      context.pending = nil
      context.stage = nil
      showErrors(context)
      return false
    end

    context.pendingIndex = context.pendingIndex + 1
    buildComponent(context, placement)
    return true
  end

  return false
end

--- Begin a staged load, discarding anything already on screen.
---@param context AeroGridContext
local function beginLoad(context)
  context.components = {}
  context.errors = {}
  context.errorLabel = nil
  context.pending = nil
  context.tokens = nil
  context.source = nil
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
    components = {},
    errors = {},
    width = zone.w,
    height = zone.h,
  }

  context.grid = select(1, loadModule(path, "lib/grid.lua"))
  context.yaml = select(1, loadModule(path, "lib/yaml.lua"))
  context.layoutValidator = select(1, loadModule(path, "lib/layout.lua"))
  context.layoutStore = select(1, loadModule(path, "lib/layout_store.lua"))
  context.componentHost = select(1, loadModule(path, "lib/component_host.lua"))
  context.themeBuilder = select(1, loadModule(path, "lib/theme.lua"))
  context.primitives = select(1, loadModule(path, "lib/primitives.lua"))

  context.root = lvgl.box({
    x = 0,
    y = 0,
    w = zone.w,
    h = zone.h,
  })

  -- The canvas must be a filled rectangle. A box ignores `color`, leaving the
  -- radio's own screen background, including its logo, visible behind us.
  context.canvas = lvgl.rectangle(context.root, {
    x = 0,
    y = 0,
    w = zone.w,
    h = zone.h,
    color = lcd.RGB(0x101316),
    filled = true,
  })

  if not context.grid or not context.yaml or not context.layoutValidator
      or not context.layoutStore or not context.componentHost
      or not context.themeBuilder or not context.primitives then
    addError(context, "AeroGrid runtime module failed to load")
    showErrors(context)
  else
    -- Loading is deliberately deferred to refresh(). Doing it here would
    -- exceed EdgeTX's per-callback instruction budget on a full dashboard.
    beginLoad(context)
  end

  return context
end

--- Recalculate component rectangles after EdgeTX changes the host zone.
---@param context AeroGridContext
local function reflow(context)
  context.root:set({w = context.zone.w, h = context.zone.h})
  context.canvas:set({w = context.zone.w, h = context.zone.h})

  for _, entry in ipairs(context.components) do
    if not entry.failed then
      local rect = context.grid.rect(context.zone, entry.placement, 4, 4, 4)
      if rect then
        entry.container:set({x = rect.x, y = rect.y, w = rect.w, h = rect.h})
        local ok, dispatchError = context.componentHost.dispatch(
          entry, "update", {x = 0, y = 0, w = rect.w, h = rect.h}, entry.settings)
        if not ok and dispatchError then
          addError(context, entry.placement.id .. ": update: " .. dispatchError)
        end
      end
    end
  end

  if context.errorLabel then
    context.errorLabel:set({w = math.max(1, context.zone.w - 16)})
  end
  showErrors(context)

  context.width = context.zone.w
  context.height = context.zone.h
end

--- Apply native host options; changing Dashboard ID or Theme rebuilds safely.
---@param context AeroGridContext
---@param widgetOptions AeroGridWidgetOptions
local function update(context, widgetOptions)
  local dashboardId = widgetOptions.DashID
  local themeMode = widgetOptions.Theme

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
  if name == "DashID" then return "Dashboard ID" end
  if name == "Theme" then return "Theme" end
  return name
end

--- Offer an input event to components until one consumes it.
---@param context AeroGridContext
---@param widgetEvent any
---@return boolean consumed
local function event(context, widgetEvent)
  for _, entry in ipairs(context.components) do
    if not entry.failed then
      local ok, dispatchError, consumed = context.componentHost.dispatch(
        entry, "event", widgetEvent)
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

--- Advance the staged loader, then keep geometry and components synchronized.
--- At most one loading step runs per call, so the instruction budget is never
--- exceeded no matter how large the layout is.
---@param context AeroGridContext
local function refresh(context)
  if context.reloadState == "clear" then
    dispatchAll(context, "destroy")
    context.root:clear()
    -- Clearing the root also destroys the canvas, which must be recreated
    -- first so it sits behind every component container.
    context.canvas = lvgl.rectangle(context.root, {
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

  if context.width ~= context.zone.w or context.height ~= context.zone.h then
    reflow(context)
  end

  dispatchAll(context, "refresh")
end

--- Keep components updated while the dashboard screen is not visible.
---@param context AeroGridContext
local function background(context)
  if context.stage or context.reloadState then return end
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