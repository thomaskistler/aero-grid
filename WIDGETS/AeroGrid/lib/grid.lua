-- SPDX-License-Identifier: GPL-2.0-only

--- Integer-safe grid geometry and placement validation.

---@class AeroGridZoneSize
---@field w integer
---@field h integer

---@class AeroGridPlacement
---@field col integer Zero-based starting column.
---@field row integer Zero-based starting row.
---@field colSpan integer Number of contiguous columns occupied.
---@field rowSpan integer Number of contiguous rows occupied.

---@class AeroGridRect
---@field x integer
---@field y integer
---@field w integer
---@field h integer

local grid = {}

--- Return whether a value is a finite Lua integer representation.
---@param value any
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value == math.floor(value)
end

--- Calculate one axis from absolute boundaries so rounding never accumulates.
---@param size integer
---@param start integer
---@param span integer
---@param count integer
---@param gutter integer
---@return integer offset
---@return integer extent
local function axisRect(size, start, span, count, gutter)
  local contentSize = size - gutter * (count - 1)
  local first = math.floor(start * contentSize / count) + start * gutter
  local last = math.floor((start + span) * contentSize / count)
    + (start + span - 1) * gutter

  return first, last - first
end

--- Validate a rectangular placement against grid dimensions.
---@param item AeroGridPlacement
---@param columns? integer Defaults to 4.
---@param rows? integer Defaults to 4.
---@return boolean valid
---@return string? error
function grid.validatePlacement(item, columns, rows)
  columns = columns or 4
  rows = rows or 4

  if type(item) ~= "table" then
    return false, "placement must be a table"
  end

  local fields = {"col", "row", "colSpan", "rowSpan"}
  for _, field in ipairs(fields) do
    if not isInteger(item[field]) then
      return false, field .. " must be an integer"
    end
  end

  if item.col < 0 or item.row < 0 then
    return false, "column and row must be non-negative"
  end
  if item.colSpan < 1 or item.rowSpan < 1 then
    return false, "column and row spans must be positive"
  end
  if item.col + item.colSpan > columns then
    return false, "placement exceeds grid columns"
  end
  if item.row + item.rowSpan > rows then
    return false, "placement exceeds grid rows"
  end

  return true
end

--- Return whether two grid placements occupy at least one common cell.
---@param first AeroGridPlacement
---@param second AeroGridPlacement
---@return boolean
function grid.overlaps(first, second)
  return first.col < second.col + second.colSpan
    and second.col < first.col + first.colSpan
    and first.row < second.row + second.rowSpan
    and second.row < first.row + first.rowSpan
end

--- Convert a validated placement into integer pixel bounds.
---@param zone AeroGridZoneSize
---@param item AeroGridPlacement
---@param columns? integer Defaults to 4.
---@param rows? integer Defaults to 4.
---@param gutter? integer Pixel gap between adjacent cells.
---@return AeroGridRect? rect
---@return string? error
function grid.rect(zone, item, columns, rows, gutter)
  columns = columns or 4
  rows = rows or 4
  gutter = gutter or 0

  local valid, err = grid.validatePlacement(item, columns, rows)
  if not valid then
    return nil, err
  end
  if type(zone) ~= "table" or not isInteger(zone.w) or not isInteger(zone.h) then
    return nil, "zone width and height must be integers"
  end
  if not isInteger(gutter) or gutter < 0 then
    return nil, "gutter must be a non-negative integer"
  end
  if zone.w < gutter * (columns - 1) or zone.h < gutter * (rows - 1) then
    return nil, "gutter exceeds available space"
  end

  local x, width = axisRect(zone.w, item.col, item.colSpan, columns, gutter)
  local y, height = axisRect(zone.h, item.row, item.rowSpan, rows, gutter)

  return {x = x, y = y, w = width, h = height}
end

return grid