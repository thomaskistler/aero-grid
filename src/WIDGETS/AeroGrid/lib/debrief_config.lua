-- SPDX-License-Identifier: GPL-2.0-only

--- Validation, draft edits, and automatic population of a layout's
--- post-flight debrief section.

local debrief = { RUNTIME_API = 1, MAX_TILES = 12, MAX_SERIES = 3 }

-- Legacy per-tile sizes, accepted when the layout has no shared size.
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
function debrief.validateTile(value, size)
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
    if size ~= nil then
        tile.colSpan, tile.rowSpan = size == "wide" and 4 or 2, 2
    end
    if type(value.title) ~= "string" or value.title == "" then
        return nil, { "title is required" }, warnings
    end
    if not debrief.size(tile) then
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

--- Validate a section's settings and tile sequence without walking its tiles.
---@param value any
---@return table? debrief Nil when the section itself is unusable.
---@return string[] errors
---@return string[] warnings
function debrief.validateHeader(value)
    if not isMapping(value) then
        return nil, { "debrief must be a mapping" }, {}
    end
    local errors, warnings, result = {}, {}, {}
    -- Unknown keys are carried through, like unknown layout keys.
    for key, field in pairs(value) do
        result[key] = field
    end
    result.tiles = {}
    if value.size ~= nil and value.size ~= "compact" and value.size ~= "wide" then
        errors[#errors + 1] = "debrief size must be compact or wide"
    end
    if value.tiles == nil then
        return result, errors, warnings
    end
    if not isSequence(value.tiles) then
        errors[#errors + 1] = "debrief tiles must be a sequence"
        return result, errors, warnings
    end
    return result, errors, warnings
end

function debrief.validate(value)
    local result, errors, warnings = debrief.validateHeader(value)
    if not result or value.tiles == nil or not isSequence(value.tiles) then
        return result, errors, warnings
    end
    for index, entry in ipairs(value.tiles) do
        if #result.tiles == debrief.MAX_TILES then
            errors[#errors + 1] = "debrief has more than " .. debrief.MAX_TILES .. " tiles; the rest were dropped"
            break
        end
        local tile, tileErrors, tileWarnings = debrief.validateTile(entry, result.size)
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

--- Older layouts retain their per-tile sizes until a shared size is chosen.
function debrief.viewSize(section)
    if section.size then
        return section.size
    end
    local first = section.tiles[1]
    return first and first.colSpan == 4 and "wide" or "compact"
end

function debrief.setSize(section, size)
    if size ~= "compact" and size ~= "wide" then
        return false, "debrief size must be compact or wide"
    end
    section.size = size
    for _, tile in ipairs(section.tiles) do
        tile.colSpan, tile.rowSpan = size == "wide" and 4 or 2, 2
    end
    return true
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
    local wide = section.size == "wide"
    section.tiles[index] = {
        title = "Tile " .. index,
        colSpan = wide and 4 or 2,
        rowSpan = 2,
        series = { { statistic = "min" } },
    }
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

local function swap(list, index, delta)
    local target = index + delta
    if not list[index] or not list[target] then
        return false, "cannot move there"
    end
    list[index], list[target] = list[target], list[index]
    return target
end

--- Swap a tile with the one above (`delta` -1) or below (`delta` 1).
---@param section table
---@param index integer
---@param delta integer
---@return integer|false index The tile's new position.
---@return string? error
function debrief.moveTile(section, index, delta)
    return swap(section.tiles, index, delta)
end

--- Swap a series with the one above (`delta` -1) or below (`delta` 1).
---@param section table
---@param index integer
---@param seriesIndex integer
---@param delta integer
---@return integer|false seriesIndex The series' new position.
---@return string? error
function debrief.moveSeries(section, index, seriesIndex, delta)
    local tile = section.tiles[index]
    if not tile then
        return false, "no tile " .. tostring(index)
    end
    return swap(tile.series, seriesIndex, delta)
end

--- Set a tile's title.
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

--- The Link panel's readings in order, each named once; either may be unset.
local function linkSources(settings)
    local rssi = settings.rssiSource
    if rssi == nil then
        rssi = "RSSI"
    end
    local list = {}
    for _, source in ipairs({ settings.qualitySource or false, rssi or false }) do
        if named(source) and list[1] ~= source then
            list[#list + 1] = source
        end
    end
    return list
end

local function satelliteSource(settings)
    return named(settings.satelliteSource) and settings.satelliteSource or "Sats"
end

local ACCENTS = { cyan = true, green = true, orange = true, amber = true }

--- A series for one Chart or Metric reading. A lone reading's label is left
--- out, since the tile title names it; beside others it tells them apart.
--- Only Chart readings carry a range and color.
local function readingSeries(entry, statistic, chart, labelled)
    local series = { source = entry.source, statistic = statistic }
    if labelled and named(entry.label) then
        series.label = entry.label
    end
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

--- Sources whose readings fall toward danger, so a fill records their
--- minimum. Thresholds are the layout's, owned as the telemetry registry owns
--- them; a source without any follows the first Metric naming a direction.
local function fallingSources(panels, thresholds)
    local falling = {}
    for sensor, spec in pairs(thresholds or {}) do
        falling[sensor] = type(spec) == "table" and spec.falling == true
    end
    for _, panel in ipairs(panels) do
        if type(panel) == "table" and panel.type == "metric" then
            for _, entry in ipairs(entries(config(panel))) do
                local direction = entry.direction
                if falling[entry.source] == nil and (direction == "falling" or direction == "rising") then
                    falling[entry.source] = direction == "falling"
                end
            end
        end
    end
    return falling
end

--- Build a debrief from a layout's panels: what a pilot would want to see
--- after a flight with this dashboard. Every tile is Compact.
---@param panels table[] The layout's panels.
---@param present? fun(source: string): boolean Whether the model has a sensor.
---@param thresholds? table<string, table> The layout's thresholds by sensor.
---@return table section
function debrief.fromPanels(panels, present, thresholds)
    present = present or sensorPresent
    panels = type(panels) == "table" and panels or {}
    local falling, tiles, seen = fallingSources(panels, thresholds), {}, {}

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

    local ordered = {}
    for _, kind in ipairs({ "rx-battery", "link-status" }) do
        for _, panel in ipairs(panels) do
            if type(panel) == "table" and panel.type == kind then
                ordered[#ordered + 1] = panel
                break
            end
        end
    end
    for _, panel in ipairs(panels) do
        if type(panel) ~= "table" or panel.type ~= "rx-battery" and panel.type ~= "link-status" then
            ordered[#ordered + 1] = panel
        end
    end

    for _, panel in ipairs(ordered) do
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
            add(title(settings.label, "RX battery"), list)
        elseif kind == "link-status" and first then
            local list = {}
            for _, source in ipairs(linkSources(settings)) do
                if has(source) then
                    list[#list + 1] = { source = source, statistic = "min" }
                end
            end
            add(title(settings.label, "Link"), list)
        elseif kind == "navigation" and first then
            add("Speed", has("GSpd") and { { source = "GSpd", statistic = "max" } } or {})
            add(title(settings.label, "Navigation"), {
                { source = "HDst", statistic = "max" },
                { source = "FDst", statistic = "delta", label = "flown" },
            })
            local satellites = satelliteSource(settings)
            add("Satellites", has(satellites) and { { source = satellites, statistic = "min" } } or {})
        elseif kind == "chart" or kind == "metric" then
            local readings, statistics, used = {}, {}, {}
            for _, entry in ipairs(entries(settings)) do
                local source, statistic = entry.source, nil
                if kind == "metric" then
                    local base, suffix = string.match(source, "^(.-)([+-])$")
                    if base and has(base) then
                        source, statistic = base, suffix == "+" and "max" or "min"
                    end
                end
                statistic = statistic or (falling[source] and "min" or "max")
                if
                    #readings < debrief.MAX_SERIES
                    and has(source)
                    and (kind == "chart" or not used[source] or not used[source][statistic])
                then
                    local reading = entry
                    if source ~= entry.source then
                        reading = copy(entry)
                        reading.source = source
                    end
                    readings[#readings + 1] = reading
                    statistics[#readings] = statistic
                    used[source] = used[source] or {}
                    used[source][statistic] = true
                end
            end
            if
                kind == "metric"
                and (used.Alt or used.GAlt)
                and not used.VSpd
                and has("VSpd")
                and #readings < debrief.MAX_SERIES
            then
                readings[#readings + 1] = { source = "VSpd", label = "VSpeed" }
            end
            local list = {}
            for index, entry in ipairs(readings) do
                local statistic = statistics[index] or (falling[entry.source] and "min" or "max")
                list[index] = readingSeries(entry, statistic, kind == "chart", #readings > 1)
            end
            local head = readings[1]
            local name = head and title(head.label, head.source)
            add(kind == "chart" and title(settings.label, name) or name, list)
        end
        if #tiles == debrief.MAX_TILES then
            break
        end
    end
    return { size = "compact", tiles = tiles }
end

--- Replace a section's tiles with those built from the panels.
---@param section table
---@param panels table[]
---@param present? fun(source: string): boolean
---@param thresholds? table<string, table>
---@return integer count
function debrief.fill(section, panels, present, thresholds)
    section.tiles = debrief.fromPanels(panels, present, thresholds).tiles
    debrief.setSize(section, section.size or "compact")
    return #section.tiles
end

return debrief
