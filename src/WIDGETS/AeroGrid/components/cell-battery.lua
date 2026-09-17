-- SPDX-License-Identifier: GPL-2.0-only

--- Flight-pack cell voltages.
---
--- The lowest cell is the safety reading, because a pack is only as good as
--- its worst cell: a 4S reading 16.2 V looks healthy right up until one cell
--- is at 3.2 V and the other three are carrying it. The lowest cell is
--- therefore the default primary reading, and the summed pack voltage is
--- supporting detail rather than the headline.
---
--- The bar is scaled over the configured usable range, from the critical
--- voltage to full, not from zero. A bar that started at zero would sit above
--- three quarters full on a pack that is nearly empty.
---
--- Two EdgeTX behaviours shape everything below. A cells source returns a
--- *table* of individual voltages, and that table is the only place a cell
--- count or a pack sum can come from. Its extremes, "Cels-" and "Cels+", carry
--- the same unit but return a plain number, which `telemetryService`
--- normalizes; an explicitly configured lowest-cell source is therefore an
--- ordinary numeric reading and is preferred when the layout names one,
--- because a receiver that computes it has seen samples between our polls.
---
--- No remaining-capacity percentage is shown. The specification forbids
--- estimating one until a component defines and labels its estimation model,
--- and voltage under load is a poor proxy for charge.

---@class AeroGridCellSettings
---@field source? string EdgeTX cells source, usually "Cels".
---@field lowestSource? string Explicit lowest-cell source such as "Cels-".
---@field label? string
---@field reading? "lowest"|"average"|"pack" Which value is dominant.
---@field min? number Volts per cell treated as empty by the bar.
---@field max? number Volts per cell treated as full by the bar.
---@field warning? number Volts per cell.
---@field critical? number Volts per cell.
---@field cells? number Expected cell count; zero follows the pack.
---@field showPack? boolean Show the summed pack voltage.
---@field showCount? boolean Show the detected cell count.
---@field visual? "bar"|"none"
---@field accent? string

---@class AeroGridCellContext
---@field panel table
---@field feed? AeroGridReading Cells subscription.
---@field lowestFeed? AeroGridReading Explicit lowest-cell subscription.
---@field summary table Reused result of the last shape validation.
---@field stateName string

local cellBattery = {
  id = "cell-battery",
  apiVersion = 1,
  supportedSpans = {
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
  },
  -- A pack voltage moves over a flight, not over a frame, and every refresh
  -- walks the cells table. Five hertz is already far more than a pilot reads.
  refreshInterval = 20,
  settings = {
    {key = "source", label = "Cells source", type = "string", default = "Cels"},
    {key = "lowestSource", label = "Lowest cell source", type = "string", default = ""},
    {key = "label", label = "Label", type = "string", default = "CELLS"},
    {key = "reading", label = "Primary reading", type = "string", default = "lowest"},
    -- The usable range, per cell: a LiPo is flat at 3.3 V and full at 4.2 V.
    {key = "min", label = "Empty voltage", type = "number", default = 3.3},
    {key = "max", label = "Full voltage", type = "number", default = 4.2},
    {key = "warning", label = "Warning voltage", type = "number", default = 3.5},
    {key = "critical", label = "Critical voltage", type = "number", default = 3.3},
    {key = "cells", label = "Expected cells", type = "number", default = 0},
    {key = "showPack", label = "Show pack voltage", type = "boolean", default = true},
    {key = "showCount", label = "Show cell count", type = "boolean", default = true},
    {key = "visual", label = "Visualization", type = "string", default = "bar"},
    {key = "accent", label = "Accent", type = "string", default = "cyan"},
  },
}

--- Most cells any supported protocol reports, and the ceiling on the walk.
--- The loop is bounded because it runs inside the host's instruction budget
--- and the table comes from the firmware rather than from this dashboard.
cellBattery.CELL_LIMIT = 16

--- Voltages outside this range are not cells.
--- A chemistry this dashboard has never heard of still cannot put 30 V across
--- one cell, so an entry above it is a pack voltage, a raw count, or a sensor
--- reporting something else entirely, and folding it in would hide a real low
--- cell behind a nonsense average.
cellBattery.CELL_MAX = 30

--- Validate a cells value and summarize it.
---
--- The result is written into a caller-owned table so a refresh allocates
--- nothing. `shape` is the honest description of what EdgeTX returned:
---
--- - `none`: nothing has been received, or the source is not configured.
--- - `number`: a plain number, which a cells source never returns; the layout
---   has pointed this component at an ordinary voltage sensor.
--- - `empty`: a table with no entries, which is what a pack that has not been
---   detected yet looks like.
--- - `invalid`: a table whose entries are not plausible cell voltages.
--- - `cells`: a usable table, with at least one valid cell.
---@param raw any Value from a telemetry subscription.
---@param out table Table to write the summary into.
---@return table out
function cellBattery.summarize(raw, out)
  out.shape = "none"
  out.count = 0
  out.entries = 0
  out.rejected = 0
  out.lowest = nil
  out.highest = nil
  out.pack = nil
  out.spread = nil

  if raw == nil then return out end

  if type(raw) ~= "table" then
    out.shape = type(raw) == "number" and "number" or "invalid"
    return out
  end

  local limit = cellBattery.CELL_LIMIT
  local maximum = cellBattery.CELL_MAX
  local sum = 0

  for index = 1, limit do
    local value = raw[index]
    if value == nil then break end

    out.entries = index
    -- A NaN compares false against everything, so it is excluded by the
    -- bounds test rather than needing its own branch.
    if type(value) == "number" and value > 0 and value < maximum then
      out.count = out.count + 1
      sum = sum + value
      if out.lowest == nil or value < out.lowest then out.lowest = value end
      if out.highest == nil or value > out.highest then out.highest = value end
    else
      out.rejected = out.rejected + 1
    end
  end

  if out.entries == 0 then
    out.shape = "empty"
    return out
  end

  if out.count == 0 then
    out.shape = "invalid"
    return out
  end

  out.shape = "cells"
  out.pack = sum
  out.spread = out.highest - out.lowest
  return out
end

--- Choose the dominant reading from a validated summary.
--- An explicitly configured lowest-cell source wins for the lowest reading,
--- because the receiver maintaining it has seen every sample between our
--- polls, where this component only sees the ones it asked for.
---@param settings AeroGridCellSettings
---@param summary table
---@param lowest? number Value of an explicit lowest-cell source.
---@return number? value
function cellBattery.primaryValue(settings, summary, lowest)
  local mode = settings.reading

  if mode == "pack" then return summary.pack end
  if mode == "average" then
    if summary.count == 0 or summary.pack == nil then return nil end
    return summary.pack / summary.count
  end

  if type(lowest) == "number" then return lowest end
  return summary.lowest
end

--- Report whether the primary reading is a per-cell voltage.
--- A pack reading is not, so per-cell thresholds and the per-cell bar must not
--- be applied to it.
---@param settings AeroGridCellSettings
---@return boolean
function cellBattery.isPerCell(settings)
  return settings.reading ~= "pack"
end

--- Resolve the component state. Cell voltages always count downward.
---@param settings AeroGridCellSettings
---@param value any Primary reading.
---@param perCell any Lowest cell, which is what the thresholds judge.
---@param stale boolean
---@return string
function cellBattery.resolveState(settings, value, perCell, stale)
  if type(value) ~= "number" or value ~= value then return "unavailable" end
  if stale then return "stale" end

  -- The thresholds are per cell, so a pack reading is still judged by its
  -- worst cell rather than by a sum that hides one.
  local judged = type(perCell) == "number" and perCell or nil
  if judged == nil then return "normal" end

  local critical = settings.critical
  local warning = settings.warning
  if type(critical) == "number" and judged <= critical then return "critical" end
  if type(warning) == "number" and judged <= warning then return "warning" end
  return "normal"
end

--- Convert a per-cell voltage into a fraction of the usable range.
--- The range runs from the configured empty voltage to full, never from zero.
---@param settings AeroGridCellSettings
---@param value any
---@param cells integer Divisor for a pack reading.
---@return number
function cellBattery.fraction(settings, value, cells)
  if type(value) ~= "number" or value ~= value then return 0 end

  local low = type(settings.min) == "number" and settings.min or 3.3
  local high = type(settings.max) == "number" and settings.max or 4.2
  if high <= low then return 0 end

  local perCell = value
  if not cellBattery.isPerCell(settings) then
    if type(cells) ~= "number" or cells < 1 then return 0 end
    perCell = value / cells
  end

  local fraction = (perCell - low) / (high - low)
  if fraction < 0 then return 0 end
  if fraction > 1 then return 1 end
  return fraction
end

--- Badge text for a state, naming the shape problem when there is one.
--- "NO SOURCE" is the right answer for a sensor the radio has never seen, but
--- it is the wrong answer for a source that answered with something this
--- component cannot read: those need different fixes, so they read
--- differently.
---@param summary table
---@param stateName string
---@param fallback? string Badge the theme resolved for this state.
---@return string
function cellBattery.badgeText(summary, stateName, fallback)
  if stateName == "unavailable" then
    if summary.shape == "number" then return "NOT CELLS" end
    if summary.shape == "invalid" then return "BAD CELLS" end
    if summary.shape == "empty" then return "NO CELLS" end
  end

  return fallback or ""
end

--- Describe how the component presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
function cellBattery.presentationFor(colSpan, rowSpan)
  local cells = (colSpan or 1) * (rowSpan or 1)
  return {showVisual = cells >= 2, showDetail = cells >= 2}
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@param sample string Widest value text this component can render.
---@return table
function cellBattery.regionsFor(theme, themeBuilder, rect, layout, fonts, sample)
  local spacing = theme.spacing
  local frame = themeBuilder.frame(theme, rect, fonts)
  local labelHeight = frame.labelHeight
  local top = frame.top
  local showVisual = layout.showVisual and layout.visual ~= "none"
  local showDetail = layout.showDetail

  local function room()
    local below = frame.bottom
    if showVisual then below = below + spacing.barHeight + 2 end
    if showDetail then below = below + labelHeight + 2 end
    return rect.h - top - below
  end

  -- The dominant reading wins: shed the supporting rows before shrinking it.
  local comfortable = themeBuilder.fontHeight(MIDSIZE)
  if room() < comfortable and showDetail then showDetail = false end
  if room() < comfortable and showVisual then showVisual = false end

  local value = themeBuilder.fitText(sample, frame.content, math.max(1, room()))
  local valueHeight = themeBuilder.fontHeight(value)
  if top + valueHeight > rect.h then top = math.max(0, rect.h - valueHeight) end

  local barY = math.max(1, rect.h - frame.bottom - spacing.barHeight)
  -- The detail row carries the cell count on the left and the pack voltage on
  -- the right, so neither can draw over the other.
  local detailWidth = math.max(1, math.floor((frame.content - 4) / 2))

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    valueY = top,
    value = value,
    detailY = math.max(1, barY - labelHeight - 2),
    detailWidth = detailWidth,
    packX = frame.pad + frame.content - detailWidth,
    barY = barY,
    showVisual = showVisual,
    showDetail = showDetail,
  }
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridCellSettings
---@param services table
---@return AeroGridCellContext
function cellBattery.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local span = services.span
  local layout = cellBattery.presentationFor(span.colSpan, span.rowSpan)
  layout.visual = settings.visual
  local presentation = services.state("normal", settings.accent)

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
    countText = "",
    packText = "",
    -- Reused so a refresh allocates nothing; the host pays this per frame.
    summary = {},
  }

  -- Subscribing in create is the mechanism: a source nothing references is
  -- never read.
  local telemetry = services.telemetry
  if telemetry then
    context.feed = telemetry:subscribe(settings.source)
    if type(settings.lowestSource) == "string" and settings.lowestSource ~= "" then
      context.lowestFeed = telemetry:subscribe(settings.lowestSource)
    end
  end

  -- A pack reading is the widest thing this component can print, so the font
  -- is chosen from that rather than from whichever value is showing now.
  local sample = cellBattery.isPerCell(settings) and "4.44V" or "88.8V"
  context.sample = sample

  local area = cellBattery.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts, sample)

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

  context.countLabel = primitives.label(panel.root, theme, {
    x = area.pad,
    y = area.detailY,
    w = area.detailWidth,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  context.packLabel = primitives.label(panel.root, theme, {
    x = area.packX,
    y = area.detailY,
    w = area.detailWidth,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  if layout.showVisual and settings.visual ~= "none" then
    context.bar = primitives.bar(panel.root, theme, {
      x = area.pad,
      y = area.barY,
      w = area.content,
      fraction = 0,
      color = presentation.accent,
    })
  end

  if not area.showDetail then
    lvgl.hide(context.countLabel)
    lvgl.hide(context.packLabel)
  end
  if context.bar and not area.showVisual then
    lvgl.hide(context.bar.track)
    lvgl.hide(context.bar.fill)
  end

  cellBattery.gather(context)
  cellBattery.apply(context)
  return context
end

--- Read both subscriptions into the context, allocating nothing.
--- Kept separate from `apply` so a refresh can decide whether anything is
--- worth repainting without summarizing the cells table twice.
---@param context AeroGridCellContext
function cellBattery.gather(context)
  local settings = context.settings
  local feed = context.feed
  local summary = cellBattery.summarize(
    type(feed) == "table" and feed.available and feed.raw or nil, context.summary)

  local lowestFeed = context.lowestFeed
  local lowest = nil
  local lowestStale = false
  if type(lowestFeed) == "table" and lowestFeed.available
      and type(lowestFeed.value) == "number" then
    lowest = lowestFeed.value
    lowestStale = lowestFeed.stale == true
  end

  -- An explicit lowest-cell source keeps this component useful when the cells
  -- table itself is unreadable, which is the whole reason it is separate.
  context.primary = cellBattery.primaryValue(settings, summary, lowest)
  context.perCell = lowest or summary.lowest

  -- Freshness follows whichever source actually produced the reading.
  if summary.shape == "cells" then
    context.stale = type(feed) == "table" and feed.stale == true
  else
    context.stale = lowest ~= nil and lowestStale
  end
end

--- Repaint the component from the gathered reading.
---@param context AeroGridCellContext
function cellBattery.apply(context)
  local settings = context.settings
  local summary = context.summary
  local value = context.primary
  local stale = context.stale == true

  local stateName = cellBattery.resolveState(
    settings, value, context.perCell, stale)
  local presentation = context.state(stateName, settings.accent)

  context.stateName = stateName
  context.reading = value
  context.staleReading = stale
  context.shape = summary.shape
  context.appliedCount = summary.count
  context.appliedPack = summary.pack
  context.appliedPerCell = context.perCell

  local text = "--"
  if type(value) == "number" then
    -- Two decimals: cells are compared against each other, and 3.8 V hides a
    -- difference that matters where 3.82 V does not.
    text = string.format("%.2fV", value)
  end
  context.text = text

  context.value:set({text = text, color = presentation.value})
  context.label:set({color = presentation.label})
  context.badge:set({
    text = cellBattery.badgeText(summary, stateName, presentation.badge),
    color = presentation.accent,
  })
  context.primitives.stylePanel(context.panel, presentation)

  local countText = ""
  if settings.showCount and summary.count > 0 then
    countText = tostring(summary.count) .. "S"
    local expected = settings.cells
    -- A cell that stopped reporting is exactly the failure this component
    -- exists to catch, so a count below the configured one is called out.
    if type(expected) == "number" and expected > 0 and summary.count ~= expected then
      countText = countText .. " OF " .. tostring(math.floor(expected))
    end
  elseif settings.showCount and summary.shape ~= "cells" and summary.shape ~= "none" then
    countText = "NO CELLS"
  end
  if countText ~= context.countText then
    context.countText = countText
    context.countLabel:set({text = countText})
  end

  local packText = ""
  if settings.showPack and type(summary.pack) == "number" then
    packText = string.format("%.1fV PACK", summary.pack)
  end
  if packText ~= context.packText then
    context.packText = packText
    context.packLabel:set({text = packText})
  end

  if context.bar then
    context.primitives.setBar(context.bar,
      cellBattery.fraction(settings, value, summary.count), presentation.accent)
  end
end

--- Advance the component, repainting only when something visible changed.
---@param context AeroGridCellContext
function cellBattery.refresh(context)
  if not context.feed and not context.lowestFeed then return end

  -- EdgeTX builds a fresh cells table on every read, so the table identity
  -- cannot be compared. Summarizing is bounded and cheap; repainting is not,
  -- so the summary decides whether anything is worth redrawing.
  cellBattery.gather(context)

  local summary = context.summary
  -- The pack sum and the worst cell both appear on the panel and both decide
  -- the state, and neither has to move when the primary reading does. Three
  -- of four cells sagging leaves the lowest cell exactly where it was.
  if context.applied and context.primary == context.reading
      and (context.stale == true) == context.staleReading
      and summary.count == context.appliedCount
      and summary.shape == context.shape
      and summary.pack == context.appliedPack
      and context.perCell == context.appliedPerCell then
    return
  end

  context.applied = true
  cellBattery.apply(context)
end

--- Reposition after a zone change.
---@param context AeroGridCellContext
---@param rect AeroGridRect
function cellBattery.update(context, rect)
  local area = cellBattery.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts, context.sample)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame)
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.content,
    font = function() return area.value end,
  })

  --- Show or hide a supporting row, positioning it only when visible.
  local function reconcile(object, visible, changes)
    if not object then return end
    if visible then
      object:set(changes)
      lvgl.show(object)
    else
      lvgl.hide(object)
    end
  end

  reconcile(context.countLabel, area.showDetail,
    {x = area.pad, y = area.detailY, w = area.detailWidth})
  reconcile(context.packLabel, area.showDetail,
    {x = area.packX, y = area.detailY, w = area.detailWidth})

  if context.bar then
    if area.showVisual then
      context.primitives.placeBar(context.bar, area.pad, area.barY, area.content,
        cellBattery.fraction(context.settings, context.reading,
          context.summary.count or 0))
      lvgl.show(context.bar.track)
      lvgl.show(context.bar.fill)
    else
      lvgl.hide(context.bar.track)
      lvgl.hide(context.bar.fill)
    end
  end
end

return cellBattery
