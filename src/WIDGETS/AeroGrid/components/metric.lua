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
---@field min? number
---@field max? number
---@field warning? number
---@field critical? number
---@field precision? number
---@field visual? "bar"|"radial"|"none"
---@field extrema? "source"|"flight"|"none"
---@field extremaMode? "min"|"max"
---@field extremaSource? string Explicit EdgeTX extreme source name.
---@field armSource? string Arm switch bounding a flight session.
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
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
  },
  -- A numeric readout is indistinguishable at 5 Hz and 50 Hz in flight, and
  -- the host pays every component's refresh inside one instruction budget.
  refreshInterval = 20,
  settings = {
    {key = "preset", label = "Preset", type = "string", default = "custom"},
    -- Absent means "take the preset's value". Presets cannot be expressed as
    -- schema defaults, because the host fills those in before the component
    -- runs and a filled default is indistinguishable from a stated one.
    {key = "label", label = "Label", type = "string", default = ""},
    {key = "source", label = "Source", type = "string", default = ""},
    {key = "unit", label = "Unit", type = "string", default = ""},
    {key = "accent", label = "Accent", type = "string", default = ""},
    {key = "min", label = "Minimum", type = "number"},
    {key = "max", label = "Maximum", type = "number"},
    {key = "warning", label = "Warning threshold", type = "number"},
    {key = "critical", label = "Critical threshold", type = "number"},
    {key = "direction", label = "Threshold direction", type = "string", default = "auto"},
    -- Negative means follow the sensor's own configured precision.
    {key = "precision", label = "Decimal places", type = "number", default = -1},
    {key = "visual", label = "Visualization", type = "string", default = ""},
    {key = "extrema", label = "Extrema", type = "string", default = ""},
    {key = "extremaMode", label = "Extreme tracked", type = "string", default = ""},
    {key = "extremaSource", label = "Extrema source", type = "string", default = ""},
    {key = "armSource", label = "Arm switch", type = "string", default = ""},
    {key = "secondarySource", label = "Secondary source", type = "string", default = ""},
    {key = "secondaryLabel", label = "Secondary label", type = "string", default = ""},
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
    min = 0,
    max = 400,
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
    min = 0,
    max = 200,
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
  if stated ~= nil and stated ~= "" then return stated end

  local fromPreset = preset[key]
  if fromPreset ~= nil then return fromPreset end
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
  settings.secondarySource =
    metric.setting(settings, preset, "secondarySource", "")
  settings.secondaryLabel =
    metric.setting(settings, preset, "secondaryLabel", "")

  if type(settings.min) ~= "number" then settings.min = preset.min end
  if type(settings.max) ~= "number" then settings.max = preset.max end

  if settings.extrema ~= "source" and settings.extrema ~= "flight" then
    settings.extrema = "none"
  end
  if settings.extremaMode ~= "min" then settings.extremaMode = "max" end

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
  if type(value) ~= "number" or value ~= value then return "--" end

  local digits = math.floor(tonumber(precision) or 0)
  if digits < 0 then digits = 0 end
  if digits > 3 then digits = 3 end

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
  if type(configured) == "number" and configured >= 0 then return configured end

  local feed = context.feed
  if feed and type(feed.precision) == "number" then return feed.precision end
  return 0
end

--- Report whether thresholds count downward for this metric.
---@param settings AeroGridMetricSettings
---@return boolean
local function isFalling(settings)
  local warning = type(settings.warning) == "number" and settings.warning or nil
  local critical = type(settings.critical) == "number" and settings.critical or nil

  if settings.direction == "falling" then return true end
  if settings.direction == "rising" then return false end
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
  if type(value) ~= "number" or value ~= value then return "unavailable" end
  if stale then return "stale" end

  local warning = type(settings.warning) == "number" and settings.warning or nil
  local critical = type(settings.critical) == "number" and settings.critical or nil
  local falling = isFalling(settings)

  if critical ~= nil then
    if falling and value <= critical then return "critical" end
    if not falling and value >= critical then return "critical" end
  end
  if warning ~= nil then
    if falling and value <= warning then return "warning" end
    if not falling and value >= warning then return "warning" end
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
    if type(reading) ~= "table" or not reading.available then return nil, false end
    return reading.value, type(reading.value) == "number"
  end

  if mode == "flight" then
    local track = context.sessionExtrema
    if type(track) ~= "table" or not track.available then return nil, false end
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
    return metric.format(settings.min, 0) .. " - " .. metric.format(settings.max, 0)
  end

  local value, available = metric.extremeValue(context)
  local caption = settings.extremaMode == "min" and "MIN " or "MAX "
  if not available then return caption .. "--" end
  return caption .. metric.format(value, metric.digitsFor(context))
end

--- Format the supporting detail row's right-hand text.
---@param context AeroGridMetricContext
---@return string
function metric.secondaryText(context)
  local feed = context.secondaryFeed
  if type(feed) ~= "table" then return "" end

  local caption = context.settings.secondaryLabel
  if type(caption) ~= "string" or caption == "" then caption = "2ND" end

  if not feed.available or type(feed.value) ~= "number" then
    return caption .. " --"
  end

  local digits = type(feed.precision) == "number" and feed.precision or 0
  local text = caption .. " " .. metric.format(feed.value, digits)
  if feed.unitText and feed.unitText ~= "" then text = text .. feed.unitText end
  return text
end

--- Advance the component from its telemetry subscription.
--- Nothing is repainted unless the reading or its freshness actually changed,
--- because the host pays this for every metric on the dashboard.
---@param context AeroGridMetricContext
function metric.refresh(context)
  local feed = context.feed
  if not feed then return end

  local value = feed.available and feed.value or nil
  local stale = feed.stale == true
  -- The sensor's precision only becomes known once the source resolves, so a
  -- change in it has to repaint even when the reading itself has not moved.
  local digits = metric.digitsFor(context)

  if not (context.applied and value == context.reading
      and stale == context.staleReading and digits == context.digits) then
    context.applied = true
    context.staleReading = stale
    context.digits = digits
    metric.setValue(context, value, stale)
  end

  -- The sensor's unit is only known once the source resolves, so the label
  -- follows it rather than being fixed when the panel was built.
  if context.unit and context.settings.unit == "" then
    local text = feed.unitText or ""
    if text ~= context.unitText then
      context.unitText = text
      context.unit:set({text = text})
    end
  end

  -- The detail row moves independently of the primary reading: an extreme
  -- changes on its own schedule and a secondary sensor has its own source.
  if context.range then
    local text = metric.detailText(context)
    if text ~= context.rangeText then
      context.rangeText = text
      context.range:set({text = text})
    end
  end

  if context.secondary then
    local text = metric.secondaryText(context)
    if text ~= context.secondaryText then
      context.secondaryText = text
      context.secondary:set({text = text})
    end
  end
end

--- Convert a reading into a 0..1 fraction of the configured range.
---@param settings AeroGridMetricSettings
---@param value any
---@return number
function metric.fraction(settings, value)
  if type(value) ~= "number" or value ~= value then return 0 end

  local low = type(settings.min) == "number" and settings.min or 0
  local high = type(settings.max) == "number" and settings.max or 100
  if high == low then return 0 end

  local fraction = (value - low) / (high - low)
  if fraction < 0 then return 0 end
  if fraction > 1 then return 1 end
  return fraction
end

--- Build the widest string this metric will ever display.
--- The primary font is chosen from this rather than from the current reading,
--- so the value never resizes as it changes: the specification requires stable
--- geometry, and a font that shrank on the first three-digit reading would
--- move every neighbouring element.
---@param settings AeroGridMetricSettings
---@param digits integer
---@return string
function metric.widestSample(settings, digits)
  local low = type(settings.min) == "number" and settings.min or 0
  local high = type(settings.max) == "number" and settings.max or 100

  local widest = metric.format(low, digits)
  local other = metric.format(high, digits)
  if #other > #widest then widest = other end

  -- A range that never goes negative still has to survive one that does, so
  -- reserve the sign only when the configured range actually uses it.
  return widest
end

--- Compute every content region from the current rectangle.
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
---@param sample? string Widest value text the component will render.
---@return table
function metric.regionsFor(theme, themeBuilder, rect, layout, fonts, sample)
  local spacing = theme.spacing
  local frame = themeBuilder.frame(theme, rect, fonts)
  local pad = frame.pad
  local compact = frame.compact
  local bottomPad = frame.bottom

  local content = frame.content
  local badgeWidth = frame.badgeWidth
  local labelHeight = frame.labelHeight
  local unitHeight = themeBuilder.fontHeight(fonts.unit)
  local top = frame.top

  local showUnit = layout.showUnit
  local showVisual = layout.showVisual and layout.visual ~= "none"
  local showRange = layout.showRange
  local showSecondary = layout.showSecondary and layout.showRange

  local function room()
    local below = bottomPad
    if showVisual then below = below + spacing.barHeight + 2 end
    if showRange then below = below + labelHeight + 2 end
    return rect.h - top - (showUnit and unitHeight or 0) - below
  end

  -- The dominant reading wins: shed optional detail before shrinking it.
  local comfortable = themeBuilder.fontHeight(MIDSIZE)
  if room() < comfortable and showRange then
    showRange = false
    showSecondary = false
  end
  if room() < comfortable and showUnit then showUnit = false end
  if room() < comfortable and showVisual then showVisual = false end

  local radius = math.max(6, math.floor(math.min(rect.w, rect.h) / 5))
  local radialX = math.max(pad, rect.w - pad - radius * 2)

  local valueWidth = content
  if showVisual and layout.visual == "radial" then
    valueWidth = math.max(1, radialX - pad - 4)
  end

  local available = math.max(1, room())
  local primary = sample
    and themeBuilder.fitText(sample, valueWidth, available)
    or themeBuilder.fitPrimary(available)
  local primaryHeight = themeBuilder.fontHeight(primary)

  if top + primaryHeight > rect.h then
    top = math.max(0, rect.h - primaryHeight)
  end

  local barY = math.max(1, rect.h - bottomPad - spacing.barHeight)
  -- The detail row splits into extrema on the left and the secondary reading
  -- on the right, so neither ever draws over the other.
  local detailWidth = showSecondary
    and math.max(1, math.floor((content - 4) / 2)) or content

  return {
    pad = pad,
    compact = compact,
    content = content,
    labelWidth = frame.labelWidth,
    badgeWidth = badgeWidth,
    badgeX = frame.badgeX,
    valueY = top,
    valueWidth = valueWidth,
    primary = primary,
    unitY = math.max(1, top + primaryHeight),
    barY = barY,
    rangeY = math.max(1, barY - labelHeight - 2),
    detailWidth = detailWidth,
    secondaryX = pad + content - detailWidth,
    radius = radius,
    radialX = radialX,
    radialY = top,
    -- EdgeTX positions an arc by its centre, so the corner above is only ever
    -- used to reserve space; the arc itself is placed from here.
    radialCentreX = radialX + radius,
    radialCentreY = top + radius,
    showUnit = showUnit,
    showVisual = showVisual,
    showRange = showRange,
    showSecondary = showSecondary,
  }
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
      context.extremeFeed =
        extrema:sourceExtreme(settings.source, settings.extremaMode)
    end
  elseif extrema and settings.extrema == "flight" then
    -- The flight session decides where one flight's extrema end, so the arm
    -- switch is configured before the tracker is subscribed.
    extrema:flight(settings.armSource ~= "" and settings.armSource or nil)
    context.sessionExtrema = extrema:sessionExtrema(settings.source)
  end

  local sample = metric.widestSample(settings, metric.digitsFor(context))
  local area = metric.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts, sample)
  context.sample = sample

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area, fonts, settings.label, presentation)

  context.value = primitives.value(panel.root, theme, {
    x = area.pad,
    y = area.valueY,
    w = area.valueWidth,
    text = "--",
    color = presentation.value,
    font = area.primary,
  })

  -- Optional elements are created whenever the span could ever want them, and
  -- hidden when the current size cannot fit them, so a later enlargement can
  -- simply reveal them instead of needing a rebuild. The unit is created even
  -- when the layout names none, because the sensor supplies one once it
  -- resolves.
  if layout.showUnit then
    context.unitText = tostring(settings.unit or "")
    context.unit = primitives.label(panel.root, theme, {
      x = area.pad,
      y = area.unitY,
      w = area.valueWidth,
      text = context.unitText,
      color = theme.color.textFaint,
      font = fonts.unit,
    })
  end

  if layout.showVisual and settings.visual == "radial" then
    context.radial = primitives.radial(panel.root, theme, {
      x = area.radialCentreX,
      y = area.radialCentreY,
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
      x = area.pad,
      y = area.rangeY,
      w = area.detailWidth,
      text = context.rangeText,
      color = theme.color.textFaint,
      font = fonts.label,
    })
  end

  if layout.showSecondary and context.secondaryFeed then
    context.secondaryText = metric.secondaryText(context)
    context.secondary = primitives.label(panel.root, theme, {
      x = area.secondaryX,
      y = area.rangeY,
      w = area.detailWidth,
      text = context.secondaryText,
      color = theme.color.textFaint,
      font = fonts.label,
    })
  end

  -- Without a telemetry service there is nothing to subscribe to, so say so
  -- rather than leaving a dash that looks like a reading in progress.
  if not context.feed then metric.setValue(context, nil) end

  if context.unit and not area.showUnit then lvgl.hide(context.unit) end
  if context.range and not area.showRange then lvgl.hide(context.range) end
  if context.secondary and not area.showSecondary then
    lvgl.hide(context.secondary)
  end
  if not area.showVisual then
    if context.bar then
      lvgl.hide(context.bar.track)
      lvgl.hide(context.bar.fill)
    end
    if context.radial then lvgl.hide(context.radial.arc) end
  end

  return context
end

--- Apply a new reading and restyle the component for the resulting state.
---@param context AeroGridMetricContext
---@param value any
---@param stale? boolean
function metric.setValue(context, value, stale)
  local settings = context.settings
  local stateName = metric.resolveState(settings, value, stale == true)
  local presentation = context.state(stateName, settings.accent)
  local fraction = metric.fraction(settings, value)

  context.reading = value
  context.stateName = stateName
  context.text = metric.format(value, metric.digitsFor(context))

  context.label:set({color = presentation.label})
  context.value:set({text = context.text, color = presentation.value})
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  context.primitives.stylePanel(context.panel, presentation)

  if context.bar then
    context.primitives.setBar(context.bar, fraction, presentation.accent)
  end
  if context.radial then
    context.primitives.setRadial(context.radial, fraction, presentation.accent)
  end
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
  local area = metric.regionsFor(theme, context.themeBuilder, rect,
    context.layout, context.fonts, context.sample)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area)
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.valueWidth,
    -- LVGL takes the font as a callback, matching how it was created.
    font = function() return area.primary end,
  })

  --- Show or hide an optional element, positioning it only when visible.
  local function reconcile(object, visible, changes)
    if not object then return end
    if visible then
      object:set(changes)
      lvgl.show(object)
    else
      lvgl.hide(object)
    end
  end

  reconcile(context.unit, area.showUnit,
    {x = area.pad, y = area.unitY, w = area.valueWidth})
  reconcile(context.range, area.showRange,
    {x = area.pad, y = area.rangeY, w = area.detailWidth})
  reconcile(context.secondary, area.showSecondary,
    {x = area.secondaryX, y = area.rangeY, w = area.detailWidth})

  if context.bar then
    reconcile(context.bar.track, area.showVisual,
      {x = area.pad, y = area.barY, w = area.content})
    reconcile(context.bar.fill, area.showVisual, {x = area.pad, y = area.barY})
    if area.showVisual then
      context.bar.width = area.content
      context.primitives.setBar(
        context.bar, metric.fraction(context.settings, context.reading))
    end
  end

  if context.radial then
    -- The arc must shrink with the panel or it will overflow a smaller zone.
    reconcile(context.radial.arc, area.showVisual,
      {x = area.radialCentreX, y = area.radialCentreY, radius = area.radius})
    if area.showVisual then
      context.radial.centreX = area.radialCentreX
      context.radial.centreY = area.radialCentreY
      context.radial.radius = area.radius
    end
  end
end

return metric
