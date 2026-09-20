-- SPDX-License-Identifier: GPL-2.0-only

--- One EdgeTX model timer, presented for the dashboard.
---
--- AeroGrid does not implement a second timer engine. EdgeTX already owns the
--- count direction, the start value, persistence, the configured name, and
--- whether the timer shows elapsed or remaining time, and it keeps counting
--- while this widget is not even visible. The component reads
--- `model.getTimer(index)` through `modelService` and renders what the radio
--- reports.
---
--- The one thing that genuinely needs presenting rather than reporting is a
--- countdown that has run past zero. EdgeTX keeps counting into negative
--- numbers there, which is easy to misread as a healthy timer, so the
--- component states it explicitly as well as showing the minus sign.

---@class AeroGridTimerSettings
---@field timer? number Zero-based EdgeTX timer index.
---@field label? string Panel label; the timer's own name is used when empty.
---@field accent? string
---@field reading? "model"|"elapsed"|"remaining"
---@field warning? number Seconds at which the timer becomes a caution.
---@field critical? number Seconds at which the timer becomes critical.

---@class AeroGridTimerContext
---@field panel table
---@field feed? AeroGridModelTimer
---@field stateName string
---@field text string Last rendered clock reading.

local flightTimer = {
  id = "flight-timer",
  apiVersion = 1,
  supportedSpans = {
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
  },
  -- A clock advances once a second, so anything faster is wasted work charged
  -- to the same instruction budget as every other component on the dashboard.
  refreshInterval = 100,
  settings = {
    {key = "timer", label = "Model timer", type = "number", default = 0},
    -- An empty label is not an absent one: it means derive the heading at
    -- runtime, here from the timer's own name, or its number when it has none. A
    -- component with a fixed heading states it as its default instead.
    {key = "label", label = "Label", type = "string", default = ""},
    {key = "accent", label = "Accent", type = "string", default = "cyan",
      choices = {"cyan", "green", "amber", "orange"}},
    -- `model` follows the timer's own configured elapsed/remaining choice.
    -- Which of the timer's values leads the panel, named `reading` like every
    -- other component that chooses between its own values.
    {key = "reading", label = "Show", type = "string", default = "model",
      choices = {"model", "elapsed", "remaining"}},
    {key = "warning", label = "Warning seconds", type = "number"},
    {key = "critical", label = "Critical seconds", type = "number"},
    -- A countdown is judged on the time it has left and a count-up timer on
    -- the time it has used, so the direction follows the timer rather than
    -- the layout and cannot be stated.
    -- No `direction`. It is real here -- a countdown alarms on the time it
    -- has left and a count-up timer on the time it has used -- but EdgeTX
    -- already says which a timer is, through `model.getTimer`, and
    -- `resolveState` has always read that rather than the setting. Stating
    -- it was restating the radio.
  },
}

--- Forms of the clock, longest first, and there is deliberately only one.
--- See the note in `regionsFor`: every shorter form of a clock drops a field,
--- and a field is magnitude.
flightTimer.FORMS = {"-88:88:88"}

--- Describe how the component presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
function flightTimer.presentationFor(colSpan, rowSpan)
  local cells = (colSpan or 1) * (rowSpan or 1)

  -- A countdown's progress bar needs a known total, so it appears only on
  -- panels large enough to carry it without crowding the clock.
  if cells >= 4 then
    return {showDetail = true, showVisual = true}
  end
  if cells >= 2 then
    return {showDetail = true, showVisual = false}
  end
  return {showDetail = false, showVisual = false}
end

--- Choose which of the timer's readings to display.
--- EdgeTX records the pilot's own elapsed/remaining preference on the timer,
--- so `model` honours it and the other choices override it deliberately.
---@param settings AeroGridTimerSettings
---@param feed AeroGridModelTimer
---@return number seconds
function flightTimer.displayValue(settings, feed)
  local display = settings.reading

  if display == "elapsed" then return feed.elapsed end
  if display == "remaining" then
    return feed.countdown and feed.remaining or feed.elapsed
  end

  -- EdgeTX's own presentation: `value` already counts the right way, and
  -- showElapsed flips a countdown to count up instead.
  if feed.showElapsed then return feed.elapsed end
  return feed.value
end

--- Resolve the component state from the timer's own reading.
---
--- A countdown is judged on the time it has left and a count-up timer on the
--- time it has used, because those are the two numbers a pilot actually flies
--- to. An expired countdown is always critical: it is the one state that must
--- not be mistaken for a healthy timer.
---@param settings AeroGridTimerSettings
---@param feed? AeroGridModelTimer
---@return string
function flightTimer.resolveState(settings, feed)
  if type(feed) ~= "table" or not feed.available then return "unavailable" end
  if feed.countdown and feed.expired then return "critical" end

  local measured = feed.countdown and feed.remaining or feed.elapsed
  local warning = type(settings.warning) == "number" and settings.warning or nil
  local critical = type(settings.critical) == "number" and settings.critical or nil

  if feed.countdown then
    if critical and measured <= critical then return "critical" end
    if warning and measured <= warning then return "warning" end
  else
    if critical and measured >= critical then return "critical" end
    if warning and measured >= warning then return "warning" end
  end

  return "normal"
end

--- Describe the timer beneath the clock.
---@param feed? AeroGridModelTimer
---@param formatTime fun(seconds: any): string
---@return string
function flightTimer.detailText(feed, formatTime)
  if type(feed) ~= "table" or not feed.available then return "NO TIMER" end

  if feed.countdown then
    if feed.expired then return "ELAPSED PAST ZERO" end
    return "OF " .. formatTime(feed.start)
  end

  return "COUNTING UP"
end

--- Fraction of a countdown that has been used, for the optional bar.
--- A count-up timer has no total, so it has no fraction and no bar.
---@param feed? AeroGridModelTimer
---@return number
function flightTimer.fraction(feed)
  if type(feed) ~= "table" or not feed.available then return 0 end
  if not feed.countdown or type(feed.start) ~= "number" or feed.start <= 0 then
    return 0
  end

  local used = feed.elapsed / feed.start
  if used < 0 then return 0 end
  if used > 1 then return 1 end
  return used
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@return table
function flightTimer.regionsFor(theme, themeBuilder, rect, layout, fonts)
  local spacing = theme.spacing
  local frame = themeBuilder.frame(theme, rect, fonts)
  local labelHeight = frame.labelHeight
  local top = frame.top

  -- Composition comes from the shared ladder, so a panel of this size carries
  -- the same rows as any other panel of this size, whichever component drew
  -- it. What this component wants is a veto, not a vote.
  local ladder = themeBuilder.ladder(theme, rect, frame)
  local showDetail = layout.showDetail and ladder.rows > 0
  local showVisual = layout.showVisual and ladder.visual

  -- "-88:88:88" is the widest clock this component can produce, so the font is
  -- chosen from that rather than from the current reading; otherwise the
  -- digits would resize the first time an hour or a minus sign appeared.
  --
  -- It is the only form offered. A clock has no redundancy in it: dropping
  -- the hours field turns 1:04:12 into 04:12, which is not a shorter reading
  -- but a different one, and one a pilot would believe. Where it will not fit,
  -- the font steps down instead.
  local clock, formIndex = themeBuilder.fitReading(
    flightTimer.FORMS, frame.content, ladder.room)
  local clockHeight = themeBuilder.fontHeight(clock)

  if top + clockHeight > rect.h then
    top = math.max(0, rect.h - clockHeight)
  end

  local barY = math.max(1, rect.h - frame.bottom - spacing.barHeight)

  -- **A lone reading does not split.** This component's only visualization
  -- is a bar, which spans the panel by design and is exempt from the rule,
  -- so there is never a second element to leave room for and the clock
  -- centres across the whole content box. Its supporting row carries one
  -- item and centres the same way.
  local readingCentre = frame.pad + math.floor(frame.content / 2)
  local clockWidth = themeBuilder.measureText(
    clock, flightTimer.FORMS[formIndex])

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    -- The slot's centre, a property of the panel. Where the clock starts
    -- depends on what it currently reads, so `primitives.centreReading` owns
    -- that and computes it from the measured string.
    valueCentre = readingCentre,
    valueX = themeBuilder.slotX(readingCentre, clockWidth),
    valueY = themeBuilder.bodyTop(ladder, clockHeight),
    valueWidth = clockWidth,
    clockY = themeBuilder.bodyTop(ladder, clockHeight),
    clock = clock,
    formIndex = formIndex,
    detailY = math.max(1, barY - labelHeight - 2),
    detailCentre = readingCentre,
    barY = barY,
    showDetail = showDetail,
    showVisual = showVisual,
  }
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridTimerSettings
---@param services table
---@return AeroGridTimerContext
function flightTimer.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local span = services.span
  local layout = flightTimer.presentationFor(span.colSpan, span.rowSpan)
  local presentation = services.state("normal", settings.accent)
  local area = flightTimer.regionsFor(
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
    text = "--:--",
    detail = "",
  }

  -- Subscribing in create is what tells the model service that this timer is
  -- referenced; a timer nothing references is never read.
  local modelService = services.model
  if modelService then
    context.feed = modelService:timer(settings.timer)
    -- Formatting lives with the service so every timer reading agrees.
    context.formatTime = modelService.formatTime
  end
  if not context.formatTime then
    context.formatTime = function() return "--:--" end
  end

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  -- The timer's configured name is the most useful label there is, so it wins
  -- unless the layout states one. It is only known once the service has read
  -- the timer, which is why refresh revisits it.
  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, flightTimer.labelText(context),
    presentation,
    services.themeBuilder)
  -- The heading is refitted whenever it changes, so the column it has to
  -- fit is kept beside it.
  context.frame = area.frame
  -- Kept, because the clock is centred on a slot and `apply` needs to know
  -- where that slot is. This component had no reason to remember its regions
  -- while everything it drew started at the padding.
  context.area = area

  context.value = primitives.value(panel.root, theme, {
    x = area.valueX,
    y = area.clockY,
    w = area.valueWidth,
    text = context.text,
    color = presentation.value,
    font = area.clock,
  })

  context.detailLabel = primitives.label(panel.root, theme, {
    x = area.pad,
    y = area.detailY,
    w = area.content,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  if layout.showVisual then
    context.bar = primitives.bar(panel.root, theme, {
      x = area.pad,
      y = area.barY,
      w = area.content,
      fraction = 0,
      color = presentation.accent,
    })
  end

  -- What the panel currently draws, so `render` declares only that and a
  -- reflow that changes nothing about visibility says nothing again.
  context.showDetail = area.showDetail
  context.showVisual = area.showVisual and context.bar ~= nil

  if not area.showDetail then lvgl.hide(context.detailLabel) end
  if context.bar and not area.showVisual then
    lvgl.hide(context.bar.track)
    lvgl.hide(context.bar.fill)
  end

  local _, drawn = primitives.changed(context, flightTimer.render)
  flightTimer.apply(context, drawn)
  return context
end

--- Resolve the panel label, preferring the timer's own configured name.
---@param context AeroGridTimerContext
---@return string
function flightTimer.labelText(context)
  local stated = context.settings.label
  if type(stated) == "string" and stated ~= "" then return stated end

  local feed = context.feed
  if type(feed) == "table" and type(feed.name) == "string" and feed.name ~= "" then
    return feed.name
  end

  return "TIMER " .. tostring(context.settings.timer)
end

--- Repaint the component from its current subscription.
---@param context AeroGridTimerContext
--- Collect everything this panel draws.
---
--- The timer's configured start is why this is a declaration. `apply` drew it
--- in "OF 5:00" and used it for the bar, while the refresh compared only the
--- displayed value, so a timer reconfigured mid-flight kept the old total.
--- The timer's own name is here for the same reason: it arrives with the
--- first successful read, and used to be reconciled by a second, separate
--- comparison bolted onto the end of refresh.
---@param context AeroGridTimerContext
---@param out table
function flightTimer.render(context, out)
  local feed = context.feed
  local settings = context.settings
  local available = type(feed) == "table" and feed.available == true

  out.state = flightTimer.resolveState(settings, feed)
  out.text = available and context.formatTime(
    flightTimer.displayValue(settings, feed)) or "--:--"
  -- Declared only where it is drawn. A panel too short for a supporting row
  -- was still formatting a second clock every frame and writing it into a
  -- hidden label, which is the invisible work the reveal work removed from
  -- five components and this one was not among them.
  if context.showDetail then
    out.detail = flightTimer.detailText(feed, context.formatTime)
  end
  if context.showVisual then
    out.fraction = flightTimer.fraction(feed)
  end
  out.label = string.upper(flightTimer.labelText(context))
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridTimerContext
---@param drawn table
function flightTimer.apply(context, drawn)
  local presentation = context.state(drawn.state, context.settings.accent)

  context.stateName = drawn.state
  context.text = drawn.text
  context.detail = drawn.detail or ""
  context.labelValue = drawn.label

  context.value:set({text = drawn.text, color = presentation.value})
  -- The clock is centred on its slot, so where it starts depends on what it
  -- reads: a timer crossing into hours grows about its middle rather than
  -- running rightwards. Keyed on the text, so a steady second costs nothing
  -- beyond the comparison.
  context.primitives.centreReading(context, context.themeBuilder,
    context.area, context.area.clock, drawn.text)
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
  context.primitives.stylePanel(context.panel, presentation)

  if context.showVisual and context.bar then
    context.primitives.setBar(context.bar, drawn.fraction, presentation.accent)
  end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridTimerContext
function flightTimer.refresh(context)
  if not context.feed then return end
  local changed, drawn = context.primitives.changed(context, flightTimer.render)
  if changed then flightTimer.apply(context, drawn) end
end

--- Reposition after a zone change, shedding or restoring optional rows.
---@param context AeroGridTimerContext
---@param rect AeroGridRect
function flightTimer.update(context, rect)
  local area = flightTimer.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts)

  context.primitives.resizePanel(context.panel, rect)
  -- The heading is the model's timer name rather than the setting, so the
  -- refit is given what the panel currently shows.
  context.primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts, context.labelValue)
  context.frame = area.frame
  context.value:set({
    x = area.valueX,
    y = area.clockY,
    w = area.valueWidth,
    font = function() return area.clock end,
  })
  context.area = area
  -- Every anchor is about a slot and a font that have just moved.
  context.readingAnchor, context.readingUnitAnchor = nil, nil
  context.detailAnchor = nil

  local primitives = context.primitives
  primitives.reconcile(context.detailLabel, area.showDetail,
    {x = area.pad, y = area.detailY, w = area.content},
    area.showDetail == context.showDetail)
  primitives.centreLabel(context, "detailAnchor", context.themeBuilder,
    area.showDetail and context.detailLabel or nil, area.detailCentre,
    area.detailY, context.fonts.label, context.detail)

  local showVisual = area.showVisual and context.bar ~= nil
  primitives.reconcileBar(context.bar, area.showVisual,
    area.pad, area.barY, area.content, flightTimer.fraction(context.feed),
    showVisual == context.showVisual)

  -- A row that has just reappeared holds whatever it had when it was shed,
  -- and `render` stopped declaring its key while it was hidden, so the record
  -- of what was drawn is dropped and the next refresh repaints it.
  if area.showDetail ~= context.showDetail
      or showVisual ~= context.showVisual then
    context.rendered = nil
  end
  context.showDetail = area.showDetail
  context.showVisual = showVisual
end

return flightTimer
