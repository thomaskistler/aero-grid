-- SPDX-License-Identifier: GPL-2.0-only

--- Validation, draft edits, and automatic population of a layout's
--- post-flight debrief section.

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

-- Sensors AeroGrid publishes itself. They exist once Discover new sensors has
-- run, so a fill names them even before the model has them.
local PUBLISHED = { VCel = true, HDst = true, FDst = true }

local function named(value)
    return type(value) == "string" and value ~= ""
end

local function sensorPresent(name)
    return getFieldInfo == nil or getFieldInfo(name) ~= nil
end

--- Whether a Metric entry's thresholds count downward, as the Metric panel
--- judges it: an explicit direction, or a critical level below the warning
--- level with both inside the range.
local function metricFalling(entry)
    if entry.direction == "falling" then
        return true
    elseif entry.direction == "rising" then
        return false
    end
    local low, high = entry.rangeMin or 0, entry.rangeMax or 100
    local ranged = type(low) == "number" and type(high) == "number"
    if ranged and high < low then
        low, high = high, low
    end
    local function within(value)
        return type(value) == "number" and (not ranged or (value >= low and value <= high))
    end
    return within(entry.warning) and within(entry.critical) and entry.critical < entry.warning
end

local function config(panel)
    return type(panel) == "table" and type(panel.config) == "table" and panel.config or {}
end

local function entries(settings)
    local list = {}
    if type(settings.metrics) == "table" then
        for _, entry in ipairs(settings.metrics) do
            if type(entry) == "table" and named(entry.source) then
                list[#list + 1] = entry
            end
        end
    end
    return list
end

local function linkSources(settings)
    local rssi = settings.rssiSource
    if rssi == nil then
        rssi = "RSSI"
    end
    return settings.qualitySource, rssi
end

local function satelliteSource(settings)
    return named(settings.satelliteSource) and settings.satelliteSource or "Sats"
end

local ACCENTS = { cyan = true, green = true, orange = true, amber = true }

--- A series for one Chart or Metric reading. Its label is left out: the tile
--- title names the reading. Only Chart readings carry a range and color.
local function readingSeries(entry, statistic, chart)
    local series = { source = entry.source, statistic = statistic }
    if type(entry.unit) == "string" then
        series.unit = entry.unit
    end
    local precision = entry.precision
    if finite(precision) and precision >= 0 and precision <= 3 and precision % 1 == 0 then
        series.precision = precision
    end
    if chart then
        local low, high = entry.rangeMin, entry.rangeMax
        low, high = finite(low) and low or nil, finite(high) and high or nil
        if not (low and high and low >= high) then
            series.rangeMin, series.rangeMax = low, high
        end
        series.accent = ACCENTS[entry.accent] and entry.accent or nil
    end
    return series
end

--- Sources the layout judges as falling, so a fill records their minimum.
local function fallingSources(panels)
    local falling = {}
    local function mark(source, value)
        if named(source) and falling[source] == nil then
            falling[source] = value
        end
    end
    for _, panel in ipairs(panels) do
        local kind, settings = type(panel) == "table" and panel.type, config(panel)
        if kind == "rx-battery" then
            mark("VCel", true)
        elseif kind == "link-status" then
            local quality, rssi = linkSources(settings)
            mark(quality, true)
            mark(rssi, true)
            if settings.protocol == "elrs4" then
                mark("Mrgn", true)
            end
        elseif kind == "navigation" then
            mark(satelliteSource(settings), true)
        elseif kind == "metric" then
            for _, entry in ipairs(entries(settings)) do
                mark(entry.source, metricFalling(entry))
            end
        end
    end
    return falling
end

--- Build a debrief from a layout's panels: what a pilot would want to see
--- after a flight with this dashboard. Every tile is Compact.
---@param panels table[] The layout's panels.
---@param present? fun(source: string): boolean Whether the model has a sensor.
---@return table section
function debrief.fromPanels(panels, present)
    present = present or sensorPresent
    panels = type(panels) == "table" and panels or {}
    local falling, tiles, seen = fallingSources(panels), {}, {}

    local function has(source)
        return named(source) and (PUBLISHED[source] or present(source) and true or false)
    end
    local function add(title, list)
        if #list > 0 and #tiles < debrief.MAX_TILES then
            tiles[#tiles + 1] = { title = title, colSpan = 2, rowSpan = 2, series = list }
        end
    end
    local function title(label, fallback)
        return named(label) and label or fallback
    end

    for _, panel in ipairs(panels) do
        local kind, settings = type(panel) == "table" and panel.type, config(panel)
        -- Only the first Battery, Link, and Navigation panel publishes.
        local first = kind and not seen[kind]
        if kind then
            seen[kind] = true
        end
        if kind == "rx-battery" and first then
            local list = { { source = "VCel", statistic = "min" } }
            if has("Capa") then
                list[2] = { source = "Capa", statistic = "delta", label = "used" }
            end
            add(title(settings.label, "PACK"), list)
        elseif kind == "link-status" and first then
            local list = {}
            local quality, rssi = linkSources(settings)
            for _, source in ipairs({ quality, rssi }) do
                if has(source) and (#list == 0 or list[1].source ~= source) then
                    list[#list + 1] = { source = source, statistic = "min" }
                end
            end
            add(title(settings.label, "LINK"), list)
        elseif kind == "navigation" and first then
            local motion = {}
            if has("GSpd") then
                motion[#motion + 1] = { source = "GSpd", statistic = "max" }
            end
            local altitude = has("Alt") and "Alt" or has("GAlt") and "GAlt"
            if altitude then
                motion[#motion + 1] = { source = altitude, statistic = "max" }
            end
            add("SPEED & ALTITUDE", motion)
            add(title(settings.label, "NAV"), {
                { source = "HDst", statistic = "max" },
                { source = "FDst", statistic = "delta", label = "flown" },
            })
            local satellites = satelliteSource(settings)
            add("SATELLITES", has(satellites) and { { source = satellites, statistic = "min" } } or {})
        elseif kind == "chart" or kind == "metric" then
            local readings, list = entries(settings), {}
            for index = 1, math.min(#readings, debrief.MAX_SERIES) do
                local entry = readings[index]
                list[index] = readingSeries(entry, falling[entry.source] and "min" or "max", kind == "chart")
            end
            local head = readings[1]
            local name = head and title(head.label, head.source)
            add(kind == "chart" and title(settings.label, name) or name, list)
        end
        if #tiles == debrief.MAX_TILES then
            break
        end
    end
    return { tiles = tiles }
end

--- Replace a section's tiles with those built from the panels.
---@param section table
---@param panels table[]
---@param present? fun(source: string): boolean
---@return integer count
function debrief.fill(section, panels, present)
    section.tiles = debrief.fromPanels(panels, present).tiles
    return #section.tiles
end

return debrief
