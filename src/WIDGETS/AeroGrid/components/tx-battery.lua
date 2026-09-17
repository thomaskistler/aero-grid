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
---@field min? number Voltage treated as empty for the optional estimate.
---@field max? number Voltage treated as full for the optional estimate.
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
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
  },
  -- A transmitter pack moves over minutes, not frames.
  refreshInterval = 50,
  settings = {
    {key = "label", label = "Label", type = "string", default = "TX BATTERY"},
    {key = "accent", label = "Accent", type = "string", default = "green"},
    -- No default range: the estimate stays off until a layout states one.
    {key = "min", label = "Empty voltage", type = "number"},
    {key = "max", label = "Full voltage", type = "number"},
    {key = "warning", label = "Warning voltage", type = "number"},
    {key = "critical", label = "Critical voltage", type = "number"},
    {key = "visual", label = "Visualization", type = "string", default = "bar"},
    {key = "showPercent", label = "Show estimate", type = "boolean", default = false},
  },
}

--- Report whether a usable voltage range was configured.
--- Without one there is no estimate, so neither the bar nor the percentage is
--- drawn however the layout set their own switches.
---@param settings AeroGridTxBatterySettings
---@return boolean
function txBattery.hasRange(settings)
  local low = settings.min
  local high = settings.max
  return type(low) == "number" and type(high) == "number" and high > low
end

--- Convert a voltage into a 0..1 fraction of the configured range.
---@param settings AeroGridTxBatterySettings
---@param value any
---@return number
function txBattery.fraction(settings, value)
  if not txBattery.hasRange(settings) then return 0 end
  if type(value) ~= "number" or value ~= value then return 0 end

  local fraction = (value - settings.min) / (settings.max - settings.min)
  if fraction < 0 then return 0 end
  if fraction > 1 then return 1 end
  return fraction
end

--- Resolve the component state. Voltage thresholds always count downward.
---@param settings AeroGridTxBatterySettings
---@param value any
---@param stale boolean
---@return string
function txBattery.resolveState(settings, value, stale)
  if type(value) ~= "number" or value ~= value then return "unavailable" end
  if stale then return "stale" end

  local critical = settings.critical
  local warning = settings.warning
  if type(critical) == "number" and value <= critical then return "critical" end
  if type(warning) == "number" and value <= warning then return "warning" end
  return "normal"
end

--- Describe how the component presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
function txBattery.presentationFor(colSpan, rowSpan)
  local cells = (colSpan or 1) * (rowSpan or 1)
  return {showVisual = cells >= 2, showDetail = cells >= 2}
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@return table
function txBattery.regionsFor(theme, themeBuilder, rect, layout, fonts)
  local spacing = theme.spacing
  local frame = themeBuilder.frame(theme, rect, fonts)
  local labelHeight = frame.labelHeight
  local top = frame.top
  local showVisual = layout.showVisual
  local showDetail = layout.showDetail

  local function room()
    local below = frame.bottom
    if showVisual then below = below + spacing.barHeight + 2 end
    if showDetail then below = below + labelHeight + 2 end
    return rect.h - top - below
  end

  local comfortable = themeBuilder.fontHeight(MIDSIZE)
  if room() < comfortable and showDetail then showDetail = false end
  if room() < comfortable and showVisual then showVisual = false end

  -- "88.8V" is the widest reading a transmitter pack produces.
  local value = themeBuilder.fitText("88.8V", frame.content, math.max(1, room()))
  local valueHeight = themeBuilder.fontHeight(value)
  if top + valueHeight > rect.h then top = math.max(0, rect.h - valueHeight) end

  local barY = math.max(1, rect.h - frame.bottom - spacing.barHeight)

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    valueY = top,
    value = value,
    detailY = math.max(1, barY - labelHeight - 2),
    barY = barY,
    showVisual = showVisual,
    showDetail = showDetail,
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
  local layout = txBattery.presentationFor(span.colSpan, span.rowSpan)
  local presentation = services.state("normal", settings.accent)
  local area = txBattery.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts)

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
    ranged = txBattery.hasRange(settings),
  }

  local modelService = services.model
  if modelService then context.feed = modelService:txVoltage() end

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation)

  context.value = primitives.value(panel.root, theme, {
    x = area.pad,
    y = area.valueY,
    w = area.content,
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

  -- The bar is an estimate, so it exists only when a range makes it mean
  -- something.
  if layout.showVisual and settings.visual ~= "none" and context.ranged then
    context.bar = primitives.bar(panel.root, theme, {
      x = area.pad,
      y = area.barY,
      w = area.content,
      fraction = 0,
      color = presentation.accent,
    })
  end

  if not area.showDetail then lvgl.hide(context.detailLabel) end
  if context.bar and not area.showVisual then
    lvgl.hide(context.bar.track)
    lvgl.hide(context.bar.fill)
  end

  txBattery.apply(context)
  return context
end

--- Repaint the component from its current subscription.
---@param context AeroGridTxBatteryContext
function txBattery.apply(context)
  local feed = context.feed
  local settings = context.settings
  local value = type(feed) == "table" and feed.available and feed.value or nil
  local stale = type(feed) == "table" and feed.stale == true
  local stateName = txBattery.resolveState(settings, value, stale)
  local presentation = context.state(stateName, settings.accent)

  context.stateName = stateName
  context.reading = value
  context.staleReading = stale

  -- One decimal: a transmitter pack reported to three decimals flickers
  -- constantly and reads no better.
  local text = "--"
  if type(value) == "number" then text = string.format("%.1fV", value) end
  context.text = text

  context.value:set({text = text, color = presentation.value})
  context.label:set({color = presentation.label})
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  context.primitives.stylePanel(context.panel, presentation)

  local detail = ""
  if context.ranged and settings.showPercent and type(value) == "number" then
    detail = string.format("%d%% EST",
      math.floor(txBattery.fraction(settings, value) * 100 + 0.5))
  end
  if detail ~= context.detail then
    context.detail = detail
    context.detailLabel:set({text = detail})
  end

  if context.bar then
    context.primitives.setBar(
      context.bar, txBattery.fraction(settings, value), presentation.accent)
  end
end

--- Advance the component, repainting only when the voltage changed.
---@param context AeroGridTxBatteryContext
function txBattery.refresh(context)
  local feed = context.feed
  if not feed then return end

  local value = feed.available and feed.value or nil
  local stale = feed.stale == true
  if context.applied and value == context.reading
      and stale == context.staleReading then
    return
  end

  context.applied = true
  txBattery.apply(context)
end

--- Reposition after a zone change.
---@param context AeroGridTxBatteryContext
---@param rect AeroGridRect
function txBattery.update(context, rect)
  local area = txBattery.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame)
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.content,
    font = function() return area.value end,
  })

  if area.showDetail then
    context.detailLabel:set({x = area.pad, y = area.detailY, w = area.content})
    lvgl.show(context.detailLabel)
  else
    lvgl.hide(context.detailLabel)
  end

  if context.bar then
    if area.showVisual then
      context.primitives.placeBar(context.bar, area.pad, area.barY, area.content,
        txBattery.fraction(context.settings, context.reading))
      lvgl.show(context.bar.track)
      lvgl.show(context.bar.fill)
    else
      lvgl.hide(context.bar.track)
      lvgl.hide(context.bar.fill)
    end
  end
end

return txBattery
