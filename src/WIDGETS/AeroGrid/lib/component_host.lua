-- SPDX-License-Identifier: GPL-2.0-only

--- Component module contract, settings resolution, and isolated lifecycle dispatch.
--- The host owns this contract so an independently authored component file can be
--- loaded, validated, and driven without trusting its implementation.

---@class AeroGridComponentSetting
---@field key string Configuration key read from the layout YAML.
---@field type? "string"|"number"|"boolean"|"table" Rejects mistyped YAML values.
---@field default? any Applied when the key is absent or mistyped.

---@class AeroGridComponentModule
---@field id string Must equal the component type name used in YAML.
---@field apiVersion integer Must equal the host component API version.
---@field supportedSpans? string[] Span strings such as "2x1", or "any".
---@field settings? AeroGridComponentSetting[]
---@field create fun(parent: any, rect: table, settings: table): any
---@field resize? fun(instance: any, rect: table)
---@field refresh? fun(instance: any)
---@field background? fun(instance: any)
---@field destroy? fun(instance: any)

---@class AeroGridComponentEntry
---@field placement table Validated YAML component placement.
---@field module AeroGridComponentModule
---@field instance any Component-owned runtime context.
---@field settings table Resolved configuration passed to create.
---@field failed? boolean Set after a lifecycle failure disables the component.
---@field error? string First lifecycle failure message.

local componentHost = {}

--- Host-side component API version. Modules declaring anything else are rejected.
componentHost.API_VERSION = 1

--- Optional lifecycle callbacks, in a fixed order so errors stay deterministic.
local OPTIONAL_CALLBACKS = {"resize", "refresh", "background", "destroy"}

--- Restrict module identifiers to the same path-safe characters as layout types.
---@param value any
---@return boolean
local function isSafeIdentifier(value)
  return type(value) == "string" and string.match(value, "^[%w_-]+$") ~= nil
end

--- Verify a loaded module satisfies the component contract.
---@param module any Value returned by the component's Lua chunk.
---@param typeName string Component type requested by the layout.
---@return boolean valid
---@return string? error
function componentHost.validateModule(module, typeName)
  if type(module) ~= "table" then
    return false, "component module must return a table"
  end
  if module.apiVersion ~= componentHost.API_VERSION then
    return false, "incompatible component API"
  end
  if not isSafeIdentifier(module.id) then
    return false, "component module declares an invalid id"
  end
  if module.id ~= typeName then
    return false, "component module id " .. module.id
      .. " does not match type " .. typeName
  end
  if type(module.create) ~= "function" then
    return false, "component has no create function"
  end

  for _, name in ipairs(OPTIONAL_CALLBACKS) do
    local callback = module[name]
    if callback ~= nil and type(callback) ~= "function" then
      return false, name .. " must be a function"
    end
  end

  if module.supportedSpans ~= nil and type(module.supportedSpans) ~= "table" then
    return false, "supportedSpans must be a sequence"
  end
  if module.settings ~= nil and type(module.settings) ~= "table" then
    return false, "settings must be a sequence"
  end

  return true
end

--- Format a placement span as the string used in supportedSpans declarations.
---@param colSpan integer
---@param rowSpan integer
---@return string
function componentHost.spanName(colSpan, rowSpan)
  return tostring(colSpan) .. "x" .. tostring(rowSpan)
end

--- Report whether a module accepts a grid span.
--- A module without a supportedSpans declaration accepts every span.
---@param module AeroGridComponentModule
---@param colSpan integer
---@param rowSpan integer
---@return boolean
function componentHost.supportsSpan(module, colSpan, rowSpan)
  local spans = module.supportedSpans
  if spans == nil then return true end

  local wanted = componentHost.spanName(colSpan, rowSpan)
  for _, span in ipairs(spans) do
    if span == "any" or span == wanted then return true end
  end

  return false
end

--- Merge declared setting defaults over the layout's configuration table.
--- Mistyped values fall back to the default so one bad key cannot break rendering.
---@param module AeroGridComponentModule
---@param config any Raw config mapping from the layout file.
---@return table settings
---@return string[] warnings
function componentHost.resolveSettings(module, config)
  local settings = {}
  local warnings = {}

  if type(config) == "table" then
    for key, value in pairs(config) do
      settings[key] = value
    end
  end

  for index, setting in ipairs(module.settings or {}) do
    if type(setting) ~= "table" or type(setting.key) ~= "string" then
      warnings[#warnings + 1] = "setting " .. index .. " is malformed"
    else
      local current = settings[setting.key]
      if current == nil then
        settings[setting.key] = setting.default
      elseif setting.type ~= nil and type(current) ~= setting.type then
        warnings[#warnings + 1] = setting.key .. " must be a " .. tostring(setting.type)
        settings[setting.key] = setting.default
      end
    end
  end

  return settings, warnings
end

--- Invoke one lifecycle callback under pcall.
--- The first failure permanently disables that component so a broken module
--- cannot repeatedly raise errors or take down the surrounding dashboard.
---@param entry AeroGridComponentEntry
---@param event string Optional callback name such as "refresh".
---@param ... any Additional callback arguments.
---@return boolean ok
---@return string? error Set only on the call that first fails.
function componentHost.dispatch(entry, event, ...)
  if type(entry) ~= "table" or entry.failed then
    return false
  end

  local callback = entry.module and entry.module[event]
  if type(callback) ~= "function" then
    return true
  end

  local ok, callbackError = pcall(callback, entry.instance, ...)
  if ok then
    return true
  end

  entry.failed = true
  entry.error = tostring(callbackError)
  return false, entry.error
end

return componentHost
