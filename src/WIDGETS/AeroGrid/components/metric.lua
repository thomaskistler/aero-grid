-- SPDX-License-Identifier: GPL-2.0-only

--- Reference metric component for the AeroGrid design system.
--- It demonstrates every theme mode, every component state, and the three
--- baseline spans, built entirely from host theme tokens and shared primitives.

---@class AeroGridMetricSettings
---@field label? string
---@field unit? string
---@field accent? "cyan"|"green"|"amber"|"orange"
---@field min? number
---@field max? number
---@field warning? number
---@field critical? number
---@field precision? number
---@field visual? "bar"|"radial"|"none"

---@class AeroGridMetricContext
---@field panel table
---@field theme AeroGridTheme
---@field primitives table
---@field state fun(name: string, accent?: string): table
---@field layout table Resolved presentation for the current span.
---@field reading? number Last applied reading.
---@field stateName string Current resolved state name.

local metric = {
  id = "metric",
  apiVersion = 1,
  supportedSpans = {"1x1", "2x1", "2x2"},
  settings = {
    {key = "label", label = "Label", type = "string", default = "METRIC"},
    {key = "unit", label = "Unit", type = "string", default = ""},
    {key = "accent", label = "Accent", type = "string", default = "cyan"},
    {key = "min", label = "Minimum", type = "number", default = 0},
    {key = "max", label = "Maximum", type = "number", default = 100},
    {key = "warning", label = "Warning threshold", type = "number"},
    {key = "critical", label = "Critical threshold", type = "number"},
    {key = "direction", label = "Threshold direction", type = "string", default = "auto"},
    {key = "precision", label = "Decimal places", type = "number", default = 0},
    {key = "visual", label = "Visualization", type = "string", default = "bar"},
    -- Temporary: drives synthetic readings until milestone 5 supplies real
    -- telemetry. Remove this setting once telemetryService exists.
    {key = "demo", label = "Demo readings", type = "boolean", default = false},
  },
}

--- Phases walked by the demo driver, in order.
local DEMO_PHASES = {"normal", "warning", "critical", "stale", "unavailable"}
--- Host refresh cycles spent in each demo phase.
local DEMO_TICKS = 45

--- Describe how the component presents itself at a given span.
--- Unsupported spans are rejected by metadata, so each entry here is deliberate.
--- A 1 x 1 shows only label and value; wider spans add units, a visualization,
--- and finally the configured range.
---@param colSpan integer
---@param rowSpan integer
---@return table
function metric.presentationFor(colSpan, rowSpan)
  local cells = (colSpan or 1) * (rowSpan or 1)

  if cells >= 4 then
    return {showUnit = true, showRange = true, showVisual = true, valueY = 42}
  end
  if cells >= 2 then
    return {showUnit = true, showRange = false, showVisual = true, valueY = 28}
  end

  return {showUnit = false, showRange = false, showVisual = false, valueY = 24}
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

--- Produce a synthetic reading that lands inside a requested state band.
--- This exists only so the design system can be reviewed on a radio before
--- milestone 5 delivers real telemetry.
---@param settings AeroGridMetricSettings
---@param phase string
---@param progress number Position within the phase, from 0 to 1.
---@return number
function metric.demoValue(settings, phase, progress)
  local low = type(settings.min) == "number" and settings.min or 0
  local high = type(settings.max) == "number" and settings.max or 100
  local warning = type(settings.warning) == "number" and settings.warning or nil
  local critical = type(settings.critical) == "number" and settings.critical or nil
  local falling = isFalling(settings)

  local function lerp(from, to, amount)
    return from + (to - from) * amount
  end

  if phase == "critical" and critical ~= nil then
    return lerp(critical, falling and low or high, progress)
  end
  if phase == "warning" and warning ~= nil then
    local bound = critical or (falling and low or high)
    -- Stop short of the critical bound so this phase stays a warning.
    return lerp(warning, bound, progress * 0.8)
  end

  if warning ~= nil then
    -- Approach the warning threshold without reaching it.
    return lerp(falling and high or low, warning, progress * 0.9)
  end
  return lerp(low, high, progress)
end

--- Advance the demo driver. Inert unless the layout opts in.
---@param context AeroGridMetricContext
function metric.refresh(context)
  if not context.settings.demo then return end

  local tick = (context.demoTick or 0) + 1
  context.demoTick = tick

  local phase = DEMO_PHASES[math.floor(tick / DEMO_TICKS) % #DEMO_PHASES + 1]
  local progress = (tick % DEMO_TICKS) / DEMO_TICKS

  if phase == "unavailable" then
    metric.setValue(context, nil)
  elseif phase == "stale" then
    metric.setValue(context, metric.demoValue(context.settings, "normal", progress), true)
  else
    metric.setValue(context, metric.demoValue(context.settings, phase, progress), false)
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

--- Width reserved for the state badge on the label row.
local BADGE_WIDTH = 56

--- Compute every content region from the current rectangle.
--- Regions are derived in one place so `create` and `update` cannot disagree,
--- and so the badge, value, unit, and visualization never share pixels.
---
--- Content is stacked using real EdgeTX font line heights rather than fixed
--- offsets. When the panel is too short, optional detail is shed before the
--- dominant reading is shrunk, and the value is finally clamped inside the
--- panel so it can never overflow.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@return table
function metric.regionsFor(theme, themeBuilder, rect, layout, fonts)
  local spacing = theme.spacing
  -- Short panels cannot afford the standard padding.
  local tight = rect.h < 80
  local pad = tight and 4 or spacing.padding
  local compact = tight and 2 or spacing.paddingCompact
  local bottomPad = 4

  local content = math.max(1, rect.w - pad * 2)
  local badgeWidth = math.min(BADGE_WIDTH, content)
  local labelHeight = themeBuilder.fontHeight(fonts.label)
  local unitHeight = themeBuilder.fontHeight(fonts.unit)
  local top = compact + labelHeight + 2

  local showUnit = layout.showUnit
  local showVisual = layout.showVisual and layout.visual ~= "none"
  local showRange = layout.showRange

  local function room()
    local below = bottomPad
    if showVisual then below = below + spacing.barHeight + 2 end
    if showRange then below = below + labelHeight + 2 end
    return rect.h - top - (showUnit and unitHeight or 0) - below
  end

  -- The dominant reading wins: shed optional detail before shrinking it.
  local comfortable = themeBuilder.fontHeight(MIDSIZE)
  if room() < comfortable and showRange then showRange = false end
  if room() < comfortable and showUnit then showUnit = false end
  if room() < comfortable and showVisual then showVisual = false end

  local primary = themeBuilder.fitPrimary(math.max(1, room()))
  local primaryHeight = themeBuilder.fontHeight(primary)

  if top + primaryHeight > rect.h then
    top = math.max(0, rect.h - primaryHeight)
  end

  local radius = math.max(6, math.floor(math.min(rect.w, rect.h) / 5))
  local radialX = math.max(pad, rect.w - pad - radius * 2)
  local barY = math.max(1, rect.h - bottomPad - spacing.barHeight)

  local valueWidth = content
  if showVisual and layout.visual == "radial" then
    valueWidth = math.max(1, radialX - pad - 4)
  end

  return {
    pad = pad,
    compact = compact,
    content = content,
    labelWidth = math.max(1, content - badgeWidth - 4),
    badgeWidth = badgeWidth,
    badgeX = math.max(pad, rect.w - pad - badgeWidth),
    valueY = top,
    valueWidth = valueWidth,
    primary = primary,
    unitY = math.max(1, top + primaryHeight),
    barY = barY,
    rangeY = math.max(1, barY - labelHeight - 2),
    radius = radius,
    radialX = radialX,
    radialY = top,
    showUnit = showUnit,
    showVisual = showVisual,
    showRange = showRange,
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
  local spacing = theme.spacing
  local span = services.span
  local layout = metric.presentationFor(span.colSpan, span.rowSpan)
  layout.visual = settings.visual
  local presentation = services.state("normal", settings.accent)
  local area = metric.regionsFor(theme, services.themeBuilder, rect, layout, fonts)

  local panel = primitives.panel(parent, rect, theme, presentation)

  local context = {
    panel = panel,
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

  context.label = primitives.label(panel.root, theme, {
    x = area.pad,
    y = area.compact,
    w = area.labelWidth,
    text = string.upper(tostring(settings.label or "")),
    color = presentation.label,
    font = fonts.label,
  })

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
  -- simply reveal them instead of needing a rebuild.
  if layout.showUnit and settings.unit ~= "" then
    context.unit = primitives.label(panel.root, theme, {
      x = area.pad,
      y = area.unitY,
      w = area.valueWidth,
      text = tostring(settings.unit),
      color = theme.color.textFaint,
      font = fonts.unit,
    })
  end

  if layout.showVisual and settings.visual == "radial" then
    context.radial = primitives.radial(panel.root, theme, {
      x = area.radialX,
      y = area.radialY,
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
    context.range = primitives.label(panel.root, theme, {
      x = area.pad,
      y = area.rangeY,
      w = area.content,
      text = metric.format(settings.min, 0) .. " - " .. metric.format(settings.max, 0),
      color = theme.color.textFaint,
      font = fonts.label,
    })
  end

  -- The badge sits beside the label, never on top of it, because state must be
  -- readable at the same time as the source name.
  context.badge = primitives.badge(panel.root, theme, {
    x = area.badgeX,
    y = area.compact,
    w = area.badgeWidth,
    text = "",
    color = theme.color.amber,
    font = fonts.badge,
  })

  if context.unit and not area.showUnit then lvgl.hide(context.unit) end
  if context.range and not area.showRange then lvgl.hide(context.range) end
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
  context.text = metric.format(value, settings.precision)

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
  local area = metric.regionsFor(
    theme, context.themeBuilder, rect, context.layout, context.fonts)

  context.primitives.resizePanel(context.panel, rect)
  context.label:set({x = area.pad, y = area.compact, w = area.labelWidth})
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.valueWidth,
    -- LVGL takes the font as a callback, matching how it was created.
    font = function() return area.primary end,
  })
  context.badge:set({y = area.compact, x = area.badgeX, w = area.badgeWidth})

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
    {x = area.pad, y = area.rangeY, w = area.content})

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
      {x = area.radialX, y = area.radialY, radius = area.radius})
  end
end

return metric
