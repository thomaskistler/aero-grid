-- SPDX-License-Identifier: GPL-2.0-only

--- The active EdgeTX flight mode.
---
--- This is the simplest component in the catalog and deliberately so: EdgeTX
--- resolves the active mode itself, and `getFlightMode()` returns both its
--- index and its configured name. AeroGrid neither infers the mode from
--- switches nor caches a mapping of its own.
---
--- The only real design problem is width. A flight mode name is free text of
--- up to EdgeTX's name length, so the reading is fitted to the panel by
--- measured width as well as height, and the font is chosen from the longest
--- name the radio can produce rather than from the current one, so switching
--- modes never resizes the panel's dominant reading.

---@class AeroGridFlightModeSettings
---@field label? string
---@field accent? string
---@field showIndex? boolean Show the mode number beneath the name.

---@class AeroGridFlightModeContext
---@field panel table
---@field feed? AeroGridFlightMode
---@field stateName string

local flightMode = {
  id = "flight-mode",
  apiVersion = 1,
  supportedSpans = {
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
  },
  -- A flight mode changes when a switch moves, which is rare, and the reading
  -- is radio-local rather than telemetry. Two hertz is responsive enough and
  -- leaves the instruction budget to components that actually need it.
  refreshInterval = 50,
  settings = {
    -- Four characters, because a single-cell header has room for about five
    -- and "FLIGHT MODE" needs eleven. A layout wanting the long form can say
    -- so on a panel wide enough to carry it.
    {key = "label", label = "Label", type = "string", default = "MODE"},
    {key = "accent", label = "Accent", type = "string", default = "green",
      choices = {"cyan", "green", "amber", "orange"}},
    {key = "showIndex", label = "Show mode number", type = "boolean", default = false},
  },
}

--- Widest name to size the reading from, when the model cannot be read.
--- `LEN_FLIGHT_MODE_NAME` is 10 on colour targets
--- (`radio/src/dataconstants.h`); an unnamed mode is drawn as `FM<n>`, which
--- is always shorter.
local WIDEST_NAME = "MMMMMMMMMM"

--- One form, and it is the real widest name rather than a short stand-in.
---
--- This used to offer three forms of ten, six and four characters. They were
--- never renderings: `fitReading` chose a font from the form that fitted, and
--- the component then drew the **whole** name at that font. A ten-character
--- name at `2 x 2` needed about 400 pixels of a 226 pixel panel and lost
--- nearly half of itself over the edge, silently.
---
--- Shortening the name instead is not available. The specification's rule is
--- that a form may drop redundancy and never magnitude, and a truncated mode
--- name is not an abbreviation of that name but a different one: `ACRO` and
--- `ACROTRAINER` must not both read `ACRO`. There is no redundancy in a name
--- to give up, so the font steps down instead, which is what one form makes
--- `fitReading` do.
---
--- The form is the widest name **this model** has rather than the widest the
--- firmware allows, because sizing every panel for ten characters costs two
--- font steps at `2 x 2` for a model whose modes are all called `NORM`. It is
--- still independent of the mode currently selected, so switching modes never
--- resizes anything.
---@param widest string
---@return string[]
local function formsFor(widest)
  return {widest}
end

--- Refuse a mode number on a panel that has nowhere to put one.
---
--- The mode number is a supporting row, and the shared ladder grants no
--- supporting row at any single-row span: a 65 pixel panel has no room under
--- the reading whatever its width, so `showIndex` on a `4 x 1` is as inert as
--- on a `1 x 1`. It used to be accepted and ignored, which is the worst of
--- the three options, because a layout author reads the setting back and
--- believes it.
---@param settings AeroGridFlightModeSettings
---@param span? table Placement span, when the host knows it.
---@param config? table What the layout actually stated.
---@return string[] messages
function flightMode.validateSettings(settings, span, config)
  local messages = {}
  -- Only a layout that asked for it is told it cannot have it. The default is
  -- false, so today these are the same thing; it is written this way because
  -- the next component to do this defaults to true and they are not.
  if not (config and config.showIndex) then return messages end
  if type(span) ~= "table" or type(span.rowSpan) ~= "number" then
    return messages
  end

  if span.rowSpan < 2 then
    messages[#messages + 1] = "showIndex needs a panel two rows tall;"
      .. " a single row has no space beneath the reading at any width."
      .. " Give the panel rowSpan 2, or drop showIndex."
  end

  return messages
end

--- Describe how the component presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
--- @param showIndex? boolean Whether the layout asked for the mode number.
function flightMode.presentationFor(colSpan, rowSpan, showIndex)
  -- The ladder decides whether a panel of this size *can* carry a supporting
  -- row, and grants none at any single-row span whatever the width. What it
  -- cannot know is whether this panel will put anything in one: the mode
  -- number is off by default, and a row nobody fills is a reserved quarter
  -- and an empty label.
  return {showDetail = showIndex == true}
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@param widest? string Widest name this model can show; defaults to the
--- widest the firmware allows.
---@return table
function flightMode.regionsFor(theme, themeBuilder, rect, layout, fonts,
    widest, out)
  -- The whole arrangement, from the shared builder: frame, bands, the font
  -- its band affords, where the name sits and where its supporting row goes.
  -- What is left below is the two things that are this component's own.
  --
  -- `draws` rather than a span rule: the mode number is off unless a layout
  -- asks for it, and a row nobody fills still costs a quarter of the panel
  -- if the bands are told otherwise.
  local forms = formsFor(widest or WIDEST_NAME)
  local area = themeBuilder.panel(theme, rect, fonts, {
    -- Built through this component's own builder, which the host may have
    -- wrapped to lay the panel out around the menu button's corner.
    frame = themeBuilder.frame(theme, rect, fonts),
    forms = forms,
    draws = {rows = layout.showDetail == true, visual = false},
  }, out or {})

  -- A flight mode is a name and there is nothing to gauge, so this panel has
  -- no visualization at any span and its supporting row hangs from the
  -- panel's own bottom edge rather than from a bar.
  --
  -- **This component pinned its row before anything else did**, privately
  -- and by a different arithmetic -- the line box against the panel's 4 px
  -- bottom rather than the baseline against the heading's own inset -- so it
  -- sat 2 px lower than the shared rule now puts it. It was right about the
  -- principle and alone in applying it; the principle is shared now, so the
  -- private copy goes.
  area.detailY = themeBuilder.rowTop(area.frame, fonts.label, rect.h)

  -- The name under its own word, because `render` and `apply` read it. The
  -- band is `valueY` in every component now; this is the reading itself.
  area.name = area.value
  return area
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridFlightModeSettings
---@param services table
---@return AeroGridFlightModeContext
function flightMode.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local span = services.span
  local layout = flightMode.presentationFor(span.colSpan, span.rowSpan,
    settings.showIndex)
  local presentation = services.state("normal", settings.accent)

  local modelService = services.model
  -- Read once, before the panel is measured, because the panel is measured
  -- from it. A model change rebuilds every widget, so it cannot go stale.
  local widest = modelService and modelService:widestFlightModeName() or nil

  local area = flightMode.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts, widest)

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
    widest = widest,
    -- What the panel currently draws, so `render` declares only that.
    showDetail = area.showDetail,
    -- Kept, because the name is centred on a slot and `apply` needs to know
    -- where that slot is.
    area = area,
  }

  if modelService then context.feed = modelService:flightMode() end

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation,
    services.themeBuilder)

  context.value = primitives.value(panel.root, theme, {
    x = area.valueX,
    y = area.valueY,
    w = area.content,
    text = "--",
    color = presentation.value,
    font = area.name,
  })

  -- Built only where the layout asked for the mode number. It used to be
  -- built on every panel and hidden on most of them, which is an object and
  -- a write per reflow for a row that can never be filled -- the invisible
  -- work the specification forbids, in the component that was swept for it.
  -- A panel that can gain the row on a reflow still gets one, because
  -- `showIndex` cannot change without rebuilding the widget.
  if settings.showIndex then
    context.detailLabel = primitives.label(panel.root, theme, {
      x = area.pad,
      y = area.detailY,
      w = area.content,
      text = "",
      color = theme.color.textFaint,
      font = fonts.label,
    })
    if not area.showDetail then lvgl.hide(context.detailLabel) end
  end

  local _, drawn = primitives.changed(context, flightMode.render)
  flightMode.apply(context, drawn)
  return context
end

--- Repaint the component from its current subscription.
---@param context AeroGridFlightModeContext
--- Collect everything this panel draws.
---
--- The mode number is why this is a declaration rather than a list. `apply`
--- drew it and the refresh compared only the name, so two flight modes sharing
--- a configured name would have left the number showing the old mode.
---@param context AeroGridFlightModeContext
---@param out table
function flightMode.render(context, out)
  local feed = context.feed
  local available = type(feed) == "table" and feed.available == true

  out.state = available and "normal" or "unavailable"
  out.text = available and tostring(feed.name) or "--"

  -- Declared only when the panel has a row to put it in. This used to be
  -- written and painted whatever the span, which is the invisible work the
  -- other five components stopped doing, and this one was not in that set.
  if context.showDetail and context.settings.showIndex then
    -- `#` rather than `MODE`, because the header already says MODE and the
    -- default configuration read `MODE` over `MODE 0`.
    out.detail = available and ("#" .. tostring(feed.index)) or "#--"
  end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridFlightModeContext
---@param drawn table
function flightMode.apply(context, drawn)
  local presentation = context.state(drawn.state, context.settings.accent)

  context.stateName = drawn.state
  context.text = drawn.text
  context.detail = drawn.detail or ""

  context.value:set({text = drawn.text, color = presentation.value})
  -- The name is centred on its slot, so where it starts depends on what it
  -- reads: a longer mode name grows about its middle rather than running
  -- rightwards. Keyed on the text, so a mode that has not changed costs
  -- nothing beyond the comparison.
  context.primitives.centreReading(context, context.themeBuilder,
    context.area, context.area.name, drawn.text)
  context.label:set({color = presentation.label})
  context.primitives.setBadge(context, context.themeBuilder, context.badge,
    context.area.frame, context.fonts.badge, presentation.badge or "",
    presentation.accent)
  -- `showDetail` and the label agree by construction: both follow
  -- `showIndex`, which cannot change without rebuilding the widget. Asking
  -- for the label as well makes a disagreement a hidden row rather than a
  -- crash, which matters because the two are decided in different functions.
  if context.showDetail and context.detailLabel then
    context.detailLabel:set({text = context.detail})
    -- A row of one item centres across the content box, as a lone reading
    -- does.
    context.primitives.centreLabel(context, "detailAnchor",
      context.themeBuilder, context.detailLabel, context.area.detailCentre,
      context.area.detailY, context.fonts.label, context.detail)
  end
  context.primitives.stylePanel(context.panel, presentation)
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridFlightModeContext
function flightMode.refresh(context)
  if not context.feed then return end
  local changed, drawn = context.primitives.changed(context, flightMode.render)
  if changed then flightMode.apply(context, drawn) end
end

--- Reposition after a zone change.
---@param context AeroGridFlightModeContext
---@param rect AeroGridRect
function flightMode.update(context, rect)
  local area = flightMode.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts, context.widest)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts, context.settings.label,
      context.badgeText)
  context.area = area
  context.value:set({
    x = area.valueX,
    y = area.valueY,
    -- The width the name draws in, not the room it had. A box given the
    -- whole content box and an x centred for a shorter string reaches past
    -- the panel's right edge by the difference.
    w = area.valueWidth,
    font = function() return area.name end,
  })
  -- Re-placed from the string the panel is actually showing, because the one
  -- above was sized from the widest name this model can produce.
  context.readingAnchor, context.readingUnitAnchor = nil, nil
  context.primitives.centreReading(context, context.themeBuilder, area,
    area.name, context.text)

  local settled = area.showDetail == context.showDetail
  context.showDetail = area.showDetail
  -- The shared helper rather than a sixth private copy of it.
  context.primitives.reconcile(context.detailLabel, area.showDetail,
    {x = area.pad, y = area.detailY, w = area.content}, settled)
  -- The row's anchor is about a slot and a font that have just moved.
  context.detailAnchor = nil
  context.primitives.centreLabel(context, "detailAnchor", context.themeBuilder,
    area.showDetail and context.detailLabel or nil, area.detailCentre,
    area.detailY, context.fonts.label, context.detail)
end

return flightMode
