-- SPDX-License-Identifier: GPL-2.0-only

--- A global variable or bounded numeric source, read only.
---
--- EdgeTX owns global variables completely: their names, bounds, precision,
--- unit, and flight-mode inheritance all come from
--- `model.getGlobalVariableDetails` and `model.getGlobalVariable`, resolved by
--- `controlService`. AeroGrid displays them and never writes one, so a
--- dashboard cannot change how the model flies.
---
--- A flight counter kept in a global variable is displayed by this component.
--- AeroGrid does not detect flights, increment the counter, or own its
--- persistence.
---
--- The same component also binds to an ordinary numeric telemetry source,
--- because "a bounded number with a name" is the same presentation problem
--- either way. What differs is where the bounds come from: a global variable
--- carries its own, and a source must be given them by the layout.

---@class AeroGridVariableSettings
---@field binding? "global"|"source"
---@field index? number Zero-based global variable index.
---@field flightMode? number Pin to a flight mode; negative follows the active one.
---@field source? string EdgeTX source name, when binding is "source".
---@field label? string Semantic label such as Flight count, Rates, or Gain.
---@field showName? boolean Keep the configured global variable name visible.
---@field presentation? "value"|"horizontal-bar"|"bipolar-bar"|"radial"
---@field min? number Overrides the resolved lower bound.
---@field max? number Overrides the resolved upper bound.
---@field precision? number Negative follows the variable or sensor.
---@field unit? string Overrides the resolved unit label.
---@field accent? string

---@class AeroGridVariableContext
---@field panel table
---@field feed? table Global variable or telemetry subscription.
---@field stateName string

local variableIndicator = {
  id = "variable-indicator",
  apiVersion = 1,
  supportedSpans = {
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
  },
  -- Global variables change when the pilot changes them, which is rare. A
  -- source binding is rate limited by the telemetry service anyway.
  refreshInterval = 50,
  settings = {
    {key = "binding", label = "Bind to", type = "string", default = "global"},
    {key = "index", label = "Global variable", type = "number", default = 0},
    {key = "flightMode", label = "Flight mode", type = "number", default = -1},
    {key = "source", label = "Source", type = "string", default = ""},
    {key = "label", label = "Label", type = "string", default = ""},
    {key = "showName", label = "Show configured name", type = "boolean", default = true},
    {key = "presentation", label = "Presentation", type = "string", default = "value"},
    {key = "min", label = "Minimum", type = "number"},
    {key = "max", label = "Maximum", type = "number"},
    {key = "precision", label = "Decimal places", type = "number", default = -1},
    {key = "unit", label = "Unit", type = "string", default = ""},
    {key = "accent", label = "Accent", type = "string", default = "cyan"},
  },
}

--- Presentations this component knows how to draw.
local PRESENTATIONS = {
  value = true,
  ["horizontal-bar"] = true,
  ["bipolar-bar"] = true,
  radial = true,
}

--- Normalize the selected presentation.
---@param name any
---@return string
function variableIndicator.presentation(name)
  return PRESENTATIONS[name] and name or "value"
end

--- Format a value with a fixed number of decimals.
---@param value any
---@param precision any
---@return string
function variableIndicator.format(value, precision)
  if type(value) ~= "number" or value ~= value then return "--" end

  local digits = math.floor(tonumber(precision) or 0)
  if digits < 0 then digits = 0 end
  if digits > 3 then digits = 3 end
  return string.format("%." .. digits .. "f", value)
end

--- Collect the current reading into one shape, whichever service produced it.
--- Bounds are resolved here because a global variable carries its own and a
--- telemetry source does not: the layout's values always win, so an explicit
--- range can narrow a global variable's own bounds for display.
---@param context AeroGridVariableContext
---@return table reading
function variableIndicator.read(context)
  local settings = context.settings
  local feed = context.feed
  local out = context.readingCache

  out.available = false
  out.stale = false
  out.value = nil
  out.name = ""
  out.unitText = ""
  out.precision = 0
  out.min = 0
  out.max = 100

  if type(feed) == "table" then
    out.available = feed.available == true and type(feed.value) == "number"
    out.stale = feed.stale == true
    if out.available then out.value = feed.value end
    out.name = type(feed.name) == "string" and feed.name or ""
    out.unitText = type(feed.unitText) == "string" and feed.unitText or ""
    out.precision = type(feed.precision) == "number" and feed.precision or 0
    -- Only the control service reports bounds; a telemetry reading has none.
    if type(feed.min) == "number" and type(feed.max) == "number"
        and feed.max ~= feed.min then
      out.min = feed.min
      out.max = feed.max
    end
  end

  if type(settings.min) == "number" then out.min = settings.min end
  if type(settings.max) == "number" then out.max = settings.max end
  if type(settings.precision) == "number" and settings.precision >= 0 then
    out.precision = settings.precision
  end
  if type(settings.unit) == "string" and settings.unit ~= "" then
    out.unitText = settings.unit
  end

  return out
end

--- Convert a reading into the fraction its presentation needs.
--- Only the drawing is clamped; the displayed value is never altered, because
--- a value outside its configured bounds is still the real value.
---@param presentation string
---@param reading table
---@param signedFraction fun(value: any, low: any, high: any): number
---@return number
function variableIndicator.fraction(presentation, reading, signedFraction)
  local value = reading.value
  if type(value) ~= "number" or value ~= value then return 0 end

  if presentation == "bipolar-bar" then
    return signedFraction(value, reading.min, reading.max)
  end

  local span = reading.max - reading.min
  if span == 0 then return 0 end

  local fraction = (value - reading.min) / span
  if fraction < 0 then return 0 end
  if fraction > 1 then return 1 end
  return fraction
end

--- Report whether the configured range crosses zero.
--- A bar over such a range needs a centre marker, or a reader cannot see which
--- side of zero the value is on.
---@param reading table
---@return boolean
function variableIndicator.crossesZero(reading)
  return reading.min < 0 and reading.max > 0
end

--- Describe how the component presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
function variableIndicator.presentationFor(colSpan, rowSpan)
  local cells = (colSpan or 1) * (rowSpan or 1)
  return {showVisual = true, showDetail = cells >= 2}
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@param sample string Widest value text this indicator can render.
---@return table
function variableIndicator.regionsFor(
    theme, themeBuilder, rect, layout, fonts, sample)
  local spacing = theme.spacing
  local frame = themeBuilder.frame(theme, rect, fonts)
  local labelHeight = frame.labelHeight
  local top = frame.top
  local radial = layout.presentation == "radial"
  local showVisual = layout.showVisual and layout.presentation ~= "value"
  local showDetail = layout.showDetail

  local function room()
    local below = frame.bottom
    if showVisual and not radial then below = below + spacing.barHeight + 2 end
    if showDetail then below = below + labelHeight + 2 end
    return rect.h - top - below
  end

  local comfortable = themeBuilder.fontHeight(MIDSIZE)
  if room() < comfortable and showDetail then showDetail = false end
  if room() < comfortable and showVisual then showVisual = false end

  local radius = math.max(6, math.floor(math.min(rect.w, rect.h) / 5))
  local radialX = math.max(frame.pad, rect.w - frame.pad - radius * 2)

  local valueWidth = frame.content
  if showVisual and radial then
    valueWidth = math.max(1, radialX - frame.pad - 4)
  end

  local value = themeBuilder.fitText(sample, valueWidth, math.max(1, room()))
  local valueHeight = themeBuilder.fontHeight(value)
  if top + valueHeight > rect.h then top = math.max(0, rect.h - valueHeight) end

  local barY = math.max(1, rect.h - frame.bottom - spacing.barHeight)

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    valueY = top,
    valueWidth = valueWidth,
    value = value,
    detailY = math.max(1, barY - labelHeight - 2),
    barY = barY,
    radius = radius,
    radialX = radialX,
    radialY = top,
    showVisual = showVisual,
    showDetail = showDetail,
  }
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridVariableSettings
---@param services table
---@return AeroGridVariableContext
function variableIndicator.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local span = services.span
  local presentationName = variableIndicator.presentation(settings.presentation)
  local layout = variableIndicator.presentationFor(span.colSpan, span.rowSpan)
  layout.presentation = presentationName
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
    -- Reused so a refresh allocates nothing; the host pays this per frame.
    readingCache = {},
  }

  -- Subscribing in create is the mechanism: a variable nothing references is
  -- never read, and neither is a source.
  if settings.binding == "source" then
    local telemetry = services.telemetry
    if telemetry then context.feed = telemetry:subscribe(settings.source) end
  else
    local control = services.control
    if control then
      local mode = settings.flightMode
      context.feed = control:globalVariable(settings.index,
        type(mode) == "number" and mode >= 0 and mode or nil)
    end
  end

  local reading = variableIndicator.read(context)
  local sample = variableIndicator.format(reading.min, reading.precision)
  local other = variableIndicator.format(reading.max, reading.precision)
  if #other > #sample then sample = other end
  -- A global variable's bounds arrive from EdgeTX after create, so reserve a
  -- sign and a digit while they are still unknown. The primary font is chosen
  -- once and never changes afterwards, which is what keeps the reading from
  -- resizing under the pilot.
  if not reading.available then sample = "-" .. sample .. "0" end
  if reading.unitText ~= "" then sample = sample .. reading.unitText end
  context.sample = sample

  local area = variableIndicator.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts, sample)

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(panel.root, theme,
    area.frame, fonts, variableIndicator.labelText(context, reading),
    presentation)

  context.value = primitives.value(panel.root, theme, {
    x = area.pad,
    y = area.valueY,
    w = area.valueWidth,
    text = "--",
    color = presentation.value,
    font = area.value,
  })

  context.detailLabel = primitives.label(panel.root, theme, {
    x = area.pad,
    y = area.detailY,
    w = area.content,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  if presentationName == "radial" then
    context.radial = primitives.radial(panel.root, theme, {
      x = area.radialX,
      y = area.radialY,
      radius = area.radius,
      color = presentation.accent,
      fraction = 0,
    })
  elseif presentationName == "bipolar-bar" then
    context.bipolar = primitives.bipolarBar(panel.root, theme, {
      x = area.pad,
      y = area.barY,
      w = area.content,
      fraction = 0,
      color = presentation.accent,
    })
  elseif presentationName == "horizontal-bar" then
    context.bar = primitives.bar(panel.root, theme, {
      x = area.pad,
      y = area.barY,
      w = area.content,
      fraction = 0,
      color = presentation.accent,
      -- A range that crosses zero needs a persistent tick at zero. The bounds
      -- of a global variable only arrive once EdgeTX has been asked for its
      -- details, which happens after create, so the tick is reserved here and
      -- positioned by the first refresh that resolves them.
      marker = true,
    })
  end

  if not area.showDetail then lvgl.hide(context.detailLabel) end
  if not area.showVisual then variableIndicator.hideVisual(context) end

  variableIndicator.apply(context)
  return context
end

--- Resolve the panel label.
--- A semantic label from the layout wins, because "Flight count" reads better
--- than the radio's own "GV3"; the configured name remains available as
--- supporting text.
---@param context AeroGridVariableContext
---@param reading table
---@return string
function variableIndicator.labelText(context, reading)
  local stated = context.settings.label
  if type(stated) == "string" and stated ~= "" then return stated end
  if reading.name ~= "" then return reading.name end
  if context.settings.binding == "source" then
    return tostring(context.settings.source or "")
  end
  return "GV" .. tostring((context.settings.index or 0) + 1)
end

--- Hide whichever visualization this indicator owns.
---@param context AeroGridVariableContext
function variableIndicator.hideVisual(context)
  if context.bar then
    lvgl.hide(context.bar.track)
    lvgl.hide(context.bar.fill)
    if context.bar.marker then lvgl.hide(context.bar.marker) end
  end
  if context.bipolar then
    lvgl.hide(context.bipolar.track)
    lvgl.hide(context.bipolar.fill)
    lvgl.hide(context.bipolar.marker)
  end
  if context.radial then lvgl.hide(context.radial.arc) end
end

--- Show whichever visualization this indicator owns.
---@param context AeroGridVariableContext
function variableIndicator.showVisual(context)
  if context.bar then
    lvgl.show(context.bar.track)
    lvgl.show(context.bar.fill)
    -- The zero tick stays hidden unless the range actually spans zero.
    if context.bar.markerFraction then lvgl.show(context.bar.marker) end
  end
  if context.bipolar then
    lvgl.show(context.bipolar.track)
    lvgl.show(context.bipolar.fill)
    lvgl.show(context.bipolar.marker)
  end
  if context.radial then lvgl.show(context.radial.arc) end
end

--- Repaint the component from its current subscription.
---@param context AeroGridVariableContext
function variableIndicator.apply(context)
  local primitives = context.primitives
  local settings = context.settings
  local reading = variableIndicator.read(context)

  local stateName = "normal"
  if not reading.available then
    stateName = "unavailable"
  elseif reading.stale then
    stateName = "stale"
  end

  local presentation = context.state(stateName, settings.accent)
  context.stateName = stateName

  local text = variableIndicator.format(reading.value, reading.precision)
  if reading.available and reading.unitText ~= "" then
    text = text .. reading.unitText
  end
  context.text = text

  context.value:set({text = text, color = presentation.value})
  context.label:set({color = presentation.label})
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  primitives.stylePanel(context.panel, presentation)

  -- The configured name is supporting text: it names the thing, while the
  -- header carries whatever the pilot chose to call it.
  local detail = ""
  if settings.showName and reading.name ~= "" then
    detail = reading.name
    if settings.binding ~= "source" and type(context.feed) == "table"
        and type(context.feed.flightMode) == "number" then
      detail = detail .. " FM" .. tostring(context.feed.flightMode)
    end
  end
  if detail ~= context.detail then
    context.detail = detail
    context.detailLabel:set({text = detail})
  end

  local fraction = variableIndicator.fraction(
    context.presentationName, reading, primitives.signedFraction)

  if context.bar then
    primitives.setBar(context.bar, fraction, presentation.accent)
    -- The zero tick only means something when the range actually spans it.
    primitives.setBarMarker(context.bar, variableIndicator.crossesZero(reading)
      and (-reading.min / (reading.max - reading.min)) or nil)
  end
  if context.bipolar then
    primitives.setBipolarBar(context.bipolar, fraction, presentation.accent)
  end
  if context.radial then
    primitives.setRadial(context.radial, fraction, presentation.accent)
  end
end

--- Advance the component, repainting only when the reading changed.
---@param context AeroGridVariableContext
function variableIndicator.refresh(context)
  local feed = context.feed
  if not feed then return end

  local value = feed.available and feed.value or nil
  local stale = feed.stale == true
  -- The flight mode has to be part of the comparison, not just the value.
  -- EdgeTX resolves global variable inheritance, so the value read for two
  -- different modes is frequently identical, and the detail row naming the
  -- mode is exactly the thing that would then go stale.
  local mode = feed.flightMode

  if context.applied and value == context.reading
      and stale == context.staleReading and mode == context.modeReading then
    return
  end

  context.applied = true
  context.reading = value
  context.staleReading = stale
  context.modeReading = mode
  variableIndicator.apply(context)

  -- The configured name and bounds arrive with the first successful read.
  local label = string.upper(
    variableIndicator.labelText(context, context.readingCache))
  if label ~= context.labelValue then
    context.labelValue = label
    context.label:set({text = label})
  end
end

--- Reposition after a zone change.
---@param context AeroGridVariableContext
---@param rect AeroGridRect
function variableIndicator.update(context, rect)
  local primitives = context.primitives
  local area = variableIndicator.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts, context.sample)

  primitives.resizePanel(context.panel, rect)
  primitives.placeHeader(context.label, context.badge, area.frame)
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.valueWidth,
    font = function() return area.value end,
  })

  if area.showDetail then
    context.detailLabel:set({x = area.pad, y = area.detailY, w = area.content})
    lvgl.show(context.detailLabel)
  else
    lvgl.hide(context.detailLabel)
  end

  if not area.showVisual then
    variableIndicator.hideVisual(context)
    return
  end

  local reading = variableIndicator.read(context)
  local fraction = variableIndicator.fraction(
    context.presentationName, reading, primitives.signedFraction)

  if context.bar then
    primitives.placeBar(context.bar, area.pad, area.barY, area.content, fraction)
  end
  if context.bipolar then
    primitives.placeBipolarBar(context.bipolar, area.pad, area.barY,
      area.content, context.bipolar.h, fraction)
  end
  if context.radial then
    context.radial.arc:set(
      {x = area.radialX, y = area.radialY, radius = area.radius})
  end

  variableIndicator.showVisual(context)
end

return variableIndicator
