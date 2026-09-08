-- SPDX-License-Identifier: GPL-2.0-only

--- Read-only layout path resolution and loading for AeroGrid phase one.

local layoutStore = {}

--- Produce a stable four-hex-digit suffix for normalized identifiers.
---@param value string
---@return string
local function shortHash(value)
  local hash = 0
  for index = 1, #value do
    hash = (hash * 33 + string.byte(value, index)) % 65536
  end
  return string.format("%04x", hash)
end

--- Convert a model or dashboard identifier into a safe filename segment.
---@param value any
---@return string
local function sanitize(value)
  local original = string.gsub(tostring(value or ""), "%.[^%.]+$", "")
  local sanitized = original
  sanitized = string.gsub(sanitized, "[^%w_-]", "-")
  sanitized = string.gsub(sanitized, "%-+", "-")
  sanitized = string.gsub(sanitized, "^%-", "")
  sanitized = string.gsub(sanitized, "%-$", "")
  if sanitized == "" then return "default" end
  if sanitized ~= original then
    sanitized = sanitized .. "-" .. shortHash(original)
  end
  return sanitized
end

--- Read a complete file through EdgeTX's reduced file API.
---@param filename string
---@return string? content
---@return string? error
local function readFile(filename)
  local info = fstat(filename)
  local fileSize = type(info) == "table" and info["size"] or nil
  if not fileSize then
    return nil, "file not found: " .. filename
  end

  local handle, openError = io.open(filename, "r")
  if not handle then
    return nil, openError or ("cannot open: " .. filename)
  end

  -- EdgeTX exposes io.read(handle, size), unlike the standard Lua io.read API.
  ---@diagnostic disable-next-line: param-type-mismatch
  local content = io.read(handle, fileSize)
  io.close(handle)
  if content == nil then
    return nil, "cannot read: " .. filename
  end

  return content
end

--- Resolve the model- and dashboard-specific YAML filename.
---@param widgetPath string Absolute AeroGrid widget directory.
---@param modelFilename string Current EdgeTX model filename.
---@param dashboardId string Native Dashboard ID option.
---@return string
function layoutStore.path(widgetPath, modelFilename, dashboardId)
  local base = widgetPath
  if string.sub(base, -1) ~= "/" then base = base .. "/" end
  return base .. "layouts/" .. sanitize(modelFilename) .. "--"
    .. sanitize(dashboardId) .. ".yaml"
end

--- Read, parse, and validate a layout, falling back to default.yaml.
---@param widgetPath string Absolute AeroGrid widget directory.
---@param modelFilename string Current EdgeTX model filename.
---@param dashboardId string Native Dashboard ID option.
---@param yaml table YAML module implementing parse.
---@param layout table Layout module implementing validate.
---@param grid table Grid module used during validation.
---@return table? document
---@return string[] errors
---@return string filename Selected specific or fallback layout path.
function layoutStore.load(widgetPath, modelFilename, dashboardId, yaml, layout, grid)
  local filename = layoutStore.path(widgetPath, modelFilename, dashboardId)
  local content, readError = readFile(filename)

  if not content then
    filename = (string.sub(widgetPath, -1) == "/" and widgetPath or widgetPath .. "/")
      .. "layouts/default.yaml"
    content, readError = readFile(filename)
  end
  if not content then return nil, {readError}, filename end

  local document, parseError = yaml.parse(content)
  if not document then return nil, {parseError}, filename end

  local normalized, validationErrors = layout.validate(document, grid)
  return normalized, validationErrors, filename
end

return layoutStore