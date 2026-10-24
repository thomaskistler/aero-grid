-- SPDX-License-Identifier: GPL-2.0-only

-- Experimental rendering panel consuming the shared map-area contract.
local map = {
    id = "map-prototype",
    apiVersion = 1,
    supportedSpans = { "any" },
    refreshInterval = 2,
    settings = {
        { key = "label", label = "Label", type = "string", default = "MAP" },
        { key = "source", label = "GPS source", type = "string", default = "GPS" },
        { key = "headingSource", label = "Heading source", type = "string", default = "" },
        { key = "armSwitch", label = "Home arm switch", type = "string", default = "" },
        { key = "satelliteSource", label = "Satellite count source", type = "string", default = "" },
        { key = "satelliteWarning", label = "Warn below satellites", type = "number", default = 8 },
        { key = "satelliteCritical", label = "Critical below satellites", type = "number", default = 4 },
        { key = "showSatellites", label = "Show satellites", type = "boolean", default = true },
        { key = "showCoordinates", label = "Show coordinates", type = "boolean", default = false },
        {
            key = "flightPath",
            label = "Flight path",
            type = "string",
            default = "off",
            choices = { "off", "trail", "full" },
        },
    },
}

local TILE = 256
local LIMIT = 85.05112878
local MAX_SLOTS = 9
local MAX_AREA_NAME_BYTES = 240
local TRAIL_POINTS = 24
local FULL_PATH_POINTS = 64
local COORDINATE_PRECISION = 6

function map.meanCourse(context, bearing)
    local history = context.courseHistory or {}
    context.courseHistory = history
    local index = context.courseIndex or 1
    history[index] = bearing
    context.courseIndex = index % 5 + 1
    local east, north = 0, 0
    for _, sample in ipairs(history) do
        east = east + math.sin(math.rad(sample))
        north = north + math.cos(math.rad(sample))
    end
    -- Opposing directions have no meaningful mean; hold until it settles.
    if east * east + north * north > (#history * 0.2) ^ 2 then
        context.course = math.deg(math.atan(east, north)) % 360
    end
    return context.course
end

local function orientAircraft(aircraft, heading)
    heading = math.floor((heading or 0) / 10 + 0.5) * 10 % 360
    if aircraft.heading == heading then
        return
    end
    aircraft.heading = heading
    aircraft.file = aircraft.assets .. string.format("map-aircraft-%03d.png", heading)
end

local function createAircraft(parent, x, y, size, assets, follow)
    local aircraft = {
        assets = assets,
        heading = 0,
        file = assets .. (follow and "map-follow.png" or "map-aircraft-000.png"),
    }
    aircraft.root = lvgl.image(parent, {
        x = x,
        y = y,
        w = size,
        h = size,
        floating = true,
        file = function()
            return aircraft.file
        end,
    })
    return aircraft
end

local function integer(value, low, high)
    return type(value) == "number" and value == value and value % 1 == 0 and value >= low and value <= high
end

local function identifier(value)
    return type(value) == "string" and #value >= 1 and #value <= 32 and string.match(value, "^[a-z0-9_-]+$")
end

local function clamp(value, low, high)
    return math.max(low, math.min(value, high))
end

function map.validateSettings(settings)
    local errors = {}
    if settings.pack ~= nil then
        errors[#errors + 1] = "pack is no longer supported; installed map areas are selected from GPS"
    end
    if settings.headingSource ~= nil and type(settings.headingSource) ~= "string" then
        errors[#errors + 1] = "headingSource must be a source name or blank for GPS course"
    end
    if settings.satelliteSource ~= nil and type(settings.satelliteSource) ~= "string" then
        errors[#errors + 1] = "satelliteSource must be a source name or blank"
    end
    for _, key in ipairs({ "satelliteWarning", "satelliteCritical" }) do
        local value = settings[key]
        if
            value ~= nil
            and (type(value) ~= "number" or value ~= value or value < 0 or value == math.huge or value % 1 ~= 0)
        then
            errors[#errors + 1] = key .. " must be a nonnegative integer"
        end
    end
    if #errors == 0 and (settings.satelliteCritical or 4) > (settings.satelliteWarning or 8) then
        errors[#errors + 1] = "satelliteCritical must not exceed satelliteWarning"
    end
    if settings.showSatellites ~= nil and type(settings.showSatellites) ~= "boolean" then
        errors[#errors + 1] = "showSatellites must be a boolean"
    end
    if settings.showCoordinates ~= nil and type(settings.showCoordinates) ~= "boolean" then
        errors[#errors + 1] = "showCoordinates must be a boolean"
    end
    if
        settings.flightPath ~= nil
        and settings.flightPath ~= "off"
        and settings.flightPath ~= "trail"
        and settings.flightPath ~= "full"
    then
        errors[#errors + 1] = "flightPath must be off, trail, or full"
    end
    local arm = settings.armSwitch
    if arm ~= nil and arm ~= "" then
        if type(arm) ~= "string" or not (string.match(arm, "^S[A-Z][%^v%-]$") or string.match(arm, "^L%d%d$")) then
            errors[#errors + 1] =
                "armSwitch must be blank, a position such as SF^, SA-, SFv, or a logical switch such as L01"
        end
    end
    return errors
end

function map.validatePack(pack)
    assert(type(pack) == "table", "map pack must be a table")
    assert(pack.format == "aerogrid-map-area" and pack.version == 2, "unsupported map area")
    assert(identifier(pack.id) and identifier(pack.imagerySet), "invalid map area or imagery-set ID")
    assert(
        pack.projection == "EPSG:3857" and pack.tileScheme == "XYZ" and pack.tileSize == TILE,
        "unsupported map projection"
    )
    assert(pack.imageFormat == "jpeg", "map areas require JPEG tiles; regenerate PNG prototype packs")
    assert(
        type(pack.name) == "string"
            and #pack.name >= 1
            and #pack.name <= MAX_AREA_NAME_BYTES
            and string.match(pack.name, "^%s*(.-)%s*$") == pack.name,
        "invalid map area name"
    )
    local selection = pack.selection
    assert(type(selection) == "table", "map area requires selection metadata")
    assert(
        identifier(selection.radio)
            and (selection.coverageMode == "full-area-clamped" or selection.coverageMode == "per-zoom-clamped"),
        "invalid map selection metadata"
    )
    local bounds = selection.bounds
    assert(type(bounds) == "table", "invalid map selection bounds")
    local west, south, east, north = bounds.west, bounds.south, bounds.east, bounds.north
    assert(
        type(west) == "number"
            and type(south) == "number"
            and type(east) == "number"
            and type(north) == "number"
            and west >= -180
            and west <= 180
            and east >= -180
            and east <= 180
            and west ~= east
            and south >= -LIMIT
            and north <= LIMIT
            and south < north,
        "invalid map selection bounds"
    )
    assert(
        type(pack.levels) == "table" and #pack.levels >= 1 and #pack.levels <= 9,
        "map area requires 1-9 zoom levels"
    )
    local previous, total = nil, 0
    for _, level in ipairs(pack.levels) do
        assert(type(level) == "table" and integer(level.zoom, 11, 19), "invalid map zoom")
        local last = 2 ^ level.zoom - 1
        assert(
            integer(level.xMin, 0, last) and integer(level.xMax, level.xMin, level.xMin + last - 1),
            "invalid map x bounds"
        )
        assert(integer(level.yMin, 0, last) and integer(level.yMax, level.yMin, last), "invalid map y bounds")
        total = total + (level.xMax - level.xMin + 1) * (level.yMax - level.yMin + 1)
        assert(total <= 2000, "map area exceeds 2000 tiles")
        if previous then
            assert(level.zoom == previous.zoom + 1, "map zoom levels must be consecutive")
        end
        previous = level
    end
    return pack
end

function map.transform(level)
    local n = 2 ^ level.zoom
    return {
        west = level.xMin / n * 360 - 180,
        longitudeCenter = (level.xMin + level.xMax + 1) / 2 / n * 360 - 180,
        north = math.pi * (1 - 2 * level.yMin / n),
        xScale = n * TILE / 360,
        yScale = n * TILE / (2 * math.pi),
    }
end

-- Keep coordinates tile-local instead of rounding very large world-pixel values.
function map.project(level, latitude, longitude, transform)
    if
        type(latitude) ~= "number"
        or type(longitude) ~= "number"
        or latitude ~= latitude
        or longitude ~= longitude
        or math.abs(latitude) > LIMIT
        or math.abs(longitude) > 180
    then
        return nil
    end
    transform = transform or map.transform(level)
    longitude = longitude + math.floor((transform.longitudeCenter - longitude + 180) / 360) * 360
    local radians = latitude * math.pi / 180
    local mercator = math.log(math.tan(math.pi / 4 + radians / 2))
    return (longitude - transform.west) * transform.xScale, (transform.north - mercator) * transform.yScale
end

function map.clampView(level, width, height, x, y)
    local mapWidth = (level.xMax - level.xMin + 1) * TILE
    local mapHeight = (level.yMax - level.yMin + 1) * TILE
    -- Centre undersized coverage; never stretch tiles or invent extra coverage.
    return math.floor(mapWidth < width and (mapWidth - width) / 2 or clamp(x, 0, mapWidth - width)),
        math.floor(mapHeight < height and (mapHeight - height) / 2 or clamp(y, 0, mapHeight - height))
end

local function geometry(context, rect)
    assert(rect.w <= 480 and rect.h <= 272, "map prototype currently targets TX16S 480x272 only")
    local frame = context.themeBuilder.frame(context.theme, rect, context.fonts, nil, context.badgeText)
    local x = context.theme.spacing.accentWidth
    local width = math.max(1, rect.w - x)
    local height = math.max(1, rect.h)
    return {
        frame = frame,
        x = x,
        y = 0,
        w = width,
        h = height,
        controlsY = height - 22,
        zoomX = x + width - 48,
        zoomY = height - 148,
        showHint = width >= 240 and height >= 96,
        showZoom = width >= 100 and height >= 164,
    }
end

local function readPack(host, name)
    assert(identifier(name), "invalid map area ID")
    local directory = host.layoutStore.sdRoot(host.path) .. "AEROGRID/maps/"
    local filename = directory .. "areas/" .. name .. ".yaml"
    local info = fstat(filename)
    assert(info and integer(info.size, 1, 8192), "missing or oversized map area: " .. filename)
    local content, readError = host.layoutStore.readCandidate(filename)
    assert(content, readError)
    assert(type(content) == "string" and #content == info.size, "incomplete map area read: " .. filename)
    local pack, parseError = host.yaml.parse(content)
    assert(pack, parseError)
    map.validatePack(pack)
    assert(pack.id == name, "map area ID does not match its filename")
    return pack, directory .. "tiles/" .. pack.imagerySet .. "/"
end

function map.covers(pack, latitude, longitude)
    for _, level in ipairs(pack.levels) do
        local x, y = map.project(level, latitude, longitude)
        if
            not x
            or x < 0
            or y < 0
            or x >= (level.xMax - level.xMin + 1) * TILE
            or y >= (level.yMax - level.yMin + 1) * TILE
        then
            return false
        end
    end
    return true
end

function map.prefer(candidate, current)
    if not current then
        return true
    end
    local a, b = candidate.levels[#candidate.levels], current.levels[#current.levels]
    if a.zoom ~= b.zoom then
        return a.zoom > b.zoom
    end
    local areaA = (a.xMax - a.xMin + 1) * (a.yMax - a.yMin + 1)
    local areaB = (b.xMax - b.xMin + 1) * (b.yMax - b.yMin + 1)
    return areaA < areaB or (areaA == areaB and candidate.id < current.id)
end

local function tileFile(context, level, x, y)
    return context.directory .. string.format("%d/%d/%d.jpg", level.zoom, x % 2 ^ level.zoom, y)
end

function map.jpegHeader(header)
    if type(header) ~= "string" or string.sub(header, 1, 2) ~= "\255\216" then
        return false
    end
    local function word(offset)
        return string.byte(header, offset) * 256 + string.byte(header, offset + 1)
    end
    local offset, frame = 3, false
    while offset + 3 <= #header and string.byte(header, offset) == 255 do
        repeat
            offset = offset + 1
        until offset > #header or string.byte(header, offset) ~= 255
        if offset + 2 > #header then
            return false
        end
        local marker = string.byte(header, offset)
        offset = offset + 1
        if marker == 218 then
            return frame
        end
        if marker == 225 or marker == 217 then
            return false
        end
        local length = word(offset)
        if length < 2 or offset + length - 1 > #header then
            return false
        end
        if marker >= 192 and marker <= 207 and marker ~= 196 and marker ~= 200 and marker ~= 204 then
            if
                (marker ~= 192 and marker ~= 194)
                or length ~= 17
                or string.byte(header, offset + 2) ~= 8
                or word(offset + 3) ~= TILE
                or word(offset + 5) ~= TILE
                or string.byte(header, offset + 7) ~= 3
            then
                return false
            end
            frame = true
        end
        offset = offset + length
    end
    return false
end

local function checkTile(filename)
    local handle, openError = io.open(filename, "r")
    assert(handle, openError or ("missing map tile: " .. filename))
    -- Header preflight is bounded. Actual decode failures remain a firmware limitation.
    ---@diagnostic disable-next-line: param-type-mismatch
    local header = io.read(handle, 4096)
    io.close(handle)
    assert(map.jpegHeader(header), "map tile must be a 256x256 8-bit RGB JPEG without EXIF: " .. filename)
end

local function setStatus(context, text)
    local healthy = text == "GPS"
    local state = healthy and context.satelliteState or nil
    if context.statusText ~= text or context.badgeState ~= state then
        local previousState = context.badgeState
        context.statusText, context.badgeState = text, state
        local presentation = context.state(state or "warning", "cyan")
        local badge = state and presentation.badge or (healthy and "" or text)
        if state and state ~= "normal" then
            context.primitives.stylePanel(context.panel, presentation)
        elseif previousState and previousState ~= "normal" then
            context.primitives.stylePanel(context.panel, context.state("normal", "cyan"))
        end
        context.primitives.setBadge(
            context,
            context.themeBuilder,
            context.badge,
            context.area.frame,
            context.fonts.badge,
            badge,
            state and presentation.accent or context.theme.color.amber
        )
    end
end

local function satelliteCount(reading)
    local value = reading and reading.available and reading.value
    if type(value) == "number" and value == value and value >= 0 and value < math.huge and value % 1 == 0 then
        return value
    end
end

local function validCoordinates(latitude, longitude)
    return type(latitude) == "number"
        and type(longitude) == "number"
        and latitude == latitude
        and longitude == longitude
        and math.abs(latitude) <= LIMIT
        and math.abs(longitude) <= 180
        and math.abs(latitude) < math.huge
        and math.abs(longitude) < math.huge
end

local function updateSatelliteState(context)
    local settings = context.settings
    if not context.satellites then
        context.satelliteState = nil
        return
    end
    local count = satelliteCount(context.satellites)
    local state
    if count == nil then
        state = "unavailable"
    elseif context.satellites.stale then
        state = "stale"
    elseif count < (settings.satelliteCritical or 4) then
        state = "critical"
    elseif count < (settings.satelliteWarning or 8) then
        state = "warning"
    else
        state = "normal"
    end
    context.satelliteState = state
    if
        context.satelliteHeader
        and (
            context.satelliteHeaderState ~= state
            or context.satelliteHeaderCount ~= count
            or context.satelliteHeaderFrame ~= context.area.frame
        )
    then
        context.satelliteHeaderState = state
        context.satelliteHeaderCount = count
        context.satelliteHeaderFrame = context.area.frame
        local presentation = context.state(state, "cyan")
        local text = count and string.format("%.0f", count) or "--"
        local builder, frame, fonts = context.themeBuilder, context.area.frame, context.fonts
        local headingWidth = builder.headingWidth(frame, fonts.badge, presentation.badge)
        local heading, font = builder.fitHeading(settings.label, headingWidth, fonts.label, fonts.badge)
        local left = frame.labelX + builder.measureText(font, heading) + 6
        local right = frame.badgeX + frame.badgeWidth
        if presentation.badge and presentation.badge ~= "" then
            right = context.primitives.badgeX(builder, frame, fonts.badge, presentation.badge) - 6
        end
        local width = 18 + builder.measureText(fonts.label, text)
        local height = math.max(16, builder.fontHeight(fonts.label))
        local visible = not frame.labelHidden and right - width >= left and frame.labelY + height <= frame.top
        if visible then
            context.satelliteHeader:set({ x = right - width, y = frame.labelY, w = width, h = height })
            context.primitives.setFont(context.satelliteLabel, fonts.label)
            context.satelliteLabel:set({ text = text, w = width - 18, color = presentation.label })
            lvgl.show(context.satelliteHeader)
        else
            lvgl.hide(context.satelliteHeader)
        end
    end
end

local function recordPath(context)
    local feed = context.feed
    local mode = context.settings.flightPath or "off"
    if
        mode == "off"
        or not feed
        or not feed.known
        or not feed.fix
        or feed.state ~= "normal"
        or not validCoordinates(feed.latitude, feed.longitude)
    then
        context.pathBreak = true
        return
    end
    if not context.pack then
        return
    end
    local now = getTime()
    if context.pathLastTime and now - context.pathLastTime < 100 then
        return
    end
    if not context.navigation then
        context.pathBreak = true
        return
    end
    local points = context.pathPoints
    local previous = points[#points]
    if
        previous
        and not context.pathBreak
        and context.navigation.distanceBetween(previous.latitude, previous.longitude, feed.latitude, feed.longitude)
            < 5
    then
        return
    end
    local point = {
        latitude = feed.latitude,
        longitude = feed.longitude,
        breakBefore = context.pathBreak or previous == nil,
    }
    context.pathBreak, context.pathLastTime = false, now
    if mode == "trail" then
        points[#points + 1] = point
        if #points > TRAIL_POINTS then
            table.remove(points, 1)
            if points[1] then
                points[1].breakBefore = true
            end
        end
    else
        if #points == FULL_PATH_POINTS then
            local compacted = {}
            for index = 1, #points, 2 do
                local retained = points[index]
                retained.breakBefore = retained.breakBefore or index > 1 and points[index - 1].breakBefore
                compacted[#compacted + 1] = retained
            end
            context.pathPoints = compacted
            points = compacted
        end
        points[#points + 1] = point
    end
end

local function drawPath(context)
    local points = context.pathPoints
    local level = context.pack.levels[context.levelIndex]
    for index, line in ipairs(context.pathLines) do
        local lineState = context.pathLineStates[index]
        local first = points[index]
        local second = points[index + 1]
        local visible = first ~= nil and second ~= nil and not second.breakBefore
        if visible then
            local x1, y1 = map.project(level, first.latitude, first.longitude, context.transform)
            local x2, y2 = map.project(level, second.latitude, second.longitude, context.transform)
            if x1 and x2 then
                local firstX, firstY = math.floor(x1 - context.viewX + 0.5), math.floor(y1 - context.viewY + 0.5)
                local secondX, secondY = math.floor(x2 - context.viewX + 0.5), math.floor(y2 - context.viewY + 0.5)
                if
                    lineState.firstX ~= firstX
                    or lineState.firstY ~= firstY
                    or lineState.secondX ~= secondX
                    or lineState.secondY ~= secondY
                then
                    line:set({ pts = { { firstX, firstY }, { secondX, secondY } } })
                    lineState.firstX, lineState.firstY, lineState.secondX, lineState.secondY =
                        firstX, firstY, secondX, secondY
                end
                if not lineState.visible then
                    lvgl.show(line)
                    lineState.visible = true
                end
            else
                visible = false
            end
        end
        if not visible and lineState.visible then
            lvgl.hide(line)
            lineState.visible = false
        end
    end
end

local function updateCoordinates(context)
    if not context.coordinatesLabel then
        return
    end
    local feed = context.feed
    local valid = feed
        and feed.known
        and feed.fix
        and feed.state == "normal"
        and validCoordinates(feed.latitude, feed.longitude)
    local text = valid
            and string.format(
                "%." .. COORDINATE_PRECISION .. "f, %." .. COORDINATE_PRECISION .. "f",
                feed.latitude,
                feed.longitude
            )
        or "--"
    if context.coordinateText ~= text then
        context.coordinatesLabel:set({ text = text })
        context.coordinateText = text
    end
    local width = math.max(1, context.area.w - 56)
    local visible = valid and width >= context.themeBuilder.measureText(TINSIZE, text)
    context.primitives.reconcile(context.coordinatesLabel, visible)
end

local function hideMarker(context)
    if context.markerVisible then
        lvgl.hide(context.marker)
        context.markerVisible = false
    end
end

local function hideHome(context)
    if context.homeVisible then
        lvgl.hide(context.homeMarker)
        context.homeVisible = false
    end
end

local function updateHome(context)
    local feed = context.feed
    local x, y
    if feed and feed.home then
        x, y = map.project(
            context.pack.levels[context.levelIndex],
            feed.pilotLatitude,
            feed.pilotLongitude,
            context.transform
        )
    end
    if not x then
        hideHome(context)
        return
    end
    x, y = math.floor(x - context.viewX + 0.5), math.floor(y - context.viewY + 0.5)
    local visible = x >= 0 and y >= 0 and x < context.area.w and y < context.area.h
    if x ~= context.homeX or y ~= context.homeY then
        context.homeMarker:set({ x = x - 24, y = y - 50 })
        context.homeX, context.homeY = x, y
    end
    if context.homeVisible ~= visible then
        context.primitives.reconcile(context.homeMarker, visible)
        context.homeVisible = visible
    end
end

function map.move(context, dx, dy, zoom)
    if not context.pack then
        return
    end
    if context.pending and zoom then
        return
    end
    local old = context.pack.levels[context.levelIndex]
    local index = clamp(context.levelIndex + (zoom or 0), 1, #context.pack.levels)
    local level = context.pack.levels[index]
    local x, y = context.viewX + dx, context.viewY + dy
    if index ~= context.levelIndex then
        context.followPan, context.followSample = nil, nil
        local factor = 2 ^ (level.zoom - old.zoom)
        x = (context.viewX + context.area.w / 2) * factor + (old.xMin * factor - level.xMin) * TILE - context.area.w / 2
        local worldWidth = 2 ^ level.zoom * TILE
        local coverageCenter = (level.xMax - level.xMin + 1) * TILE / 2
        x = x + math.floor((coverageCenter - x - context.area.w / 2) / worldWidth + 0.5) * worldWidth
        y = (context.viewY + context.area.h / 2) * factor + (old.yMin * factor - level.yMin) * TILE - context.area.h / 2
    end
    x, y = map.clampView(level, context.area.w, context.area.h, x, y)
    if x ~= context.viewX or y ~= context.viewY or index ~= context.levelIndex then
        context.levelIndex, context.viewX, context.viewY = index, x, y
        context.pending = nil
        context.dirty = true
    end
end

local function prepareView(context)
    local level = context.pack.levels[context.levelIndex]
    context.transform = map.transform(level)
    local area = context.area
    local wanted, used = {}, {}
    local firstX = math.max(level.xMin, level.xMin + math.floor(context.viewX / TILE))
    local firstY = math.max(level.yMin, level.yMin + math.floor(context.viewY / TILE))
    local lastX = math.min(level.xMax, level.xMin + math.floor((context.viewX + area.w - 1) / TILE))
    local lastY = math.min(level.yMax, level.yMin + math.floor((context.viewY + area.h - 1) / TILE))
    for y = firstY, lastY do
        for x = firstX, lastX do
            wanted[#wanted + 1] = {
                file = tileFile(context, level, x, y),
                x = (x - level.xMin) * TILE - context.viewX,
                y = (y - level.yMin) * TILE - context.viewY,
            }
        end
    end
    assert(#wanted <= MAX_SLOTS, "map tile pool exhausted")
    for _, tile in ipairs(wanted) do
        for index, slot in ipairs(context.tiles) do
            if slot.file == tile.file then
                tile.slot = slot
                tile.retained = slot.visible
                used[index] = true
                break
            end
        end
    end
    local cursor = 1
    for _, tile in ipairs(wanted) do
        if not tile.slot then
            while used[cursor] do
                cursor = cursor + 1
            end
            tile.slot = context.tiles[cursor]
            used[cursor] = true
        end
    end
    local pending = {}
    for _, tile in ipairs(wanted) do
        local slot = tile.slot
        if tile.retained then
            if slot.x ~= tile.x or slot.y ~= tile.y then
                slot.image:set({ x = tile.x, y = tile.y })
                slot.x, slot.y = tile.x, tile.y
            end
        else
            lvgl.hide(slot.image)
            slot.visible = false
            pending[#pending + 1] = tile
        end
    end
    for index, slot in ipairs(context.tiles) do
        if not used[index] then
            if slot.visible ~= false then
                lvgl.hide(slot.image)
            end
            slot.visible = false
            slot.file = ""
            slot.x, slot.y = nil, nil
        end
    end
    context.pending, context.nextTile, context.dirty = #pending > 0 and pending or nil, 1, false
    context.markerLatitude, context.markerLongitude = nil, nil
    if context.pending then
        setStatus(context, "LOADING")
    else
        context.viewChanges = context.viewChanges + 1
    end
end

local function loadTile(context)
    local tile = context.pending[context.nextTile]
    if tile then
        local slot = tile.slot
        if slot.file ~= tile.file then
            checkTile(tile.file)
            slot.file = tile.file
            context.tileLoads = context.tileLoads + 1
        end
        slot.image:set({ x = tile.x, y = tile.y })
        slot.x, slot.y = tile.x, tile.y
        lvgl.show(slot.image)
        slot.visible = true
        context.nextTile = context.nextTile + 1
    end
    if context.nextTile > #context.pending then
        context.pending = nil
        context.viewChanges = context.viewChanges + 1
    end
end

local function followAircraft(context)
    local feed = context.feed
    if not context.following or context.drag or not feed or not feed.known or not feed.fix or feed.state == "stale" then
        context.followPan, context.followSample = nil, nil
        return
    end
    local level = context.pack.levels[context.levelIndex]
    local x, y = map.project(level, feed.latitude, feed.longitude)
    if not x then
        context.followPan, context.followSample = nil, nil
        return
    end
    local now = getTime()
    local sample = context.followSample
    if not sample then
        sample = { x = x, y = y, time = now, vx = 0, vy = 0 }
        context.followSample = sample
    elseif now - sample.time >= 20 then
        local elapsed = (now - sample.time) / 100
        local weight = math.min(1, elapsed)
        sample.vx = sample.vx + ((x - sample.x) / elapsed - sample.vx) * weight
        sample.vy = sample.vy + ((y - sample.y) / elapsed - sample.vy) * weight
        sample.x, sample.y, sample.time = x, y, now
    end
    local area = context.area
    local screenX, screenY = x - context.viewX, y - context.viewY
    local edgeTime = math.huge
    if math.abs(sample.vx) > 0.5 then
        edgeTime = math.min(edgeTime, math.max(0, sample.vx > 0 and area.w - screenX or screenX) / math.abs(sample.vx))
    end
    if math.abs(sample.vy) > 0.5 then
        edgeTime = math.min(edgeTime, math.max(0, sample.vy > 0 and area.h - screenY or screenY) / math.abs(sample.vy))
    end
    local pan = context.followPan
    if
        not pan
        and (screenX < area.w * 0.2 or screenX > area.w * 0.8 or screenY < area.h * 0.2 or screenY > area.h * 0.8)
    then
        local targetX, targetY = map.clampView(level, area.w, area.h, x - area.w / 2, y - area.h / 2)
        if targetX == context.viewX and targetY == context.viewY then
            return
        end
        pan = {
            x = context.viewX,
            y = context.viewY,
            targetX = targetX,
            targetY = targetY,
            started = now,
            duration = clamp(edgeTime / 3, 0.5, 3) * 100,
        }
        context.followPan = pan
    end
    if pan then
        if edgeTime < 0.75 and pan.started + pan.duration - now > 50 then
            pan.x, pan.y, pan.started, pan.duration = context.viewX, context.viewY, now, 50
        end
        local progress = clamp((now - pan.started) / pan.duration, 0, 1)
        local eased = progress * progress * (3 - 2 * progress)
        local nextX = math.floor(pan.x + (pan.targetX - pan.x) * eased + 0.5)
        local nextY = math.floor(pan.y + (pan.targetY - pan.y) * eased + 0.5)
        map.move(context, nextX - context.viewX, nextY - context.viewY)
        if progress == 1 then
            context.followPan = nil
        end
    end
end

local function updateMarker(context)
    local feed = context.feed
    local state = not feed and "NO GPS"
        or not feed.known and "NO GPS"
        or feed.state == "stale" and "GPS STALE"
        or not feed.fix and "NO FIX"
    if state then
        hideMarker(context)
        hideHome(context)
        setStatus(context, state)
        context.markerLatitude, context.markerLongitude = nil, nil
        context.courseLatitude, context.courseLongitude = nil, nil
        context.courseHistory, context.courseIndex = nil, nil
        return
    end
    local positionChanged = feed.latitude ~= context.markerLatitude or feed.longitude ~= context.markerLongitude
    context.markerLatitude, context.markerLongitude = feed.latitude, feed.longitude
    local level = context.pack.levels[context.levelIndex]
    local x, y = map.project(level, feed.latitude, feed.longitude, context.transform)
    if not x then
        hideMarker(context)
        hideHome(context)
        setStatus(context, "INVALID GPS")
        context.courseLatitude, context.courseLongitude = nil, nil
        context.courseHistory, context.courseIndex = nil, nil
        return
    end
    local heading
    if context.settings.headingSource and context.settings.headingSource ~= "" then
        local reading = context.headingFeed
        if
            reading
            and reading.available
            and reading.fresh
            and not reading.stale
            and type(reading.value) == "number"
            and reading.value == reading.value
            and math.abs(reading.value) < math.huge
        then
            heading = reading.value % 360
        end
    else
        if
            context.courseLatitude
            and positionChanged
            and (feed.latitude ~= context.courseLatitude or feed.longitude ~= context.courseLongitude)
        then
            local distance = context.navigation.distanceBetween(
                context.courseLatitude,
                context.courseLongitude,
                feed.latitude,
                feed.longitude
            )
            -- Accumulate sub-metre changes instead of turning on stationary GPS noise.
            if distance >= 1 then
                local bearing = context.navigation.bearingBetween(
                    context.courseLatitude,
                    context.courseLongitude,
                    feed.latitude,
                    feed.longitude
                )
                map.meanCourse(context, bearing)
                context.courseLatitude, context.courseLongitude = feed.latitude, feed.longitude
            end
        elseif not context.courseLatitude then
            context.courseLatitude, context.courseLongitude = feed.latitude, feed.longitude
            context.course = nil
            context.courseHistory, context.courseIndex = nil, nil
        end
        heading = context.course
    end
    context.heading = heading
    orientAircraft(context.aircraft, heading or context.aircraft.heading)
    x, y = math.floor(x - context.viewX + 0.5), math.floor(y - context.viewY + 0.5)
    updateHome(context)
    if x < 6 or y < 6 or x >= context.area.w - 6 or y >= context.area.h - 6 then
        hideMarker(context)
        setStatus(context, "OFF VIEW")
        return
    end
    if x ~= context.markerX or y ~= context.markerY then
        context.marker:set({ x = x - 26, y = y - 26 })
        context.markerX, context.markerY = x, y
        context.markerMoves = context.markerMoves + 1
    end
    if not context.markerVisible then
        lvgl.show(context.marker)
        context.markerVisible = true
    end
    setStatus(context, "GPS")
end

local function previewDrag(context, dx, dy)
    for _, slot in ipairs(context.tiles) do
        if slot.x then
            slot.image:set({ x = slot.x + dx, y = slot.y + dy })
        end
    end
end

local function cancelDrag(context)
    if context.drag then
        previewDrag(context, 0, 0)
        context.drag = nil
    end
end

local function controlAt(context, touch, rect)
    if not context.area.showZoom or not touch or not rect then
        return nil
    end
    local x, y = touch.x - rect.x - context.area.zoomX, touch.y - rect.y - context.area.zoomY
    if x < 0 or x >= 40 then
        return nil
    end
    for index, top in ipairs({ 44, 76, 0, 108 }) do
        if y >= top and y < top + (index == 3 and 40 or 32) then
            return index
        end
    end
end

local function activateControl(context, index)
    local now = getTime()
    if context.lastControl == index and now - (context.lastControlTime or 0) < 15 then
        return
    end
    context.lastControl, context.lastControlTime = index, now
    if index == 4 then
        local feed = context.feed
        context.locationDetailsRequested = feed and feed.known and feed.fix and feed.state == "normal" or false
    elseif index == 3 then
        context.following = true
        context.followPan, context.followSample = nil, nil
    else
        map.move(context, 0, 0, index == 1 and 1 or -1)
    end
end

function map.event(context, event, touch, rect)
    if not context.pack or not lvgl.isFullScreen() then
        cancelDrag(context)
        context.controlPress = nil
        return false
    end
    if event == _G.EVT_TOUCH_TAP then
        local control = controlAt(context, touch, rect)
        if control then
            local cancelled = context.controlPress and context.controlPress.cancelled
            context.controlPress, context.drag = nil, nil
            if not cancelled and getTime() >= (context.cancelledControlUntil or 0) then
                activateControl(context, control)
            end
            return true
        end
    end
    if context.controlPress then
        local press = context.controlPress
        if event == _G.EVT_TOUCH_SLIDE and touch then
            if
                math.abs(touch.x - press.x) >= 8
                or math.abs(touch.y - press.y) >= 8
                or controlAt(context, touch, rect) ~= press.index
            then
                press.cancelled = true
            end
        elseif event == _G.EVT_TOUCH_BREAK or event == _G.EVT_TOUCH_TAP then
            context.controlPress = nil
            -- Native BREAK can report (0, 0); use the last slide in that case.
            if touch and (touch.x ~= 0 or touch.y ~= 0) and controlAt(context, touch, rect) ~= press.index then
                press.cancelled = true
            end
            if not press.cancelled then
                activateControl(context, press.index)
            else
                context.cancelledControlUntil = getTime() + 15
            end
        end
        return true
    end
    if event == _G.EVT_TOUCH_FIRST then
        if context.drag then
            return true
        end
        local control = controlAt(context, touch, rect)
        if control then
            context.controlPress = { index = control, x = touch.x, y = touch.y }
            return true
        end
        if context.pending or context.dirty or not touch or not rect then
            return false
        end
        local x, y = touch.x - rect.x - context.area.x, touch.y - rect.y - context.area.y
        local zoomX, zoomY = touch.x - rect.x - context.area.zoomX, touch.y - rect.y - context.area.zoomY
        if context.area.showZoom and zoomX >= 0 and zoomX < 40 and zoomY >= 0 and zoomY < 140 then
            return true
        end
        if x < 0 or y < 0 or x >= context.area.w or y >= context.area.h then
            return false
        end
        context.drag = {
            x = touch.x,
            y = touch.y,
            startViewX = context.viewX,
            startViewY = context.viewY,
        }
        return true
    end
    local drag = context.drag
    if not drag then
        return false
    end
    if event == _G.EVT_TOUCH_SLIDE and touch then
        if math.abs(touch.x - drag.x) >= 8 or math.abs(touch.y - drag.y) >= 8 then
            context.following = false
            context.followPan, context.followSample = nil, nil
        end
        local x, y = map.clampView(
            context.pack.levels[context.levelIndex],
            context.area.w,
            context.area.h,
            drag.startViewX + drag.x - touch.x,
            drag.startViewY + drag.y - touch.y
        )
        if x ~= context.viewX or y ~= context.viewY then
            previewDrag(context, context.viewX - x, context.viewY - y)
            local dx, dy = x - context.viewX, y - context.viewY
            for _, slot in ipairs(context.tiles) do
                if slot.x then
                    slot.x, slot.y = slot.x - dx, slot.y - dy
                end
            end
            map.move(context, dx, dy)
            updateMarker(context)
        end
        return true
    elseif event == _G.EVT_TOUCH_BREAK or event == _G.EVT_TOUCH_TAP then
        context.drag = nil
        return true
    end
    return false
end

local function updateControls(context)
    local interactive = context.pack ~= nil and lvgl.isFullScreen() and context.area.showZoom
    if context.interactive == interactive then
        return
    end
    context.interactive = interactive
    if not interactive and #context.controls > 0 then
        context.controlPress = nil
        context.controlsRoot:clear()
        context.controls = {}
        context.followAircraft, context.followIcon = nil, nil
        context.infoIcon = nil
    end
    if interactive and #context.controls == 0 then
        local actions = { { "+", 44, 1 }, { "-", 76, -1 }, { "target", 0 }, { "GPS", 108 } }
        for index, action in ipairs(actions) do
            context.controls[index] = lvgl.rectangle(context.controlsRoot, {
                x = 4,
                y = action[2] + (index == 3 and 4 or 0),
                w = 32,
                h = index == 1 and 64 or 32,
                color = lcd.RGB(0x101414),
                rounded = 5,
                filled = true,
            })
            local y = action[2]
            local white = lcd.RGB(0xFFFFFF)
            if index == 4 then
                context.infoIcon = lvgl.image(context.controlsRoot, {
                    x = 8,
                    y = y + 4,
                    w = 24,
                    h = 24,
                    floating = true,
                    file = context.assets .. "map-info.png",
                })
            elseif action[3] then
                lvgl.rectangle(
                    context.controlsRoot,
                    { x = 13, y = y + 15, w = 14, h = 2, filled = true, color = white }
                )
                if action[3] == 1 then
                    lvgl.rectangle(
                        context.controlsRoot,
                        { x = 19, y = y + 9, w = 2, h = 14, filled = true, color = white }
                    )
                end
            else
                context.followAircraft = createAircraft(context.controlsRoot, 8, y + 8, 24, context.assets, true)
                context.followIcon = context.followAircraft.root
            end
        end
        lvgl.rectangle(context.controlsRoot, { x = 9, y = 76, w = 22, h = 1, filled = true, color = lcd.RGB(0x333737) })
    end
    context.primitives.reconcile(context.controlsHint, not lvgl.isFullScreen() and context.area.showHint)
end

local function selectArea(context)
    local feed = context.feed
    if not feed or not feed.known or not feed.fix or feed.state ~= "normal" then
        return
    end
    if context.pack then
        if not map.project(context.pack.levels[context.levelIndex], feed.latitude, feed.longitude) then
            return
        end
        if map.covers(context.pack, feed.latitude, feed.longitude) then
            return
        end
    end
    if context.pack then
        cancelDrag(context)
        hideMarker(context)
        hideHome(context)
        for _, slot in ipairs(context.tiles) do
            lvgl.hide(slot.image)
            slot.visible = false
        end
        context.pack, context.directory, context.pending = nil, nil, nil
        context.followPan, context.followSample, context.controlPress = nil, nil, nil
        context.courseHistory, context.courseIndex, context.courseLatitude, context.courseLongitude = nil, nil, nil, nil
        context.dirty = false
        context.nextDiscovery = nil
    end
    if not context.discovery then
        if getTime() < (context.nextDiscovery or 0) then
            return
        end
        local folder = context.host.layoutStore.sdRoot(context.host.path) .. "AEROGRID/maps/areas/"
        context.nextDiscovery = getTime() + 1000
        if not fstat(folder) then
            context.discoveryStatus = "NO INSTALLED MAP"
            return
        end
        assert(type(dir) == "function", "map discovery requires EdgeTX directory access")
        local iterator = dir(folder)
        assert(type(iterator) == "function", "unable to list installed map areas: " .. folder)
        context.discovery = {
            iterator = iterator,
            entries = 0,
            areas = 0,
            latitude = feed.latitude,
            longitude = feed.longitude,
        }
    end
    local scan = context.discovery
    context.discoveryStatus = "FINDING MAP"
    local filename = scan.iterator()
    if filename then
        scan.entries = scan.entries + 1
        assert(scan.entries <= 256, "map areas directory exceeds 256 entries")
        local name = string.match(filename, "^(.*)%.yaml$")
        if name then
            scan.areas = scan.areas + 1
            assert(scan.areas <= 64, "automatic map selection supports at most 64 installed areas")
            local pack, directory = readPack(context.host, name)
            if map.covers(pack, scan.latitude, scan.longitude) and map.prefer(pack, scan.best) then
                scan.best, scan.directory = pack, directory
            end
        end
        return
    end
    context.discovery = nil
    if not scan.best or not map.covers(scan.best, feed.latitude, feed.longitude) then
        context.discoveryStatus = "NO MAP AT GPS"
        context.nextDiscovery = getTime() + 1000
        return
    end
    context.pack, context.directory = scan.best, scan.directory
    context.levelIndex, context.viewX, context.viewY = 1, 0, 0
    context.following, context.dirty = true, true
    context.markerLatitude, context.markerLongitude = nil, nil
    local level = context.pack.levels[1]
    local x, y = map.project(level, feed.latitude, feed.longitude)
    context.viewX, context.viewY =
        map.clampView(level, context.area.w, context.area.h, x - context.area.w / 2, y - context.area.h / 2)
end

function map.refresh(context)
    updateSatelliteState(context)
    if context.automatic then
        selectArea(context)
    end
    updateControls(context)
    if not lvgl.isFullScreen() then
        cancelDrag(context)
    end
    recordPath(context)
    if not context.pack then
        local feed = context.feed
        local live = feed and feed.known and feed.fix and feed.state == "normal"
        setStatus(context, live and (context.discoveryStatus or "FINDING MAP") or "WAITING FOR GPS")
        updateCoordinates(context)
        return
    end
    followAircraft(context)
    if context.dirty then
        prepareView(context)
    end
    drawPath(context)
    if context.pending and getTime() >= (context.nextTileLoad or 0) then
        loadTile(context)
        context.nextTileLoad = getTime() + 25
    end
    updateMarker(context)
    updateCoordinates(context)
end

function map.create(parent, rect, settings, services)
    local context = {
        automatic = true,
        host = services.host,
        pack = nil,
        directory = nil,
        settings = settings,
        theme = services.theme,
        themeBuilder = services.themeBuilder,
        primitives = services.primitives,
        state = services.state,
        fonts = services.fonts,
        levelIndex = 1,
        tiles = {},
        controls = {},
        pathPoints = {},
        pathLines = {},
        pathLineStates = {},
        tileLoads = 0,
        viewChanges = 0,
        markerMoves = 0,
        dirty = false,
        following = true,
    }
    context.area = geometry(context, rect)
    local area = context.area
    local presentation = services.state("normal", "cyan")
    context.panel = services.primitives.panel(parent, rect, services.theme, presentation)
    context.viewport = lvgl.box(context.panel.root, {
        x = area.x,
        y = area.y,
        w = area.w,
        h = area.h,
        scrollDir = 0,
        scrollBar = false,
    })
    for index = 1, MAX_SLOTS do
        local slot = { file = "" }
        slot.image = lvgl.image(context.viewport, {
            x = 0,
            y = 0,
            w = TILE,
            h = TILE,
            floating = true,
            file = function()
                return slot.file
            end,
        })
        context.tiles[index] = slot
        lvgl.hide(slot.image)
        slot.visible = false
    end
    if (settings.flightPath or "off") ~= "off" then
        local lineCount = settings.flightPath == "trail" and TRAIL_POINTS - 1 or FULL_PATH_POINTS - 1
        for index = 1, lineCount do
            context.pathLines[index] = lvgl.line(context.viewport, {
                pts = { { 0, 0 }, { 0, 0 } },
                thickness = 2,
                color = services.theme.color.green,
            })
            lvgl.hide(context.pathLines[index])
            context.pathLineStates[index] = { visible = false }
        end
    end
    if settings.showCoordinates then
        context.coordinatesLabel = services.primitives.label(context.panel.root, services.theme, {
            x = area.x + 4,
            y = area.h - 20,
            w = math.max(1, area.w - 56),
            text = "",
            font = TINSIZE,
            color = services.theme.color.text,
        })
        lvgl.hide(context.coordinatesLabel)
    end
    local assets = services.host.path .. "assets/"
    context.assets = assets
    context.homeMarker = lvgl.image(context.viewport, {
        x = 0,
        y = 0,
        w = 52,
        h = 52,
        floating = true,
        file = assets .. "map-home.png",
    })
    lvgl.hide(context.homeMarker)
    context.aircraft = createAircraft(context.viewport, 0, 0, 52, assets, false)
    context.marker = context.aircraft.root
    lvgl.hide(context.marker)
    context.label, context.badge = services.primitives.header(
        context.panel.root,
        services.theme,
        area.frame,
        services.fonts,
        settings.label,
        presentation,
        services.themeBuilder
    )
    context.controlsHint = services.primitives.label(context.panel.root, services.theme, {
        x = area.x + 16,
        y = area.controlsY,
        w = math.max(1, area.w - 32),
        text = "Hold for fullscreen",
        font = TINSIZE,
        color = services.theme.color.textMuted,
    })
    context.controlsRoot = lvgl.box(context.panel.root, {
        x = area.zoomX,
        y = area.zoomY,
        w = 40,
        h = 140,
        scrollDir = 0,
        scrollBar = false,
    })
    updateControls(context)
    if services.navigation then
        context.navigation = services.navigation
        context.feed = services.navigation:subscribe(settings.source, settings.armSwitch)
    end
    if settings.headingSource and settings.headingSource ~= "" and services.telemetry then
        context.headingFeed = services.telemetry:subscribe(settings.headingSource)
    end
    if settings.satelliteSource and settings.satelliteSource ~= "" then
        assert(services.telemetry, "map satellite count requires telemetry service")
        context.satellites = services.telemetry:subscribe(settings.satelliteSource)
        if settings.showSatellites ~= false then
            context.satelliteHeader = lvgl.box(context.panel.root, { x = 0, y = 0, w = 1, h = 1 })
            local filename = assets .. (services.theme.light and "satellite-light.png" or "satellite.png")
            local handle = io.open(filename, "r")
            assert(handle, "map satellite icon missing: " .. filename)
            io.close(handle)
            services.primitives.image(context.satelliteHeader, {
                x = 0,
                y = 0,
                w = 16,
                h = 16,
                file = filename,
            })
            context.satelliteLabel = services.primitives.label(context.satelliteHeader, services.theme, {
                x = 18,
                y = 0,
                text = "",
                font = services.fonts.label,
                color = services.theme.color.textMuted,
            })
            lvgl.hide(context.satelliteHeader)
        end
    end
    return context
end

function map.update(context, rect)
    cancelDrag(context)
    context.controlPress = nil
    context.followPan, context.followSample = nil, nil
    context.area = geometry(context, rect)
    local area = context.area
    context.primitives.resizeHeader(context, rect, area.frame, context.settings.label)
    context.viewport:set({ x = area.x, y = area.y, w = area.w, h = area.h })
    context.controlsHint:set({ x = area.x + 16, y = area.controlsY, w = math.max(1, area.w - 32) })
    context.controlsRoot:set({ x = area.zoomX, y = area.zoomY, h = 140 })
    if context.coordinatesLabel then
        context.coordinatesLabel:set({ x = area.x + 4, y = area.h - 20, w = math.max(1, area.w - 56) })
    end
    if context.satelliteHeader then
        updateSatelliteState(context)
    end
    updateControls(context)
    if context.pack then
        context.viewX, context.viewY =
            map.clampView(context.pack.levels[context.levelIndex], area.w, area.h, context.viewX, context.viewY)
        context.pending, context.dirty = nil, true
    end
end

return map
