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
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
  },
  -- A transmitter pack moves over minutes, not frames.
  refreshInterval = 50,
  settings = {
    -- "TX BATTERY" needs ten characters of a header that has about five.
    {key = "label", label = "Label", type = "string", default = "TX"},
    -- Cyan, because the specification reserves it for electrical data and this
    -- is a battery. `cell-battery` was already cyan and these two disagreed.
    {key = "accent", label = "Accent", type = "string", default = "cyan",
      choices = {"cyan", "green", "amber", "orange"}},
    -- No default range: the estimate stays off until a layout states one.
    {key = "packEmpty", label = "Empty volts, whole pack", type = "number"},
    {key = "packFull", label = "Full volts, whole pack", type = "number"},
    {key = "warning", label = "Warning volts", type = "number"},
    {key = "critical", label = "Critical volts", type = "number"},
    -- No `direction`. A transmitter pack only ever alarms downward.
    {key = "visual", label = "Visualization", type = "string", default = "bar",
      choices = {"bar", "none"}},
    {key = "showPercent", label = "Show estimate", type = "boolean", default = false},
  },
}

--- Lossless forms of the reading, longest first. The unit is redundant with
--- the panel's label; the digits are not.
txBattery.FORMS = {"88.8V", "88.8"}

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

  if type(range) == "table" and range.available
      and type(range.empty) == "number" and type(range.full) == "number"
      and range.full > range.empty then
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
  if not low then return 0 end
  if type(value) ~= "number" or value ~= value then return 0 end

  local fraction = (value - low) / (high - low)
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
  if type(config) ~= "table" then return messages end
  if type(span) ~= "table" or type(span.rowSpan) ~= "number" then
    return messages
  end
  if span.rowSpan >= 2 then return messages end

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
  -- Composition comes from the shared ladder, so a panel of this size carries
  -- the same rows as any other panel of this size, whichever component drew
  -- it. What this component wants is a veto, not a vote.
  local ladder = themeBuilder.ladder(theme, rect, frame)
  local showVisual = layout.showVisual and ladder.visual
  local showDetail = layout.showDetail and ladder.rows > 0

  -- "88.8V" is the widest reading a transmitter pack produces, and "88.8" is
  -- the same reading without a unit the panel's own label already carries.
  -- Nothing shorter is offered: a digit here is magnitude.
  local value, formIndex = themeBuilder.fitReading(
    txBattery.FORMS, frame.content, ladder.room)
  local valueHeight = themeBuilder.fontHeight(value)
  if top + valueHeight > rect.h then top = math.max(0, rect.h - valueHeight) end

  local barY = math.max(1, rect.h - frame.bottom - spacing.barHeight)

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    valueY = top,
    value = value,
    formIndex = formIndex,
    formIndex = formIndex,
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

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation,
    services.themeBuilder)

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

  -- The bar is an estimate, so it is built whenever the panel could ever have
  -- a range to measure against, and hidden until one arrives. It used to be
  -- built only when the layout stated a range, which was safe while that was
  -- the only source; the radio's range arrives on the service's first update,
  -- after this runs, so deciding here would have meant no bar ever.
  if layout.showVisual and settings.visual ~= "none" then
    context.bar = primitives.bar(panel.root, theme, {
      x = area.pad,
      y = area.barY,
      w = area.content,
      fraction = 0,
      color = presentation.accent,
    })
  end

  if not area.showDetail then lvgl.hide(context.detailLabel) end
  -- What the panel currently shows, so `render` declares only that and a
  -- reflow that changes nothing about visibility does not tell every object
  -- again what it already is.
  context.showVisual = area.showVisual
  context.showDetail = area.showDetail
  -- Whether the bar is *showing* is the box's answer and the range's answer
  -- together, and the second only arrives once the service has run.
  context.barShown = false
  context.barX, context.barY, context.barWidth = area.pad, area.barY, area.content

  if context.bar and not area.showVisual then
    lvgl.hide(context.bar.track)
    lvgl.hide(context.bar.fill)
  end

  local _, drawn = primitives.changed(context, txBattery.render)
  txBattery.apply(context, drawn)
  return context
end

--- Repaint the component from its current subscription.
---@param context AeroGridTxBatteryContext
--- Collect everything this panel draws.
---@param context AeroGridTxBatteryContext
---@param out table
function txBattery.render(context, out)
  local settings = context.settings
  local feed = context.feed
  local value = type(feed) == "table" and feed.available and feed.value or nil
  local stale = type(feed) == "table" and feed.stale == true

  out.state = txBattery.resolveState(settings, value, stale)
  out.text = type(value) == "number" and string.format("%.1fV", value) or "--"
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
  if context.showDetail and out.ranged and settings.showPercent
      and type(value) == "number" then
    out.detail = string.format("%d%% EST", math.floor(out.fraction * 100 + 0.5))
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

  context.value:set({text = drawn.text, color = presentation.value})
  context.label:set({color = presentation.label})
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  if context.showDetail then
    context.detailLabel:set({text = context.detail})
  end
  context.primitives.stylePanel(context.panel, presentation)

  -- A bar with nothing to measure against is not a quiet bar, it is a
  -- confident one drawn from nothing, so it stays away until a range exists.
  local barShown = context.bar ~= nil and context.showVisual and drawn.ranged
  if barShown then
    context.primitives.setBar(context.bar, drawn.fraction, presentation.accent)
  end
  if context.bar and barShown ~= context.barShown then
    context.primitives.reconcileBar(context.bar, barShown,
      context.barX, context.barY, context.barWidth, drawn.fraction)
    context.barShown = barShown
  end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridTxBatteryContext
function txBattery.refresh(context)
  if not context.feed then return end
  local changed, drawn = context.primitives.changed(context, txBattery.render)
  if changed then txBattery.apply(context, drawn) end
end

--- Reposition after a zone change.
---@param context AeroGridTxBatteryContext
---@param rect AeroGridRect
function txBattery.update(context, rect)
  local area = txBattery.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts)
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.content,
    font = function() return area.value end,
  })

  context.primitives.reconcile(context.detailLabel, area.showDetail,
    {x = area.pad, y = area.detailY, w = area.content},
    area.showDetail == context.showDetail)

  -- A row that has just reappeared holds whatever it had when it was shed,
  -- and `render` stopped declaring its key while it was hidden.
  if area.showDetail ~= context.showDetail then context.rendered = nil end
  context.showDetail = area.showDetail

  context.barX, context.barY, context.barWidth = area.pad, area.barY, area.content
  local barShown = context.bar ~= nil and area.showVisual
    and txBattery.hasRange(context.settings, context.range)
  context.primitives.reconcileBar(context.bar, barShown,
    area.pad, area.barY, area.content,
    txBattery.fraction(context.settings, context.reading, context.range),
    barShown == context.barShown)
  context.barShown = barShown
  context.showVisual = area.showVisual
end

return txBattery
