-- SPDX-License-Identifier: GPL-2.0-only

--- Reference metric panel for the AeroGrid design system.
--- It demonstrates every theme mode, every panel state, and the three
--- baseline spans, built entirely from host theme tokens and shared primitives.
---
--- Sources and presentation are configured explicitly by the layout.

---@class AeroGridMetricEntry
---@field source string EdgeTX numeric source name.
---@field label? string
---@field unit? string
---@field precision? integer
---@field rangeMin? number
---@field rangeMax? number
---@field warning? number
---@field critical? number
---@field direction? "auto"|"rising"|"falling"

---@class AeroGridMetricSettings
---@field metrics AeroGridMetricEntry[] Ordered primary and supporting metrics.
---@field accent? "cyan"|"green"|"amber"|"orange"
---@field visual? "bar"|"radial"|"none"

---@class AeroGridResolvedMetricSettings: AeroGridMetricEntry
---@field metrics AeroGridMetricEntry[]
---@field accent string
---@field visual string

---@class AeroGridMetricContext
---@field panel table
---@field theme AeroGridTheme
---@field primitives table
---@field state fun(name: string, accent?: string): table
---@field layout table Resolved presentation for the current span.
---@field feed? AeroGridReading Immutable telemetry subscription.
---@field reading? number Last applied reading.
---@field stateName string Current resolved state name.
---@field settings AeroGridResolvedMetricSettings

local metric = {
    id = "metric",
    apiVersion = 1,
    -- Every region is derived from the measured rectangle, so the panel
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
    -- the host pays every panel's refresh inside one instruction budget.
    refreshInterval = 20,
    settings = {
        {
            key = "metrics",
            label = "Metrics",
            type = "table",
            minItems = 1,
            maxItems = 3,
            -- Every reading setting, so the editor offers ones an entry omits.
            fields = {
                { key = "source", label = "Source", type = "string", required = true },
                { key = "label", label = "Label", type = "string" },
                { key = "unit", label = "Unit", type = "string" },
                {
                    key = "precision",
                    label = "Precision",
                    type = "number",
                    min = 0,
                    max = 3,
                    step = 1,
                    empty = "Sensor",
                },
                {
                    key = "direction",
                    label = "Direction",
                    type = "string",
                    choices = { "auto", "rising", "falling" },
                    default = "auto",
                },
                { key = "rangeMin", label = "Range min", type = "number", step = 0.1, default = 0 },
                { key = "rangeMax", label = "Range max", type = "number", step = 0.1, default = 100 },
                { key = "warning", label = "Warning", type = "number", step = 0.1, empty = "Off" },
                { key = "critical", label = "Critical", type = "number", step = 0.1, empty = "Off" },
            },
            default = {
                {
                    source = "RSSI",
                    label = "RSSI",
                    unit = "",
                    precision = 0,
                    direction = "auto",
                },
            },
        },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "cyan",
            choices = { "cyan", "green", "amber", "orange" },
        },
        {
            key = "visual",
            label = "Visualization",
            type = "string",
            default = "bar",
            choices = { "bar", "radial", "none" },
        },
    },
}

function metric.validateSettings(settings)
    local warnings = {}
    local entries = settings.metrics
    if type(entries) ~= "table" then
        return { "metrics must contain a contiguous list of 1 to 3 readings" }
    end
    local count = 0
    for key, entry in pairs(entries) do
        count = count + 1
        local prefix = "metrics[" .. tostring(key) .. "]"
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 3 then
            warnings[#warnings + 1] = prefix .. " must be an index from 1 to 3"
        elseif type(entry) ~= "table" then
            warnings[#warnings + 1] = prefix .. " must be a mapping"
        else
            if type(entry.source) ~= "string" or entry.source == "" then
                warnings[#warnings + 1] = prefix .. ".source must be a nonempty string"
            end
            for field, value in pairs(entry) do
                if field == "label" or field == "unit" then
                    if type(value) ~= "string" then
                        warnings[#warnings + 1] = prefix .. "." .. field .. " must be a string"
                    end
                elseif field == "precision" then
                    if type(value) ~= "number" or value ~= value or value < 0 or value > 3 or value % 1 ~= 0 then
                        warnings[#warnings + 1] = prefix .. ".precision must be an integer from 0 to 3"
                    end
                elseif field == "rangeMin" or field == "rangeMax" or field == "warning" or field == "critical" then
                    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
                        warnings[#warnings + 1] = prefix .. "." .. field .. " must be a finite number"
                    end
                elseif field == "direction" then
                    if value ~= "auto" and value ~= "rising" and value ~= "falling" then
                        warnings[#warnings + 1] = prefix .. ".direction must be auto, rising, or falling"
                    end
                elseif field ~= "source" then
                    warnings[#warnings + 1] = prefix .. "." .. tostring(field) .. " is not a reading setting"
                end
            end
        end
    end
    if count < 1 or count > 3 or #entries ~= count then
        warnings[#warnings + 1] = "metrics must contain a contiguous list of 1 to 3 readings"
    end
    return warnings
end

local function readingText(entry, feed)
    local caption = entry.label or entry.source
    if not feed or not feed.available or type(feed.value) ~= "number" then
        return caption .. " --"
    end
    local digits = entry.precision or feed.precision or 0
    local text = caption .. " " .. metric.format(feed.value, digits)
    local unit = entry.unit
    if unit == nil then
        unit = feed.unitText or ""
    end
    if unit ~= "" then
        text = text .. " " .. unit
    end
    return text
end

--- Describe how the panel presents itself at a given span.
--- Unsupported spans are rejected by metadata, so each entry here is deliberate.
--- A 1 x 1 shows only label and value; wider spans add units, a visualization,
--- and finally the supporting readings.
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
---@param settings AeroGridResolvedMetricSettings
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

--- Resolve the panel state from thresholds and reading availability.
--- Direction may be stated explicitly. When left on `auto` it can only be
--- inferred from two thresholds; a single threshold alone is ambiguous, so it
--- is treated as rising and the panel documents that in its settings.
---@param settings AeroGridResolvedMetricSettings
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

--- Format the second metric for the supporting row.
---@param context AeroGridMetricContext
---@return string
function metric.detailText(context)
    local entry = context.metrics[2]
    return entry and readingText(entry, context.detailFeed) or ""
end

--- Format the third metric for the supporting row.
---@param context AeroGridMetricContext
---@return string
function metric.secondaryText(context)
    local entry = context.metrics[3]
    return entry and readingText(entry, context.secondaryFeed) or ""
end

--- Advance the panel from its telemetry subscription.
--- Nothing is repainted unless the reading or its freshness actually changed,
--- because the host pays this for every metric on the dashboard.
---@param context AeroGridMetricContext
--- Collect everything this panel draws.
---
--- Metric kept a separate cache beside each `set` call rather than one list,
--- which is safe but is a third mechanism: the catalogue now has one, and a
--- panel that opts out of it is a panel the next reader has to check
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
    out.fraction = metric.fraction(settings, value, context.primitives)
    out.value = value

    -- The sensor's unit is likewise only known once the source resolves, so the
    -- label follows it rather than being fixed when the panel was built.
    if context.unit and settings.unit == "" and not context.suppressSensorUnit then
        out.unit = feed and feed.unitText or ""
    end
    -- The detail row moves independently of the primary reading: an extreme
    -- changes on its own schedule and a secondary sensor has its own source.
    --
    -- Gated on whether the row is showing, not on whether it was built. A panel
    -- shrinks its rows away and this used to go on formatting them, which was
    -- work with no reader; it also meant a revealed row was already current by
    -- accident rather than by design, which is why this panel alone needed
    -- no discard. Now the key is simply absent while the row is shed, and
    -- reappears when it is not, which is what `changed` compares.
    if context.showRange then
        out.range = metric.detailText(context)
        if
            context.metrics
            and context.themeBuilder.measureText(context.fonts.label, out.range) > context.area.detailWidth
        then
            out.range = ""
        end
    end
    if context.showSecondary then
        out.secondary = metric.secondaryText(context)
        if
            context.metrics
            and context.themeBuilder.measureText(context.fonts.label, out.secondary) > context.area.rowRightWidth
        then
            out.secondary = ""
        end
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
            context.area.rowRightY or context.area.detailY,
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

--- Advance the panel, repainting only when something drawn changed.
---@param context AeroGridMetricContext
function metric.refresh(context)
    if not context.feed then
        return
    end
    local digits = metric.digitsFor(context)
    if digits ~= context.sampleDigits then
        context.sampleDigits = digits
        context.sample = metric.widestSample(context.settings, digits)
        metric.update(context, context.rect)
        context.rendered = nil
    end
    if context.layout.supporting then
        local first = metric.detailText(context)
        local second = context.metrics[3] and metric.secondaryText(context) or nil
        local supporting = context.layout.supporting
        local unit = context.suppressSensorUnit and "" or context.settings.unit
        if unit == "" and not context.suppressSensorUnit then
            unit = context.feed.unitText or ""
        end
        if supporting[1] ~= first or supporting[2] ~= second or context.unitText ~= unit then
            supporting[1], supporting[2] = first, second
            context.unitText = unit
            if context.unit then
                context.unit:set({ text = unit })
            end
            metric.update(context, context.rect)
            context.rendered = nil
        end
    end
    local changed, drawn = context.primitives.changed(context, metric.render)
    if changed then
        metric.apply(context, drawn)
    end
end

--- Convert a reading into a 0..1 fraction of the configured range.
---@param settings AeroGridResolvedMetricSettings
---@param value any
---@param primitives table
---@return number
function metric.fraction(settings, value, primitives)
    local low = type(settings.rangeMin) == "number" and settings.rangeMin or 0
    local high = type(settings.rangeMax) == "number" and settings.rangeMax or 100
    return primitives.fraction(value, low, high)
end

--- The forms this metric's reading may be drawn in, longest first.
---
--- There is only one. A metric draws its unit as a separate label, so the
--- reading is digits alone and there is no redundancy in it to give up:
--- dropping a digit would drop magnitude, which no font size is worth.
---
--- The forms are built from the configured range rather than from the current
--- reading, so the font is chosen once and does not change as the value moves.
---@param settings AeroGridResolvedMetricSettings
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
    -- the same panel splits under one setting and not the other.
    local area = themeBuilder.panel(theme, rect, fonts, {
        -- Built through this panel's own builder, which the host may have
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
        supporting = layout.supporting,
    }, out or {})

    -- The unit rides beside the reading rather than beneath it, so it costs
    -- the composition no height at all. Where its top sits depends on the two
    -- fonts, which is this panel's business: it is the only one that
    -- prints a unit as a separate object.
    area.unitY = themeBuilder.unitTop(area.value, area.unitFont, area.valueY)
    if area.showSide then
        local readingWidth = themeBuilder.measureText(area.value, (sample or { "" })[1])
        local unitWidth = themeBuilder.measureText(area.unitFont, unit or "")
        area.showUnit = area.showUnit
            and readingWidth / 2 + themeBuilder.unitGap(area.unitFont) + unitWidth <= area.valueBudget / 2
    end
    -- The row was granted or it was not, and a secondary cannot be drawn into
    -- a row that does not exist.
    area.showSecondary = layout.showSecondary == true and (area.showDetail or area.showSide)

    -- The dial under this panel's own names. EdgeTX positions an arc by
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

--- Build the panel's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param config AeroGridMetricSettings
---@param services table Host-provided shared objects.
---@return AeroGridMetricContext
function metric.create(parent, rect, config, services)
    local theme = services.theme
    local primitives = services.primitives
    local fonts = services.fonts
    local span = services.span
    local entries = config.metrics
    local warnings = metric.validateSettings(config)
    if #warnings > 0 then
        error(table.concat(warnings, "; "))
    end
    local primary = entries[1]
    ---@type AeroGridResolvedMetricSettings
    local settings = {
        metrics = entries,
        source = primary.source,
        label = primary.label or primary.source,
        unit = primary.unit or "",
        precision = primary.precision or -1,
        rangeMin = primary.rangeMin or 0,
        rangeMax = primary.rangeMax or 100,
        warning = primary.warning,
        critical = primary.critical,
        direction = primary.direction or "auto",
        accent = config.accent or "cyan",
        visual = config.visual or "bar",
    }

    local layout = metric.presentationFor(span.colSpan, span.rowSpan)
    layout.showRange = entries[2] ~= nil
    layout.showSecondary = entries[3] ~= nil
    layout.supporting = entries[2]
            and { entries[2].label or entries[2].source, entries[3] and (entries[3].label or entries[3].source) }
        or nil
    layout.visual = settings.visual

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
        metrics = entries,
        suppressSensorUnit = entries[1].unit == "",
        rect = rect,
    }

    -- The host owns polling. Subscribing here, in create, is what tells the
    -- telemetry service that this source is referenced at all; a source nothing
    -- references is never read.
    local telemetry = services.telemetry
    if telemetry then
        context.feed = telemetry:subscribe(settings.source)
        if entries[2] then
            context.detailFeed = telemetry:subscribe(entries[2].source)
        end
        if entries[3] then
            context.secondaryFeed = telemetry:subscribe(entries[3].source)
        end
    end

    local sample = metric.widestSample(settings, metric.digitsFor(context))
    context.unitText = tostring(settings.unit or "")
    local area = metric.regionsFor(theme, services.themeBuilder, rect, layout, fonts, sample, context.unitText)
    context.sample = sample
    context.sampleDigits = metric.digitsFor(context)

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
            y = area.rowRightY or area.detailY,
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
            area.rowRightY or area.detailY,
            fonts.label,
            context.secondaryText
        )
    end

    -- Without a telemetry service there is nothing to subscribe to, so say so
    -- rather than leaving a dash that looks like a reading in progress.
    if context.unit and not area.showUnit then
        lvgl.hide(context.unit)
    end
    if context.range and not (area.showDetail or area.showSide) then
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
    context.showRange = context.range ~= nil and (area.showDetail == true or area.showSide == true)
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

    if not context.feed then
        metric.setValue(context, nil)
    end
    return context
end

--- Apply a new reading and restyle the panel for the resulting state.
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
    context.rect = rect
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

    context.primitives.resizeHeader(context, rect, area.frame, context.settings.label)
    context.primitives.setFont(context.value, area.value)
    context.value:set({
        x = area.pad,
        y = area.valueY,
        w = area.valueWidth,
    })
    --- Show or hide an optional element, positioning it only when visible.
    local reconcile = context.primitives.reconcile

    context.showRange = context.range ~= nil and (area.showDetail == true or area.showSide == true)
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
    context.primitives.reflowReading(context, context.themeBuilder, area, area.value, context.text or "--", shows)
    context.rangeAnchor, context.secondaryAnchor = nil, nil
    reconcile(context.range, context.showRange, { x = area.detailX, y = area.detailY, w = area.detailWidth })
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
    reconcile(
        context.secondary,
        area.showSecondary,
        { x = area.rowRightX, y = area.rowRightY or area.detailY, w = area.rowRightWidth }
    )
    context.primitives.centreLabel(
        context,
        "secondaryAnchor",
        context.themeBuilder,
        context.showSecondary and context.secondary or nil,
        area.rowRightCentre,
        area.rowRightY or area.detailY,
        context.fonts.label,
        context.secondaryText
    )

    context.primitives.reconcileBar(
        context.bar,
        area.showVisual,
        area.pad,
        area.barY,
        area.content,
        metric.fraction(context.settings, context.reading, context.primitives),
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
