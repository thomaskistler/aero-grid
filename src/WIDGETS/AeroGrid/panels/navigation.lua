-- SPDX-License-Identifier: GPL-2.0-only

--- GPS position, distance to home, and the north-up bearing from home.
---
--- Direction is measured from home toward the model, not aircraft heading
--- or transmitter orientation. The tape scrolls this bearing beneath a fixed
--- pointer; the alternative bearing row reports the same measurement as text.
---
--- A GPS source returns a table, and every field in it can be missing. Three
--- degraded states matter and are reported separately, because each has a
--- different cause and a different fix:
---
--- - No source: the layout names a sensor the radio does not have.
--- - No fix: the sensor is there and reporting, but has no position yet.
--- - No home: there is a position, but no EdgeTX or first-arm home is available.
---   Distance and bearing are withheld rather than measured from nowhere.

---@class AeroGridNavigationSettings
---@field source? string GPS source name.
---@field armSwitch? string Armed switch position for first-arm home capture.
---@field label? string
---@field showTape? boolean
---@field bearingFormat? "degrees"|"quadrant"
---@field showCoordinates? boolean
---@field satelliteSource? string Locked satellite count source.
---@field satelliteWarning? number Warn below this count.
---@field satelliteCritical? number Critical below this count.
---@field accent? string

---@class AeroGridNavigationContext
---@field panel table
---@field feed? AeroGridNavigation Navigation subscription.
---@field satellites? AeroGridReading Optional satellite-count subscription.
---@field stateName string

local navigation = {
    id = "navigation",
    apiVersion = 1,
    supportedSpans = {
        "1x1",
        "2x1",
        "3x1",
        "4x1",
        "1x2",
        "2x2",
        "3x2",
        "4x2",
        "2x3",
        "3x3",
        "4x3",
        "2x4",
        "3x4",
        "4x4",
    },
    -- Telemetry GPS arrives at a few hertz at best, and the navigation service
    -- is itself rate limited because every update costs trigonometry.
    refreshInterval = 25,
    settings = {
        { key = "label", label = "Label", type = "string", default = "NAV" },
        { key = "source", label = "GPS source", type = "string", default = "GPS" },
        { key = "armSwitch", label = "Home arm switch (blank: EdgeTX)", type = "string", default = "" },
        { key = "satelliteSource", label = "Satellite count source", type = "string", default = "" },
        { key = "satelliteWarning", label = "Warn below satellites", type = "number", default = 8 },
        { key = "satelliteCritical", label = "Critical below satellites", type = "number", default = 4 },
        { key = "showTape", label = "Show tape", type = "boolean", default = false },
        {
            key = "bearingFormat",
            label = "Bearing format",
            type = "string",
            default = "degrees",
            choices = { "degrees", "quadrant" },
            visibleWhen = { key = "showTape", value = true, invert = true },
        },
        { key = "showCoordinates", label = "Show coordinates", type = "boolean", default = false },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "cyan",
            choices = { "cyan", "green", "amber", "orange" },
        },
    },
}

function navigation.validateSettings(settings)
    local errors = {}
    local arm = settings.armSwitch
    if arm ~= nil and arm ~= "" then
        if type(arm) ~= "string" or not (string.match(arm, "^S[A-Z][%^v%-]$") or string.match(arm, "^L%d%d$")) then
            errors[#errors + 1] =
                "armSwitch must be blank, a position such as SF^, SA-, SFv, or a logical switch such as L01"
        end
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
    return errors
end

function navigation.satelliteCount(reading)
    local value = reading and reading.available and reading.value
    if type(value) == "number" and value == value and value >= 0 and value < math.huge and value % 1 == 0 then
        return value
    end
    return nil
end

--- Forms of the distance reading, longest first, and there is only one.
---
--- A distance has no redundancy to give up. Its unit is not decoration,
--- because it changes with range: `1.23km` and `1.23m` are different readings,
--- so dropping it would be dropping magnitude. Nor can a decimal go, since
--- `1.23km` as `1km` discards 230 metres of a number a pilot is flying by.
--- Where it will not fit, the font steps down instead.
navigation.DIGITS = "888.88"

--- Widest unit a distance carries. `km` is two characters where `m` is one,
--- so fitting against it means a reading that switches to metres never has to
--- be reconsidered.
navigation.UNIT = "km"

--- Eight-point compass names.
--- Eight points, not sixteen: a telemetry bearing computed from two GPS
--- positions a few metres apart does not justify naming a direction to
--- 22.5 degrees, and the numeric bearing is printed beside it anyway.
local CARDINALS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

--- Name the eight-point sector a bearing falls in.
---@param bearing any Degrees clockwise from north.
---@return string
function navigation.cardinal(bearing)
    if type(bearing) ~= "number" or bearing ~= bearing then
        return ""
    end

    local index = math.floor(((bearing % 360) + 22.5) / 45) % 8
    return CARDINALS[index + 1]
end

--- Resolve the panel state from the navigation snapshot.
---
--- Satellite thresholds apply even before a fix/home is available. Missing or
--- stale inputs are explicit states, never substituted with a zero count.
---@param settings AeroGridNavigationSettings
--- No source, no fix and no home are three different causes with three
--- different fixes, and the origin caption below the reading says which in
--- words. The badge says only what state the panel is in, because a badge is
--- one word from a closed set and a caption is a vocabulary this panel
--- owns.
---
--- **What lets the caption carry that is the vocabulary, not the room.** The
--- caption is now half a supporting row on a slotted panel, so on a narrow
--- span it prints `NO GPS` rather than `NO GPS SOURCE`; the distinction
--- survives because the shortest form of each cause differs from the
--- shortest form of every other, which is what
--- `testSupportingWordingsStayDistinct` holds this panel to.
---@param view any Navigation subscription.
---@param satellites? AeroGridReading
---@return string stateName
function navigation.resolveState(settings, view, satellites)
    if type(view) ~= "table" then
        return "unavailable"
    end
    if view.source == nil or view.source == "" then
        return "unavailable"
    end
    if not view.known then
        return "unavailable"
    end
    if view.state == "stale" then
        return "stale"
    end
    if settings.satelliteSource and settings.satelliteSource ~= "" then
        local count = navigation.satelliteCount(satellites)
        if not satellites or count == nil then
            return "unavailable"
        end
        if satellites.stale then
            return "stale"
        end
        if count < (settings.satelliteCritical or 4) then
            return "critical"
        end
        if count < (settings.satelliteWarning or 8) then
            return "warning"
        end
    end
    return view.fix and "normal" or "unavailable"
end

--- Format the dominant distance reading.
---@param view any
---@param formatter fun(view: table): string?
---@return string
function navigation.distanceText(view, formatter)
    if type(view) ~= "table" then
        return "--"
    end
    if type(view.distance) ~= "number" then
        return "--"
    end
    return formatter(view) or "--"
end

--- The distance split into the number and the unit riding beside it.
---@param view any
---@param formatter fun(view: table): string?, string
---@return string digits
---@return string unit
function navigation.distanceParts(view, formatter)
    if type(view) ~= "table" or type(view.distance) ~= "number" then
        return "--", ""
    end
    local digits, unit = formatter(view)
    return digits or "--", unit or ""
end

--- Wordings for the supporting bearing row, longest first.
--- The bearing is withheld, not zeroed, when there is no home position: due
--- north and "nowhere to measure from" must not look the same.
---@param view any
---@return string[]
function navigation.bearingVariants(view, format)
    if type(view) ~= "table" or type(view.bearing) ~= "number" then
        return { "BRG --", "--" }
    end

    local bearing = math.floor(view.bearing % 360 + 0.5) % 360
    local cardinal = navigation.cardinal(bearing)
    if format == "quadrant" then
        local text
        if bearing % 90 == 0 then
            text = navigation.cardinal(bearing)
        elseif bearing < 90 then
            text = "N" .. bearing .. "\194\176E"
        elseif bearing < 180 then
            text = "S" .. (180 - bearing) .. "\194\176E"
        elseif bearing < 270 then
            text = "S" .. (bearing - 180) .. "\194\176W"
        else
            text = "N" .. (360 - bearing) .. "\194\176W"
        end
        return { "BRG " .. text, text, cardinal }
    end
    -- `BRG 009 N` needed 89 px and was drawn into 38 on a 1 x 2 panel, so the
    -- compass point goes first and then the caption, leaving the number, which
    -- is the part that is actually a measurement.
    return {
        string.format("BRG %03d %s", bearing, cardinal),
        string.format("BRG %03d", bearing),
        string.format("%03d %s", bearing, cardinal),
        string.format("%03d", bearing),
    }
end

--- Format the supporting bearing row at whatever width it has.
---@param view any
---@param themeBuilder? table
---@param font? any
---@param width? integer
---@return string
function navigation.bearingText(view, themeBuilder, font, width, format)
    local variants = navigation.bearingVariants(view, format)
    if not themeBuilder then
        return variants[1]
    end
    return themeBuilder.fitLabel(variants, font, width)
end

--- Wordings for the origin caption, longest first.
--- The caption shares a row with the bearing, so the space it gets depends on
--- the panel. Each state offers progressively shorter phrasings rather than
--- being clipped, which the specification requires and which silently lost the
--- final word of "NORTH UP FROM HOME" on a 2 x 2 panel.
---@param view any
---@return string[]
function navigation.originVariants(view)
    if type(view) ~= "table" then
        return { "NO GPS" }
    end
    if not view.known then
        return { "NO GPS SOURCE", "NO GPS SRC", "NO GPS" }
    end
    if not view.fix then
        return { "NO FIX" }
    end
    if not view.home then
        if view.homeStatus == "switch-unavailable" then
            return { "ARM SWITCH UNAVAILABLE", "NO ARM SWITCH", "NO ARM" }
        elseif view.homeStatus == "waiting" then
            return { "WAITING FOR ARM", "WAIT ARM", "ARM" }
        elseif view.homeStatus == "missed" then
            return { "HOME NOT SET", "NO HOME" }
        end
        return { "NO HOME POSITION", "NO HOME POS", "NO HOME" }
    end
    if view.state == "stale" then
        return { "LAST KNOWN", "LAST" }
    end
    -- Stated in words, because an arrow on a dial is exactly the thing a pilot
    -- would otherwise read as aircraft heading.
    return { "" }
end

--- Choose the longest wording that fits the width it will be given.
---@param view any
---@param themeBuilder table
---@param font any
---@param width integer
---@return string
function navigation.originText(view, themeBuilder, font, width)
    local variants = navigation.originVariants(view)

    -- Callers without layout context get the full wording. Choosing between the
    -- wordings is the shared helper's job now: every supporting row in the
    -- catalogue has this problem and only this one used to solve it.
    if not themeBuilder then
        return variants[1]
    end
    return themeBuilder.fitLabel(variants, font, width)
end

--- Format the coordinates row.
---@param view any
---@return string
function navigation.coordinateText(view)
    if type(view) ~= "table" or type(view.latitude) ~= "number" or type(view.longitude) ~= "number" then
        return "-- , --"
    end

    return string.format("%.5f %.5f", view.latitude, view.longitude)
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@param sample table Widest value text and unit this panel can render.
---@return table
function navigation.regionsFor(theme, themeBuilder, rect, layout, fonts, sample)
    local frame = themeBuilder.frame(theme, rect, fonts)
    local labelHeight = frame.labelHeight
    local rowFont = fonts.label
    local ladder = themeBuilder.ladder(theme, rect, frame)
    local showDetail = not layout.showTape and ladder.rows > 0
    local bands = ladder.bands
    local function rowsExtent(count)
        return (count - 1) * labelHeight + themeBuilder.fontAscent(rowFont)
    end
    local showCoordinates = layout.showCoordinates
        and ladder.rows > 0
        and bands.tertiary.h >= rowsExtent(showDetail and 2 or 1)
    local rowCount = (showDetail and 1 or 0) + (showCoordinates and 1 or 0)
    local rowsHeight = rowCount > 0 and rowsExtent(rowCount) or 0
    local rowsTop = rect.h - frame.bottom - rowsHeight
    local valueWidth = frame.content
    local valueRoom = ladder.room
    local valueCentre = frame.pad + math.floor(frame.content / 2)
    local tapeFont = frame.content >= 140 and SMLSIZE or TINSIZE
    local tapeHeight = 23 + themeBuilder.fontHeight(tapeFont)
    local wide = layout.wide
    local tapeX, tapeY, tapeWidth = frame.pad, 0, frame.content
    local showTape = layout.showTape == true
    if showTape then
        if wide then
            valueWidth = math.floor((frame.content - 8) / 2)
            valueCentre = frame.pad + math.floor(valueWidth / 2)
            tapeX = frame.pad + valueWidth + 8
            tapeWidth = rect.w - math.max(rect.w - frame.pad - frame.content, math.ceil(rect.w * 0.1)) - tapeX
            tapeFont = SMLSIZE
            tapeHeight = 23 + themeBuilder.fontHeight(tapeFont)
            valueRoom = math.max(1, rowsTop - frame.top - 4)
            tapeHeight = math.min(tapeHeight, valueRoom)
            tapeY = frame.top + math.floor((valueRoom - tapeHeight) / 2)
        else
            local inset = math.max(frame.pad, rect.w - frame.pad - frame.content, math.ceil(rect.w * 0.1))
            tapeX = inset
            tapeWidth = rect.w - inset * 2
            tapeFont = tapeWidth >= 140 and SMLSIZE or TINSIZE
            tapeHeight = 23 + themeBuilder.fontHeight(tapeFont)
            tapeY = rowsTop - tapeHeight - 4
            valueRoom = math.max(1, tapeY - frame.top - 4)
        end
        showTape = tapeWidth >= 54 and tapeY >= frame.top and valueRoom >= themeBuilder.fontAscent(SMLSIZE)
    end
    if layout.showTape and not showTape then
        valueWidth, valueRoom = frame.content, ladder.room
        valueCentre = frame.pad + math.floor(frame.content / 2)
    end
    local value, unitFont, _, fits =
        themeBuilder.fitReadingUnit(sample.digits, sample.unit, valueWidth, valueRoom, true)
    if not fits and showTape then
        showTape = false
        valueWidth, valueRoom = frame.content, ladder.room
        valueCentre = frame.pad + math.floor(frame.content / 2)
        value, unitFont = themeBuilder.fitReadingUnit(sample.digits, sample.unit, valueWidth, valueRoom, true)
    end
    local widest = themeBuilder.readingWidth(value, sample.digits, unitFont, sample.unit)
    local valueHeight = themeBuilder.fontAscent(value)
    local valueY = showTape and (frame.top + math.floor((valueRoom - valueHeight) / 2))
        or themeBuilder.bodyTop(ladder, valueHeight)
    if showTape and layout.square then
        valueY = math.max(frame.top, valueY - math.max(4, math.floor(rect.h * 0.03)))
    end
    local rowLeft, rowRight = themeBuilder.slotCentres(frame, themeBuilder.SLOT_TIGHT)
    local rowBudget = math.max(1, rowRight - rowLeft - 4)
    local detailY = rowsTop
    local coordinatesY = rowsTop + (showDetail and labelHeight or 0)

    return {
        frame = frame,
        rowFont = rowFont,
        pad = frame.pad,
        content = frame.content,
        bands = bands,
        valueCentre = valueCentre,
        valueX = themeBuilder.slotX(valueCentre, widest),
        valueY = valueY,
        valueWidth = widest,
        valueBudget = valueWidth,
        value = value,
        unitFont = unitFont,
        showUnit = true,
        detailWidth = rowBudget,
        originWidth = rowBudget,
        detailCentre = rowLeft,
        originCentre = rowRight,
        detailX = rowLeft - math.floor(rowBudget / 2),
        originX = rowRight - math.floor(rowBudget / 2),
        coordinatesCentre = frame.pad + math.floor(frame.content / 2),
        detailY = math.max(1, detailY),
        coordinatesY = math.max(1, coordinatesY),
        tapeX = tapeX,
        tapeY = tapeY,
        tapeWidth = tapeWidth,
        tapeHeight = tapeHeight,
        tapeFont = tapeFont,
        showDetail = showDetail,
        showCoordinates = showCoordinates,
        showTape = showTape,
    }
end

local function tapeSurfaceColors(context, surface)
    local function shade(amount)
        return lcd.RGB(context.themeBuilder.shade(surface, amount))
    end
    local light = context.themeBuilder.contrast(surface, 0x000000) > context.themeBuilder.contrast(surface, 0xFFFFFF)
    local shading = light and { -0.08, -0.02, 0, -0.06 } or { -0.45, -0.08, 0.04, -0.32 }
    local rims = {}
    for index, amount in ipairs(shading) do
        shading[index] = shade(amount)
    end
    for index = 1, 7 do
        local strength = 1 - math.abs(index - 4) * 0.1
        for edge = 1, 2 do
            rims[#rims + 1] =
                shade(strength * (light and (edge == 1 and -0.18 or -0.12) or (edge == 1 and 0.48 or 0.3)))
        end
    end
    return shading, rims
end

--- A fixed object pool keeps scrolling allocation-free and wraps through north.
function navigation.createTape(parent, context, area)
    local tape = { ticks = {}, labels = {}, dots = {}, shading = {}, rims = {}, dotHighlights = {}, pending = true }
    tape.surface = context.theme.rgb.surface
    local shading, rims = tapeSurfaceColors(context, tape.surface)
    tape.tickColors = { context.theme.color.textFaint, context.theme.color.textMuted, context.theme.color.text }
    tape.root = lvgl.box(parent, { x = area.tapeX, y = area.tapeY, w = area.tapeWidth, h = area.tapeHeight })
    for index, color in ipairs(shading) do
        tape.shading[index] = lvgl.rectangle(tape.root, {
            x = 0,
            y = 10,
            w = 1,
            h = 1,
            color = color,
            filled = true,
        })
    end
    for index, color in ipairs(rims) do
        tape.rims[index] = lvgl.rectangle(tape.root, {
            x = 0,
            y = 0,
            w = 1,
            h = 2,
            color = color,
            filled = true,
        })
    end
    for index = 1, 23 do
        tape.ticks[index] = lvgl.line(tape.root, {
            pts = { { 0, 10 }, { 0, 14 } },
            thickness = 1,
            color = context.theme.color.textFaint,
        })
    end
    for index = 1, 3 do
        tape.labels[index] = context.primitives.label(tape.root, context.theme, {
            x = 0,
            y = 19,
            text = "",
            font = area.tapeFont,
            color = context.theme.color.textMuted,
        })
    end
    for index = 1, 9 do
        tape.dots[index] = lvgl.rectangle(tape.root, {
            x = 0,
            y = 0,
            w = 3,
            h = 3,
            rounded = 2,
            color = context.theme.color.textMuted,
            filled = true,
        })
    end
    tape.pointer =
        lvgl.triangle(tape.root, { pts = { { 0, 0 }, { 1, 0 }, { 0, 1 } }, color = context.theme.color.green })
    tape.status = context.primitives.label(tape.root, context.theme, {
        x = 0,
        y = 10,
        text = "",
        font = TINSIZE,
        color = context.theme.color.textMuted,
    })
    lvgl.hide(tape.root)
    return tape
end

function navigation.setTape(context, bearing, color, status)
    local tape, area = context.tape, context.area
    if not tape then
        return
    end
    context.primitives.reconcile(tape.root, area.showTape, {
        x = area.tapeX,
        y = area.tapeY,
        w = area.tapeWidth,
        h = area.tapeHeight,
    })
    if not area.showTape then
        return
    end
    local surface = context.theme.alertRgb[context.stateName] or context.theme.rgb.surface
    if tape.surface ~= surface then
        tape.surface = surface
        local shading, rims = tapeSurfaceColors(context, surface)
        for index, strip in ipairs(tape.shading) do
            strip:set({ color = shading[index] })
        end
        for index, rim in ipairs(tape.rims) do
            rim:set({ color = rims[index] })
        end
    end
    if tape.width ~= area.tapeWidth or tape.height ~= area.tapeHeight then
        tape.width, tape.height = area.tapeWidth, area.tapeHeight
        local height = area.tapeHeight - 10
        for index, strip in ipairs(tape.shading) do
            local top = math.floor((index - 1) * height / #tape.shading)
            local bottom = math.floor(index * height / #tape.shading)
            strip:set({ x = 0, y = 8 + top, w = area.tapeWidth, h = bottom - top })
        end
        for index, rim in ipairs(tape.rims) do
            local segment = math.floor((index - 1) / 2)
            local leftFraction = segment <= 3 and segment * 0.05 or 0.85 + (segment - 4) * 0.05
            local rightFraction = segment < 3 and (segment + 1) * 0.05 or 0.85 + (segment - 3) * 0.05
            local left = math.floor(leftFraction * area.tapeWidth + 0.5)
            local right = math.floor(rightFraction * area.tapeWidth + 0.5)
            rim:set({ x = left, y = index % 2 == 1 and 6 or area.tapeHeight - 2, w = right - left })
        end
    end
    local valid = type(bearing) == "number" and bearing == bearing and math.abs(bearing) < math.huge
    local centre = math.floor(area.tapeWidth / 2)
    context.primitives.reconcile(tape.pointer, valid, {
        pts = { { centre - 4, 1 }, { centre + 4, 1 }, { centre, 8 } },
        color = color,
    })
    local message =
        context.themeBuilder.fitLabel({ status and status ~= "" and status or "--", "--" }, TINSIZE, area.tapeWidth)
    local messageWidth = context.themeBuilder.measureText(TINSIZE, message)
    context.primitives.reconcile(tape.status, not valid, {
        text = message,
        x = math.floor((area.tapeWidth - messageWidth) / 2),
        w = messageWidth,
    })
    bearing = valid and bearing % 360 or 0
    local scale = (area.tapeWidth - 1) / 210
    local start = math.floor(bearing / 10) * 10 - 110
    for index, tick in ipairs(tape.ticks) do
        local degrees = start + (index - 1) * 10
        local x = math.floor(centre + (degrees - bearing) * scale + 0.5)
        local major = degrees % 30 == 0
        local height = major and 7 or 3
        context.primitives.reconcile(tick, valid and x >= 0 and x < area.tapeWidth, {
            pts = { { x, 11 }, { x, 11 + height } },
            color = tape.tickColors[major and 3 or 1],
        })
    end
    for index, label in ipairs(tape.labels) do
        local degrees = math.floor(bearing / 90 + 0.5) * 90 + (index - 2) * 90
        local text = CARDINALS[(degrees / 45) % 8 + 1]
        local width = context.themeBuilder.measureText(area.tapeFont, text)
        local x = math.floor(centre + (degrees - bearing) * scale - width / 2 + 0.5)
        context.primitives.setFont(label, area.tapeFont)
        context.primitives.reconcile(label, valid and x >= 0 and x + width <= area.tapeWidth, {
            text = text,
            x = x,
            y = 19,
            w = width,
        })
    end
    local firstDot = math.floor(bearing / 30) * 30 - 120
    local dotY = 21 + math.floor(context.themeBuilder.fontAscent(area.tapeFont) / 2) - 1
    for index, dot in ipairs(tape.dots) do
        local degrees = firstDot + (index - 1) * 30
        local x = math.floor(centre + (degrees - bearing) * scale + 0.5) - 1
        local visible = valid and degrees % 90 ~= 0 and x >= 0 and x + 3 <= area.tapeWidth
        context.primitives.reconcile(dot, visible, {
            x = x,
            y = dotY,
        })
    end
end

--- Build the panel's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridNavigationSettings
---@param services table
---@return AeroGridNavigationContext
function navigation.create(parent, rect, settings, services)
    local theme = services.theme
    local primitives = services.primitives
    local fonts = services.fonts
    local span = services.span
    local layout = {
        showTape = settings.showTape == true,
        showCoordinates = settings.showCoordinates == true,
        wide = span.colSpan > span.rowSpan,
        square = span.colSpan == span.rowSpan,
    }
    local presentation = services.state("normal", settings.accent)

    local context = {
        theme = theme,
        themeBuilder = services.themeBuilder,
        primitives = primitives,
        state = services.state,
        fonts = fonts,
        layout = layout,
        settings = settings,
        stateName = "normal",
        text = "--",
        detail = "",
        origin = "",
        coordinates = "",
    }

    -- Subscribing in create is the mechanism: a GPS source nothing references
    -- is never read, and neither is its trigonometry ever computed.
    local service = services.navigation
    if service then
        context.service = service
        context.feed = service:subscribe(settings.source, settings.armSwitch)
    end
    if settings.satelliteSource and settings.satelliteSource ~= "" then
        assert(services.telemetry, "navigation satellite count requires telemetry service")
        context.satellites = services.telemetry:subscribe(settings.satelliteSource)
    end

    -- The widest distance this panel can print, so the font is chosen from
    -- that rather than from the current reading.
    context.sample = { digits = navigation.DIGITS, unit = navigation.UNIT }

    local area = navigation.regionsFor(theme, services.themeBuilder, rect, layout, fonts, context.sample)

    local panel
    context.panel, context.label, context.badge = primitives.panelWithHeader(
        parent,
        rect,
        theme,
        presentation,
        area.frame,
        fonts,
        settings.label,
        services.themeBuilder
    )
    panel = context.panel
    if context.satellites then
        context.satelliteHeader = lvgl.box(panel.root, { x = 0, y = 0, w = 1, h = 1 })
        local filename = services.host.path .. "assets/" .. (theme.light and "satellite-light.png" or "satellite.png")
        local handle = io.open(filename, "r")
        assert(handle, "navigation satellite icon missing: " .. filename)
        io.close(handle)
        context.satelliteIcon = primitives.image(context.satelliteHeader, {
            x = 0,
            y = 0,
            w = 16,
            h = 16,
            file = filename,
        })
        context.satelliteLabel = primitives.label(context.satelliteHeader, theme, {
            x = 18,
            y = 0,
            text = "",
            font = fonts.label,
            color = theme.color.textMuted,
        })
        lvgl.hide(context.satelliteHeader)
    end

    context.value = primitives.value(panel.root, theme, {
        x = area.pad,
        y = area.valueY,
        w = area.valueWidth,
        text = "--",
        color = presentation.value,
        font = area.value,
    })

    -- The unit changes with range, so it is built empty and written whenever
    -- the reading is. A distance never sheds it: a number without `m` or `km`
    -- beside it is not the same reading shortened, it is a different one.
    context.unit = primitives.unit(panel.root, theme, {
        x = area.pad,
        y = area.valueY,
        text = "",
        color = theme.color.textMuted,
        font = area.unitFont,
    })

    context.detailLabel = primitives.label(panel.root, theme, {
        x = area.detailX,
        y = area.detailY,
        w = area.detailWidth,
        text = "",
        color = theme.color.text,
        font = fonts.label,
    })

    -- Both wordings are chosen against the widths they will be given, so both
    -- widths are remembered.
    context.detailWidth = area.detailWidth
    context.originWidth = area.originWidth
    context.showDetail = area.showDetail
    context.area = area
    -- A distance always carries its unit, because the unit is its scale.
    context.showUnit = true
    context.unitText = ""
    context.originLabel = primitives.label(panel.root, theme, {
        x = area.originX,
        y = area.detailY,
        w = area.originWidth,
        text = "",
        color = theme.color.text,
        font = fonts.label,
    })

    if layout.showCoordinates then
        context.coordinatesLabel = primitives.label(panel.root, theme, {
            x = area.pad,
            y = area.coordinatesY,
            w = area.content,
            text = "",
            color = theme.color.text,
            font = fonts.label,
        })
    end

    if layout.showTape then
        context.tape = navigation.createTape(panel.root, context, area)
    end

    if not area.showDetail then
        lvgl.hide(context.detailLabel)
        lvgl.hide(context.originLabel)
    end
    if context.coordinatesLabel and not area.showCoordinates then
        lvgl.hide(context.coordinatesLabel)
    end
    -- Recorded after the rows are built, because whether there is a row at all
    -- is decided by the span and whether it is showing by the box.
    context.showCoordinates = context.coordinatesLabel ~= nil and area.showCoordinates == true
    context.showTape = context.tape ~= nil and area.showTape == true

    local _, drawn = primitives.changed(context, navigation.render)
    navigation.apply(context, drawn)
    return context
end

--- Repaint the panel from its current subscription.
---@param context AeroGridNavigationContext
--- Collect everything this panel draws.
---
--- The coordinates row is why this is a declaration. `apply` drew it from the
--- position and the refresh compared distance and bearing, which are derived
--- from the position *and the home position*: a model moving along an arc at
--- constant range changes its coordinates without moving either.
---@param out table
function navigation.render(context, out)
    local view = context.feed
    local service = context.service

    out.state = navigation.resolveState(context.settings, view, context.satellites)
    if context.satellites then
        local count = navigation.satelliteCount(context.satellites)
        out.satellites = count and string.format("%.0f", count) or "--"
    end
    out.text = "--"
    out.unit = ""
    if service and type(view) == "table" then
        out.text, out.unit = navigation.distanceParts(view, service.describeDistanceParts)
    end

    --- Satellite telemetry yields to the heading and the state badge, never clips.
    function navigation.setSatelliteHeader(context, text, presentation)
        if not context.satelliteHeader then
            return
        end
        local builder, frame, fonts = context.themeBuilder, context.area.frame, context.fonts
        local heading, font = builder.fitHeading(context.settings.label, frame.labelWidth, fonts.label)
        local left = frame.labelX + builder.measureText(font, heading) + 6
        local right = frame.badgeX + frame.badgeWidth
        if presentation.badge and presentation.badge ~= "" then
            right = context.primitives.badgeX(builder, frame, fonts.badge, presentation.badge) - 6
        end
        local width = 18 + builder.measureText(fonts.label, text)
        local height = math.max(16, builder.fontHeight(fonts.label))
        context.showSatellites = right - width >= left and frame.labelY + height <= frame.top
        if context.showSatellites then
            context.satelliteHeader:set({ x = right - width, y = frame.labelY, w = width, h = height })
            context.primitives.setFont(context.satelliteLabel, fonts.label)
            context.satelliteLabel:set({ text = text, w = width - 18, color = presentation.label })
            lvgl.show(context.satelliteHeader)
        else
            lvgl.hide(context.satelliteHeader)
        end
    end
    -- Only what this panel draws. Both supporting rows are shed on a small
    -- panel and the coordinate row unless explicitly enabled, and
    -- fitting a caption to a width nobody sees is work with no reader. It also
    -- makes the reveal safe by construction: the key is absent while the row is
    -- shed, so `changed` sees it reappear and repaints with a wording fitted to
    -- the width the row now has. This used to be unconditional and `update`
    -- discarded the last record to compensate, which worked only as long as
    -- nobody forgot.
    if context.showDetail then
        out.origin = navigation.originText(view, context.themeBuilder, context.area.rowFont, context.originWidth)
        out.detail = navigation.bearingText(
            view,
            context.themeBuilder,
            context.area.rowFont,
            out.origin == "" and context.area.content or context.detailWidth,
            context.settings.bearingFormat
        )
    end
    if context.showCoordinates then
        out.coordinates = navigation.coordinateText(view)
    end
    if context.showTape then
        out.bearing = type(view) == "table" and view.bearing or nil
        out.origin = navigation.originText(view, context.themeBuilder, TINSIZE, context.area.tapeWidth)
    end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridNavigationContext
---@param drawn table
function navigation.apply(context, drawn)
    local presentation = context.state(drawn.state, context.settings.accent)

    context.stateName = drawn.state
    context.text = drawn.text
    context.detail = drawn.detail
    context.origin = drawn.origin
    context.coordinates = drawn.coordinates
    context.bearing = drawn.bearing

    context.value:set({ text = drawn.text, color = presentation.value })
    if (drawn.unit or "") ~= context.unitText then
        context.unitText = drawn.unit or ""
        context.unit:set({ text = context.unitText })
    end
    context.primitives.centreReading(context, context.themeBuilder, context.area, context.area.value, drawn.text)
    context.label:set({ color = presentation.label })
    context.primitives.setBadge(
        context,
        context.themeBuilder,
        context.badge,
        context.area.frame,
        context.fonts.badge,
        presentation.badge or "",
        presentation.accent
    )
    context.primitives.stylePanel(context.panel, presentation)
    navigation.setSatelliteHeader(context, drawn.satellites or "--", presentation)

    -- Every row takes the panel's slot centres, keyed on what it says. A
    -- bearing changes every time the aircraft turns, so the helpers measure
    -- only when the wording actually moves.
    -- The coordinates are a row of one and centre across the content box the
    -- way a lone reading does. The bearing and the origin are a row of two and
    -- keep their columns; see `regionsFor` for why that is pending rather than
    -- done.
    local area, fonts = context.area, context.fonts
    if context.showDetail then
        context.primitives.setFont(context.detailLabel, area.rowFont)
        context.primitives.setFont(context.originLabel, area.rowFont)
        context.detailLabel:set({
            text = drawn.detail,
        })
        context.originLabel:set({
            text = drawn.origin,
        })
        context.primitives.centreLabel(
            context,
            "detailAnchor",
            context.themeBuilder,
            context.detailLabel,
            drawn.origin == "" and area.coordinatesCentre or area.detailCentre,
            area.detailY,
            area.rowFont,
            drawn.detail
        )
        context.primitives.centreLabel(
            context,
            "originAnchor",
            context.themeBuilder,
            context.originLabel,
            area.originCentre,
            area.detailY,
            area.rowFont,
            drawn.origin
        )
    end
    if context.showCoordinates then
        context.primitives.setFont(context.coordinatesLabel, area.rowFont)
        context.coordinatesLabel:set({
            text = drawn.coordinates,
        })
        context.primitives.centreLabel(
            context,
            "coordinatesAnchor",
            context.themeBuilder,
            context.coordinatesLabel,
            area.coordinatesCentre,
            area.coordinatesY,
            area.rowFont,
            drawn.coordinates
        )
    end

    if context.tape and not context.tape.pending then
        local pointerColor = drawn.state == "normal" and context.state("normal", "green").accent or presentation.accent
        navigation.setTape(context, drawn.bearing, pointerColor, drawn.origin)
    end
end

--- Advance the panel, repainting only when something drawn changed.
---@param context AeroGridNavigationContext
function navigation.refresh(context)
    if not context.feed and not (context.tape and context.tape.pending) then
        return
    end
    local changed, drawn = context.primitives.changed(context, navigation.render)
    local pending = context.tape and context.tape.pending
    if pending then
        context.tape.pending = nil
    end
    if changed or pending then
        navigation.apply(context, drawn)
    end
end

--- Reposition after a zone change.
---@param context AeroGridNavigationContext
---@param rect AeroGridRect
---@param settings? AeroGridNavigationSettings
---@param span? table Current grid placement, including preview resizes.
function navigation.update(context, rect, settings, _, span)
    if span then
        context.layout.wide = span.colSpan > span.rowSpan
        context.layout.square = span.colSpan == span.rowSpan
        context.fonts = context.themeBuilder.typography(span.colSpan, span.rowSpan)
    end
    local area =
        navigation.regionsFor(context.theme, context.themeBuilder, rect, context.layout, context.fonts, context.sample)

    context.primitives.resizeHeader(context, rect, area.frame, context.settings.label)
    -- Every anchor is about a slot and a font that have just moved, so all of
    -- them are discarded rather than trusted. A panel that reflowed while its
    -- distance and bearing held steady would otherwise keep the positions it
    -- had at the old span.
    context.unitAnchor = nil
    context.readingAnchor, context.readingUnitAnchor = nil, nil
    context.detailAnchor, context.originAnchor = nil, nil
    context.coordinatesAnchor = nil
    context.area = area
    context.primitives.setFont(context.value, area.value)
    context.value:set({
        x = area.valueX,
        y = area.valueY,
        w = area.valueWidth,
    })
    context.primitives.reflowReading(context, context.themeBuilder, area, area.value, context.text)

    --- Show or hide a supporting row, positioning it only when visible.
    local reconcile = context.primitives.reconcile

    reconcile(context.detailLabel, area.showDetail, { x = area.detailX, y = area.detailY, w = area.detailWidth })
    -- Recorded and nothing more. `render` reads all four, so a row that is shed
    -- declares nothing, a row that reappears declares a key that was missing,
    -- and a caption whose width moved declares whatever that width now fits.
    -- The discards that used to be here are gone with the guesswork.
    context.detailWidth = area.detailWidth
    context.originWidth = area.originWidth
    context.showDetail = area.showDetail
    context.showCoordinates = context.coordinatesLabel ~= nil and area.showCoordinates == true
    context.showTape = context.tape ~= nil and area.showTape == true
    reconcile(context.originLabel, area.showDetail, { x = area.originX, y = area.detailY, w = area.originWidth })
    reconcile(context.coordinatesLabel, area.showCoordinates, { x = area.pad, y = area.coordinatesY, w = area.content })
    if context.showDetail then
        context.primitives.centreLabel(
            context,
            "detailAnchor",
            context.themeBuilder,
            context.detailLabel,
            context.origin == "" and area.coordinatesCentre or area.detailCentre,
            area.detailY,
            area.rowFont,
            context.detail
        )
        context.primitives.centreLabel(
            context,
            "originAnchor",
            context.themeBuilder,
            context.originLabel,
            area.originCentre,
            area.detailY,
            area.rowFont,
            context.origin
        )
    end
    if context.showCoordinates then
        context.primitives.centreLabel(
            context,
            "coordinatesAnchor",
            context.themeBuilder,
            context.coordinatesLabel,
            area.coordinatesCentre,
            area.coordinatesY,
            area.rowFont,
            context.coordinates
        )
    end

    local _, drawn = context.primitives.changed(context, navigation.render)
    navigation.apply(context, drawn)
end

return navigation
