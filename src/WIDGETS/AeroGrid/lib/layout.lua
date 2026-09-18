-- SPDX-License-Identifier: GPL-2.0-only

--- AeroGrid schema validation and normalization.

---@class AeroGridLayoutDocument
---@field version integer
---@field grid table
---@field components table[]

---@class AeroGridValidatedLayout
---@field version integer
---@field grid table
---@field components table[] Only valid, non-overlapping components.
--- Unrecognized top-level keys from the source document are preserved verbatim.

local layout = {}

--- Restrict IDs and component types to path-safe characters.
---@param value any
---@return boolean
local function isSafeIdentifier(value)
  return type(value) == "string" and string.match(value, "^[%w_-]+$") ~= nil
end

--- Report whether a value is a pure array, so a mapping written where a
--- sequence is required is rejected instead of silently loading nothing.
---@param value any
---@return boolean
local function isSequence(value)
  if type(value) ~= "table" then return false end

  local count = 0
  for _ in pairs(value) do count = count + 1 end

  return count == #value
end

--- Validate the optional layout-level theme block.
--- Phase 1 has no editor, so the layout file is the only way to select a theme
--- mode or supply custom overrides.
---@param value any
---@param errors string[]
---@return table? theme
local function validateTheme(value, errors)
  if value == nil then return nil end
  if type(value) ~= "table" then
    errors[#errors + 1] = "theme must be a mapping"
    return nil
  end

  local result = {}
  if value.mode ~= nil then
    if type(value.mode) ~= "string" then
      errors[#errors + 1] = "theme mode must be a string"
    else
      result.mode = value.mode
    end
  end

  if value.overrides ~= nil then
    if type(value.overrides) ~= "table" then
      errors[#errors + 1] = "theme overrides must be a mapping"
    else
      result.overrides = value.overrides
    end
  end

  return result
end

--- Validate the optional layout-level flight session block.
---
--- The arm switch bounds one flight, and a dashboard has one flight. It used
--- to be a per-component setting, which let two components state different
--- switches; `extremaService:flight` takes the first caller's and ignores the
--- rest, so the second component's was silently discarded. A setting whose
--- value is thrown away is worse than no setting, because it reads like a
--- choice. It belongs to the layout, which is the thing there is one of.
---@param value any
---@param errors string[]
---@return table? session
local function validateSession(value, errors)
  if value == nil then return nil end
  if type(value) ~= "table" then
    errors[#errors + 1] = "session must be a mapping"
    return nil
  end

  local result = {}
  if value.armSource ~= nil then
    if type(value.armSource) ~= "string" then
      errors[#errors + 1] = "session armSource must be a string"
    else
      result.armSource = value.armSource
    end
  end

  return result
end

--- Validate the document's own fields, excluding its components.
--- A document this loader cannot interpret fails closed, because rendering its
--- components under phase-one assumptions would silently misplace them.
---@param document table
---@return table? header
---@return string[] errors
function layout.validateDocument(document)
  if type(document) ~= "table" then
    return nil, {"layout document must be a table"}
  end

  local errors = {}
  local normalized = {}

  -- Unknown top-level keys are carried through so a newer authoring tool's
  -- additions survive a round trip in memory.
  for key, value in pairs(document) do
    normalized[key] = value
  end
  normalized.version = document.version
  normalized.grid = document.grid
  normalized.components = {}
  normalized.theme = validateTheme(document.theme, errors)
  normalized.session = validateSession(document.session, errors)

  if document.version ~= 1 then
    return nil, {"unsupported layout version"}
  end
  if type(document.grid) ~= "table"
      or document.grid.columns ~= 4
      or document.grid.rows ~= 4 then
    return nil, {"phase 1 requires a 4 x 4 grid"}
  end

  return normalized, errors
end

--- Validate one component against the grid and the entries already accepted.
--- Returning the outcome per entry lets the host validate and build components
--- one at a time, rather than holding the whole layout in one callback.
---@param component any
---@param index integer Position in the sequence, for error messages.
---@param grid table
---@param accepted table[] Components already accepted.
---@param identifiers table<string, boolean> Ids already used.
---@return boolean valid
---@return string? error
function layout.validateComponent(component, index, grid, accepted, identifiers)
  local prefix = "component " .. index .. ": "

  if type(component) ~= "table" then
    return false, prefix .. "entry must be a mapping"
  end

  if not isSafeIdentifier(component.id) then
    return false, prefix .. "invalid id"
  end
  if identifiers[component.id] then
    return false, prefix .. "duplicate id " .. component.id
  end
  if not isSafeIdentifier(component.type) then
    return false, prefix .. "invalid type"
  end

  local placementValid, placementError = grid.validatePlacement(component, 4, 4)
  if not placementValid then
    return false, prefix .. placementError
  end

  for _, existing in ipairs(accepted) do
    if grid.overlaps(existing, component) then
      return false, prefix .. "overlaps " .. existing.id
    end
  end

  component.config = type(component.config) == "table" and component.config or {}
  return true
end

--- Validate a parsed phase-one document while retaining valid components.
--- Invalid components are reported and omitted so they cannot block the
--- dashboard. The host loads incrementally instead; this remains for callers
--- that can afford to validate a whole document at once.
---@param document AeroGridLayoutDocument
---@param grid table Grid module implementing placement validation and overlap checks.
---@return AeroGridValidatedLayout? layout
---@return string[] errors
function layout.validate(document, grid)
  local normalized, errors = layout.validateDocument(document)
  if not normalized then return nil, errors end

  if not isSequence(document.components) then
    errors[#errors + 1] = "components must be a sequence"
    return normalized, errors
  end

  local identifiers = {}
  for index, component in ipairs(document.components) do
    local valid, componentError = layout.validateComponent(
      component, index, grid, normalized.components, identifiers)
    if valid then
      identifiers[component.id] = true
      normalized.components[#normalized.components + 1] = component
    else
      errors[#errors + 1] = componentError
    end
  end

  return normalized, errors
end

return layout