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

local layout = {}

--- Restrict IDs and component types to path-safe characters.
---@param value any
---@return boolean
local function isSafeIdentifier(value)
  return type(value) == "string" and string.match(value, "^[%w_-]+$") ~= nil
end

--- Validate a parsed phase-one document while retaining valid components.
--- Invalid components are reported and omitted so they cannot block the dashboard.
---@param document AeroGridLayoutDocument
---@param grid table Grid module implementing placement validation and overlap checks.
---@return AeroGridValidatedLayout? layout
---@return string[] errors
function layout.validate(document, grid)
  if type(document) ~= "table" then
    return nil, {"layout document must be a table"}
  end

  local errors = {}
  local normalized = {
    version = document.version,
    grid = document.grid,
    components = {},
  }

  if document.version ~= 1 then
    errors[#errors + 1] = "unsupported layout version"
  end
  if type(document.grid) ~= "table"
      or document.grid.columns ~= 4
      or document.grid.rows ~= 4 then
    errors[#errors + 1] = "phase 1 requires a 4 x 4 grid"
  end
  if type(document.components) ~= "table" then
    errors[#errors + 1] = "components must be a sequence"
    return normalized, errors
  end

  local identifiers = {}
  for index, component in ipairs(document.components) do
    local prefix = "component " .. index .. ": "
    local valid = true

    if not isSafeIdentifier(component.id) then
      errors[#errors + 1] = prefix .. "invalid id"
      valid = false
    elseif identifiers[component.id] then
      errors[#errors + 1] = prefix .. "duplicate id " .. component.id
      valid = false
    end
    if not isSafeIdentifier(component.type) then
      errors[#errors + 1] = prefix .. "invalid type"
      valid = false
    end

    local placementValid, placementError = grid.validatePlacement(component, 4, 4)
    if not placementValid then
      errors[#errors + 1] = prefix .. placementError
      valid = false
    end

    if valid then
      for _, existing in ipairs(normalized.components) do
        if grid.overlaps(existing, component) then
          errors[#errors + 1] = prefix .. "overlaps " .. existing.id
          valid = false
          break
        end
      end
    end

    if valid then
      identifiers[component.id] = true
      component.config = type(component.config) == "table" and component.config or {}
      normalized.components[#normalized.components + 1] = component
    end
  end

  return normalized, errors
end

return layout