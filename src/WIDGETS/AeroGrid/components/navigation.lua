-- SPDX-License-Identifier: GPL-2.0-only

--- GPS position, distance to home, and the north-up bearing from home.
---
--- Everything this component draws is measured from the pilot's position
--- toward the model. That is the only direction EdgeTX can supply: it records
--- a pilot position when a fix is first acquired, and reports the model's
--- position afterwards. It reports neither the aircraft's heading nor the
--- transmitter's orientation, so the dial is always north-up and the arrow
--- must never be read as "the way the model is pointing" or "the way to turn".
--- The supporting row says so in words for exactly that reason.
---
--- A GPS source returns a table, and every field in it can be missing. Three
--- degraded states matter and are reported separately, because each has a
--- different cause and a different fix:
---
--- - No source: the layout names a sensor the radio does not have.
--- - No fix: the sensor is there and reporting, but has no position yet.
--- - No home: there is a position, but EdgeTX never recorded a pilot
---   position, so distance and bearing would be measured from nowhere. They
---   are withheld rather than computed from a zero that is not a place.

---@class AeroGridNavigationSettings
---@field source? string GPS source name.
---@field distanceSource? string Native distance sensor, preferred when set.
---@field label? string
---@field presentation? "auto"|"distance"|"bearing"|"compass"|"detailed"
---@field warning? number Distance in metres that raises a warning.
---@field critical? number Distance in metres that raises a critical state.
---@field accent? string

---@class AeroGridNavigationContext
---@field panel table
---@field feed? AeroGridNavigation Navigation subscription.
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
        { key = "source", label = "GPS source", type = "string", default = "GPS" },
        { key = "distanceSource", label = "Distance source", type = "string", default = "" },
        { key = "label", label = "Label", type = "string", default = "NAV" },
        -- Responsive content: which of the four arrangements this panel draws.
        {
            key = "presentation",
            label = "Presentation",
            type = "string",
            default = "auto",
            choices = { "auto", "distance", "bearing", "compass", "detailed" },
        },
        -- No default thresholds: a safe distance is a property of the field and
        -- the model, not of the dashboard.
        { key = "warning", label = "Warning distance, metres", type = "number" },
        { key = "critical", label = "Critical distance, metres", type = "number" },
        -- Distance is the one threshold in the catalogue that counts upward:
        -- further away is worse.
        -- No `direction`. Distance from home only alarms upward, which is the
        -- one threshold in the catalogue that counts that way.
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "cyan",
            choices = { "cyan", "green", "amber", "orange" },
        },
    },
}

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

--- Presentations this component knows how to draw, from least to most.
local PRESENTATIONS = {
    distance = true,
    bearing = true,
    compass = true,
    detailed = true,
}

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

--- Resolve the presentation for a span.
--- `auto` spends space on direction only once there is room for it: a single
--- cell shows the distance alone, because a dial squeezed into it would be
--- decoration rather than information.
---@param name any Configured presentation.
---@param colSpan integer
---@param rowSpan integer
---@return string
function navigation.presentation(name, colSpan, rowSpan)
    if PRESENTATIONS[name] then
        return name
    end

    local cells = (colSpan or 1) * (rowSpan or 1)
    if cells >= 6 then
        return "detailed"
    end
    if cells >= 4 then
        return "compass"
    end
    if cells >= 2 then
        return "bearing"
    end
    return "distance"
end

--- Describe what a presentation contains.
---@param presentation string
---@return table
function navigation.presentationFor(presentation)
    return {
        presentation = presentation,
        showDetail = presentation ~= "distance",
        showCompass = presentation == "compass" or presentation == "detailed",
        showCoordinates = presentation == "detailed",
    }
end

--- Resolve the component state from the navigation snapshot.
---
--- A missing fix is `unavailable` rather than a distance of zero, because zero
--- metres from home is a real and very different reading. A missing home
--- position leaves the fix itself perfectly good, so the panel stays normal
--- and says which part is missing.
---@param settings AeroGridNavigationSettings
--- No source, no fix and no home are three different causes with three
--- different fixes, and the origin caption below the reading says which in
--- words. The badge says only what state the panel is in, because a badge is
--- one word from a closed set and a caption is a vocabulary this component
--- owns.
---
--- **What lets the caption carry that is the vocabulary, not the room.** The
--- caption is now half a supporting row on a slotted panel, so on a narrow
--- span it prints `NO GPS` rather than `NO GPS SOURCE`; the distinction
--- survives because the shortest form of each cause differs from the
--- shortest form of every other, which is what
--- `testSupportingWordingsStayDistinct` holds this component to.
---@param view any Navigation subscription.
---@return string stateName
function navigation.resolveState(settings, view)
    if type(view) ~= "table" then
        return "unavailable"
    end
    if view.source == nil or view.source == "" then
        return "unavailable"
    end
    if not view.known then
        return "unavailable"
    end
    if not view.fix then
        return "unavailable"
    end
    if view.state == "stale" then
        return "stale"
    end
    -- A missing home position leaves the fix perfectly good, so the panel is not
    -- in a failed state at all; only the two values measured from home are
    -- withheld, and the caption says so.
    if not view.home then
        return "normal"
    end

    local distance = view.distance
    if type(distance) == "number" then
        local critical = settings.critical
        local warning = settings.warning
        -- Distance thresholds count upward: further away is worse.
        if type(critical) == "number" and distance >= critical then
            return "critical"
        end
        if type(warning) == "number" and distance >= warning then
            return "warning"
        end
    end

    return "normal"
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
function navigation.bearingVariants(view)
    if type(view) ~= "table" or type(view.bearing) ~= "number" then
        return { "BRG --", "--" }
    end

    local bearing = math.floor(view.bearing % 360 + 0.5) % 360
    local cardinal = navigation.cardinal(bearing)
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
function navigation.bearingText(view, themeBuilder, font, width)
    local variants = navigation.bearingVariants(view)
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
        return { "NO HOME POSITION", "NO HOME POS", "NO HOME" }
    end
    if view.state == "stale" then
        return { "LAST KNOWN", "LAST" }
    end
    -- Stated in words, because an arrow on a dial is exactly the thing a pilot
    -- would otherwise read as aircraft heading.
    return { "NORTH UP FROM HOME", "NORTH UP", "N UP" }
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

--- Widest dial this component will draw.
---
--- A compass given every pixel of a two-row panel is taller than the number
--- beside it, and a dial is an indicator rather than the reading. The same
--- fifty pixels `tx-battery` caps its cell at, for the same reason and so
--- that two panels of different components put comparable weight on their
--- secondary element.
navigation.DIAL_MAX_DIAMETER = 50

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
---@param sample table Widest value text and unit this component can render.
---@return table
function navigation.regionsFor(theme, themeBuilder, rect, layout, fonts, sample)
    local frame = themeBuilder.frame(theme, rect, fonts)
    local labelHeight = frame.labelHeight
    local top = frame.top
    -- Composition comes from the shared ladder, so a panel of this size carries
    -- the same rows as any other panel of this size, whichever component drew
    -- it. Navigation asks for two rows where every other component asks for
    -- one, so the second is granted only where the first left room for it.
    local ladder = themeBuilder.ladder(theme, rect, frame)
    local showDetail = layout.showDetail and ladder.rows > 0
    local showCompass = layout.showCompass
    local bands = ladder.bands

    --- The marked extent of `count` stacked supporting rows.
    ---
    --- Ink, like everything else this dashboard measures: rows are stacked a
    --- line height apart, and what the group actually marks runs from the top
    --- of the first row's glyphs to the bottom of the last row's. Two rows are
    --- 32 px where their line boxes are 36.
    local function rowsExtent(count)
        return (count - 1) * (labelHeight + 2) + themeBuilder.fontAscent(fonts.label)
    end

    -- **The second row is granted by the band that has to hold it.**
    --
    -- This asked whether the *body* band had a MIDSIZE reading's worth of room
    -- left after a row -- which is a question about the wrong band, and it is
    -- the seam this project keeps finding: the grant and the thing granted
    -- were measured in different places. The rows live in the tertiary
    -- quarter, so the tertiary quarter is what decides how many of them there
    -- are.
    --
    -- It did not show while the band grew to fit whatever was put in it. Under
    -- fixed bands a quarter is a quarter: 31 px at a two-row span in App mode
    -- and 25 px in Full screen, against 32 px of two-row ink. So a two-row
    -- panel draws one supporting row and a three-row panel draws two, and
    -- nothing overflows into the reading above it.
    --
    -- **The cost is the coordinates at every two-row span**, including the
    -- shipped `sim` dashboard's own navigation panel. That is the rule the
    -- user chose applied to the one component that wanted more than its
    -- quarter, and the alternative was the reading yielding instead -- which
    -- is paying magnitude for layout.
    local showCoordinates = layout.showCoordinates and showDetail and bands.tertiary.h >= rowsExtent(2)

    local rowsHeight = rowsExtent(showCoordinates and 2 or 1)
    -- The dial's cap, which is not the reading's room. A reading is sized
    -- against the panel now; a dial is an indicator beside it and is still
    -- held to the middle band, so that letting the panel grow does not turn
    -- the decoration into the largest thing on it.
    local available = bands.body.h

    -- Half the content is what either element may claim, whichever slot set
    -- the panel settles on: the right centre moves between 70% and 75%, but
    -- the half never grows.
    local half = math.floor(frame.content / 2)

    -- **The dial is bounded by its band, not by the panel.** It used to take
    -- whatever vertical room the ladder left after the rows, and stand from the
    -- content top downward, which put it straight through the supporting row
    -- beneath it -- 44 by 2 pixels at `2 x 2` and `4 x 2`. A body band is half
    -- the panel's extent and the rows own the quarter below it, so sizing
    -- against the band is what keeps the two apart, by construction rather
    -- than by a clearance somebody has to remember.
    -- **A dial is an indicator beside the reading, not a second reading.** Let
    -- it take the whole body band and it becomes the largest thing on the
    -- panel, and it fills the band exactly -- which leaves the supporting rows
    -- nowhere to overflow to when their own quarter cannot hold them, and they
    -- overflow upward into it. `tx-battery` caps its cell at the same size and
    -- for the same reason.
    -- **The rows are measured before the dial is sized, and the dial has to
    -- clear them.** Two supporting rows need more than the quarter they were
    -- given, so they overflow their band upward -- into the bottom of the body
    -- band, where the dial lives. Sizing the dial against the band alone left
    -- it touching the caption by a pixel, which the collision check found the
    -- moment a long enough caption was put on a screen. The row's own top is
    -- the bound, so the two cannot meet however the bands fall out.
    --
    -- **The group is pinned, not each row.** Pinning a row would put the
    -- bearing on the floor and the coordinates off the panel; what hangs from
    -- the floor is the last row of the group, and the rest stack above it.
    -- `theme.rowTop` takes the count for exactly that reason -- this component
    -- is the only caller that passes more than one, and it is the component
    -- this arrangement has been tightest on every time.
    local rowsTop = showDetail and themeBuilder.rowTop(frame, fonts.label, rect.h, showCoordinates and 2 or 1)
        or (rect.h - frame.bottom)
    -- **The reading's own room, which is what keeps it off the rows.** This
    -- used to be measured privately, from the body band's top to the rows --
    -- correct while the block was centred in that band and wrong the moment
    -- the block moved to the panel's centre, because the two origins differ.
    -- Rather than correct the private copy, the dial takes the budget
    -- `theme.readingRoom` already caps against the supporting row: one number
    -- for everything centred on the panel, which is the arrangement this
    -- component has twice been the one to break.
    local dialRoom = ladder.room

    local radius = math.floor(math.min(half, available, dialRoom, navigation.DIAL_MAX_DIAMETER) / 2)
    if radius < 10 then
        showCompass = false
    end
    if not showCompass then
        radius = 0
    end

    -- A distance has no redundancy: dropping a decimal turns 1.23 km into
    -- 1 km, which is 230 metres of a number a pilot is flying by. Nor is its
    -- unit redundancy, because it changes with range -- `1.23km` and `1.23m`
    -- are different readings -- so unlike a voltage's it is never dropped, and
    -- a panel with no room for it has no room for the reading either.
    -- **Fitted against the whole content box, never against the slot.** The
    -- distance does not know there is a dial beside it and must not: a
    -- reading narrowed to make room for a decoration has paid for the
    -- decoration with magnitude, and magnitude is the first thing a pilot
    -- reads. Whether the dial survives is settled below, once the reading's
    -- width is known.
    --
    -- This component used to hold its own version of the shedding rule -- the
    -- reading fitted into half the panel and allowed to step down one size to
    -- keep the compass, the compass shed at two. That rule is gone from the
    -- rest of the dashboard and it is gone here; it could charge the distance
    -- a size for a dial the panel then dropped anyway.
    local valueWidth = frame.content
    local value, unitFont, _, fits =
        themeBuilder.fitReadingUnit(sample.digits, sample.unit, valueWidth, ladder.room, true)

    -- The dial gives its room back rather than clipping the distance. A
    -- compass is a shape and survives being absent; a distance that runs off
    -- the panel is a number a pilot cannot read at the moment they need it, and
    -- the unit cannot be dropped to buy the space because it carries the scale.
    if not fits and showCompass then
        showCompass, radius = false, 0
    end

    -- Asked of the widest distance this component can ever print, so the
    -- arrangement is fixed for the life of the panel rather than flipping as
    -- the aircraft flies away from home.
    local widest = themeBuilder.readingWidth(value, sample.digits, unitFont, sample.unit)
    local slots, separated
    if showCompass then
        slots, separated = themeBuilder.slotsFor(frame, widest, radius * 2)
        -- Neither arrangement separates them, so the dial goes -- the same
        -- answer this component already reaches when the distance will not fit
        -- beside it, and the same one `tx-battery` reaches at `1 x 2`.
        -- Nothing is refitted, because nothing was narrowed.
        if not separated then
            showCompass, radius, slots = false, 0, nil
        end
    end

    local leftCentre = showCompass and select(1, themeBuilder.slotCentres(frame, slots))
        or (frame.pad + math.floor(frame.content / 2))
    local rightCentre = showCompass and select(2, themeBuilder.slotCentres(frame, slots)) or nil

    -- Reading and dial share the body band and are centred on each other, so
    -- the block the band centres is the deeper of the two.
    local valueHeight = themeBuilder.fontAscent(value)
    local blockHeight = math.max(valueHeight, radius * 2)
    local blockTop = themeBuilder.bodyTop(ladder, blockHeight)
    local valueY = blockTop + math.floor((blockHeight - valueHeight) / 2)

    -- **A row of two takes the panel's two slot centres**, the same 30% and
    -- 70% the reading and the dial use, so the arrangement is one rule at
    -- every level of the panel rather than a body rule with a footer
    -- exception. Chosen on a radio against the column split it replaces, which
    -- was built and measured first; the design guide records what it cost.
    local rowLeft, rowRight = themeBuilder.slotCentres(frame, slots or themeBuilder.SLOT_TIGHT)

    -- Two boxes centred this far apart can each be half that distance wide
    -- before they meet, so that is the budget each wording is fitted to. It is
    -- narrower than the column split reached, and the wordings that no longer
    -- fit are shed by `fitLabel` in the order their components declare -- see
    -- `originVariants`, whose shortest forms stay distinct from one another
    -- precisely so that this narrowing costs detail and never meaning.
    local rowBudget = math.max(1, rowRight - rowLeft - 4)

    local centreX = rightCentre or (rect.w - frame.pad)
    local centreY = blockTop + math.floor(blockHeight / 2)

    -- **Both supporting rows live in the tertiary band**, which is the quarter
    -- the panel reserved for them, rather than being stacked up from the
    -- panel's floor. Two rows where there are two, one where the second was
    -- shed, and the pair is centred in the band so the group sits where the
    -- rule puts it rather than where the bottom margin leaves it.
    -- **Two rows do not fit a quarter, and pinning is what settles where the
    -- overflow goes.** Two SMLSIZE rows need 36 px of a 31 px band on a 134 px
    -- panel. Centred in the band the pair overflowed it by three pixels at
    -- each end, and the end that mattered was the bottom one, because the
    -- panel's floor is there and a band is not. Hung from the floor the pair
    -- overflows upward only, into the air the reading was already being held
    -- out of -- so the quarter is now a grant rather than a container, and
    -- `bands.tertiary.h` above decides whether a second row is offered rather
    -- than where either row lands.
    local detailY = rowsTop
    local coordinatesY = rowsTop + labelHeight + 2

    return {
        frame = frame,
        pad = frame.pad,
        content = frame.content,
        -- The bands this panel was laid out against. Exposed because the
        -- supporting rows are the one thing in the catalogue that can want more
        -- than the quarter reserved for them, so a check on where they landed
        -- has to be able to ask what they were granted.
        bands = bands,
        -- The slot's centre, a property of the panel. Where the reading starts
        -- depends on what it currently says, so `primitives.centreReading` owns
        -- that and computes it from the measured string.
        valueCentre = leftCentre,
        valueX = themeBuilder.slotX(leftCentre, widest),
        valueY = valueY,
        -- **The box the reading draws in, which hugs the measured string, and
        -- separately the room it was given.** This component carried one number
        -- for both, which was survivable only while the reading was fitted to
        -- half the panel: the budget was then a box the dial could sit beside.
        -- A reading fitted against the whole panel has a budget that spans it,
        -- and a box of that width drawn from the left slot runs straight
        -- through the compass. Every other component separated these when it
        -- moved onto the shared builder; this is the last one.
        valueWidth = widest,
        valueBudget = valueWidth,
        value = value,
        unitFont = unitFont,
        showUnit = true,
        -- **The supporting row is a row of two, so it takes the same two slot
        -- centres the reading and the dial use** -- the bearing on the left, the
        -- orientation on the right. The row used to be split by a flat 40% of
        -- the content with each half left-aligned in its own box, which is a
        -- second arrangement inside a panel that already has one. Where there is
        -- no dial there is one slot, and the row of two shares the panel the way
        -- a lone reading does: left of centre and right of centre.
        -- The budget each item's wording is fitted to, which is a different
        -- question from where it is drawn. Two items centred on centres that are
        -- a fixed distance apart can each have half that distance before they
        -- meet, so the budget is derived from the centres rather than from the
        -- panel's half -- a half-width box on each of two centres 40% apart
        -- overlaps by a tenth of the panel. The estimate answers this question
        -- and the measurement answers the placement.
        detailWidth = rowBudget,
        originWidth = rowBudget,
        detailCentre = rowLeft,
        originCentre = rowRight,
        detailX = rowLeft - math.floor(rowBudget / 2),
        originX = rowRight - math.floor(rowBudget / 2),
        -- A row of one item centres across the whole content box, exactly as a
        -- lone reading does.
        coordinatesCentre = frame.pad + math.floor(frame.content / 2),
        detailY = math.max(1, detailY),
        coordinatesY = math.max(1, coordinatesY),
        radius = radius,
        centreX = centreX,
        centreY = centreY,
        showDetail = showDetail,
        showCoordinates = showCoordinates,
        showCompass = showCompass,
    }
end

--- Build the component's LVGL objects.
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
    local presentationName = navigation.presentation(settings.presentation, span.colSpan, span.rowSpan)
    local layout = navigation.presentationFor(presentationName)
    local presentation = services.state("normal", settings.accent)

    local context = {
        theme = theme,
        themeBuilder = services.themeBuilder,
        primitives = primitives,
        state = services.state,
        fonts = fonts,
        layout = layout,
        settings = settings,
        presentationName = presentationName,
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
        context.feed =
            service:subscribe(settings.source, settings.distanceSource ~= "" and settings.distanceSource or nil)
    end

    -- The widest distance this component can print, so the font is chosen from
    -- that rather than from the current reading.
    context.sample = { digits = navigation.DIGITS, unit = navigation.UNIT }

    local area = navigation.regionsFor(theme, services.themeBuilder, rect, layout, fonts, context.sample)

    local panel = primitives.panel(parent, rect, theme, presentation)
    context.panel = panel

    context.label, context.badge =
        primitives.header(panel.root, theme, area.frame, fonts, settings.label, presentation, services.themeBuilder)

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
        color = theme.color.textFaint,
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
        color = theme.color.textFaint,
        font = fonts.label,
    })

    if layout.showCoordinates then
        context.coordinatesLabel = primitives.label(panel.root, theme, {
            x = area.pad,
            y = area.coordinatesY,
            w = area.content,
            text = "",
            color = theme.color.textFaint,
            font = fonts.label,
        })
    end

    if layout.showCompass then
        context.compass = primitives.compass(panel.root, theme, {
            x = area.centreX,
            y = area.centreY,
            radius = math.max(1, area.radius),
            thickness = 6,
            color = presentation.accent,
        })
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
    context.showCompass = context.compass ~= nil and area.showCompass == true
    if context.compass and not area.showCompass then
        navigation.hideCompass(context)
    end

    local _, drawn = primitives.changed(context, navigation.render)
    navigation.apply(context, drawn)
    return context
end

--- Hide the dial and its north tick together.
---@param context AeroGridNavigationContext
function navigation.hideCompass(context)
    if not context.compass then
        return
    end
    lvgl.hide(context.compass.ring)
    lvgl.hide(context.compass.north)
end

--- Show the dial and its north tick together.
---@param context AeroGridNavigationContext
function navigation.showCompass(context)
    if not context.compass then
        return
    end
    lvgl.show(context.compass.ring)
    lvgl.show(context.compass.north)
end

--- Repaint the component from its current subscription.
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

    out.state = navigation.resolveState(context.settings, view)
    out.text = "--"
    out.unit = ""
    if service and type(view) == "table" then
        out.text, out.unit = navigation.distanceParts(view, service.describeDistanceParts)
    end
    -- Only what this panel draws. Both supporting rows are shed on a small
    -- panel and the coordinate row on all but the detailed arrangement, and
    -- fitting a caption to a width nobody sees is work with no reader. It also
    -- makes the reveal safe by construction: the key is absent while the row is
    -- shed, so `changed` sees it reappear and repaints with a wording fitted to
    -- the width the row now has. This used to be unconditional and `update`
    -- discarded the last record to compensate, which worked only as long as
    -- nobody forgot.
    if context.showDetail then
        out.detail = navigation.bearingText(view, context.themeBuilder, context.fonts.label, context.detailWidth)
        out.origin = navigation.originText(view, context.themeBuilder, context.fonts.label, context.originWidth)
    end
    if context.showCoordinates then
        out.coordinates = navigation.coordinateText(view)
    end
    -- The dial is shed on a panel too small for it, and a bearing declared
    -- while it is shed is a number that moves the whole declaration every time
    -- the model turns, repainting a panel whose visible parts have not changed.
    if context.showCompass then
        out.bearing = type(view) == "table" and view.bearing or nil
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

    -- Every row takes the panel's slot centres, keyed on what it says. A
    -- bearing changes every time the aircraft turns, so the helpers measure
    -- only when the wording actually moves.
    -- The coordinates are a row of one and centre across the content box the
    -- way a lone reading does. The bearing and the origin are a row of two and
    -- keep their columns; see `regionsFor` for why that is pending rather than
    -- done.
    local area, fonts = context.area, context.fonts
    if context.showDetail then
        context.detailLabel:set({ text = drawn.detail })
        context.originLabel:set({ text = drawn.origin })
        context.primitives.centreLabel(
            context,
            "detailAnchor",
            context.themeBuilder,
            context.detailLabel,
            area.detailCentre,
            area.detailY,
            fonts.label,
            drawn.detail
        )
        context.primitives.centreLabel(
            context,
            "originAnchor",
            context.themeBuilder,
            context.originLabel,
            area.originCentre,
            area.detailY,
            fonts.label,
            drawn.origin
        )
    end
    if context.showCoordinates then
        context.coordinatesLabel:set({ text = drawn.coordinates })
        context.primitives.centreLabel(
            context,
            "coordinatesAnchor",
            context.themeBuilder,
            context.coordinatesLabel,
            area.coordinatesCentre,
            area.coordinatesY,
            fonts.label,
            drawn.coordinates
        )
    end

    if context.showCompass then
        -- A bearing that does not exist hides the pointer rather than resting it
        -- at north, which would read as a real due-north fix.
        context.primitives.setCompass(context.compass, drawn.bearing, presentation.accent)
    end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridNavigationContext
function navigation.refresh(context)
    if not context.feed then
        return
    end
    local changed, drawn = context.primitives.changed(context, navigation.render)
    if changed then
        navigation.apply(context, drawn)
    end
end

--- Reposition after a zone change.
---@param context AeroGridNavigationContext
---@param rect AeroGridRect
function navigation.update(context, rect)
    local area =
        navigation.regionsFor(context.theme, context.themeBuilder, rect, context.layout, context.fonts, context.sample)

    context.primitives.resizePanel(context.panel, rect)
    context.primitives.placeHeader(
        context.label,
        context.badge,
        area.frame,
        context.themeBuilder,
        context.fonts,
        context.settings.label,
        context.badgeText
    )
    context.primitives.placeUnit(
        context.unit,
        context.themeBuilder,
        area.valueX,
        area.valueY,
        area.value,
        context.text,
        area.unitFont
    )
    context.unit:set({
        font = function()
            return area.unitFont
        end,
    })
    -- Every anchor is about a slot and a font that have just moved, so all of
    -- them are discarded rather than trusted. A panel that reflowed while its
    -- distance and bearing held steady would otherwise keep the positions it
    -- had at the old span.
    context.unitAnchor = nil
    context.readingAnchor, context.readingUnitAnchor = nil, nil
    context.detailAnchor, context.originAnchor = nil, nil
    context.coordinatesAnchor = nil
    context.area = area
    context.value:set({
        x = area.valueX,
        y = area.valueY,
        w = area.valueWidth,
        font = function()
            return area.value
        end,
    })

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
    context.showCompass = context.compass ~= nil and area.showCompass == true
    reconcile(context.originLabel, area.showDetail, { x = area.originX, y = area.detailY, w = area.originWidth })
    reconcile(context.coordinatesLabel, area.showCoordinates, { x = area.pad, y = area.coordinatesY, w = area.content })

    if context.compass then
        if area.showCompass then
            context.primitives.placeCompass(context.compass, area.centreX, area.centreY, area.radius)
            navigation.showCompass(context)
        else
            navigation.hideCompass(context)
        end
    end
end

return navigation
