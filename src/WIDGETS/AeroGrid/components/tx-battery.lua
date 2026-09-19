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
    -- A battery rather than a bar, because a bar says "some of something"
    -- and this panel is about which something. The bar stays available: on a
    -- panel four cells wide a glyph is a small shape in a lot of space, and a
    -- track running the width reads better there.
    {key = "visual", label = "Visualization", type = "string",
      default = "battery", choices = {"battery", "bar", "none"}},
    {key = "showPercent", label = "Show estimate", type = "boolean", default = false},
  },
}

--- Widest digits this panel prints. The unit is no longer part of the string:
--- it rides beside the number in its own label at a smaller font, so there is
--- one form rather than two and nothing to choose wrongly between.
txBattery.DIGITS = "88.8"

--- The unit, which every transmitter pack is measured in.
txBattery.UNIT = "V"

--- Print the reading. Digits only: the unit is a separate label.
---
--- This used to choose between `88.8V` and `88.8` on the strength of a form
--- index the fitter returned and the printing ignored, which is how a 116
--- pixel string came to be drawn in a 105 pixel column. There is nothing to
--- choose now, so there is nothing to get wrong.
---@param value any
---@return string
function txBattery.reading(value)
  if type(value) ~= "number" or value ~= value then return "--" end
  return string.format("%.1f", value)
end

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

--- Vertical air between the reading and the glyph beside it, and between the
--- glyph and the percentage beneath it.
txBattery.GLYPH_GAP = 6

--- Tallest cell this panel will draw.
--- An upright battery given every pixel of a two-row panel would be taller
--- than the number beside it, and a battery is an indicator rather than the
--- reading. Fifty pixels stands a little above an XXLSIZE line's ascent.
txBattery.GLYPH_MAX_HEIGHT = 50

--- Choose the largest glyph the panel can afford beside its reading.
---
--- The cell stands upright, so **height is what is searched and width follows
--- it**. That is the whole of what turning it vertical changed here: a lying
--- battery was bounded by the width the reading left, and an upright one is
--- bounded by the room above the supporting row as well, so both have to be
--- satisfied at once.
---
--- The glyph still takes a column, so the reading is still fitted against
--- what is left rather than against the whole panel, and the budget is the
--- one the ladder implies: **a reading may step down one size to make room,
--- and no further.** Two steps is the panel telling us it cannot hold both.
---
--- Sized by search rather than by formula because the answer is not smooth:
--- a glyph one pixel narrower can be the difference between the reading
--- keeping XXLSIZE and dropping to DBLSIZE, and there is no expression for
--- where that edge falls that is not just this loop written out.
---@param themeBuilder table
---@param primitives table Owns what is too small to read as a battery.
---@param content integer Full content width.
---@param room integer Vertical room the ladder left.
---@param tall integer Vertical pixels the glyph's own column has.
---@return integer? width
---@return integer? height
---@return any font Reading font once the glyph has taken its column.
---@return any unitFont
---@return boolean showUnit
function txBattery.glyphFor(themeBuilder, primitives, content, room, tall)
  local digits, unit = txBattery.DIGITS, txBattery.UNIT
  local bare, bareUnitFont, bareShowsUnit =
    themeBuilder.fitReadingUnit(digits, unit, content, room)
  local step = themeBuilder.readingStep(bare)
  local floorStep = step and math.min(step + 1, #themeBuilder.READING_FONTS)
  local floorHeight = floorStep
    and themeBuilder.fontHeight(themeBuilder.READING_FONTS[floorStep])
    or 0

  -- As tall as its column allows, capped so a cell beside an XXLSIZE reading
  -- is an indicator rather than a second reading.
  local ideal = math.min(txBattery.GLYPH_MAX_HEIGHT, tall)

  for height = ideal, primitives.GLYPH_MIN_HEIGHT, -1 do
    local width = math.max(primitives.GLYPH_MIN_WIDTH,
      math.floor(height / primitives.GLYPH_ASPECT + 0.5))
    local left = content - width - txBattery.GLYPH_GAP
    local font, rider, showUnit, fits =
      themeBuilder.fitReadingUnit(digits, unit, left, room)
    -- Two conditions, and the second is not implied by the first. A reading
    -- already at the bottom of the ladder passes a test that only asks how
    -- far it stepped, because there is nowhere further for it to step, and
    -- the glyph would take width the reading needed.
    --
    -- The unit is not part of the budget. It costs the reading nothing by
    -- construction, so a glyph that squeezes the unit out has not made the
    -- number smaller -- it has spent redundancy, which is the cheap thing.
    if fits and themeBuilder.fontHeight(font) >= floorHeight then
      return width, height, font, rider, showUnit
    end
  end

  return nil, nil, bare, bareUnitFont, bareShowsUnit
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param primitives table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@return table
function txBattery.regionsFor(theme, themeBuilder, primitives, rect, layout,
    fonts)
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
  local wantsGlyph = layout.visual == "battery"

  local barY = math.max(1, rect.h - frame.bottom - spacing.barHeight)
  local detailY = math.max(1, barY - labelHeight - 2)

  -- The column an upright cell stands in: from under the header down to the
  -- supporting row where there is one, or to the panel's own bottom where
  -- there is not.
  local glyphFloor = showDetail and (detailY - txBattery.GLYPH_GAP)
    or (rect.h - frame.bottom)
  local glyphRoom = math.max(0, glyphFloor - top)

  -- `88.8` is the widest number a transmitter pack produces. The `V` is not
  -- part of it: it rides beside it in its own label at a smaller font, and is
  -- dropped only where there is no room for the pair.
  local value, unitFont, showUnit, glyphWidth, glyphHeight
  if wantsGlyph and showVisual then
    glyphWidth, glyphHeight, value, unitFont, showUnit = txBattery.glyphFor(
      themeBuilder, primitives, frame.content, ladder.room, glyphRoom)
    -- A panel that cannot hold a glyph sheds it, the way it sheds any other
    -- visual. It does not fall back to a bar: the layout asked for a
    -- battery, and a bar in its place is a different answer to the question.
    if not glyphWidth then showVisual = false end
  else
    value, unitFont, showUnit = themeBuilder.fitReadingUnit(
      txBattery.DIGITS, txBattery.UNIT, frame.content, ladder.room)
  end

  local valueHeight = themeBuilder.fontHeight(value)
  if top + valueHeight > rect.h then top = math.max(0, rect.h - valueHeight) end

  local glyphX, glyphY, detailUnderGlyph, glyphBorder
  if glyphWidth then
    -- The stroke is answered here, where the reading's font is known, so the
    -- cell is outlined for the number it stands beside rather than for the
    -- span it happens to be at.
    glyphBorder = primitives.batteryStroke(themeBuilder, value, glyphWidth)
    glyphX = frame.pad + frame.content - glyphWidth
    if showDetail then
      -- The percentage sits on the supporting row every other panel of this
      -- size uses, and the cell stands directly above it, so the right column
      -- reads as one indicator without the row drifting away from where the
      -- dashboard puts supporting rows.
      glyphY = math.max(top, detailY - txBattery.GLYPH_GAP - glyphHeight)
      -- Under the cell only if it fits under the cell. An upright battery is
      -- half as wide as it is tall, so this is a narrower column than a lying
      -- one gave and the percentage stays beneath the reading more often.
      detailUnderGlyph = themeBuilder.textWidth(fonts.label, "100%") <= glyphWidth
    else
      glyphY = top + math.max(0, math.floor((valueHeight - glyphHeight) / 2))
    end
  end

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    valueY = top,
    value = value,
    unitFont = unitFont,
    showUnit = showUnit,
    -- The reading's own column, which is what is left once the glyph has
    -- taken its share. Written down rather than recomputed, because the
    -- label's width is what decides whether LVGL wraps it.
    valueWidth = glyphWidth and (frame.content - glyphWidth - txBattery.GLYPH_GAP)
      or frame.content,
    glyphX = glyphX,
    glyphY = glyphY,
    glyphWidth = glyphWidth,
    glyphHeight = glyphHeight,
    glyphBorder = glyphBorder,
    detailUnderGlyph = detailUnderGlyph == true,
    detailX = detailUnderGlyph and glyphX or frame.pad,
    detailWidth = detailUnderGlyph and glyphWidth
      or (glyphWidth and (frame.content - glyphWidth - txBattery.GLYPH_GAP)
        or frame.content),
    detailY = detailY,
    barY = barY,
    showVisual = showVisual,
    showDetail = showDetail,
    showGlyph = glyphWidth ~= nil,
    showBar = showVisual and layout.visual == "bar",
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
  layout.visual = settings.visual
  local presentation = services.state("normal", settings.accent)
  local area = txBattery.regionsFor(
    theme, services.themeBuilder, primitives, rect, layout, fonts)

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
    -- `render` needs this: the percentage is fitted to the column it lands
    -- in, which is the glyph's when it sits under one.
    detailWidth = area.detailWidth,
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
    -- Its own column, not the panel's. A label's width is what LVGL wraps
    -- against, so a reading handed the full content width while a glyph sits
    -- in part of it would be measured against space it does not have.
    w = area.valueWidth,
    text = "--",
    color = presentation.value,
    font = area.value,
  })

  -- Created whenever the panel could ever show it, and hidden until it does,
  -- for the reason every optional object here is: whether it is shown can
  -- change on a reflow and rebuilding an object is not free.
  context.unit = primitives.unit(panel.root, theme, {
    x = area.pad,
    y = area.valueY,
    text = txBattery.UNIT,
    color = theme.color.textMuted,
    font = area.unitFont,
  })

  context.detailLabel = primitives.label(panel.root, theme, {
    x = area.detailX,
    y = area.detailY,
    w = area.detailWidth,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  -- The bar is an estimate, so it is built whenever the panel could ever have
  -- a range to measure against, and hidden until one arrives. It used to be
  -- built only when the layout stated a range, which was safe while that was
  -- the only source; the radio's range arrives on the service's first update,
  -- after this runs, so deciding here would have meant no bar ever.
  if layout.showVisual and settings.visual == "bar" then
    context.bar = primitives.bar(panel.root, theme, {
      x = area.pad,
      y = area.barY,
      w = area.content,
      fraction = 0,
      color = presentation.accent,
    })
  elseif settings.visual == "battery" and area.showGlyph then
    context.glyph = primitives.batteryGlyph(panel.root, theme, {
      x = area.glyphX,
      y = area.glyphY,
      w = area.glyphWidth,
      h = area.glyphHeight,
      fraction = 0,
      color = presentation.accent,
      border = area.glyphBorder,
    })
  end

  if not area.showDetail then lvgl.hide(context.detailLabel) end
  if not area.showUnit then lvgl.hide(context.unit) end
  context.showUnit = area.showUnit
  context.area = area
  -- What the panel currently shows, so `render` declares only that and a
  -- reflow that changes nothing about visibility does not tell every object
  -- again what it already is.
  context.showVisual = area.showVisual
  context.showDetail = area.showDetail
  -- Whether the bar is *showing* is the box's answer and the range's answer
  -- together, and the second only arrives once the service has run.
  context.barShown = false
  context.glyphShown = false
  context.barX, context.barY, context.barWidth = area.pad, area.barY, area.content
  context.glyphRect = {x = area.glyphX, y = area.glyphY,
    w = area.glyphWidth, h = area.glyphHeight}

  if context.bar and not area.showVisual then
    lvgl.hide(context.bar.track)
    lvgl.hide(context.bar.fill)
  end
  if context.glyph then
    -- Built hidden and revealed by `apply`, for the same reason the bar is:
    -- whether there is a range to measure against is only known once the
    -- service has run, which is after this.
    lvgl.hide(context.glyph.shell)
    lvgl.hide(context.glyph.nub)
    lvgl.hide(context.glyph.fill)
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
  -- The form the fitter chose, not the longest one. The fitter was picking
  -- `88.8` at a `1 x 2` -- DBLSIZE, 93 pixels of a 105 pixel column -- and
  -- this printed `88.8V`, which is 116 and wraps onto a second line over
  -- whatever is beneath it. It has been true since the forms were written and
  -- only showed above 9.9 V, because `7.9V` happens to fit where `10.0V` does
  -- not. The same shape as the flight mode's name: measure one string, draw
  -- another.
  out.text = txBattery.reading(value)
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
    local percent = math.floor(out.fraction * 100 + 0.5)
    -- `EST` says the number is a linear fit rather than a gauge, so it is the
    -- first thing to go when the column is narrow -- which under a glyph it
    -- usually is. Fitted rather than assumed, like every other supporting row.
    out.detail = context.themeBuilder.fitLabel(
      {percent .. "% EST", percent .. "%"},
      context.fonts.label, context.detailWidth)
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
  -- The unit follows what the number actually says. A unit holding station at
  -- the width of `88.8` while the panel reads `7.9` has stopped being
  -- attached to it.
  context.primitives.followUnit(context, context.themeBuilder,
    context.area, context.area.value, drawn.text)
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

  -- And the glyph, on the same terms: an outline with no fill in it is a
  -- claim that the pack is empty, which is worse than showing nothing.
  local glyphShown = context.glyph ~= nil and context.showVisual and drawn.ranged
  if glyphShown then
    context.primitives.setBatteryGlyph(
      context.glyph, drawn.fraction, presentation.accent)
  end
  if context.glyph and glyphShown ~= context.glyphShown then
    local rect = context.glyphRect
    context.primitives.reconcileBatteryGlyph(context.glyph, glyphShown,
      rect.x, rect.y, rect.w, rect.h, drawn.fraction)
    context.glyphShown = glyphShown
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
    context.primitives, rect, context.layout, context.fonts)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts, context.settings.label)
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.valueWidth,
    font = function() return area.value end,
  })

  context.primitives.reconcileUnit(context.unit, area.showUnit,
    context.themeBuilder, area.pad, area.valueY, area.value, context.text,
    area.unitFont, area.showUnit == context.showUnit)
  context.showUnit = area.showUnit
  context.unitAnchor = nil

  context.primitives.reconcile(context.detailLabel, area.showDetail,
    {x = area.detailX, y = area.detailY, w = area.detailWidth},
    area.showDetail == context.showDetail)

  -- A row that has just reappeared holds whatever it had when it was shed,
  -- and `render` stopped declaring its key while it was hidden. The same
  -- applies when the row merely moved column: the percentage is fitted to its
  -- width, so a narrower column wants it written again.
  if area.showDetail ~= context.showDetail
      or area.detailWidth ~= context.detailWidth then
    context.rendered = nil
  end
  context.showDetail = area.showDetail
  context.detailWidth = area.detailWidth
  context.area = area

  local ranged = txBattery.hasRange(context.settings, context.range)
  local fraction = txBattery.fraction(
    context.settings, context.reading, context.range)

  context.barX, context.barY, context.barWidth = area.pad, area.barY, area.content
  local barShown = context.bar ~= nil and area.showVisual and ranged
  context.primitives.reconcileBar(context.bar, barShown,
    area.pad, area.barY, area.content, fraction,
    barShown == context.barShown)
  context.barShown = barShown

  -- A reflow can take the glyph away entirely: a panel narrowed to one cell
  -- has nowhere to put it, and the reading has first claim on the width.
  local glyphShown = context.glyph ~= nil and area.showVisual
    and area.showGlyph and ranged
  if area.showGlyph then
    context.glyphRect = {x = area.glyphX, y = area.glyphY,
      w = area.glyphWidth, h = area.glyphHeight}
  end
  local rect2 = context.glyphRect
  context.primitives.reconcileBatteryGlyph(context.glyph, glyphShown,
    rect2.x, rect2.y, rect2.w, rect2.h, fraction,
    glyphShown == context.glyphShown)
  context.glyphShown = glyphShown
  context.showVisual = area.showVisual
end

return txBattery
