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

---@class AeroGridComponentEntry
---@field placement table Validated YAML component placement.
---@field module table Loaded component module.
---@field instance table Component-owned runtime context.

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
---@field layoutPath? string
---@field errorLabel? any
---@field reloadState? "clear"|"build"

local options = {
  {"DashID", STRING, "main"},
}

local COMPONENT_API_VERSION = 1

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
---@param context AeroGridContext
local function showErrors(context)
  if #context.errors == 0 then return end

  context.errorLabel = lvgl.label(context.root, {
      x = 8,
      y = 8,
      w = math.max(1, context.zone.w - 16),
      h = 0,
      text = table.concat(context.errors, "\n"),
      color = lcd.RGB(240, 82, 82),
      font = function() return SMLSIZE end,
  })
end

--- Load, validate, and instantiate every component in the selected layout.
---@param context AeroGridContext
local function loadComponents(context)
  local modelInfo = model.getInfo()
  local document, layoutErrors, filename = context.layoutStore.load(
    context.path,
    modelInfo and modelInfo.filename or "default",
    context.dashboardId,
    context.yaml,
    context.layoutValidator,
    context.grid)

  context.layoutPath = filename
  for _, layoutError in ipairs(layoutErrors or {}) do addError(context, layoutError) end
  if not document then
    showErrors(context)
    return
  end

  for _, placement in ipairs(document.components) do
    local component, componentError = loadModule(
      context.path, "components/" .. placement.type .. ".lua")
    if not component then
      addError(context, placement.id .. ": " .. tostring(componentError))
    elseif component.apiVersion ~= COMPONENT_API_VERSION then
      addError(context, placement.id .. ": incompatible component API")
    elseif type(component.create) ~= "function" then
      addError(context, placement.id .. ": component has no create function")
    else
      local rect, rectError = context.grid.rect(context.zone, placement, 4, 4, 4)
      if not rect then
        addError(context, placement.id .. ": " .. tostring(rectError))
      else
        local ok, instance = pcall(
          component.create, context.root, rect, placement.config)
        if ok then
          context.components[#context.components + 1] = {
            placement = placement,
            module = component,
            instance = instance,
          }
        else
          addError(context, placement.id .. ": " .. tostring(instance))
        end
      end
    end
  end

  showErrors(context)
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
    components = {},
    errors = {},
    width = zone.w,
    height = zone.h,
  }

  context.grid = select(1, loadModule(path, "lib/grid.lua"))
  context.yaml = select(1, loadModule(path, "lib/yaml.lua"))
  context.layoutValidator = select(1, loadModule(path, "lib/layout.lua"))
  context.layoutStore = select(1, loadModule(path, "lib/layout_store.lua"))

  context.root = lvgl.box({
    x = 0,
    y = 0,
    w = zone.w,
    h = zone.h,
    color = lcd.RGB(16, 19, 22),
  })

  if not context.grid or not context.yaml
      or not context.layoutValidator or not context.layoutStore then
    addError(context, "AeroGrid runtime module failed to load")
    showErrors(context)
  else
    loadComponents(context)
  end

  return context
end

--- Recalculate component rectangles after EdgeTX changes the host zone.
---@param context AeroGridContext
local function reflow(context)
  context.root:set({w = context.zone.w, h = context.zone.h})

  for _, entry in ipairs(context.components) do
    local rect = context.grid.rect(context.zone, entry.placement, 4, 4, 4)
    if rect and type(entry.module.resize) == "function" then
      entry.module.resize(entry.instance, rect)
    end
  end

  if context.errorLabel then
    context.errorLabel:set({w = math.max(1, context.zone.w - 16)})
  end

  context.width = context.zone.w
  context.height = context.zone.h
end

--- Apply native host options; changing Dashboard ID schedules a safe rebuild.
---@param context AeroGridContext
---@param widgetOptions AeroGridWidgetOptions
local function update(context, widgetOptions)
  local dashboardId = widgetOptions.DashID
  if dashboardId ~= context.dashboardId then
    context.dashboardId = dashboardId
    context.reloadState = "clear"
  end
end

--- Translate compact native option keys into user-facing labels.
---@param name string
---@return string
local function translate(name)
  if name == "DashID" then return "Dashboard ID" end
  return name
end

--- Advance deferred reloads and keep component geometry synchronized.
---@param context AeroGridContext
local function refresh(context)
  if context.reloadState == "clear" then
    context.root:clear()
    context.components = {}
    context.errors = {}
    context.errorLabel = nil
    context.reloadState = "build"
    return
  elseif context.reloadState == "build" then
    context.reloadState = nil
    loadComponents(context)
  end

  if context.width ~= context.zone.w or context.height ~= context.zone.h then
    reflow(context)
  end
end

return {
  name = "AeroGrid",
  options = options,
  create = create,
  update = update,
  refresh = refresh,
  translate = translate,
  useLvgl = true,
}