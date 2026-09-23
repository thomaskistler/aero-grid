-- SPDX-License-Identifier: GPL-2.0-only

--- Transmitter battery voltage.
---
--- Voltage is the authoritative reading and is always shown. Any fill or
--- percentage is an estimate, because battery chemistry and cell count vary by
--- radio and EdgeTX does not report either to Lua, so the estimate is off by
--- default and only appears once a layout states the voltage range it should
--- be measured against. A dashboard that guessed a range would show a
--- confident percentage derived from nothing.
---
--- The reading comes from `modelService`, which reads the radio's own
--- `tx-voltage` source. It does not depend on a telemetry link, but it is
--- shaped like a telemetry reading so the same states apply.

---@class AeroGridTxBatterySettings
---@field label? string
---@field accent? string
---@field packEmpty? number Voltage treated as empty for the optional estimate.
---@field packFull? number Voltage treated as full for the optional estimate.
---@field warning? number
---@field critical? number
---@field visual? "none"|"bar"
---@field showPercent? boolean

---@class AeroGridTxBatteryContext
---@field panel table
---@field feed? AeroGridReading
---@field stateName string

local txBattery = {
    id = "tx-battery",
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
    },
    -- A transmitter pack moves over minutes, not frames.
    refreshInterval = 50,
    settings = {
        -- "TX BATTERY" needs ten characters of a header that has about five.
        { key = "label", label = "Label", type = "string", default = "TX" },
        -- Cyan, because the specification reserves it for electrical data and this
        -- is a battery. `cell-battery` was already cyan and these two disagreed.
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "cyan",
            choices = { "cyan", "green", "amber", "orange" },
        },
        -- No default range: the estimate stays off until a layout states one.
        { key = "packEmpty", label = "Empty volts, whole pack", type = "number" },
        { key = "packFull", label = "Full volts, whole pack", type = "number" },
        { key = "warning", label = "Warning volts", type = "number" },
        { key = "critical", label = "Critical volts", type = "number" },
        -- No `direction`. A transmitter pack only ever alarms downward.
        -- A battery rather than a bar, because a bar says "some of something"
        -- and this panel is about which something. The bar stays available: on a
        -- panel four cells wide a glyph is a small shape in a lot of space, and a
        -- track running the width reads better there.
        {
            key = "visual",
            label = "Visualization",
            type = "string",
            default = "battery",
            choices = { "battery", "bar", "none" },
        },
        { key = "showPercent", label = "Show estimate", type = "boolean", default = false },
    },
}

--- Widest digits this panel prints. The unit is no longer part of the string:
--- it rides beside the number in its own label at a smaller font, so there is
--- one form rather than two and nothing to choose wrongly between.
txBattery.DIGITS = "88.8"

--- The unit, which every transmitter pack is measured in.
txBattery.UNIT = "V"

--- Print the reading. Digits only: the unit is a separate label.
---
--- This used to choose between `88.8V` and `88.8` on the strength of a form
--- index the fitter returned and the printing ignored, which is how a 116
--- pixel string came to be drawn in a 105 pixel column. There is nothing to
--- choose now, so there is nothing to get wrong.
---@param value any
---@return string
function txBattery.reading(value)
    if type(value) ~= "number" or value ~= value then
        return "--"
    end
    return string.format("%.1f", value)
end

--- Resolve the voltage range to measure the estimate against.
---
--- The radio already knows this. EdgeTX carries a battery meter range at SYS
--- then Hardware then Battery meter range, set per radio to suit its pack --
--- 6.4 to 8.4 for a 2S LiPo, 4.6 to 6.0 for four alkaline cells -- and it is
--- already correct on any radio whose battery icon is sensible. Asking a
--- layout to restate it was asking for something the radio had.
---
--- So the radio's range is the default and the layout's is an override, which
--- stays useful for a modified pack or a dashboard written for someone
--- else's radio. Both ends come from one place: half a range is not a range,
--- and mixing a stated empty with the radio's full would produce a
--- confident percentage measured against two different packs.
---@param settings AeroGridTxBatterySettings
---@param range? table `modelService:batteryRange()` view, when there is one.
---@return number? empty
---@return number? full
---@return string source One of `layout`, `radio`, or `none`.
function txBattery.rangeFor(settings, range)
    local low, high = settings.packEmpty, settings.packFull
    if type(low) == "number" and type(high) == "number" and high > low then
        return low, high, "layout"
    end

    if
        type(range) == "table"
        and range.available
        and type(range.empty) == "number"
        and type(range.full) == "number"
        and range.full > range.empty
    then
        return range.empty, range.full, "radio"
    end

    -- A firmware without `getGeneralSettings` and a layout that states nothing
    -- leave nothing to measure against, which is where this component started
    -- and is still the honest answer.
    return nil, nil, "none"
end

--- Report whether a usable voltage range is available at all.
--- Without one there is no estimate, so neither the bar nor the percentage is
--- drawn however the layout set their own switches.
---@param settings AeroGridTxBatterySettings
---@param range? table
---@return boolean
function txBattery.hasRange(settings, range)
    local low = select(1, txBattery.rangeFor(settings, range))
    return low ~= nil
end

--- Convert a voltage into a 0..1 fraction of the configured range.
---@param settings AeroGridTxBatterySettings
---@param value any
---@param range? table
---@return number
function txBattery.fraction(settings, value, range)
    local low, high = txBattery.rangeFor(settings, range)
    if not low then
        return 0
    end
    if type(value) ~= "number" or value ~= value then
        return 0
    end

    local fraction = (value - low) / (high - low)
    if fraction < 0 then
        return 0
    end
    if fraction > 1 then
        return 1
    end
    return fraction
end

--- Resolve the component state. Voltage thresholds always count downward.
---@param settings AeroGridTxBatterySettings
---@param value any
---@param stale boolean
---@return string
function txBattery.resolveState(settings, value, stale)
    if type(value) ~= "number" or value ~= value then
        return "unavailable"
    end
    if stale then
        return "stale"
    end

    local critical = settings.critical
    local warning = settings.warning
    if type(critical) == "number" and value <= critical then
        return "critical"
    end
    if type(warning) == "number" and value <= warning then
        return "warning"
    end
    return "normal"
end

--- Refuse a supporting row on a panel that has nowhere to put one.
---
--- No single-row span grants a supporting row: a 65 pixel panel has no space
--- beneath the reading whatever its width, so asking for one on a `4 x 1` is
--- as inert as asking on a `1 x 1`. Accepting it and ignoring it is the worst
--- of the three options, because a layout author reads the setting back and
--- believes it.
---
--- Only a layout that **stated** it is told. These settings arrive filled
--- from their defaults, and a default that cannot apply here is the panel
--- shedding a row, which is normal and silent.
---@param settings AeroGridTxBatterySettings
---@param span? table Placement span, when the host knows it.
---@param config? table What the layout actually stated.
---@return string[] messages
function txBattery.validateSettings(settings, span, config)
    local messages = {}
    if type(config) ~= "table" then
        return messages
    end
    if type(span) ~= "table" or type(span.rowSpan) ~= "number" then
        return messages
    end
    if span.rowSpan >= 2 then
        return messages
    end

    if config.showPercent then
        messages[#messages + 1] = "showPercent needs a panel two rows tall;"
            .. " a single row has no space beneath the reading at any width."
            .. " Give the panel rowSpan 2, or drop showPercent."
    end

    return messages
end

--- Describe how the component presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
--- @param showPercent? boolean Whether the layout asked for the estimate.
function txBattery.presentationFor(colSpan, rowSpan, showPercent)
    local cells = (colSpan or 1) * (rowSpan or 1)
    -- The estimate is the only thing this panel's supporting row carries, and
    -- it is off by default. A row nobody fills is a reserved quarter of the
    -- panel and an empty label, so the span's permission is narrowed by what
    -- the layout actually asked for.
    return {
        showVisual = cells >= 2,
        showDetail = cells >= 2 and showPercent == true,
    }
end

--- Tallest cell this panel will draw.
--- An upright battery given every pixel of a two-row panel would be taller
--- than the number beside it, and a battery is an indicator rather than the
--- reading. Fifty pixels stands a little above an XXLSIZE line's ascent.
txBattery.GLYPH_MAX_HEIGHT = 50

--- Choose the largest glyph the panel can afford beside its reading.
---
--- The cell stands upright, so **height is what is searched and width follows
--- it**. That is the whole of what turning it vertical changed here: a lying
--- battery was bounded by the width the reading left, and an upright one is
--- bounded by the room above the supporting row as well, so both have to be
--- satisfied at once.
---
--- **The reading's font is no longer what this search protects.** It comes
--- from the body band now, which is derived from the panel and does not
--- consult the content at all, so nothing the glyph does can shrink the
--- number. What the glyph has to fit is its own slot: the search is for the
--- largest cell that lives in the right slot without reaching the left one.
---
--- Sized by search rather than by formula because the answer is not smooth:
--- a glyph one pixel narrower can be the difference between it fitting its
--- slot and being shed, and there is no expression for where that edge falls
--- that is not just this loop written out.
---@param primitives table Owns what is too small to read as a battery.
---@param slot integer Width the glyph's own slot has.
---@param tall integer Vertical pixels the body band gives it.
---@return integer? width
---@return integer? height
function txBattery.glyphFor(primitives, slot, tall)
    -- As tall as its band allows, capped so a cell beside an XXLSIZE reading
    -- is an indicator rather than a second reading.
    local ideal = math.min(txBattery.GLYPH_MAX_HEIGHT, tall)

    for height = ideal, primitives.GLYPH_MIN_HEIGHT, -1 do
        local width = math.max(primitives.GLYPH_MIN_WIDTH, math.floor(height / primitives.GLYPH_ASPECT + 0.5))
        if width <= slot then
            return width, height
        end
    end

    return nil, nil
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param primitives table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@return table
function txBattery.regionsFor(theme, themeBuilder, primitives, rect, layout, fonts)
    local spacing = theme.spacing
    local frame = themeBuilder.frame(theme, rect, fonts)
    local labelHeight = frame.labelHeight
    -- Composition comes from the shared ladder, so a panel of this size carries
    -- the same rows as any other panel of this size, whichever component drew
    -- it. What this component wants is a veto, not a vote.
    --
    -- The ladder is not told what will be drawn, because the bands no longer
    -- ask: a panel reserves its bottom quarter whether or not the percentage
    -- is on. This component used to declare it and gain a font size at every
    -- two-row span; that gain is what the fixed-bands rule gives back, and the
    -- design guide records the user choosing consistency over it.
    local ladder = themeBuilder.ladder(theme, rect, frame)
    local showVisual = layout.showVisual and ladder.visual
    local showDetail = layout.showDetail and ladder.rows > 0
    local wantsGlyph = layout.visual == "battery"
    local showBar = showVisual and layout.visual == "bar"

    -- A bar is exempt from the arrangement and keeps the panel's floor. Its
    -- length *is* the reading, and a track that stops short of the panel edge
    -- measures against a scale the eye cannot see.
    local barY = math.max(1, rect.h - frame.bottom - spacing.barHeight)

    -- The bands and the font come from the shared ladder, so this panel is
    -- banded the same way every panel of its size is, whichever component drew
    -- it.
    local bands = ladder.bands

    -- The font comes from the panel's own height, so it does not consult the
    -- reading at all and cannot change as the voltage does.
    local value = themeBuilder.bandFont(ladder.room)
    local unitFont = themeBuilder.unitFont(value)
    local valueHeight = themeBuilder.fontHeight(value)

    -- Half the content is what either element may claim, whichever slots the
    -- panel settles on. The right slot's centre moves between 70% and 75%, but
    -- its half never grows, so sizing the glyph against the half is the answer
    -- both arrangements accept.
    local half = math.floor(frame.content / 2)

    -- **The cell takes the reading's room, and that is now enough to keep it
    -- off the row.** The two share a centre and that centre is the panel's, so
    -- a cell sized against a budget the reading's own centring is safe with is
    -- safe with it too -- `theme.readingRoom` is what caps both against the
    -- supporting row. It was not always: the cell was sized against half the
    -- panel while the row was still measured from the middle band, and a
    -- 117 by 84 panel stood its cell one pixel into the percentage.
    local glyphWidth, glyphHeight
    if wantsGlyph and showVisual then
        glyphWidth, glyphHeight = txBattery.glyphFor(primitives, half, ladder.room)
        -- A panel that cannot hold a glyph sheds it, the way it sheds any other
        -- visual. It does not fall back to a bar: the layout asked for a
        -- battery, and a bar in its place is a different answer to the question.
        if not glyphWidth then
            showVisual = false
        end
    end

    -- **The slot is reserved on the basis that this layout could ever show a
    -- battery, not on whether one is being drawn.** The range comes from a live
    -- `getGeneralSettings` subscription rather than from anything known when
    -- the panel is built, so a reading placed on the whole content box now and
    -- on the left slot two frames later would move exactly once per power-up,
    -- and again whenever a pilot edits the battery meter range in flight. That
    -- is the objection this arrangement exists to avoid, so the slot is held
    -- open and the panel accepts an empty right half where no range ever
    -- arrives.
    local reserveSlot = wantsGlyph and showVisual

    -- The unit is redundancy and is bought with width, never with a size. The
    -- number it rides beside has already been chosen by the band.
    local function widthOf(room)
        local rides = themeBuilder.readingWidth(value, txBattery.DIGITS, unitFont, txBattery.UNIT) <= room
        return rides, themeBuilder.readingWidth(value, txBattery.DIGITS, unitFont, rides and txBattery.UNIT or nil)
    end

    -- Asked of `88.8`, the widest a transmitter pack prints, so the arrangement
    -- is fixed for the life of the panel rather than flipping as the voltage
    -- crosses a digit.
    local showUnit, valueWidth = widthOf(reserveSlot and half or frame.content)
    local slots, separated
    if reserveSlot then
        slots, separated = themeBuilder.slotsFor(frame, valueWidth, glyphWidth)
        if not separated then
            -- **No pair of slots separates them, so the glyph goes.** A band-derived
            -- font does not consult the content, so the reading cannot be made
            -- narrower to accommodate a cell, and `1 x 2` is the span where that
            -- bites: 105 px of content, a DBLSIZE `88.8` that wants 93 of them, and
            -- half a panel is 52. Shedding the visualization is what the panel
            -- already does when it cannot hold one, and it is the answer
            -- `navigation` reaches at `1 x 1` for the same reason.
            showVisual, reserveSlot = false, false
            glyphWidth, glyphHeight, slots = nil, nil, nil
            showUnit, valueWidth = widthOf(frame.content)
        end
    end

    local leftCentre = reserveSlot and select(1, themeBuilder.slotCentres(frame, slots))
        or (frame.pad + math.floor(frame.content / 2))
    local rightCentre = reserveSlot and select(2, themeBuilder.slotCentres(frame, slots)) or nil

    -- Two boxes sharing an optical centre stack to the taller of them, so the
    -- block the band centres is simply the deeper of reading and glyph --
    -- measured as ink rather than as line box, because a font's descent and
    -- leading are not drawn and centring them leaves the number high.
    local valueInk = themeBuilder.fontAscent(value)
    local blockHeight = math.max(valueInk, glyphHeight or 0)
    local blockTop = themeBuilder.bodyTop(ladder, blockHeight)
    local valueY = blockTop + math.floor((blockHeight - valueInk) / 2)

    local glyphX, glyphY, glyphBorder
    if glyphWidth then
        -- The stroke is answered here, where the reading's font is known, so the
        -- cell is outlined for the number it stands beside rather than for the
        -- span it happens to be at.
        glyphBorder = primitives.batteryStroke(themeBuilder, value, glyphWidth)
        glyphX = themeBuilder.slotX(rightCentre, glyphWidth)
        glyphY = blockTop + math.floor((blockHeight - glyphHeight) / 2)
    end

    -- One item on a row centres across the whole content box, exactly as a lone
    -- reading does. The percentage used to sit under the glyph where it fitted
    -- there, which made the supporting row's position depend on what was above
    -- it; a row derived from the panel does not.
    -- Hung from the panel's floor, or from the bar where this layout asks for
    -- one. `showBar` is settled from the layout and the ladder before the
    -- glyph shedding below can touch it, so it is what this panel *reserves*
    -- rather than what is on screen -- which is the question the floor has to
    -- be asked, or the row would move when a cell was shed.
    local detailY = themeBuilder.rowTop(frame, fonts.label, showBar and barY or rect.h)

    return {
        frame = frame,
        pad = frame.pad,
        content = frame.content,
        bands = bands,
        labelY = themeBuilder.clampToPanel(themeBuilder.centreInBand(bands.label, labelHeight), fonts.label, rect.h),
        valueY = valueY,
        -- **The slot's centre, which is a property of the panel.** Where the
        -- reading actually starts depends on what it currently says, so it is
        -- computed from the measured string when the string is known rather than
        -- from the widest one at build. `primitives.centreReading` owns that.
        valueCentre = leftCentre,
        -- Where a `--` reading sits until the first real value arrives. The
        -- widest string still sizes the box, so nothing wraps before then.
        valueX = themeBuilder.slotX(leftCentre, valueWidth),
        value = value,
        unitFont = unitFont,
        showUnit = showUnit,
        valueWidth = valueWidth,
        glyphX = glyphX,
        glyphY = glyphY,
        glyphWidth = glyphWidth,
        glyphHeight = glyphHeight,
        glyphBorder = glyphBorder,
        detailUnderGlyph = false,
        detailX = frame.pad,
        detailWidth = frame.content,
        detailY = detailY,
        barY = barY,
        showVisual = showVisual,
        showDetail = showDetail,
        showGlyph = glyphWidth ~= nil,
        showBar = showBar,
    }
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridTxBatterySettings
---@param services table
---@return AeroGridTxBatteryContext
function txBattery.create(parent, rect, settings, services)
    local theme = services.theme
    local primitives = services.primitives
    local fonts = services.fonts
    local span = services.span
    local layout = txBattery.presentationFor(span.colSpan, span.rowSpan, settings.showPercent)
    layout.visual = settings.visual
    local presentation = services.state("normal", settings.accent)
    local area = txBattery.regionsFor(theme, services.themeBuilder, primitives, rect, layout, fonts)

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
        -- `render` needs this: the percentage is fitted to the column it lands
        -- in, which is the glyph's when it sits under one.
        detailWidth = area.detailWidth,
    }

    local modelService = services.model
    if modelService then
        context.feed = modelService:txVoltage()
        -- Subscribed rather than read once: a pilot can change the meter range in
        -- radio settings while the dashboard is running, and nothing rebuilds a
        -- widget for that the way a model change does.
        context.range = modelService:batteryRange()
    end

    local panel = primitives.panel(parent, rect, theme, presentation)
    context.panel = panel

    context.label, context.badge =
        primitives.header(panel.root, theme, area.frame, fonts, settings.label, presentation, services.themeBuilder)

    context.value = primitives.value(panel.root, theme, {
        x = area.valueX,
        y = area.valueY,
        -- Exactly what the reading and its unit occupy, because it is centred on
        -- a slot rather than started at an edge: a label given more width than it
        -- needs would centre the slot on the wrong point.
        w = area.valueWidth,
        text = "--",
        color = presentation.value,
        font = area.value,
    })

    -- Created whenever the panel could ever show it, and hidden until it does,
    -- for the reason every optional object here is: whether it is shown can
    -- change on a reflow and rebuilding an object is not free.
    context.unit = primitives.unit(panel.root, theme, {
        x = area.valueX,
        y = area.valueY,
        text = txBattery.UNIT,
        color = theme.color.textMuted,
        font = area.unitFont,
    })

    -- Built only where the layout asked for the estimate: on every other
    -- panel it was an object built to be hidden, and a row that could never be
    -- filled.
    if settings.showPercent then
        context.detailLabel = primitives.label(panel.root, theme, {
            x = area.detailX,
            y = area.detailY,
            w = area.detailWidth,
            text = "",
            color = theme.color.textFaint,
            font = fonts.label,
        })
    end

    -- The bar is an estimate, so it is built whenever the panel could ever have
    -- a range to measure against, and hidden until one arrives. It used to be
    -- built only when the layout stated a range, which was safe while that was
    -- the only source; the radio's range arrives on the service's first update,
    -- after this runs, so deciding here would have meant no bar ever.
    if layout.showVisual and settings.visual == "bar" then
        context.bar = primitives.bar(panel.root, theme, {
            x = area.pad,
            y = area.barY,
            w = area.content,
            fraction = 0,
            color = presentation.accent,
        })
    elseif settings.visual == "battery" and area.showGlyph then
        context.glyph = primitives.batteryGlyph(panel.root, theme, {
            x = area.glyphX,
            y = area.glyphY,
            w = area.glyphWidth,
            h = area.glyphHeight,
            fraction = 0,
            color = presentation.accent,
            border = area.glyphBorder,
        })
    end

    if context.detailLabel and not area.showDetail then
        lvgl.hide(context.detailLabel)
    end
    if not area.showUnit then
        lvgl.hide(context.unit)
    end
    context.showUnit = area.showUnit
    context.area = area
    -- What the panel currently shows, so `render` declares only that and a
    -- reflow that changes nothing about visibility does not tell every object
    -- again what it already is.
    context.showVisual = area.showVisual
    context.showDetail = area.showDetail
    -- Whether the bar is *showing* is the box's answer and the range's answer
    -- together, and the second only arrives once the service has run.
    context.barShown = false
    context.glyphShown = false
    context.barX, context.barY, context.barWidth = area.pad, area.barY, area.content
    context.glyphRect = { x = area.glyphX, y = area.glyphY, w = area.glyphWidth, h = area.glyphHeight }

    if context.bar and not area.showVisual then
        lvgl.hide(context.bar.track)
        lvgl.hide(context.bar.fill)
    end
    if context.glyph then
        -- Built hidden and revealed by `apply`, for the same reason the bar is:
        -- whether there is a range to measure against is only known once the
        -- service has run, which is after this.
        lvgl.hide(context.glyph.shell)
        lvgl.hide(context.glyph.nub)
        lvgl.hide(context.glyph.fill)
    end

    local _, drawn = primitives.changed(context, txBattery.render)
    txBattery.apply(context, drawn)
    return context
end

--- Repaint the component from its current subscription.
---@param context AeroGridTxBatteryContext
--- Collect everything this panel draws.
---@param out table
function txBattery.render(context, out)
    local settings = context.settings
    local feed = context.feed
    local value = type(feed) == "table" and feed.available and feed.value or nil
    local stale = type(feed) == "table" and feed.stale == true

    out.state = txBattery.resolveState(settings, value, stale)
    -- The form the fitter chose, not the longest one. The fitter was picking
    -- `88.8` at a `1 x 2` -- DBLSIZE, 93 pixels of a 105 pixel column -- and
    -- this printed `88.8V`, which is 116 and wraps onto a second line over
    -- whatever is beneath it. It has been true since the forms were written and
    -- only showed above 9.9 V, because `7.9V` happens to fit where `10.0V` does
    -- not. The same shape as the flight mode's name: measure one string, draw
    -- another.
    out.text = txBattery.reading(value)
    -- Whether there is a range at all is part of what the panel draws: it
    -- decides whether the bar and the percentage appear, and it can change
    -- after the panel is built.
    out.ranged = txBattery.hasRange(settings, context.range)
    out.fraction = txBattery.fraction(settings, value, context.range)
    out.value = value

    -- One decimal: a transmitter pack reported to three flickers constantly and
    -- reads no better.
    -- Declared only where it is drawn. Every single-row span sheds this row,
    -- so a `4 x 1` was formatting a percentage every frame and writing it into
    -- a hidden label.
    if context.showDetail and out.ranged and settings.showPercent and type(value) == "number" then
        local percent = math.floor(out.fraction * 100 + 0.5)
        -- `EST` says the number is a linear fit rather than a gauge, so it is the
        -- first thing to go when the column is narrow -- which under a glyph it
        -- usually is. Fitted rather than assumed, like every other supporting row.
        out.detail = context.themeBuilder.fitLabel(
            { percent .. "% EST", percent .. "%" },
            context.fonts.label,
            context.detailWidth
        )
    end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridTxBatteryContext
---@param drawn table
function txBattery.apply(context, drawn)
    local presentation = context.state(drawn.state, context.settings.accent)

    context.stateName = drawn.state
    context.reading = drawn.value
    context.text = drawn.text
    context.detail = drawn.detail or ""

    context.value:set({ text = drawn.text, color = presentation.value })
    -- The reading is centred on its slot, so where it starts depends on what
    -- it says: both the number and the unit beside it move together when the
    -- digit count changes. Guarded on the text inside the helper, so a panel
    -- whose voltage is steady pays nothing.
    context.unitText = txBattery.UNIT
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
    if context.showDetail then
        context.detailLabel:set({ text = context.detail })
    end
    context.primitives.stylePanel(context.panel, presentation)

    -- A bar with nothing to measure against is not a quiet bar, it is a
    -- confident one drawn from nothing, so it stays away until a range exists.
    local barShown = context.bar ~= nil and context.showVisual and drawn.ranged
    if barShown then
        context.primitives.setBar(context.bar, drawn.fraction, presentation.accent)
    end
    if context.bar and barShown ~= context.barShown then
        context.primitives.reconcileBar(
            context.bar,
            barShown,
            context.barX,
            context.barY,
            context.barWidth,
            drawn.fraction
        )
        context.barShown = barShown
    end

    -- And the glyph, on the same terms: an outline with no fill in it is a
    -- claim that the pack is empty, which is worse than showing nothing.
    local glyphShown = context.glyph ~= nil and context.showVisual and drawn.ranged
    if glyphShown then
        context.primitives.setBatteryGlyph(context.glyph, drawn.fraction, presentation.accent)
    end
    if context.glyph and glyphShown ~= context.glyphShown then
        local rect = context.glyphRect
        context.primitives.reconcileBatteryGlyph(
            context.glyph,
            glyphShown,
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            drawn.fraction
        )
        context.glyphShown = glyphShown
    end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridTxBatteryContext
function txBattery.refresh(context)
    if not context.feed then
        return
    end
    local changed, drawn = context.primitives.changed(context, txBattery.render)
    if changed then
        txBattery.apply(context, drawn)
    end
end

--- Reposition after a zone change.
---@param context AeroGridTxBatteryContext
---@param rect AeroGridRect
function txBattery.update(context, rect)
    local area = txBattery.regionsFor(
        context.theme,
        context.themeBuilder,
        context.primitives,
        rect,
        context.layout,
        context.fonts
    )

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
    context.value:set({
        x = area.valueX,
        y = area.valueY,
        w = area.valueWidth,
        font = function()
            return area.value
        end,
    })

    context.primitives.reconcileUnit(
        context,
        context.unit,
        area.showUnit,
        context.themeBuilder,
        area.valueX,
        area.valueY,
        area.value,
        context.text,
        area.unitFont,
        area.showUnit == context.showUnit
    )
    context.showUnit = area.showUnit
    -- Both anchors are about a slot and a font that have just moved, so they
    -- are discarded rather than trusted. Without clearing the reading's, a
    -- panel that reflowed while its voltage held steady would keep the
    -- position it had at the old span.
    context.unitAnchor = nil
    context.readingAnchor = nil

    context.primitives.reconcile(
        context.detailLabel,
        area.showDetail,
        { x = area.detailX, y = area.detailY, w = area.detailWidth },
        area.showDetail == context.showDetail
    )

    -- A row that has just reappeared holds whatever it had when it was shed,
    -- and `render` stopped declaring its key while it was hidden. The same
    -- applies when the row merely moved column: the percentage is fitted to its
    -- width, so a narrower column wants it written again.
    if area.showDetail ~= context.showDetail or area.detailWidth ~= context.detailWidth then
        context.rendered = nil
    end
    context.showDetail = area.showDetail
    context.detailWidth = area.detailWidth
    context.area = area

    local ranged = txBattery.hasRange(context.settings, context.range)
    local fraction = txBattery.fraction(context.settings, context.reading, context.range)

    context.barX, context.barY, context.barWidth = area.pad, area.barY, area.content
    local barShown = context.bar ~= nil and area.showVisual and ranged
    context.primitives.reconcileBar(
        context.bar,
        barShown,
        area.pad,
        area.barY,
        area.content,
        fraction,
        barShown == context.barShown
    )
    context.barShown = barShown

    -- A reflow can take the glyph away entirely: a panel narrowed to one cell
    -- has nowhere to put it, and the reading has first claim on the width.
    local glyphShown = context.glyph ~= nil and area.showVisual and area.showGlyph and ranged
    if area.showGlyph then
        context.glyphRect = { x = area.glyphX, y = area.glyphY, w = area.glyphWidth, h = area.glyphHeight }
    end
    local rect2 = context.glyphRect
    context.primitives.reconcileBatteryGlyph(
        context.glyph,
        glyphShown,
        rect2.x,
        rect2.y,
        rect2.w,
        rect2.h,
        fraction,
        glyphShown == context.glyphShown
    )
    context.glyphShown = glyphShown
    context.showVisual = area.showVisual
end

return txBattery
