-- SPDX-License-Identifier: GPL-2.0-only

--- Reference metric component for the AeroGrid design system.
--- It demonstrates every theme mode, every component state, and the three
--- baseline spans, built entirely from host theme tokens and shared primitives.
---
--- Domain presets exist so altitude and speed do not need their own component
--- files. A preset supplies labels, an accent, likely source defaults, and an
--- extrema mode; every one of them remains overridable from the layout, so the
--- dashboard never depends on a protocol-specific sensor name.

---@class AeroGridMetricSettings
---@field preset? "custom"|"altitude"|"speed"
---@field label? string
---@field source? string EdgeTX source name read through telemetryService.
---@field unit? string Overrides the sensor's own unit label.
---@field accent? "cyan"|"green"|"amber"|"orange"
---@field rangeMin? number
---@field rangeMax? number
---@field warning? number
---@field critical? number
---@field precision? number
---@field visual? "bar"|"radial"|"none"
---@field extrema? "source"|"flight"|"none"
---@field extremaMode? "min"|"max"
---@field extremaSource? string Explicit EdgeTX extreme source name.
---@field secondarySource? string
---@field secondaryLabel? string

---@class AeroGridMetricContext
---@field panel table
---@field theme AeroGridTheme
---@field primitives table
---@field state fun(name: string, accent?: string): table
---@field layout table Resolved presentation for the current span.
---@field feed? AeroGridReading Immutable telemetry subscription.
---@field reading? number Last applied reading.
---@field stateName string Current resolved state name.

local metric = {
    id = "metric",
    apiVersion = 1,
    -- Every region is derived from the measured rectangle, so the component
    -- adapts to any span it is given; the spans below are the ones whose
    -- presentations are defined and verified.
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
    -- A numeric readout is indistinguishable at 5 Hz and 50 Hz in flight, and
    -- the host pays every component's refresh inside one instruction budget.
    refreshInterval = 20,
    settings = {
        {
            key = "preset",
            label = "Preset",
            type = "string",
            default = "custom",
            choices = { "custom", "altitude", "speed" },
        },
        -- Absent means "take the preset's value". Presets cannot be expressed as
        -- schema defaults, because the host fills those in before the component
        -- runs and a filled default is indistinguishable from a stated one.
        -- An empty label is not an absent one: it means derive the heading at
        -- runtime, here from the preset's label, or METRIC when the preset is custom. A
        -- component with a fixed heading states it as its default instead.
        { key = "label", label = "Label", type = "string", default = "" },
        { key = "source", label = "Source", type = "string", default = "" },
        { key = "unit", label = "Unit", type = "string", default = "" },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "",
            choices = { "", "cyan", "green", "amber", "orange" },
        },
        -- The range the visualization normalizes against. It is not a limit and
        -- never clamps the reading: a value outside it is still drawn. Named for
        -- what it bounds, because four components meant four things by `min`.
        { key = "rangeMin", label = "Range minimum", type = "number" },
        { key = "rangeMax", label = "Range maximum", type = "number" },
        { key = "warning", label = "Warning, in the configured unit", type = "number" },
        { key = "critical", label = "Critical, in the configured unit", type = "number" },
        -- Which way the thresholds count. `auto` can only be inferred from two
        -- thresholds, so a layout with one states it.
        {
            key = "direction",
            label = "Threshold direction",
            type = "string",
            default = "auto",
            choices = { "auto", "rising", "falling" },
        },
        -- Negative means follow the sensor's own configured precision.
        { key = "precision", label = "Decimal places", type = "number", default = -1 },
        {
            key = "visual",
            label = "Visualization",
            type = "string",
            default = "",
            choices = { "", "bar", "radial", "none" },
        },
        {
            key = "extrema",
            label = "Extrema",
            type = "string",
            default = "",
            choices = { "", "source", "flight", "none" },
        },
        {
            key = "extremaMode",
            label = "Extreme tracked",
            type = "string",
            default = "",
            choices = { "", "min", "max" },
        },
        { key = "extremaSource", label = "Extrema source", type = "string", default = "" },
        { key = "secondarySource", label = "Secondary source", type = "string", default = "" },
        { key = "secondaryLabel", label = "Secondary label", type = "string", default = "" },
    },
}

--- Domain presets from the specification.
--- Each supplies only what a pilot would otherwise have to type; a layout that
--- states a key always wins, so the preset never overrides explicit intent.
metric.PRESETS = {
    custom = {
        label = "METRIC",
        accent = "cyan",
        visual = "bar",
        extrema = "none",
        extremaMode = "max",
    },
    altitude = {
        label = "ALT",
        source = "Alt",
        accent = "green",
        visual = "bar",
        rangeMin = 0,
        rangeMax = 400,
        extrema = "source",
        extremaMode = "max",
        -- Vertical speed is shown only when the configured source is valid.
        -- Deriving it from altitude needs filtering behaviour this release does
        -- not define, so it is never computed.
        secondarySource = "VSpd",
        secondaryLabel = "VS",
    },
    speed = {
        label = "SPD",
        source = "GSpd",
        accent = "cyan",
        visual = "bar",
        rangeMin = 0,
        rangeMax = 200,
        extrema = "source",
        extremaMode = "max",
    },
}

--- Resolve one setting, falling back to the preset and then to a literal.
---@param settings AeroGridMetricSettings
---@param preset table
---@param key string
---@param fallback any
---@return any
function metric.setting(settings, preset, key, fallback)
    local stated = settings[key]
    if stated ~= nil and stated ~= "" then
        return stated
    end

    local fromPreset = preset[key]
    if fromPreset ~= nil then
        return fromPreset
    end
    return fallback
end

--- Apply a preset over the resolved settings, in place.
--- Doing this once, in create, means neither refresh nor update has to know
--- that presets exist.
---@param settings AeroGridMetricSettings
---@return table preset
function metric.applyPreset(settings)
    local preset = metric.PRESETS[settings.preset] or metric.PRESETS.custom

    settings.label = metric.setting(settings, preset, "label", "METRIC")
    settings.source = metric.setting(settings, preset, "source", "")
    settings.accent = metric.setting(settings, preset, "accent", "cyan")
    settings.visual = metric.setting(settings, preset, "visual", "bar")
    settings.extrema = metric.setting(settings, preset, "extrema", "none")
    settings.extremaMode = metric.setting(settings, preset, "extremaMode", "max")
    settings.secondarySource = metric.setting(settings, preset, "secondarySource", "")
    settings.secondaryLabel = metric.setting(settings, preset, "secondaryLabel", "")

    if type(settings.rangeMin) ~= "number" then
        settings.rangeMin = preset.rangeMin
    end
    if type(settings.rangeMax) ~= "number" then
        settings.rangeMax = preset.rangeMax
    end

    if settings.extrema ~= "source" and settings.extrema ~= "flight" then
        settings.extrema = "none"
    end
    if settings.extremaMode ~= "min" then
        settings.extremaMode = "max"
    end

    return preset
end

--- Describe how the component presents itself at a given span.
--- Unsupported spans are rejected by metadata, so each entry here is deliberate.
--- A 1 x 1 shows only label and value; wider spans add units, a visualization,
--- and finally the supporting detail row carrying extrema and the secondary
--- reading.
---@param colSpan integer
---@param rowSpan integer
---@return table
function metric.presentationFor(colSpan, rowSpan)
    local cells = (colSpan or 1) * (rowSpan or 1)

    if cells >= 4 then
        return {
            showUnit = true,
            showRange = true,
            showVisual = true,
            showSecondary = true,
            valueY = 42,
        }
    end
    if cells >= 2 then
        return {
            showUnit = true,
            showRange = false,
            showVisual = true,
            showSecondary = false,
            valueY = 28,
        }
    end

    return {
        showUnit = false,
        showRange = false,
        showVisual = false,
        showSecondary = false,
        valueY = 24,
    }
end

--- Format a reading with fixed decimals so the text width stays stable.
---@param value any
---@param precision any
---@return string
function metric.format(value, precision)
    if type(value) ~= "number" or value ~= value then
        return "--"
    end

    local digits = math.floor(tonumber(precision) or 0)
    if digits < 0 then
        digits = 0
    end
    if digits > 3 then
        digits = 3
    end

    return string.format("%." .. digits .. "f", value)
end

--- Resolve how many decimals to print.
--- A negative configured precision means "follow the sensor", which is what
--- the telemetry service normalizes from the model's sensor table. A layout
--- that states a precision always wins, because a pilot may want a coarser
--- readout than the sensor offers.
---@param context AeroGridMetricContext
---@return integer
function metric.digitsFor(context)
    local configured = context.settings.precision
    if type(configured) == "number" and configured >= 0 then
        return configured
    end

    local feed = context.feed
    if feed and type(feed.precision) == "number" then
        return feed.precision
    end
    return 0
end

--- Report whether thresholds count downward for this metric.
---@param settings AeroGridMetricSettings
---@return boolean
local function isFalling(settings)
    local warning = type(settings.warning) == "number" and settings.warning or nil
    local critical = type(settings.critical) == "number" and settings.critical or nil

    if settings.direction == "falling" then
        return true
    end
    if settings.direction == "rising" then
        return false
    end
    return warning ~= nil and critical ~= nil and critical < warning
end

--- Resolve the component state from thresholds and reading availability.
--- Direction may be stated explicitly. When left on `auto` it can only be
--- inferred from two thresholds; a single threshold alone is ambiguous, so it
--- is treated as rising and the component documents that in its settings.
---@param settings AeroGridMetricSettings
---@param value any
---@param stale boolean
---@return string
function metric.resolveState(settings, value, stale)
    if type(value) ~= "number" or value ~= value then
        return "unavailable"
    end
    if stale then
        return "stale"
    end

    local warning = type(settings.warning) == "number" and settings.warning or nil
    local critical = type(settings.critical) == "number" and settings.critical or nil
    local falling = isFalling(settings)

    if critical ~= nil then
        if falling and value <= critical then
            return "critical"
        end
        if not falling and value >= critical then
            return "critical"
        end
    end
    if warning ~= nil then
        if falling and value <= warning then
            return "warning"
        end
        if not falling and value >= warning then
            return "warning"
        end
    end

    return "normal"
end

--- Read whichever extreme the layout asked for.
--- `source` mode reads EdgeTX's own "<name>-" or "<name>+" sensor, which the
--- radio maintains on its own schedule. `flight` mode reads the dashboard's
--- own session extrema, which cover exactly one flight. The two are not
--- interchangeable and the component never silently substitutes one.
---@param context AeroGridMetricContext
---@return number? value
---@return boolean available
function metric.extremeValue(context)
    local mode = context.settings.extrema

    if mode == "source" then
        local reading = context.extremeFeed
        if type(reading) ~= "table" or not reading.available then
            return nil, false
        end
        return reading.value, type(reading.value) == "number"
    end

    if mode == "flight" then
        local track = context.sessionExtrema
        if type(track) ~= "table" or not track.available then
            return nil, false
        end
        local value = context.settings.extremaMode == "min" and track.min or track.max
        return value, type(value) == "number"
    end

    return nil, false
end

--- Format the supporting detail row's left-hand text.
--- With no extrema configured the row falls back to the configured range,
--- which is what the panel showed before extrema existed.
---@param context AeroGridMetricContext
---@return string
function metric.detailText(context)
    local settings = context.settings

    if settings.extrema == "none" then
        return metric.format(settings.rangeMin, 0) .. " - " .. metric.format(settings.rangeMax, 0)
    end

    local value, available = metric.extremeValue(context)
    local caption = settings.extremaMode == "min" and "MIN " or "MAX "
    if not available then
        return caption .. "--"
    end
    return caption .. metric.format(value, metric.digitsFor(context))
end

--- Format the supporting detail row's right-hand text.
---@param context AeroGridMetricContext
---@return string
function metric.secondaryText(context)
    local feed = context.secondaryFeed
    if type(feed) ~= "table" then
        return ""
    end

    local caption = context.settings.secondaryLabel
    if type(caption) ~= "string" or caption == "" then
        caption = "2ND"
    end

    if not feed.available or type(feed.value) ~= "number" then
        return caption .. " --"
    end

    local digits = type(feed.precision) == "number" and feed.precision or 0
    local text = caption .. " " .. metric.format(feed.value, digits)
    if feed.unitText and feed.unitText ~= "" then
        text = text .. feed.unitText
    end
    return text
end

--- Advance the component from its telemetry subscription.
--- Nothing is repainted unless the reading or its freshness actually changed,
--- because the host pays this for every metric on the dashboard.
---@param context AeroGridMetricContext
--- Collect everything this panel draws.
---
--- Metric kept a separate cache beside each `set` call rather than one list,
--- which is safe but is a third mechanism: the catalogue now has one, and a
--- component that opts out of it is a component the next reader has to check
--- by hand.
---@param out table
function metric.render(context, out)
    local settings = context.settings
    local feed = context.feed
    local forced = context.forced
    local value = feed and feed.available and feed.value or nil
    local stale = feed and feed.stale == true or false
    if forced then
        value, stale = forced.value, forced.stale
    end

    out.state = metric.resolveState(settings, value, stale)
    -- The sensor's precision is only known once the source resolves, so it has
    -- to repaint even when the reading itself has not moved.
    out.text = metric.format(value, metric.digitsFor(context))
    out.fraction = metric.fraction(settings, value)
    out.value = value

    -- The sensor's unit is likewise only known once the source resolves, so the
    -- label follows it rather than being fixed when the panel was built.
    if context.showUnit and settings.unit == "" then
        out.unit = feed and feed.unitText or ""
    end
    -- The detail row moves independently of the primary reading: an extreme
    -- changes on its own schedule and a secondary sensor has its own source.
    --
    -- Gated on whether the row is showing, not on whether it was built. A panel
    -- shrinks its rows away and this used to go on formatting them, which was
    -- work with no reader; it also meant a revealed row was already current by
    -- accident rather than by design, which is why this component alone needed
    -- no discard. Now the key is simply absent while the row is shed, and
    -- reappears when it is not, which is what `changed` compares.
    if context.showRange then
        out.range = metric.detailText(context)
    end
    if context.showSecondary then
        out.secondary = metric.secondaryText(context)
    end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridMetricContext
---@param drawn table
function metric.apply(context, drawn)
    local presentation = context.state(drawn.state, context.settings.accent)

    context.reading = drawn.value
    context.stateName = drawn.state
    context.text = drawn.text

    context.label:set({ color = presentation.label })
    context.value:set({ text = drawn.text, color = presentation.value })
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

    -- A sensor's unit arrives with its source rather than when the panel was
    -- built, so whether there is room beside the reading for it is settled here
    -- the first time one turns up.
    if context.unit and drawn.unit and drawn.unit ~= context.unitText then
        context.unitText = drawn.unit
        context.unit:set({ text = drawn.unit })
        local shows = context.area.showUnit
            and context.primitives.unitFits(
                context.themeBuilder,
                context.area.value,
                context.sample[1],
                context.area.unitFont,
                drawn.unit,
                context.area.valueBudget
            )
        if shows ~= context.showUnit then
            -- Permission only. Whether the unit is *drawn* is settled by
            -- `centreReading` immediately below, which is the one place that
            -- knows both this answer and what the reading currently says; a
            -- show here would be a second opinion, and it would win for one
            -- frame over a panel with no value to qualify.
            context.showUnit = shows
            -- Every anchor is about a slot and a font that have just moved.
            context.unitAnchor = nil
            context.readingAnchor, context.readingUnitAnchor = nil, nil
            context.rangeAnchor, context.secondaryAnchor = nil, nil
        end
    end
    context.primitives.centreReading(context, context.themeBuilder, context.area, context.area.value, drawn.text)
    if context.showRange and drawn.range then
        context.rangeText = drawn.range
        context.range:set({ text = drawn.range })
        -- The supporting row takes the panel's slot centres, keyed on what it
        -- says so a steady reading pays nothing.
        context.primitives.centreLabel(
            context,
            "rangeAnchor",
            context.themeBuilder,
            context.range,
            context.area.detailCentre,
            context.area.detailY,
            context.fonts.label,
            drawn.range
        )
    end
    if context.showSecondary and drawn.secondary then
        context.secondaryText = drawn.secondary
        context.secondary:set({ text = drawn.secondary })
        context.primitives.centreLabel(
            context,
            "secondaryAnchor",
            context.themeBuilder,
            context.secondary,
            context.area.rowRightCentre,
            context.area.detailY,
            context.fonts.label,
            drawn.secondary
        )
    end

    if context.bar then
        context.primitives.setBar(context.bar, drawn.fraction, presentation.accent)
    end
    if context.radial then
        context.primitives.setRadial(context.radial, drawn.fraction, presentation.accent)
    end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridMetricContext
function metric.refresh(context)
    if not context.feed then
        return
    end
    local changed, drawn = context.primitives.changed(context, metric.render)
    if changed then
        metric.apply(context, drawn)
    end
end

--- Convert a reading into a 0..1 fraction of the configured range.
---@param settings AeroGridMetricSettings
---@param value any
---@return number
function metric.fraction(settings, value)
    if type(value) ~= "number" or value ~= value then
        return 0
    end

    local low = type(settings.rangeMin) == "number" and settings.rangeMin or 0
    local high = type(settings.rangeMax) == "number" and settings.rangeMax or 100
    if high == low then
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

--- The forms this metric's reading may be drawn in, longest first.
---
--- There is only one. A metric draws its unit as a separate label, so the
--- reading is digits alone and there is no redundancy in it to give up:
--- dropping a digit would drop magnitude, which no font size is worth.
---
--- The forms are built from the configured range rather than from the current
--- reading, so the font is chosen once and does not change as the value moves.
---@param settings AeroGridMetricSettings
---@param digits integer
---@return string[]
function metric.widestSample(settings, digits)
    local low = type(settings.rangeMin) == "number" and settings.rangeMin or 0
    local high = type(settings.rangeMax) == "number" and settings.rangeMax or 100

    local widest = metric.format(low, digits)
    local other = metric.format(high, digits)
    if #other > #widest then
        widest = other
    end

    return { widest }
end

--- Compute every content region from the current rectangle.
--- The radial's diameter, as a function of the panel rather than a closure
--- built per call. A dial is square, so one number describes it; the builder
--- bounds it by the slot it has to live in as well as by the panel.
---@param panelRect AeroGridRect
---@return integer
local function radialSize(panelRect)
    return math.max(12, math.floor(math.min(panelRect.w, panelRect.h) / 5) * 2)
end

--- Regions are derived in one place so `create` and `update` cannot disagree,
--- and so the badge, value, unit, and visualization never share pixels.
---
--- Content is stacked using real EdgeTX font line heights rather than fixed
--- offsets. When the panel is too short, optional detail is shed before the
--- dominant reading is shrunk, and the value is finally clamped inside the
--- panel so it can never overflow. Width is checked as well as height,
--- because a long reading in a narrow cell clips sideways otherwise.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@param sample? string[] Lossless forms of the reading, longest first.
---@return table
function metric.regionsFor(theme, themeBuilder, rect, layout, fonts, sample, unit, out)
    -- The whole arrangement, from the shared builder. A radial is a compact
    -- visual and takes the right slot; a bar spans the panel and is exempt, so
    -- the same component splits under one setting and not the other.
    local area = themeBuilder.panel(theme, rect, fonts, {
        -- Built through this component's own builder, which the host may have
        -- wrapped to lay the panel out around the menu button's corner.
        frame = themeBuilder.frame(theme, rect, fonts),
        -- Only the longest form is offered, because a reading carrying a unit is
        -- fitted as a pair and `fitReadingUnit` takes one string. The shorter
        -- forms exist for `primitives.reconcile` to fall back to at draw time,
        -- which is a question about the value rather than about the panel.
        forms = { (sample or { "" })[1] or "" },
        unit = unit,
        draws = {
            rows = layout.showRange == true,
            visual = layout.showVisual == true and layout.visual ~= "none",
        },
        bar = true,
        compact = layout.visual == "radial" and radialSize or nil,
        -- **A row of two only where there will be two.** Whether this panel
        -- carries a secondary reading depends on a source being configured,
        -- which is why `create` resolves it onto the layout before asking.
        rowItems = layout.showSecondary == true and 2 or 1,
    }, out or {})

    -- The unit rides beside the reading rather than beneath it, so it costs
    -- the composition no height at all. Where its top sits depends on the two
    -- fonts, which is this component's business: it is the only one that
    -- prints a unit as a separate object.
    area.unitY = themeBuilder.unitTop(area.value, area.unitFont, area.valueY)
    -- The row was granted or it was not, and a secondary cannot be drawn into
    -- a row that does not exist.
    area.showSecondary = layout.showSecondary == true and area.showDetail

    -- The dial under this component's own names. EdgeTX positions an arc by
    -- its centre; the corner only reserves space.
    if area.visualSize then
        area.radius = math.floor(area.visualSize / 2)
    else
        -- A bar panel still reports a radius, because `create` sizes the object
        -- it may later reveal from it.
        area.radius = math.max(6, math.floor(math.min(rect.w, rect.h) / 5))
        area.visualCentreX = rect.w - area.frame.pad - area.radius
        area.visualCentreY = area.valueY + math.floor(themeBuilder.fontHeight(area.value) / 2)
    end
    area.radialX = area.visualCentreX - area.radius
    area.radialY = area.visualCentreY - area.radius
    return area
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridMetricSettings
---@param services table Host-provided shared objects.
---@return AeroGridMetricContext
function metric.create(parent, rect, settings, services)
    local theme = services.theme
    local primitives = services.primitives
    local fonts = services.fonts
    local span = services.span
    metric.applyPreset(settings)

    local layout = metric.presentationFor(span.colSpan, span.rowSpan)
    layout.visual = settings.visual
    -- **A row of two only where there will be two.** The span decides whether
    -- this panel *may* carry a secondary reading; whether it *does* depends on
    -- a source being configured, which the span cannot know. The geometry has
    -- to be told, because a row of one centres across the content box and a
    -- row of two takes the panel's two slot centres -- and a panel granted a
    -- secondary it never draws would otherwise centre its only supporting row
    -- on the left slot, which looks like a mistake and is one.
    layout.showSecondary = layout.showSecondary
        and type(settings.secondarySource) == "string"
        and settings.secondarySource ~= ""

    local presentation = services.state("normal", settings.accent)

    local context = {
        theme = theme,
        primitives = primitives,
        state = services.state,
        themeBuilder = services.themeBuilder,
        layout = layout,
        fonts = fonts,
        settings = settings,
        stateName = "normal",
        text = "--",
    }

    -- The host owns polling. Subscribing here, in create, is what tells the
    -- telemetry service that this source is referenced at all; a source nothing
    -- references is never read.
    local telemetry = services.telemetry
    if telemetry then
        context.feed = telemetry:subscribe(settings.source)
        if settings.secondarySource ~= "" then
            context.secondaryFeed = telemetry:subscribe(settings.secondarySource)
        end
    end

    local extrema = services.extrema
    if extrema and settings.extrema == "source" then
        -- An explicitly named extreme source wins, because not every protocol
        -- names its extremes after the base sensor.
        local named = settings.extremaSource
        if type(named) == "string" and named ~= "" then
            context.extremeFeed = telemetry and telemetry:subscribe(named) or nil
        else
            context.extremeFeed = extrema:sourceExtreme(settings.source, settings.extremaMode)
        end
    elseif extrema and settings.extrema == "flight" then
        -- The flight session decides where one flight's extrema end, so the arm
        -- switch is configured before the tracker is subscribed.
        local arm = services.session and services.session.armSource
        extrema:flight(arm ~= "" and arm or nil)
        context.sessionExtrema = extrema:sessionExtrema(settings.source)
    end

    local sample = metric.widestSample(settings, metric.digitsFor(context))
    context.unitText = tostring(settings.unit or "")
    local area = metric.regionsFor(theme, services.themeBuilder, rect, layout, fonts, sample, context.unitText)
    context.sample = sample

    local panel = primitives.panel(parent, rect, theme, presentation)
    context.panel = panel

    context.label, context.badge =
        primitives.header(panel.root, theme, area.frame, fonts, settings.label, presentation, services.themeBuilder)

    context.value = primitives.value(panel.root, theme, {
        x = area.valueX,
        y = area.valueY,
        w = area.valueWidth,
        text = "--",
        color = presentation.value,
        font = area.value,
    })

    -- Optional elements are created whenever the span could ever want them, and
    -- hidden when the current size cannot fit them, so a later enlargement can
    -- simply reveal them instead of needing a rebuild. The unit is created even
    -- when the layout names none, because the sensor supplies one once it
    -- resolves.
    if layout.showUnit then
        context.unit = primitives.unit(panel.root, theme, {
            x = area.valueX,
            y = area.unitY,
            text = context.unitText,
            color = theme.color.textMuted,
            font = area.unitFont,
        })
        -- Shown straight away when the layout named a unit, because then there
        -- is one to show and `regionsFor` has already said it fits. A sensor's
        -- own unit arrives when its source resolves, which is after this, so a
        -- panel that named none starts hidden and `apply` reveals it.
        if not area.showUnit then
            lvgl.hide(context.unit)
        end
        context.showUnit = area.showUnit
    end

    if layout.showVisual and settings.visual == "radial" then
        context.radial = primitives.radial(panel.root, theme, {
            x = area.visualCentreX,
            y = area.visualCentreY,
            radius = area.radius,
            color = presentation.accent,
            fraction = 0,
        })
    elseif layout.showVisual and settings.visual ~= "none" then
        context.bar = primitives.bar(panel.root, theme, {
            x = area.pad,
            y = area.barY,
            w = area.content,
            fraction = 0,
            color = presentation.accent,
        })
    end

    if layout.showRange then
        context.rangeText = metric.detailText(context)
        context.range = primitives.label(panel.root, theme, {
            x = area.detailX,
            y = area.detailY,
            w = area.detailWidth,
            text = context.rangeText,
            color = theme.color.textFaint,
            font = fonts.label,
        })
        -- Centred on its slot straight away. `apply` only re-places the row when
        -- the wording changes, and a panel whose range never changes would
        -- otherwise keep the left-aligned position it was built at.
        primitives.centreLabel(
            context,
            "rangeAnchor",
            services.themeBuilder,
            context.range,
            area.detailCentre,
            area.detailY,
            fonts.label,
            context.rangeText
        )
    end

    if layout.showSecondary and context.secondaryFeed then
        context.secondaryText = metric.secondaryText(context)
        context.secondary = primitives.label(panel.root, theme, {
            x = area.rowRightX,
            y = area.detailY,
            w = area.detailWidth,
            text = context.secondaryText,
            color = theme.color.textFaint,
            font = fonts.label,
        })
        primitives.centreLabel(
            context,
            "secondaryAnchor",
            services.themeBuilder,
            context.secondary,
            area.rowRightCentre,
            area.detailY,
            fonts.label,
            context.secondaryText
        )
    end

    -- Without a telemetry service there is nothing to subscribe to, so say so
    -- rather than leaving a dash that looks like a reading in progress.
    if not context.feed then
        metric.setValue(context, nil)
    end

    if context.unit and not area.showUnit then
        lvgl.hide(context.unit)
    end
    if context.range and not area.showDetail then
        lvgl.hide(context.range)
    end
    if context.secondary and not area.showSecondary then
        lvgl.hide(context.secondary)
    end
    -- A row exists when the span allows one and shows when the box has space
    -- for it. Only the second decides what is drawn, so only the second is
    -- what `render` is allowed to read. The unit is not among them any more:
    -- it depends on a unit that has not arrived, so `apply` settles it.
    context.area = area
    context.showRange = context.range ~= nil and area.showDetail == true
    context.showSecondary = context.secondary ~= nil and area.showSecondary == true
    -- What the panel currently shows, so a reflow that changes nothing about
    -- visibility does not tell every object again what it already is.
    context.showVisual = area.showVisual
    if not area.showVisual then
        if context.bar then
            lvgl.hide(context.bar.track)
            lvgl.hide(context.bar.fill)
        end
        if context.radial then
            lvgl.hide(context.radial.arc)
        end
    end

    return context
end

--- Apply a new reading and restyle the component for the resulting state.
---@param context AeroGridMetricContext
---@param value any
---@param stale? boolean
function metric.setValue(context, value, stale)
    -- Kept as the way a caller forces a reading, and routed through the same
    -- render-and-paint path so it cannot draw something `render` would not.
    context.forced = { value = value, stale = stale == true }
    local _, drawn = context.primitives.changed(context, metric.render)
    metric.apply(context, drawn)
    context.forced = nil
end

--- Reposition after a zone or configuration change.
--- The resolved region set can differ from the one `create` used, because a
--- smaller panel sheds optional detail. Objects whose region disappeared are
--- hidden rather than left at coordinates the new layout does not reserve,
--- and objects whose region returned are shown again.
---@param context AeroGridMetricContext
---@param rect AeroGridRect
function metric.update(context, rect)
    local theme = context.theme
    local area = metric.regionsFor(
        theme,
        context.themeBuilder,
        rect,
        context.layout,
        context.fonts,
        context.sample,
        context.unitText
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
        x = area.pad,
        y = area.valueY,
        w = area.valueWidth,
        -- LVGL takes the font as a callback, matching how it was created.
        font = function()
            return area.value
        end,
    })

    --- Show or hide an optional element, positioning it only when visible.
    local reconcile = context.primitives.reconcile

    context.showRange = context.range ~= nil and area.showDetail == true
    context.showSecondary = context.secondary ~= nil and area.showSecondary == true
    context.area = area

    local shows = area.showUnit
        and context.unit ~= nil
        and context.primitives.unitFits(
            context.themeBuilder,
            area.value,
            context.sample[1],
            area.unitFont,
            context.unitText,
            area.valueBudget
        )
    context.primitives.reconcileUnit(
        context,
        context.unit,
        shows,
        context.themeBuilder,
        area.valueX,
        area.valueY,
        area.value,
        context.text or "--",
        area.unitFont,
        shows == context.showUnit
    )
    context.showUnit = shows
    context.unitAnchor = nil
    reconcile(context.range, area.showDetail, { x = area.detailX, y = area.detailY, w = area.detailWidth })
    context.primitives.centreLabel(
        context,
        "rangeAnchor",
        context.themeBuilder,
        context.showRange and context.range or nil,
        area.detailCentre,
        area.detailY,
        context.fonts.label,
        context.rangeText
    )
    reconcile(context.secondary, area.showSecondary, { x = area.rowRightX, y = area.detailY, w = area.detailWidth })
    context.primitives.centreLabel(
        context,
        "secondaryAnchor",
        context.themeBuilder,
        context.showSecondary and context.secondary or nil,
        area.rowRightCentre,
        area.detailY,
        context.fonts.label,
        context.secondaryText
    )

    context.primitives.reconcileBar(
        context.bar,
        area.showVisual,
        area.pad,
        area.barY,
        area.content,
        metric.fraction(context.settings, context.reading),
        area.showVisual == context.showVisual
    )
    context.showVisual = area.showVisual

    if context.radial then
        -- The arc must shrink with the panel or it will overflow a smaller zone.
        reconcile(
            context.radial.arc,
            area.showVisual,
            { x = area.visualCentreX, y = area.visualCentreY, radius = area.radius }
        )
        if area.showVisual then
            context.radial.centreX = area.visualCentreX
            context.radial.centreY = area.visualCentreY
            context.radial.radius = area.radius
        end
    end
end

return metric
