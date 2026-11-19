-- SPDX-License-Identifier: GPL-2.0-only

--- Validation and draft edits of a layout's post-flight debrief section.
--- Loaded only for layouts that have one.

local debrief = { RUNTIME_API = 1, MAX_TILES = 12, MAX_SERIES = 3 }

-- Compact 2 x 2, Wide 4 x 2, and Wide 4 x 1.
local SIZES = { ["2x2"] = true, ["4x2"] = true, ["4x1"] = true }
local STATISTICS = { min = true, max = true, avg = true, delta = true }
local ACCENTS = { cyan = true, green = true, orange = true, amber = true }
local TILE_KEYS = { title = true, colSpan = true, rowSpan = true, series = true }

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isSequence(value)
    if type(value) ~= "table" then
        return false
    end
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    return count == #value
end

local function isMapping(value)
    return type(value) == "table" and (next(value) == nil or #value == 0)
end

local SERIES_FIELDS = {
    source = function(value)
        return type(value) == "string" and value ~= ""
    end,
    statistic = function(value)
        return STATISTICS[value] == true
    end,
    label = function(value)
        return type(value) == "string"
    end,
    unit = function(value)
        return type(value) == "string"
    end,
    precision = function(value)
        return finite(value) and value >= 0 and value <= 3 and value % 1 == 0
    end,
    rangeMin = finite,
    rangeMax = finite,
    accent = function(value)
        return ACCENTS[value] == true
    end,
}

--- Validate one series; an invalid series is rejected whole.
---@param value any
---@return table? series
---@return string? error
function debrief.validateSeries(value)
    if not isMapping(value) then
        return nil, "must be a mapping"
    end
    local series = {}
    for key, field in pairs(value) do
        local check = SERIES_FIELDS[key]
        if not check then
            return nil, tostring(key) .. " is not a series setting"
        end
        if not check(field) then
            return nil, key .. " is invalid"
        end
        series[key] = field
    end
    if series.source == nil then
        return nil, "source is required"
    end
    if series.statistic == nil then
        return nil, "statistic must be min, max, avg, or delta"
    end
    if series.rangeMin and series.rangeMax and series.rangeMin >= series.rangeMax then
        return nil, "rangeMax must be greater than rangeMin"
    end
    return series
end

--- Validate one tile, dropping invalid series.
---@param value any
---@return table? tile
---@return string[] errors Problems, including those of dropped series.
function debrief.validateTile(value)
    if not isMapping(value) then
        return nil, { "must be a mapping" }
    end
    for key in pairs(value) do
        if not TILE_KEYS[key] then
            return nil, { tostring(key) .. " is not a tile setting" }
        end
    end
    if type(value.title) ~= "string" or value.title == "" then
        return nil, { "title is required" }
    end
    local colSpan, rowSpan = value.colSpan or 2, value.rowSpan or 2
    if not SIZES[tostring(colSpan) .. "x" .. tostring(rowSpan)] then
        return nil, { "size must be 2 x 2, 4 x 2, or 4 x 1" }
    end
    if not isSequence(value.series) then
        return nil, { "series must be a sequence" }
    end

    local errors, series = {}, {}
    for index, entry in ipairs(value.series) do
        if #series == debrief.MAX_SERIES then
            errors[#errors + 1] = "more than " .. debrief.MAX_SERIES .. " series; the rest were dropped"
            break
        end
        local valid, seriesError = debrief.validateSeries(entry)
        if valid then
            series[#series + 1] = valid
        else
            errors[#errors + 1] = "series " .. index .. ": " .. seriesError
        end
    end
    if #series == 0 then
        errors[#errors + 1] = "has no valid series"
        return nil, errors
    end
    return { title = value.title, colSpan = colSpan, rowSpan = rowSpan, series = series }, errors
end

--- Validate a debrief section. Invalid tiles and series are reported and
--- dropped, so the valid remainder can still be shown; `tiles: []` is a valid,
--- empty debrief.
---@param value any
---@return table? debrief Nil when the section itself is unusable.
---@return string[] errors
function debrief.validate(value)
    if not isMapping(value) then
        return nil, { "debrief must be a mapping" }
    end
    local errors, result = {}, {}
    -- Unknown keys are carried through, like unknown layout keys.
    for key, field in pairs(value) do
        result[key] = field
    end
    result.tiles = {}
    if value.tiles == nil then
        return result, errors
    end
    if not isSequence(value.tiles) then
        errors[#errors + 1] = "debrief tiles must be a sequence"
        return result, errors
    end
    for index, entry in ipairs(value.tiles) do
        if #result.tiles == debrief.MAX_TILES then
            errors[#errors + 1] = "debrief has more than " .. debrief.MAX_TILES .. " tiles; the rest were dropped"
            break
        end
        local tile, tileErrors = debrief.validateTile(entry)
        for _, message in ipairs(tileErrors) do
            errors[#errors + 1] = "debrief tile " .. index .. ": " .. message
        end
        result.tiles[#result.tiles + 1] = tile
    end
    return result, errors
end

--- The legend text before a series value.
---@param series table
---@return string
function debrief.label(series)
    if type(series.label) == "string" and series.label ~= "" then
        return series.label
    end
    return series.statistic
end

---@param section table?
---@return boolean
function debrief.canAdd(section)
    return section == nil or #section.tiles < debrief.MAX_TILES
end

--- Append a tile.
---@param section table
---@param tile table
---@return integer|false index
---@return string? error
function debrief.addTile(section, tile)
    if not debrief.canAdd(section) then
        return false, "a debrief has at most " .. debrief.MAX_TILES .. " tiles"
    end
    local valid, errors = debrief.validateTile(tile)
    if not valid or #errors > 0 then
        return false, table.concat(errors, "; ")
    end
    section.tiles[#section.tiles + 1] = valid
    return #section.tiles
end

--- Replace a tile.
---@param section table
---@param index integer
---@param tile table
---@return boolean ok
---@return string? error
function debrief.setTile(section, index, tile)
    if not section.tiles[index] then
        return false, "no tile " .. tostring(index)
    end
    local valid, errors = debrief.validateTile(tile)
    if not valid or #errors > 0 then
        return false, table.concat(errors, "; ")
    end
    section.tiles[index] = valid
    return true
end

---@param section table
---@param index integer
---@return boolean removed
function debrief.removeTile(section, index)
    if not section.tiles[index] then
        return false
    end
    table.remove(section.tiles, index)
    return true
end

--- Move a tile by `delta` places.
---@param section table
---@param index integer
---@param delta integer
---@return integer|false index The tile's new position.
function debrief.moveTile(section, index, delta)
    local target = index + delta
    if not section.tiles[index] or target < 1 or target > #section.tiles then
        return false
    end
    local tile = table.remove(section.tiles, index)
    table.insert(section.tiles, target, tile)
    return target
end

return debrief
