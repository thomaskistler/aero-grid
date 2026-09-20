-- SPDX-License-Identifier: GPL-2.0-only

--- Effective trim positions, inside a normal grid panel.
---
--- EdgeTX draws trims along the screen edges. This component puts them where
--- the pilot is already looking, and reads them through selectable trim
--- sources so EdgeTX resolves flight-mode trim inheritance rather than
--- AeroGrid guessing at it. It is read-only: changing a trim remains the job
--- of the radio's own trim controls.
---
--- Two firmware behaviours shape everything here, and both are handled by
--- `controlService` rather than repeated in the presentation:
---
--- * A trim source returns eight times the stored trim, and EdgeTX clamps the
---   stored value to TRIM_MAX (128) or TRIM_EXTENDED_MAX (512). The real
---   spans are therefore 1024 and 4096, not 1000 and 4000, and the model's
---   extended-trim flag is not exposed to Lua at all. `auto` starts standard
---   and widens permanently once a value outside the standard range appears.
---
--- * A trim configured as a three-position toggle returns full deflection or
---   nothing, which is exactly what a standard trim parked at its end stop
---   returns. One sample can never distinguish them, so the service claims a
---   toggle only after seeing a centre and a full deflection with nothing in
---   between, and this component labels that state rather than printing a
---   percentage that would be meaningless.
---
--- The trim's axis is the one thing neither the firmware nor the service can
--- supply: EdgeTX exposes no axis metadata for a trim source. The panel
--- therefore takes an orientation, with a per-indicator override, rather than
--- matching on trim names the specification explicitly forbids assuming.

---@class AeroGridTrimSettings
---@field indicators? "single"|"pair"|"all"
---@field trim1? string
---@field trim2? string
---@field trim3? string
---@field trim4? string
---@field orientation? "auto"|"horizontal"|"vertical"
---@field orientation1? string Per-indicator override; empty follows the panel.
---@field orientation2? string
---@field orientation3? string
---@field orientation4? string
---@field scale? "standard"|"extended"|"auto"
---@field readout? "percent"|"raw"|"none"
---@field label? string
---@field accent? string

---@class AeroGridTrimIndicator
---@field feed? AeroGridTrim
---@field name string
---@field vertical boolean
---@field bar table
---@field caption any
---@field value any

local trimPanel = {
  id = "trim-panel",
  apiVersion = 1,
  supportedSpans = {
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
    "2x3", "3x3", "4x3", "2x4", "3x4", "4x4",
  },
  -- A trim moves under the pilot's thumb, so it is refreshed at the same rate
  -- as a telemetry readout rather than at a status-panel rate.
  refreshInterval = 20,
  settings = {
    -- How many trims the panel shows. `mode` said nothing about which axis of
    -- the component it selected; the label already said "Indicators".
    {key = "indicators", label = "Indicators", type = "string",
      default = "single", choices = {"single", "pair", "all"}},
    -- Trim source names are persisted rather than assumed. They follow the
    -- radio's hardware description, not the pilot's stick mode.
    {key = "trim1", label = "Trim 1", type = "string", default = "trim-ail"},
    {key = "trim2", label = "Trim 2", type = "string", default = "trim-ele"},
    {key = "trim3", label = "Trim 3", type = "string", default = "trim-thr"},
    {key = "trim4", label = "Trim 4", type = "string", default = "trim-rud"},
    {key = "orientation", label = "Orientation", type = "string",
      default = "auto", choices = {"auto", "horizontal", "vertical"}},
    {key = "orientation1", label = "Trim 1 axis", type = "string", default = ""},
    {key = "orientation2", label = "Trim 2 axis", type = "string", default = ""},
    {key = "orientation3", label = "Trim 3 axis", type = "string", default = ""},
    {key = "orientation4", label = "Trim 4 axis", type = "string", default = ""},
    {key = "scale", label = "Scale", type = "string", default = "auto",
      choices = {"auto", "standard", "extended"}},
    {key = "readout", label = "Readout", type = "string", default = "percent",
      choices = {"percent", "raw", "none"}},
    {key = "label", label = "Label", type = "string", default = "TRIM"},
    {key = "accent", label = "Accent", type = "string", default = "cyan",
      choices = {"cyan", "green", "amber", "orange"}},
  },
}

--- How many indicators each mode asks for.
local MODE_COUNT = {single = 1, pair = 2, all = 4}

--- Thickness of a trim bar, and the smallest cell worth drawing text in.
local BAR_THICKNESS = 6
local MIN_TEXT_CELL = 34

--- Resolve the number of indicators a mode requests.
---@param mode any
---@return integer
function trimPanel.indicatorCount(mode)
  return MODE_COUNT[mode] or 1
end

--- Resolve one indicator's axis.
--- `auto` follows the panel's own shape, because a panel wider than it is tall
--- has room for a horizontal bar and a tall one does not. An explicit
--- per-indicator override always wins, since EdgeTX cannot tell us which stick
--- axis a trim source belongs to.
---@param settings AeroGridTrimSettings
---@param index integer
---@param rect AeroGridRect
---@return boolean vertical
function trimPanel.isVertical(settings, index, rect)
  local override = settings["orientation" .. index]
  if override == "vertical" then return true end
  if override == "horizontal" then return false end

  local panel = settings.orientation
  if panel == "vertical" then return true end
  if panel == "horizontal" then return false end

  return rect.h > rect.w
end

--- Short caption for one indicator.
--- A trim source is named "trim-ail" and the panel has no room for that, so
--- the stem after the dash is used and the full name stays in the layout.
---@param name any
---@return string
function trimPanel.captionFor(name)
  if type(name) ~= "string" or name == "" then return "--" end

  local stem = string.match(name, "^trim%-(.+)$")
  return string.upper(stem or name)
end

--- Format one indicator's readout.
--- A three-position trim reports full deflection or nothing, so a percentage
--- would imply a precision it does not have; its position is named instead.
---@param settings AeroGridTrimSettings
---@param feed? AeroGridTrim
---@return string
function trimPanel.valueText(settings, feed)
  if settings.readout == "none" then return "" end
  if type(feed) ~= "table" or not feed.available then return "--" end

  if feed.threePosition then
    if feed.centered then return "3P MID" end
    return feed.raw > 0 and "3P HI" or "3P LO"
  end

  if feed.centered then return settings.readout == "raw" and "0" or "0%" end

  if settings.readout == "raw" then
    return (feed.value > 0 and "+" or "") .. tostring(feed.value)
  end

  local percent = feed.fraction * 100
  -- Round half away from zero. Adding a negative half and flooring rounds
  -- -23.4 to -24, which reads as more deflection than the trim actually has.
  if percent < 0 then
    percent = -math.floor(-percent + 0.5)
  else
    percent = math.floor(percent + 0.5)
  end
  return (percent > 0 and "+" or "") .. tostring(percent) .. "%"
end

--- Compute the geometry of every indicator cell.
---
--- Cells are laid out along the panel's longer axis so each one stays as wide
--- as possible, and text is shed before an indicator is dropped: a trim panel
--- that silently stopped showing one of its trims would be worse than one
--- showing four unlabelled bars.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param count integer
---@param fonts table
---@return table
function trimPanel.regionsFor(theme, themeBuilder, rect, count, fonts)
  local frame = themeBuilder.frame(theme, rect, fonts)
  local labelHeight = frame.labelHeight
  local top = frame.top

  local available = math.max(1, rect.h - top - frame.bottom)
  local columns = rect.w >= rect.h

  local cellWidth, cellHeight
  if columns then
    cellWidth = math.max(1, math.floor(frame.content / count))
    cellHeight = available
  else
    cellWidth = frame.content
    cellHeight = math.max(1, math.floor(available / count))
  end

  -- Each cell stacks a caption, a bar, and a readout. Text goes first when
  -- the cell cannot hold all three.
  local showCaption = cellHeight >= labelHeight * 2 + BAR_THICKNESS + 4
    and cellWidth >= MIN_TEXT_CELL
  local showValue = cellHeight >= labelHeight + BAR_THICKNESS + 4
    and cellWidth >= MIN_TEXT_CELL

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    top = top,
    columns = columns,
    cellWidth = cellWidth,
    cellHeight = cellHeight,
    labelHeight = labelHeight,
    showCaption = showCaption,
    showValue = showValue,
  }
end

--- Resolve one indicator cell's rectangle and the boxes inside it.
---
--- **This component is outside the slot rule, and the reason is structural
--- rather than an exemption granted to it.** The rule places a panel's
--- reading on one slot, a compact visual beside it on the other, and the
--- panel's supporting rows on the same two centres. This panel has none of
--- those three: it draws no reading at all -- there is no `primitives.value`
--- anywhere in it -- and its captions and readouts belong to repeated items
--- rather than to the panel, which is the one case the specification allows
--- a component to look like several things at once.
---
--- What the rule exists to produce, it already has. Every position here is
--- derived from the panel: the cells divide the content box evenly, a
--- vertical bar is centred in its cell and a horizontal one spans it, so
--- nothing moves because its contents changed width.
---
--- The one change that could be argued for is centring each cell's caption
--- and readout over the bar they belong to. It was implemented and reverted.
--- An LVGL label is left-aligned within its box, so moving the box centres
--- nothing without also measuring the text -- and a readout changes every
--- frame, which puts that measurement in the dashboard's largest callback.
--- Merely computing the cell's centre, before any measuring, cost 200
--- instructions of that callback. A cosmetic change is not worth the budget
--- of the panel that has least of it.
---@param area table
---@param index integer One-based indicator position.
---@param vertical boolean Bar axis for this indicator.
---@return table
function trimPanel.cellFor(area, index, vertical)
  local offset = index - 1
  local x = area.pad + (area.columns and offset * area.cellWidth or 0)
  local y = area.top + (area.columns and 0 or offset * area.cellHeight)

  local captionY = y
  local barTop = y + (area.showCaption and (area.labelHeight + 2) or 0)
  local barRoom = area.cellHeight
    - (area.showCaption and (area.labelHeight + 2) or 0)
    - (area.showValue and (area.labelHeight + 2) or 0)
  if barRoom < 2 then barRoom = math.max(2, area.cellHeight) end

  local barWidth, barHeight, barX, barY
  if vertical then
    barWidth = BAR_THICKNESS
    barHeight = barRoom
    barX = x + math.max(0, math.floor((area.cellWidth - BAR_THICKNESS) / 2))
    barY = barTop
  else
    barWidth = math.max(2, area.cellWidth - 4)
    barHeight = BAR_THICKNESS
    barX = x
    -- Centre the bar in the room it was given so it does not hug the caption.
    barY = barTop + math.max(0, math.floor((barRoom - BAR_THICKNESS) / 2))
  end

  return {
    x = x,
    y = y,
    w = area.cellWidth,
    h = area.cellHeight,
    captionY = captionY,
    valueY = y + area.cellHeight - area.labelHeight,
    barX = barX,
    barY = barY,
    barWidth = barWidth,
    barHeight = barHeight,
    textWidth = math.max(1, area.cellWidth - 2),
  }
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridTrimSettings
---@param services table
---@return table
function trimPanel.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local presentation = services.state("normal", settings.accent)
  local count = trimPanel.indicatorCount(settings.indicators)
  local area = trimPanel.regionsFor(
    theme, services.themeBuilder, rect, count, fonts)

  local context = {
    theme = theme,
    themeBuilder = services.themeBuilder,
    primitives = primitives,
    state = services.state,
    fonts = fonts,
    settings = settings,
    count = count,
    indicators = {},
    stateName = "normal",
    -- What the cells have room for. Held on the context because `render` has
    -- to know: a readout the panel has shed is a reading nobody can check,
    -- and formatting one four times a frame is work with no reader.
    showCaption = area.showCaption,
    showValue = area.showValue,
  }

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation,
    services.themeBuilder)

  local control = services.control
  local scale = settings.scale

  for index = 1, count do
    local name = settings["trim" .. index]
    local vertical = trimPanel.isVertical(settings, index, rect)
    local cell = trimPanel.cellFor(area, index, vertical)

    local indicator = {
      name = type(name) == "string" and name or "",
      vertical = vertical,
      valueText = "",
    }

    -- Subscribing in create is what makes the control service read this trim
    -- at all; a trim nothing references is never polled.
    if control then indicator.feed = control:trim(indicator.name, scale) end

    indicator.caption = primitives.label(panel.root, theme, {
      x = cell.x,
      y = cell.captionY,
      w = cell.textWidth,
      text = area.showCaption and trimPanel.captionFor(indicator.name) or "",
      color = theme.color.textFaint,
      font = fonts.label,
    })

    indicator.bar = primitives.bipolarBar(panel.root, theme, {
      x = cell.barX,
      y = cell.barY,
      w = cell.barWidth,
      h = cell.barHeight,
      thickness = BAR_THICKNESS,
      vertical = vertical,
      fraction = 0,
      color = presentation.accent,
    })

    indicator.value = primitives.label(panel.root, theme, {
      x = cell.x,
      y = cell.valueY,
      w = cell.textWidth,
      text = "",
      color = theme.color.textMuted,
      font = fonts.label,
    })

    if not area.showCaption then lvgl.hide(indicator.caption) end
    if not area.showValue then lvgl.hide(indicator.value) end

    context.indicators[index] = indicator
  end

  local _, drawn = primitives.changed(context, trimPanel.render)
  trimPanel.apply(context, drawn)
  return context
end

--- Resolve the panel's state from the indicators it actually has.
--- One unreadable trim among four is reported by that indicator's own dashes;
--- the panel only calls itself unavailable when none of them can be read.
---@param context table
---@return string
function trimPanel.resolveState(context)
  for _, indicator in ipairs(context.indicators) do
    local feed = indicator.feed
    if type(feed) == "table" and feed.available then return "normal" end
  end
  return "unavailable"
end

--- Repaint every indicator from its current subscription.
---@param context table
--- Collect everything this panel draws.
---
--- One panel with several indicators, so the declaration is flat: each
--- indicator contributes its own keys. A nested table would compare by
--- identity and never differ.
---@param context table
---@param out table
function trimPanel.render(context, out)
  local settings = context.settings
  local showValue = context.showValue
  out.state = trimPanel.resolveState(context)

  for index, indicator in ipairs(context.indicators) do
    local feed = indicator.feed
    local available = type(feed) == "table" and feed.available == true
    -- A cell too narrow for text has no readout, so none is formatted. The
    -- key is absent rather than empty, which `changed` notices by counting.
    if showValue then
      out["text" .. index] = trimPanel.valueText(settings, feed)
    end
    out["fraction" .. index] = available and feed.fraction or 0
    out["available" .. index] = available
  end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context table
---@param drawn table
function trimPanel.apply(context, drawn)
  local primitives = context.primitives
  local presentation = context.state(drawn.state, context.settings.accent)

  context.stateName = drawn.state
  context.label:set({color = presentation.label})
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  primitives.stylePanel(context.panel, presentation)

  for index, indicator in ipairs(context.indicators) do
    -- An unreadable trim must not look like a centred one, so its bar is
    -- drawn in the faint token rather than the panel's accent.
    primitives.setBipolarBar(indicator.bar, drawn["fraction" .. index],
      drawn["available" .. index] and presentation.accent
        or context.theme.color.textFaint)

    if context.showValue then
      local text = drawn["text" .. index]
      indicator.valueText = text
      indicator.value:set({text = text})
    end
  end
end

--- Advance the panel, repainting only when something drawn changed.
---@param context table
function trimPanel.refresh(context)
  local changed, drawn = context.primitives.changed(context, trimPanel.render)
  if changed then trimPanel.apply(context, drawn) end
end

--- Reposition after a zone change, re-deriving every cell.
---@param context table
---@param rect AeroGridRect
function trimPanel.update(context, rect)
  local primitives = context.primitives
  local area = trimPanel.regionsFor(context.theme, context.themeBuilder,
    rect, context.count, context.fonts)

  primitives.resizePanel(context.panel, rect)
  primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts, context.settings.label)

  local reconcile = primitives.reconcile
  local captionsChanged = area.showCaption ~= context.showCaption
  context.showCaption = area.showCaption

  local valuesChanged = area.showValue ~= context.showValue
  if valuesChanged then
    context.showValue = area.showValue
    if not area.showValue then
      -- Nothing reads a shed readout, and a stale one left behind reads like
      -- a value that is still being kept up to date.
      for _, indicator in ipairs(context.indicators) do
        indicator.valueText = ""
      end
    end
    -- Nothing is discarded here on purpose. Every other component that sheds
    -- a row drops its last record so the next refresh repaints, because its
    -- row keeps being declared while hidden and the comparison would
    -- otherwise match. This panel stops declaring the readout at all, so the
    -- key count changes and `changed` sees the reveal by construction. The
    -- discard was written first and then removed when no test could be made
    -- to fail without it.
  end

  for index, indicator in ipairs(context.indicators) do
    -- The panel's shape may have changed, so an `auto` axis is resolved again.
    local vertical = trimPanel.isVertical(context.settings, index, rect)
    local cell = trimPanel.cellFor(area, index, vertical)

    if vertical ~= indicator.vertical then
      indicator.vertical = vertical
      indicator.bar.vertical = vertical
    end

    -- Eight rows here rather than one or two, so a row whose visibility has
    -- not moved is repositioned without being told again what it already is.
    reconcile(indicator.caption, area.showCaption,
      {x = cell.x, y = cell.captionY, w = cell.textWidth}, not captionsChanged)
    reconcile(indicator.value, area.showValue,
      {x = cell.x, y = cell.valueY, w = cell.textWidth}, not valuesChanged)
    primitives.placeBipolarBar(indicator.bar, cell.barX, cell.barY,
      cell.barWidth, cell.barHeight,
      type(indicator.feed) == "table" and indicator.feed.fraction or 0)

    -- A caption is fixed text, so it is written once when the row appears
    -- rather than on every reflow that keeps it.
    if captionsChanged and area.showCaption then
      indicator.caption:set({text = trimPanel.captionFor(indicator.name)})
    end
  end
end

return trimPanel
