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
---@field cellEmpty? number Volts per cell treated as empty by the bar.
---@field cellFull? number Volts per cell treated as full by the bar.
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
    {key = "label", label = "Label", type = "string", default = "PACK"},
    {key = "reading", label = "Primary reading", type = "string",
      default = "lowest", choices = {"lowest", "average", "pack"}},
    -- The usable range, per cell: a LiPo is flat at 3.3 V and full at 4.2 V.
    -- Named for what they range over, because `min` and `max` meant four
    -- different things across the catalogue and nothing in the key said which.
    {key = "cellEmpty", label = "Empty volts per cell", type = "number", default = 3.3},
    {key = "cellFull", label = "Full volts per cell", type = "number", default = 4.2},
    {key = "warning", label = "Warning volts per cell", type = "number", default = 3.5},
    {key = "critical", label = "Critical volts per cell", type = "number", default = 3.3},
    -- Cell voltages only ever count downward, but it is stated rather than
    -- assumed so every threshold in the catalogue reads the same way.
    -- No `direction`. A cell only ever alarms downward, so the setting had
    -- one valid value and told a reader nothing except to wonder what the
    -- other one would do. The behaviour is documented instead.
    {key = "cells", label = "Expected cells", type = "number", default = 0},
    {key = "showPack", label = "Show pack voltage", type = "boolean", default = true},
    {key = "showCount", label = "Show cell count", type = "boolean", default = true},
    {key = "visual", label = "Visualization", type = "string", default = "bar",
      choices = {"bar", "none"}},
    {key = "accent", label = "Accent", type = "string", default = "cyan",
      choices = {"cyan", "green", "amber", "orange"}},
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
---
--- **Five shapes, two wordings.** `number` and `invalid` print the same row,
--- `CELLS ERR`, because a pilot does the same thing about both: something is
--- arriving and it is wrong, so go and fix the configuration. They are still
--- separated here, and `service-probe` and the host diagnostics view still
--- report which one arrived -- that is a question someone at a desk can act
--- on, where the row is read at arm's length in flight. **The distinction is
--- withheld from the panel, not discarded**; see `countVariants`.
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

  local low = type(settings.cellEmpty) == "number" and settings.cellEmpty or 3.3
  local high = type(settings.cellFull) == "number" and settings.cellFull or 4.2
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

--- Wordings for the cell-count row, which is where a shape problem is named.
---
--- "N/A" is the right badge for a source that answered with something this
--- component cannot read, and it is not enough on its own. What the row adds
--- is **what the pilot should do about it**, and there are two answers:
---
--- - `NO CELLS` -- nothing has arrived and may yet. The source answered with
---   an empty table, which is what a pack that has not been detected looks
---   like. Wait.
--- - `CELLS ERR` -- something is arriving and it is wrong. Either the source
---   is not a cells sensor at all, or it is one reporting implausible
---   voltages. Go and fix the configuration.
---
--- **Three wordings became two, and the reason is the action rather than the
--- width.** All three fitted: `NOT CELLS`, `BAD CELLS` and `NO CELLS` are 67,
--- 66 and 59 px against budgets of 105 and 86. But whether the wrong thing
--- arriving is an ordinary voltage sensor or a nonsense table is a
--- distinction the pilot cannot act on differently -- both mean the layout or
--- the receiver is misconfigured, and both are fixed on the ground. A row
--- that spends a word on a difference nobody can use is spending it twice:
--- once in the reading and once in the reader.
---
--- **The `shape` values stay five.** `summarize` still separates `number`
--- from `invalid`, `service-probe` and the diagnostics view still report
--- which arrived, and a future component may still care. Only the
--- pilot-facing row collapses; the distinction is not thrown away, it is
--- withheld from a place it cannot be used.
---
--- So there are two displayed states here rather than three, and
--- `testSupportingWordingsStayDistinct` holds *those* two apart. It fires if
--- they are ever collapsed further, which is the check doing its job rather
--- than an obstacle: two states that print the same thing and imply the same
--- action are one state.
---@param summary table
---@param settings AeroGridCellSettings
---@return string[]
function cellBattery.countVariants(summary, settings)
  local shape = summary.shape

  -- One wording, not a ladder. A form that fits the narrowest row fits every
  -- row, so a longer one would only ever be drawn where the short one was
  -- also correct.
  if shape == "number" or shape == "invalid" then return {"CELLS ERR"} end
  if shape == "empty" then return {"NO CELLS"} end
  if shape ~= "cells" or summary.count == 0 then return {""} end
  if not settings.showCount then return {""} end

  local count = tostring(summary.count) .. "S"
  local expected = settings.cells
  -- A cell that stopped reporting is exactly the failure this component exists
  -- to catch, so a count below the configured one is called out.
  if type(expected) == "number" and expected > 0 and summary.count ~= expected then
    local full = count .. " OF " .. tostring(math.floor(expected))
    return {full, count .. "/" .. tostring(math.floor(expected)), count}
  end

  return {count}
end

--- Wordings for the pack-voltage row.
---@param summary table
---@param settings AeroGridCellSettings
---@return string[]
function cellBattery.packVariants(summary, settings)
  if not settings.showPack or type(summary.pack) ~= "number" then return {""} end

  local volts = string.format("%.1fV", summary.pack)
  return {volts .. " PACK", volts}
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
---@param settings AeroGridCellSettings
---@param span? table Placement span, when the host knows it.
---@param config? table What the layout actually stated.
---@return string[] messages
function cellBattery.validateSettings(settings, span, config)
  local messages = {}
  if type(config) ~= "table" then return messages end
  if type(span) ~= "table" or type(span.rowSpan) ~= "number" then
    return messages
  end
  if span.rowSpan >= 2 then return messages end

  if config.showPack then
    messages[#messages + 1] = "showPack needs a panel two rows tall;"
      .. " a single row has no space beneath the reading at any width."
      .. " Give the panel rowSpan 2, or drop showPack."
  end

  if config.showCount then
    messages[#messages + 1] = "showCount needs a panel two rows tall;"
      .. " a single row has no space beneath the reading at any width."
      .. " Give the panel rowSpan 2, or drop showCount."
  end

  return messages
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
---@param sample table Widest digits this component prints, and its unit.
---@return table
function cellBattery.regionsFor(theme, themeBuilder, rect, layout, fonts,
    sample, out)
  -- The whole arrangement, from the shared builder. Like `link-status`, this
  -- component's only visualization is a bar, so the reading never splits.
  local area = themeBuilder.panel(theme, rect, fonts, {
    -- Built through this component's own builder, which the host may have
    -- wrapped to lay the panel out around the menu button's corner.
    frame = themeBuilder.frame(theme, rect, fonts),
    forms = {sample.digits},
    unit = sample.unit,
    draws = {
      rows = layout.showDetail == true,
      visual = layout.showVisual == true and layout.visual ~= "none",
    },
    bar = true,
    -- The cell count on the left, the pack voltage on the right.
    rowItems = 2,
  }, out or {})
  return area
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

  -- The widest number this component can print, taken from what it reads
  -- rather than from whatever is showing now, so the reading does not resize
  -- as the pack drains. The two decimals are not negotiable: cells are
  -- compared against each other, and 3.8 V hides a difference that matters
  -- where 3.82 V does not. The unit rides beside the number rather than
  -- being part of it.
  local sample = {
    digits = cellBattery.isPerCell(settings) and "4.44" or "88.8",
    unit = "V",
  }
  context.sample = sample

  local area = cellBattery.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts, sample)
  context.detailWidth = area.detailWidth
  context.showDetail = area.showDetail

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation,
    services.themeBuilder)

  context.value = primitives.value(panel.root, theme, {
    x = area.valueX,
    y = area.valueY,
    w = area.valueWidth,
    text = "--",
    color = presentation.value,
    font = area.value,
  })

  -- Recorded as well as drawn. The reading is centred on its slot and the
  -- unit rides past it, so the helper that places the pair has to know how
  -- wide the pair is -- and an LVGL object is userdata on a radio, with no
  -- readable text to ask. This component's unit never changes, unlike
  -- `link-status`, whose telemetry answers with one.
  context.unitText = sample.unit
  context.unit = primitives.unit(panel.root, theme, {
    x = area.valueX,
    y = area.valueY,
    text = sample.unit,
    color = theme.color.textMuted,
    font = area.unitFont,
  })

  context.countLabel = primitives.label(panel.root, theme, {
    x = area.detailX,
    y = area.detailY,
    w = area.detailWidth,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  context.packLabel = primitives.label(panel.root, theme, {
    x = area.rowRightX,
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
  if not area.showUnit then lvgl.hide(context.unit) end
  context.showUnit = area.showUnit
  context.area = area
  -- What the panel currently shows, so a reflow that changes nothing about
  -- visibility does not tell every object again what it already is.
  context.showVisual = area.showVisual
  if context.bar and not area.showVisual then
    lvgl.hide(context.bar.track)
    lvgl.hide(context.bar.fill)
  end

  local _, drawn = primitives.changed(context, cellBattery.render)
  cellBattery.apply(context, drawn)
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
--- Collect everything this panel draws.
---@param context AeroGridCellContext
---@param out table
function cellBattery.render(context, out)
  cellBattery.gather(context)

  local settings = context.settings
  local summary = context.summary
  local value = context.primary
  local stale = context.stale == true

  out.state = cellBattery.resolveState(settings, value, context.perCell, stale)
  -- Two decimals: cells are compared against each other, and 3.8 V hides a
  -- difference that matters where 3.82 V does not.
  -- Digits alone. The `V` is its own label beside them, so there is no
  -- longer a shorter form of this string to measure and then not draw.
  out.text = type(value) == "number" and string.format("%.2f", value) or "--"
  out.fraction = cellBattery.fraction(settings, value, summary.count)
  out.value = value

  if context.showDetail then
    local fit = context.themeBuilder.fitLabel
    local font = context.fonts.label
    out.count = fit(cellBattery.countVariants(summary, settings), font,
      context.detailWidth)
    out.pack = fit(cellBattery.packVariants(summary, settings), font,
      context.detailWidth)
  end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridCellContext
---@param drawn table
function cellBattery.apply(context, drawn)
  local presentation = context.state(drawn.state, context.settings.accent)

  context.stateName = drawn.state
  context.reading = drawn.value
  context.text = drawn.text
  context.countText = drawn.count
  context.packText = drawn.pack

  context.value:set({text = drawn.text, color = presentation.value})
  -- The unit follows what the number says, so it stays attached to a short
  -- reading instead of holding station at the widest one's edge.
  context.primitives.centreReading(context, context.themeBuilder,
    context.area, context.area.value, drawn.text)
  context.label:set({color = presentation.label})
  context.primitives.setBadge(context, context.themeBuilder, context.badge,
    context.area.frame, context.fonts.badge, presentation.badge or "",
    presentation.accent)
  context.primitives.stylePanel(context.panel, presentation)

  if context.showDetail then
    context.countLabel:set({text = drawn.count})
    context.packLabel:set({text = drawn.pack})
    -- Both items take the panel's slot centres, keyed on what they say so a
    -- steady pack pays nothing.
    context.primitives.centreLabel(context, "countAnchor",
      context.themeBuilder, context.countLabel, context.area.detailCentre,
      context.area.detailY, context.fonts.label, drawn.count)
    context.primitives.centreLabel(context, "packAnchor",
      context.themeBuilder, context.packLabel, context.area.rowRightCentre,
      context.area.detailY, context.fonts.label, drawn.pack)
  end

  if context.bar then
    context.primitives.setBar(context.bar, drawn.fraction, presentation.accent)
  end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridCellContext
function cellBattery.refresh(context)
  if not context.feed and not context.lowestFeed then return end
  local changed, drawn = context.primitives.changed(context, cellBattery.render)
  if changed then cellBattery.apply(context, drawn) end
end

--- Reposition after a zone change.
---@param context AeroGridCellContext
---@param rect AeroGridRect
function cellBattery.update(context, rect)
  local area = cellBattery.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts, context.sample)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts, context.settings.label,
      context.badgeText)
  context.value:set({
    x = area.valueX,
    y = area.valueY,
    w = area.valueWidth,
    font = function() return area.value end,
  })

  context.primitives.reconcileUnit(context.unit, area.showUnit,
    context.themeBuilder, area.valueX, area.valueY, area.value, context.text,
    area.unitFont, area.showUnit == context.showUnit)
  context.showUnit = area.showUnit
  -- Every anchor is about a slot and a font that have just moved.
  context.unitAnchor = nil
  context.readingAnchor, context.readingUnitAnchor = nil, nil
  context.countAnchor, context.packAnchor = nil, nil
  context.area = area

  --- Show or hide a supporting row, positioning it only when visible.
  local reconcile = context.primitives.reconcile

  -- A resize changes how much room each row has and whether there is a row at
  -- all. Both are recorded and nothing else is done, because `render` reads
  -- both: it declares no count or pack key while the row is shed, so the key
  -- reappearing is what tells `changed` to repaint, and it refits against the
  -- new width, so a wording that has to change is a value that has changed.
  -- There used to be a discard here. It was removed once no test could be
  -- made to fail without it.
  context.detailWidth = area.detailWidth
  context.showDetail = area.showDetail

  reconcile(context.countLabel, area.showDetail,
    {x = area.detailX, y = area.detailY, w = area.detailWidth})
  reconcile(context.packLabel, area.showDetail,
    {x = area.rowRightX, y = area.detailY, w = area.detailWidth})

  context.primitives.reconcileBar(context.bar, area.showVisual,
    area.pad, area.barY, area.content,
    cellBattery.fraction(context.settings, context.reading,
      context.summary.count or 0),
    area.showVisual == context.showVisual)
  context.showVisual = area.showVisual
end

return cellBattery
