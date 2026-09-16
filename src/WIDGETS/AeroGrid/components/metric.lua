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
  },
}

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
  local falling

  if settings.direction == "falling" then
    falling = true
  elseif settings.direction == "rising" then
    falling = false
  else
    falling = warning ~= nil and critical ~= nil and critical < warning
  end

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
--- and so the badge, value, and visualization never share pixels.
---@param theme AeroGridTheme
---@param rect AeroGridRect
---@param layout table
---@return table
local function regions(theme, rect, layout)
  local spacing = theme.spacing
  local pad = spacing.padding
  local content = math.max(1, rect.w - pad * 2)
  local badgeWidth = math.min(BADGE_WIDTH, content)
  local radius = math.max(6, math.floor(math.min(rect.w, rect.h) / 5))
  local radialX = math.max(pad, rect.w - pad - radius * 2)
  local barY = math.max(1, rect.h - pad - spacing.barHeight)

  local valueWidth = content
  if layout.showVisual and layout.visual == "radial" then
    valueWidth = math.max(1, radialX - pad - 4)
  end

  return {
    pad = pad,
    content = content,
    labelWidth = math.max(1, content - badgeWidth - 4),
    badgeWidth = badgeWidth,
    badgeX = math.max(pad, rect.w - pad - badgeWidth),
    valueWidth = valueWidth,
    barY = barY,
    rangeY = math.max(1, barY - 18),
    radius = radius,
    radialX = radialX,
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
  local area = regions(theme, rect, layout)

  local panel = primitives.panel(parent, rect, theme, presentation)

  local context = {
    panel = panel,
    theme = theme,
    primitives = primitives,
    state = services.state,
    layout = layout,
    fonts = fonts,
    settings = settings,
    stateName = "normal",
    text = "--",
  }

  context.label = primitives.label(panel.root, theme, {
    x = area.pad,
    y = spacing.paddingCompact,
    w = area.labelWidth,
    text = string.upper(tostring(settings.label or "")),
    color = presentation.label,
    font = fonts.label,
  })

  context.value = primitives.value(panel.root, theme, {
    x = area.pad,
    y = layout.valueY,
    w = area.valueWidth,
    text = "--",
    color = presentation.value,
    font = fonts.primary,
  })

  if layout.showUnit and settings.unit ~= "" then
    context.unit = primitives.label(panel.root, theme, {
      x = area.pad,
      y = layout.valueY + 24,
      w = area.valueWidth,
      text = tostring(settings.unit),
      color = theme.color.textFaint,
      font = fonts.unit,
    })
  end

  if layout.showVisual and settings.visual == "radial" then
    context.radial = primitives.radial(panel.root, theme, {
      x = area.radialX,
      y = layout.valueY,
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
    y = spacing.paddingCompact,
    w = area.badgeWidth,
    text = "",
    color = theme.color.amber,
    font = fonts.badge,
  })

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
---@param context AeroGridMetricContext
---@param rect AeroGridRect
function metric.update(context, rect)
  local theme = context.theme
  local area = regions(theme, rect, context.layout)

  context.primitives.resizePanel(context.panel, rect)
  context.label:set({w = area.labelWidth})
  context.value:set({w = area.valueWidth})
  context.badge:set({x = area.badgeX, w = area.badgeWidth})

  if context.unit then context.unit:set({w = area.valueWidth}) end
  if context.range then
    context.range:set({w = area.content, y = area.rangeY})
  end
  if context.bar then
    context.bar.width = area.content
    context.bar.track:set({w = area.content, y = area.barY})
    context.bar.fill:set({y = area.barY})
    context.primitives.setBar(
      context.bar, metric.fraction(context.settings, context.reading))
  end
  if context.radial then
    -- The arc must shrink with the panel or it will overflow a smaller zone.
    context.radial.arc:set({x = area.radialX, radius = area.radius})
  end
end

return metric
