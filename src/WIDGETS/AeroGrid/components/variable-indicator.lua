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
---@field visual? "none"|"bar"|"bipolar-bar"|"radial"
---@field rangeMin? number Overrides the resolved lower bound.
---@field rangeMax? number Overrides the resolved upper bound.
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
    {key = "binding", label = "Bind to", type = "string", default = "global",
      choices = {"global", "source"}},
    {key = "index", label = "Global variable", type = "number", default = 0},
    {key = "flightMode", label = "Flight mode", type = "number", default = -1},
    {key = "source", label = "Source", type = "string", default = ""},
    -- An empty label is not an absent one: it means derive the heading at
    -- runtime, here from the global variable's configured name. A
    -- component with a fixed heading states it as its default instead.
    {key = "label", label = "Label", type = "string", default = ""},
    {key = "showName", label = "Show configured name", type = "boolean", default = true},
    -- How the value is drawn as a shape, which is what every other component
    -- calls `visual`. It used to be `presentation`, which elsewhere selects
    -- responsive content: two different questions under one name.
    {key = "visual", label = "Visualization", type = "string",
      default = "none",
      choices = {"none", "bar", "bipolar-bar", "radial"}},
    -- Normalization range for the visualization, as in `metric`. It is not a
    -- limit: a value outside it still reads as itself.
    {key = "rangeMin", label = "Range minimum", type = "number"},
    {key = "rangeMax", label = "Range maximum", type = "number"},
    {key = "precision", label = "Decimal places", type = "number", default = -1},
    {key = "unit", label = "Unit", type = "string", default = ""},
    {key = "accent", label = "Accent", type = "string", default = "cyan",
      choices = {"cyan", "green", "amber", "orange"}},
  },
}

--- Presentations this component knows how to draw.
local VISUALS = {
  none = true,
  bar = true,
  ["bipolar-bar"] = true,
  radial = true,
}

--- Normalize the selected visualization.
---@param name any
---@return string
function variableIndicator.visual(name)
  return VISUALS[name] and name or "none"
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

  if type(settings.rangeMin) == "number" then out.min = settings.rangeMin end
  if type(settings.rangeMax) == "number" then out.max = settings.rangeMax end
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
---@param visual string
---@param reading table
---@param signedFraction fun(value: any, low: any, high: any): number
---@return number
function variableIndicator.fraction(visual, reading, signedFraction)
  local value = reading.value
  if type(value) ~= "number" or value ~= value then return 0 end

  if visual == "bipolar-bar" then
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
---@param settings AeroGridVariableSettings
---@param span? table Placement span, when the host knows it.
---@param config? table What the layout actually stated.
---@return string[] messages
function variableIndicator.validateSettings(settings, span, config)
  local messages = {}
  if type(config) ~= "table" then return messages end
  if type(span) ~= "table" or type(span.rowSpan) ~= "number" then
    return messages
  end
  if span.rowSpan >= 2 then return messages end

  if config.showName then
    messages[#messages + 1] = "showName needs a panel two rows tall;"
      .. " a single row has no space beneath the reading at any width."
      .. " Give the panel rowSpan 2, or drop showName."
  end

  return messages
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
  -- Composition comes from the shared ladder, so a panel of this size carries
  -- the same rows as any other panel of this size, whichever component drew
  -- it. What this component wants is a veto, not a vote.
  local ladder = themeBuilder.ladder(theme, rect, frame)
  local radial = layout.visual == "radial"
  local showVisual = layout.showVisual and layout.visual ~= "none"
    and (radial or ladder.visual)
  local showDetail = layout.showDetail and ladder.rows > 0

  -- A radial is a compact visual and takes the right slot; a bar spans the
  -- panel and is exempt, so a barred panel never splits.
  local split = showVisual and radial
  local half = math.floor(frame.content / 2)
  local radius = math.max(6, math.floor(math.min(rect.w, rect.h) / 5))
  -- Bounded by the slot it lives in as well as by the panel, so a radial on
  -- a narrow panel shrinks rather than reaching into the reading.
  if split then radius = math.min(radius, math.floor(half / 2)) end

  local valueWidth = split and half or frame.content

  local value, unitFont, showUnit = themeBuilder.fitReadingUnit(
    sample.digits, sample.unit, valueWidth, ladder.room)
  local valueHeight = themeBuilder.fontHeight(value)

  -- Asked of the widest string this component can print, so the arrangement
  -- is fixed for the life of the panel rather than flipping as the value
  -- changes.
  local readingWidth = themeBuilder.readingWidth(
    value, sample.digits, unitFont, showUnit and sample.unit or nil)
  local slots, separated
  if split then
    slots, separated = themeBuilder.slotsFor(frame, readingWidth, radius * 2)
    -- Neither arrangement separates them, so the visualization goes, which
    -- is what every other converted component does in the same position.
    if not separated then
      showVisual, split, slots = false, false, nil
      valueWidth = frame.content
    end
  end

  local readingCentre = split
    and select(1, themeBuilder.slotCentres(frame, slots))
    or (frame.pad + math.floor(frame.content / 2))
  local radialCentreX = split
    and select(2, themeBuilder.slotCentres(frame, slots))
    or (rect.w - frame.pad - radius)

  -- Reading and radial share the body band and are centred on each other, so
  -- the block the band centres is the deeper of the two.
  local blockHeight = math.max(valueHeight, split and radius * 2 or 0)
  local blockTop = themeBuilder.bodyTop(ladder, blockHeight)
  local valueY = blockTop + math.floor((blockHeight - valueHeight) / 2)
  local radialCentreY = blockTop + math.floor(blockHeight / 2)

  local barY = math.max(1, rect.h - frame.bottom - spacing.barHeight)

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    -- The slot's centre, a property of the panel. Where the reading starts
    -- depends on what it currently says, so `primitives.centreReading` owns
    -- that and computes it from the measured string.
    valueCentre = readingCentre,
    valueX = themeBuilder.slotX(readingCentre, readingWidth),
    -- **The room the reading has, which is not the width it draws in.** The
    -- drawn box hugs the measured string so the slot centres it; the budget
    -- is the slot itself, and it is what a later question about whether a
    -- unit still fits has to be asked against. Collapsing the two made that
    -- question circular -- a unit that arrives after build, as a global
    -- variable's does, was measured against a box sized without it and never
    -- fitted.
    valueBudget = valueWidth,
    valueY = valueY,
    valueWidth = readingWidth,
    value = value,
    unitFont = unitFont,
    showUnit = showUnit,
    detailY = math.max(1, barY - labelHeight - 2),
    -- A row of one, so it centres across the whole content box.
    detailCentre = frame.pad + math.floor(frame.content / 2),
    barY = barY,
    radius = radius,
    radialX = radialCentreX - radius,
    radialY = radialCentreY - radius,
    -- EdgeTX positions an arc by its centre; the corner only reserves space.
    radialCentreX = radialCentreX,
    radialCentreY = radialCentreY,
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
  local visualName = variableIndicator.visual(settings.visual)
  local layout = variableIndicator.presentationFor(span.colSpan, span.rowSpan)
  layout.visual = visualName
  local presentation = services.state("normal", settings.accent)

  local context = {
    theme = theme,
    themeBuilder = services.themeBuilder,
    primitives = primitives,
    state = services.state,
    fonts = fonts,
    layout = layout,
    settings = settings,
    visualName = visualName,
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
  -- The unit is redundant with the panel's label and with the configured name
  -- on the supporting row, so it may go. The digits may not: a rates value of
  -- 4.5 shown as 4 is a different number, not a shorter one. It rides beside
  -- the number now rather than being glued onto it, which is what stopped the
  -- fitter measuring one string and this drawing another.
  local forms = {digits = sample, unit = reading.unitText}
  context.sample = forms

  local area = variableIndicator.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts, forms)

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(panel.root, theme,
    area.frame, fonts, variableIndicator.labelText(context, reading),
    presentation,
    services.themeBuilder)
  -- The heading is refitted whenever it changes, so the column it has to
  -- fit is kept beside it.
  context.frame = area.frame
  -- Built hidden. The unit is not known yet, so nothing here could decide
  -- whether it fits; `apply` decides once it arrives.
  context.showUnit = false
  context.unitText = ""
  context.area = area

  context.value = primitives.value(panel.root, theme, {
    x = area.valueX,
    y = area.valueY,
    w = area.valueWidth,
    text = "--",
    color = presentation.value,
    font = area.value,
  })

  -- The unit comes from `getGlobalVariableDetails`, so it is known here, but
  -- the label is still written by `apply` so there is one path that puts text
  -- into it rather than two.
  context.unit = primitives.unit(panel.root, theme, {
    x = area.valueX,
    y = area.valueY,
    text = "",
    color = theme.color.textMuted,
    font = area.unitFont,
  })

  context.detailLabel = primitives.label(panel.root, theme, {
    x = area.pad,
    y = area.detailY,
    w = area.content,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  if visualName == "radial" then
    context.radial = primitives.radial(panel.root, theme, {
      x = area.radialCentreX,
      y = area.radialCentreY,
      radius = area.radius,
      color = presentation.accent,
      fraction = 0,
    })
  elseif visualName == "bipolar-bar" then
    context.bipolar = primitives.bipolarBar(panel.root, theme, {
      x = area.pad,
      y = area.barY,
      w = area.content,
      fraction = 0,
      color = presentation.accent,
    })
  elseif visualName == "bar" then
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

  -- What the panel currently draws, so `render` declares only that.
  context.showDetail = area.showDetail
  context.showVisual = area.showVisual

  if not area.showDetail then lvgl.hide(context.detailLabel) end
  lvgl.hide(context.unit)
  if not area.showVisual then variableIndicator.hideVisual(context) end

  -- The first paint goes through the same path as every later one, so the
  -- panel cannot start out showing something `render` would never produce.
  local _, drawn = primitives.changed(context, variableIndicator.render)
  variableIndicator.apply(context, drawn)
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
--- Collect everything this panel draws, into one table.
---
--- The comparison that decides whether to repaint is taken from exactly this,
--- so a value drawn from here cannot be left out of it. The defect this
--- replaces was the header and the supporting row disagreeing about a global
--- variable's name: the refresh compared the value, the staleness and the
--- flight mode, and `apply` also drew the configured name. When EdgeTX
--- answered `getGlobalVariableDetails` after the first read and the value had
--- not moved, the header updated and the row kept saying `GV1`.
---@param context AeroGridVariableContext
---@param out table
function variableIndicator.render(context, out)
  local settings = context.settings
  local reading = variableIndicator.read(context)

  out.state = "normal"
  if not reading.available then
    out.state = "unavailable"
  elseif reading.stale then
    out.state = "stale"
  end

  out.text = variableIndicator.format(reading.value, reading.precision)
  -- Always declared, because whether it can be shown is decided from it.
  out.unit = reading.available and reading.unitText or ""

  -- The configured name is supporting text: it names the thing, while the
  -- header carries whatever the pilot chose to call it.
  if context.showDetail and settings.showName and reading.name ~= "" then
    out.detail = reading.name
    if settings.binding ~= "source" and type(context.feed) == "table"
        and type(context.feed.flightMode) == "number" then
      out.detail = out.detail .. " FM" .. tostring(context.feed.flightMode)
    end
  end

  out.label = string.upper(variableIndicator.labelText(context, reading))

  -- A panel with no visualization has no fraction to draw, and a panel too
  -- small for one was computing it, and its zero tick, on every frame.
  if context.showVisual then
    out.fraction = variableIndicator.fraction(
      context.visualName, reading, context.primitives.signedFraction)
    -- The zero tick only means something when the range actually spans it.
    out.marker = variableIndicator.crossesZero(reading)
      and (-reading.min / (reading.max - reading.min)) or nil
  end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridVariableContext
---@param drawn table
function variableIndicator.apply(context, drawn)
  local primitives = context.primitives
  local presentation = context.state(drawn.state, context.settings.accent)

  context.stateName = drawn.state
  context.text = drawn.text
  context.detail = drawn.detail or ""
  context.labelValue = drawn.label

  context.value:set({text = drawn.text, color = presentation.value})
  -- A global variable's unit arrives from EdgeTX after the panel is built, so
  -- whether there is room for it cannot be settled at build time. It is
  -- settled here, once, when the unit first turns up.
  local unitText = drawn.unit or ""
  if unitText ~= context.unitText then
    context.unitText = unitText
    local shows = context.primitives.unitFits(context.themeBuilder,
      context.area.value, context.sample.digits, context.area.unitFont,
      unitText, context.area.valueBudget)
    context.unit:set({text = unitText})
    if shows ~= context.showUnit then
      if shows then lvgl.show(context.unit) else lvgl.hide(context.unit) end
      context.showUnit = shows
      context.unitAnchor = nil
    end
  end
  context.primitives.centreReading(context, context.themeBuilder,
    context.area, context.area.value, drawn.text)
  -- Through the fitter, not straight into the label: this heading comes from
  -- the model at runtime and is exactly the kind that overflows its column.
  context.primitives.setHeading(context.label, context.themeBuilder,
    context.frame, context.fonts, drawn.label, presentation.label)
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  if context.showDetail then
    context.detailLabel:set({text = context.detail})
    -- A row of one item centres across the content box, exactly as a lone
    -- reading does.
    context.primitives.centreLabel(context, "detailAnchor",
      context.themeBuilder, context.detailLabel, context.area.detailCentre,
      context.area.detailY, context.fonts.label, context.detail)
  end
  primitives.stylePanel(context.panel, presentation)

  if not context.showVisual then return end

  if context.bar then
    primitives.setBar(context.bar, drawn.fraction, presentation.accent)
    primitives.setBarMarker(context.bar, drawn.marker)
  end
  if context.bipolar then
    primitives.setBipolarBar(context.bipolar, drawn.fraction, presentation.accent)
  end
  if context.radial then
    primitives.setRadial(context.radial, drawn.fraction, presentation.accent)
  end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridVariableContext
function variableIndicator.refresh(context)
  if not context.feed then return end

  local changed, drawn = context.primitives.changed(
    context, variableIndicator.render)
  if changed then variableIndicator.apply(context, drawn) end
end

--- Reposition after a zone change.
---@param context AeroGridVariableContext
---@param rect AeroGridRect
function variableIndicator.update(context, rect)
  local primitives = context.primitives
  local area = variableIndicator.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts, context.sample)

  primitives.resizePanel(context.panel, rect)
  -- The heading is the global variable's own name rather than the setting,
  -- so the refit is given what the panel currently shows.
  primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts, context.labelValue)
  context.frame = area.frame
  context.value:set({
    x = area.valueX,
    y = area.valueY,
    w = area.valueWidth,
    font = function() return area.value end,
  })

  -- A reflow can change the column and the reading's font, so whether the
  -- unit still fits is asked again with the unit that is actually in hand.
  local shows = context.primitives.unitFits(context.themeBuilder, area.value,
    context.sample.digits, area.unitFont, context.unitText, area.valueBudget)
  context.primitives.reconcileUnit(context.unit, shows, context.themeBuilder,
    area.valueX, area.valueY, area.value, context.text, area.unitFont,
    shows == context.showUnit)
  context.showUnit = shows
  -- Every anchor is about a slot and a font that have just moved.
  context.unitAnchor = nil
  context.readingAnchor, context.readingUnitAnchor = nil, nil
  context.detailAnchor = nil
  context.area = area

  primitives.reconcile(context.detailLabel, area.showDetail,
    {x = area.pad, y = area.detailY, w = area.content},
    area.showDetail == context.showDetail)

  -- A row or a shape that has just reappeared holds whatever it had when it
  -- was shed, and `render` stopped declaring its keys while it was hidden.
  local moved = area.showDetail ~= context.showDetail
    or area.showVisual ~= context.showVisual
  if moved then context.rendered = nil end

  local settled = area.showVisual == context.showVisual
  context.showDetail = area.showDetail
  context.showVisual = area.showVisual

  if not area.showVisual then
    -- Told once, when it stops being shown, rather than on every reflow.
    if not settled then variableIndicator.hideVisual(context) end
    return
  end

  local reading = variableIndicator.read(context)
  local fraction = variableIndicator.fraction(
    context.visualName, reading, primitives.signedFraction)

  if context.bar then
    primitives.placeBar(context.bar, area.pad, area.barY, area.content, fraction)
  end
  if context.bipolar then
    primitives.placeBipolarBar(context.bipolar, area.pad, area.barY,
      area.content, context.bipolar.h, fraction)
  end
  if context.radial then
    primitives.placeRadial(context.radial, area.radialCentreX,
      area.radialCentreY, area.radius)
  end

  if not settled then variableIndicator.showVisual(context) end
end

return variableIndicator
