-- SPDX-License-Identifier: GPL-2.0-only

--- Validation and draft edits of a layout's post-flight debrief section.
--- Loaded only for layouts that have one.

local debrief = { RUNTIME_API = 1, MAX_TILES = 12, MAX_SERIES = 3 }

-- Compact 2 x 2, Wide 4 x 2, and Wide 4 x 1, in setup page order.
debrief.SIZES = { "2x2", "4x2", "4x1" }
local TILE_KEYS = { title = true, colSpan = true, rowSpan = true, series = true }

--- Series settings: the Chart panel's metric settings plus a statistic. The
--- setup page renders these, and validation checks against them.
debrief.SERIES_FIELDS = {
    {
        key = "statistic",
        label = "Statistic",
        type = "string",
        required = true,
        choices = { "min", "max", "avg", "delta" },
        message = "statistic must be min, max, avg, or delta",
    },
    { key = "source", label = "Source", type = "string", required = true },
    { key = "label", label = "Label", type = "string" },
    { key = "rangeMin", label = "Range min", type = "number", step = 0.1, empty = "Auto" },
    { key = "rangeMax", label = "Range max", type = "number", step = 0.1, empty = "Auto" },
    { key = "unit", label = "Unit", type = "string" },
    { key = "precision", label = "Precision", type = "number", min = 0, max = 3, step = 1, empty = "Sensor" },
    { key = "accent", label = "Color", type = "string", choices = { "cyan", "green", "orange", "amber" } },
}

local SERIES_FIELDS = {}
for _, field in ipairs(debrief.SERIES_FIELDS) do
    SERIES_FIELDS[field.key] = field
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isSequence(value)
    if type(value) ~= "table" then
        return false
    end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then
            return false
        end
        count = count + 1
    end
    return count == #value
end

local function isMapping(value)
    return type(value) == "table" and (next(value) == nil or #value == 0)
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, entry in pairs(value) do
        result[key] = copy(entry)
    end
    return result
end

--- Check one present series setting.
---@return string? error
local function checkField(field, value)
    local valid
    if field.choices then
        for _, choice in ipairs(field.choices) do
            valid = valid or value == choice
        end
    elseif field.type == "number" then
        valid = finite(value)
            and (not field.min or value >= field.min)
            and (not field.max or value <= field.max)
            and (field.step ~= 1 or value % 1 == 0)
    else
        valid = type(value) == "string" and not (field.required and value == "")
    end
    if not valid then
        return field.message or field.key .. " is invalid"
    end
end

--- Validate one series; an invalid series is rejected whole.
---@param value any
---@return table? series
---@return string? error
---@return string[] warnings
function debrief.validateSeries(value)
    if not isMapping(value) then
        return nil, "must be a mapping", {}
    end
    local series, warnings = {}, {}
    for key, field in pairs(value) do
        local known = SERIES_FIELDS[key]
        local message = known and checkField(known, field)
        if not known then
            warnings[#warnings + 1] = tostring(key) .. " is not a series setting"
        elseif message then
            return nil, message, warnings
        end
        series[key] = field
    end
    for _, field in ipairs(debrief.SERIES_FIELDS) do
        if field.required and series[field.key] == nil then
            return nil, field.message or field.key .. " is required", warnings
        end
    end
    if series.rangeMin and series.rangeMax and series.rangeMin >= series.rangeMax then
        return nil, "rangeMax must be greater than rangeMin", warnings
    end
    return series, nil, warnings
end

--- Validate one tile, dropping invalid series.
---@param value any
---@return table? tile
---@return string[] errors Problems, including those of dropped series.
---@return string[] warnings
function debrief.validateTile(value)
    if not isMapping(value) then
        return nil, { "must be a mapping" }, {}
    end
    local tile, warnings = {}, {}
    for key, field in pairs(value) do
        if not TILE_KEYS[key] then
            warnings[#warnings + 1] = tostring(key) .. " is not a tile setting"
        end
        tile[key] = field
    end
    if type(value.title) ~= "string" or value.title == "" then
        return nil, { "title is required" }, warnings
    end
    if not debrief.size(value) then
        return nil, { "size must be 2 x 2, 4 x 2, or 4 x 1" }, warnings
    end
    if not isSequence(value.series) then
        return nil, { "series must be a sequence" }, warnings
    end

    local errors, series = {}, {}
    for index, entry in ipairs(value.series) do
        if #series == debrief.MAX_SERIES then
            errors[#errors + 1] = "more than " .. debrief.MAX_SERIES .. " series; the rest were dropped"
            break
        end
        local valid, seriesError, seriesWarnings = debrief.validateSeries(entry)
        for _, message in ipairs(seriesWarnings) do
            warnings[#warnings + 1] = "series " .. index .. ": " .. message
        end
        if valid then
            series[#series + 1] = valid
        else
            errors[#errors + 1] = "series " .. index .. ": " .. seriesError
        end
    end
    if #series == 0 then
        errors[#errors + 1] = "has no valid series"
        return nil, errors, warnings
    end
    tile.series = series
    return tile, errors, warnings
end

--- Validate a debrief section. Invalid tiles and series are reported and
--- dropped, so the valid remainder can still be shown; `tiles: []` is a valid,
--- empty debrief.
---@param value any
---@return table? debrief Nil when the section itself is unusable.
---@return string[] errors
---@return string[] warnings
function debrief.validate(value)
    if not isMapping(value) then
        return nil, { "debrief must be a mapping" }, {}
    end
    local errors, warnings, result = {}, {}, {}
    -- Unknown keys are carried through, like unknown layout keys.
    for key, field in pairs(value) do
        result[key] = field
    end
    result.tiles = {}
    if value.tiles == nil then
        return result, errors, warnings
    end
    if not isSequence(value.tiles) then
        errors[#errors + 1] = "debrief tiles must be a sequence"
        return result, errors, warnings
    end
    for index, entry in ipairs(value.tiles) do
        if #result.tiles == debrief.MAX_TILES then
            errors[#errors + 1] = "debrief has more than " .. debrief.MAX_TILES .. " tiles; the rest were dropped"
            break
        end
        local tile, tileErrors, tileWarnings = debrief.validateTile(entry)
        for _, message in ipairs(tileErrors) do
            errors[#errors + 1] = "debrief tile " .. index .. ": " .. message
        end
        for _, message in ipairs(tileWarnings) do
            warnings[#warnings + 1] = "debrief tile " .. index .. ": " .. message
        end
        result.tiles[#result.tiles + 1] = tile
    end
    return result, errors, warnings
end

---@param section table?
---@return boolean
function debrief.canAdd(section)
    return section == nil or #section.tiles < debrief.MAX_TILES
end

--- A tile's size key, such as "4x2", or nil when its spans are not a size.
---@param tile table
---@return string?
function debrief.size(tile)
    local size = tostring(tile.colSpan) .. "x" .. tostring(tile.rowSpan)
    for _, candidate in ipairs(debrief.SIZES) do
        if candidate == size then
            return size
        end
    end
end

--- Append a new Compact tile with one series still to be chosen.
---@param section table
---@return integer|false index
---@return string? error
function debrief.addTile(section)
    if not debrief.canAdd(section) then
        return false, "a debrief has at most " .. debrief.MAX_TILES .. " tiles"
    end
    local index = #section.tiles + 1
    section.tiles[index] = { title = "Tile " .. index, colSpan = 2, rowSpan = 2, series = { { statistic = "min" } } }
    return index
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

--- Paste a copy of tile `from`, or move it, before or after tile `target`.
---@param section table
---@param from integer
---@param target integer
---@param after boolean
---@param duplicate boolean Copy rather than move.
---@return integer|false index The pasted tile's position.
---@return string? error
function debrief.pasteTile(section, from, target, after, duplicate)
    local tiles = section.tiles
    if not tiles[from] or not tiles[target] then
        return false, "no such tile"
    end
    if duplicate and not debrief.canAdd(section) then
        return false, "a debrief has at most " .. debrief.MAX_TILES .. " tiles"
    end
    if not duplicate and from == target then
        return from
    end
    local tile = duplicate and copy(tiles[from]) or table.remove(tiles, from)
    if not duplicate and from < target then
        target = target - 1
    end
    local index = after and target + 1 or target
    table.insert(tiles, index, tile)
    return index
end

--- Set a tile setting: `title`, or `size` as one of SIZES.
---@param section table
---@param index integer
---@param key string
---@param value any
---@return boolean ok
---@return string? error
function debrief.setTileValue(section, index, key, value)
    local tile = section.tiles[index]
    if not tile then
        return false, "no tile " .. tostring(index)
    end
    if key == "title" then
        if type(value) ~= "string" or value == "" then
            return false, "Title is required"
        end
        tile.title = value
    elseif key == "size" then
        local colSpan, rowSpan = string.match(tostring(value), "^(%d)x(%d)$")
        local size = { colSpan = tonumber(colSpan), rowSpan = tonumber(rowSpan) }
        if not debrief.size(size) then
            return false, "size must be 2 x 2, 4 x 2, or 4 x 1"
        end
        tile.colSpan, tile.rowSpan = size.colSpan, size.rowSpan
    else
        return false, tostring(key) .. " is not a tile setting"
    end
    return true
end

--- Set or, with nil, clear a series setting.
---@param section table
---@param index integer
---@param seriesIndex integer
---@param key string
---@param value any
---@return boolean ok
---@return string? error
function debrief.setSeriesValue(section, index, seriesIndex, key, value)
    local series = section.tiles[index] and section.tiles[index].series[seriesIndex]
    local field = SERIES_FIELDS[key]
    if not series then
        return false, "no series " .. tostring(seriesIndex)
    elseif not field then
        return false, tostring(key) .. " is not a series setting"
    end
    local message
    if value == nil then
        message = field.required and field.label .. " is required"
    else
        message = checkField(field, value)
    end
    if message then
        return false, message
    end
    series[key] = value
    return true
end

---@param section table
---@param index integer
---@return integer|false seriesIndex
---@return string? error
function debrief.addSeries(section, index)
    local tile = section.tiles[index]
    if not tile then
        return false, "no tile " .. tostring(index)
    elseif #tile.series >= debrief.MAX_SERIES then
        return false, "a tile has at most " .. debrief.MAX_SERIES .. " series"
    end
    tile.series[#tile.series + 1] = { statistic = "min" }
    return #tile.series
end

--- Remove a series; a tile keeps at least one.
---@param section table
---@param index integer
---@param seriesIndex integer
---@return boolean removed
---@return string? error
function debrief.removeSeries(section, index, seriesIndex)
    local tile = section.tiles[index]
    if not tile or not tile.series[seriesIndex] then
        return false, "no series " .. tostring(seriesIndex)
    elseif #tile.series == 1 then
        return false, "a tile needs a series"
    end
    table.remove(tile.series, seriesIndex)
    return true
end

return debrief
