-- SPDX-License-Identifier: GPL-2.0-only

--- GPS position, distance to home, and the north-up bearing from home.
---
--- Everything this component draws is measured from the pilot's position
--- toward the model. That is the only direction EdgeTX can supply: it records
--- a pilot position when a fix is first acquired, and reports the model's
--- position afterwards. It reports neither the aircraft's heading nor the
--- transmitter's orientation, so the dial is always north-up and the arrow
--- must never be read as "the way the model is pointing" or "the way to turn".
--- The supporting row says so in words for exactly that reason.
---
--- A GPS source returns a table, and every field in it can be missing. Three
--- degraded states matter and are reported separately, because each has a
--- different cause and a different fix:
---
--- - No source: the layout names a sensor the radio does not have.
--- - No fix: the sensor is there and reporting, but has no position yet.
--- - No home: there is a position, but EdgeTX never recorded a pilot
---   position, so distance and bearing would be measured from nowhere. They
---   are withheld rather than computed from a zero that is not a place.

---@class AeroGridNavigationSettings
---@field source? string GPS source name.
---@field distanceSource? string Native distance sensor, preferred when set.
---@field label? string
---@field presentation? "auto"|"distance"|"bearing"|"compass"|"detailed"
---@field warning? number Distance in metres that raises a warning.
---@field critical? number Distance in metres that raises a critical state.
---@field accent? string

---@class AeroGridNavigationContext
---@field panel table
---@field feed? AeroGridNavigation Navigation subscription.
---@field stateName string

local navigation = {
  id = "navigation",
  apiVersion = 1,
  supportedSpans = {
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
    "2x3", "3x3", "4x3", "2x4", "3x4", "4x4",
  },
  -- Telemetry GPS arrives at a few hertz at best, and the navigation service
  -- is itself rate limited because every update costs trigonometry.
  refreshInterval = 25,
  settings = {
    {key = "source", label = "GPS source", type = "string", default = "GPS"},
    {key = "distanceSource", label = "Distance source", type = "string", default = ""},
    {key = "label", label = "Label", type = "string", default = "NAV"},
    -- Responsive content: which of the four arrangements this panel draws.
    {key = "presentation", label = "Presentation", type = "string",
      default = "auto",
      choices = {"auto", "distance", "bearing", "compass", "detailed"}},
    -- No default thresholds: a safe distance is a property of the field and
    -- the model, not of the dashboard.
    {key = "warning", label = "Warning distance, metres", type = "number"},
    {key = "critical", label = "Critical distance, metres", type = "number"},
    -- Distance is the one threshold in the catalogue that counts upward:
    -- further away is worse.
    -- No `direction`. Distance from home only alarms upward, which is the
    -- one threshold in the catalogue that counts that way.
    {key = "accent", label = "Accent", type = "string", default = "cyan",
      choices = {"cyan", "green", "amber", "orange"}},
  },
}

--- Forms of the distance reading, longest first, and there is only one.
---
--- A distance has no redundancy to give up. Its unit is not decoration,
--- because it changes with range: `1.23km` and `1.23m` are different readings,
--- so dropping it would be dropping magnitude. Nor can a decimal go, since
--- `1.23km` as `1km` discards 230 metres of a number a pilot is flying by.
--- Where it will not fit, the font steps down instead.
navigation.DIGITS = "888.88"

--- Widest unit a distance carries. `km` is two characters where `m` is one,
--- so fitting against it means a reading that switches to metres never has to
--- be reconsidered.
navigation.UNIT = "km"

--- Presentations this component knows how to draw, from least to most.
local PRESENTATIONS = {
  distance = true,
  bearing = true,
  compass = true,
  detailed = true,
}

--- Eight-point compass names.
--- Eight points, not sixteen: a telemetry bearing computed from two GPS
--- positions a few metres apart does not justify naming a direction to
--- 22.5 degrees, and the numeric bearing is printed beside it anyway.
local CARDINALS = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"}

--- Name the eight-point sector a bearing falls in.
---@param bearing any Degrees clockwise from north.
---@return string
function navigation.cardinal(bearing)
  if type(bearing) ~= "number" or bearing ~= bearing then return "" end

  local index = math.floor(((bearing % 360) + 22.5) / 45) % 8
  return CARDINALS[index + 1]
end

--- Resolve the presentation for a span.
--- `auto` spends space on direction only once there is room for it: a single
--- cell shows the distance alone, because a dial squeezed into it would be
--- decoration rather than information.
---@param name any Configured presentation.
---@param colSpan integer
---@param rowSpan integer
---@return string
function navigation.presentation(name, colSpan, rowSpan)
  if PRESENTATIONS[name] then return name end

  local cells = (colSpan or 1) * (rowSpan or 1)
  if cells >= 6 then return "detailed" end
  if cells >= 4 then return "compass" end
  if cells >= 2 then return "bearing" end
  return "distance"
end

--- Describe what a presentation contains.
---@param presentation string
---@return table
function navigation.presentationFor(presentation)
  return {
    presentation = presentation,
    showDetail = presentation ~= "distance",
    showCompass = presentation == "compass" or presentation == "detailed",
    showCoordinates = presentation == "detailed",
  }
end

--- Resolve the component state from the navigation snapshot.
---
--- A missing fix is `unavailable` rather than a distance of zero, because zero
--- metres from home is a real and very different reading. A missing home
--- position leaves the fix itself perfectly good, so the panel stays normal
--- and says which part is missing.
---@param settings AeroGridNavigationSettings
--- No source, no fix and no home are three different causes with three
--- different fixes, and the origin caption below the reading says which in
--- words. The badge says only what state the panel is in, because a badge has
--- room for one word and the caption has room for a sentence.
---@param view any Navigation subscription.
---@return string stateName
function navigation.resolveState(settings, view)
  if type(view) ~= "table" then return "unavailable" end
  if view.source == nil or view.source == "" then return "unavailable" end
  if not view.known then return "unavailable" end
  if not view.fix then return "unavailable" end
  if view.state == "stale" then return "stale" end
  -- A missing home position leaves the fix perfectly good, so the panel is not
  -- in a failed state at all; only the two values measured from home are
  -- withheld, and the caption says so.
  if not view.home then return "normal" end

  local distance = view.distance
  if type(distance) == "number" then
    local critical = settings.critical
    local warning = settings.warning
    -- Distance thresholds count upward: further away is worse.
    if type(critical) == "number" and distance >= critical then
      return "critical"
    end
    if type(warning) == "number" and distance >= warning then
      return "warning"
    end
  end

  return "normal"
end

--- Format the dominant distance reading.
---@param view any
---@param formatter fun(view: table): string?
---@return string
function navigation.distanceText(view, formatter)
  if type(view) ~= "table" then return "--" end
  if type(view.distance) ~= "number" then return "--" end
  return formatter(view) or "--"
end

--- The distance split into the number and the unit riding beside it.
---@param view any
---@param formatter fun(view: table): string?, string
---@return string digits
---@return string unit
function navigation.distanceParts(view, formatter)
  if type(view) ~= "table" or type(view.distance) ~= "number" then
    return "--", ""
  end
  local digits, unit = formatter(view)
  return digits or "--", unit or ""
end

--- Wordings for the supporting bearing row, longest first.
--- The bearing is withheld, not zeroed, when there is no home position: due
--- north and "nowhere to measure from" must not look the same.
---@param view any
---@return string[]
function navigation.bearingVariants(view)
  if type(view) ~= "table" or type(view.bearing) ~= "number" then
    return {"BRG --", "--"}
  end

  local bearing = math.floor(view.bearing % 360 + 0.5) % 360
  local cardinal = navigation.cardinal(bearing)
  -- `BRG 009 N` needed 89 px and was drawn into 38 on a 1 x 2 panel, so the
  -- compass point goes first and then the caption, leaving the number, which
  -- is the part that is actually a measurement.
  return {
    string.format("BRG %03d %s", bearing, cardinal),
    string.format("BRG %03d", bearing),
    string.format("%03d %s", bearing, cardinal),
    string.format("%03d", bearing),
  }
end

--- Format the supporting bearing row at whatever width it has.
---@param view any
---@param themeBuilder? table
---@param font? any
---@param width? integer
---@return string
function navigation.bearingText(view, themeBuilder, font, width)
  local variants = navigation.bearingVariants(view)
  if not themeBuilder then return variants[1] end
  return themeBuilder.fitLabel(variants, font, width)
end

--- Wordings for the origin caption, longest first.
--- The caption shares a row with the bearing, so the space it gets depends on
--- the panel. Each state offers progressively shorter phrasings rather than
--- being clipped, which the specification requires and which silently lost the
--- final word of "NORTH UP FROM HOME" on a 2 x 2 panel.
---@param view any
---@return string[]
function navigation.originVariants(view)
  if type(view) ~= "table" then return {"NO GPS"} end
  if not view.known then return {"NO GPS SOURCE", "NO GPS SRC", "NO GPS"} end
  if not view.fix then return {"NO FIX"} end
  if not view.home then return {"NO HOME POSITION", "NO HOME POS", "NO HOME"} end
  if view.state == "stale" then return {"LAST KNOWN", "LAST"} end
  -- Stated in words, because an arrow on a dial is exactly the thing a pilot
  -- would otherwise read as aircraft heading.
  return {"NORTH UP FROM HOME", "NORTH UP", "N UP"}
end

--- Choose the longest wording that fits the width it will be given.
---@param view any
---@param themeBuilder table
---@param font any
---@param width integer
---@return string
function navigation.originText(view, themeBuilder, font, width)
  local variants = navigation.originVariants(view)

  -- Callers without layout context get the full wording. Choosing between the
  -- wordings is the shared helper's job now: every supporting row in the
  -- catalogue has this problem and only this one used to solve it.
  if not themeBuilder then return variants[1] end
  return themeBuilder.fitLabel(variants, font, width)
end

--- Format the coordinates row.
---@param view any
---@return string
function navigation.coordinateText(view)
  if type(view) ~= "table" or type(view.latitude) ~= "number"
      or type(view.longitude) ~= "number" then
    return "-- , --"
  end

  return string.format("%.5f %.5f", view.latitude, view.longitude)
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@param sample string Widest value text this component can render.
---@return table
function navigation.regionsFor(theme, themeBuilder, rect, layout, fonts, sample)
  local frame = themeBuilder.frame(theme, rect, fonts)
  local labelHeight = frame.labelHeight
  local top = frame.top
  -- Composition comes from the shared ladder, so a panel of this size carries
  -- the same rows as any other panel of this size, whichever component drew
  -- it. Navigation asks for two rows where every other component asks for
  -- one, so the second is granted only where the first left room for it.
  local ladder = themeBuilder.ladder(theme, rect, frame)
  local rowHeight = labelHeight + 2
  local showDetail = layout.showDetail and ladder.rows > 0
  local showCoordinates = layout.showCoordinates and showDetail
    and ladder.room - rowHeight >= themeBuilder.fontHeight(MIDSIZE)
  local showCompass = layout.showCompass

  local available = math.max(1, ladder.room
    - (showCoordinates and rowHeight or 0))

  -- The dial is square, so it is bounded by whichever of the two axes runs
  -- out first, and it is dropped entirely when what remains is too small to
  -- read a direction from.
  local radius = math.floor(math.min(math.floor(frame.content / 2), available) / 2)
  if radius < 10 then showCompass = false end
  if not showCompass then radius = 0 end

  local centreX = rect.w - frame.pad - radius
  local centreY = top + radius

  local valueWidth = frame.content
  if showCompass then
    valueWidth = math.max(1, (centreX - radius) - frame.pad - 4)
  end

  -- A distance has no redundancy: dropping a decimal turns 1.23 km into
  -- 1 km, which is 230 metres of a number a pilot is flying by. Nor is its
  -- unit redundancy, because it changes with range -- `1.23km` and `1.23m`
  -- are different readings -- so unlike a voltage's it is never dropped, and
  -- a panel with no room for it has no room for the reading either.
  local value, unitFont, _, fits = themeBuilder.fitReadingUnit(
    sample.digits, sample.unit, valueWidth, available, true)

  -- The dial gives its room back rather than clipping the distance. A
  -- compass is a shape and survives being absent; a distance that runs off
  -- the panel is a number a pilot cannot read at the moment they need it, and
  -- the unit cannot be dropped to buy the space because it carries the scale.
  -- This was reachable at a single cell asking for a dial, where even the
  -- smallest font needs 75 pixels of the 63 the dial left.
  if not fits and showCompass then
    showCompass = false
    radius = 0
    centreX = rect.w - frame.pad
    centreY = top
    valueWidth = frame.content
    value, unitFont = themeBuilder.fitReadingUnit(
      sample.digits, sample.unit, valueWidth, available, true)
  end

  local valueHeight = themeBuilder.fontHeight(value)
  if top + valueHeight > rect.h then top = math.max(0, rect.h - valueHeight) end

  local stack = frame.bottom
  local coordinatesY = rect.h - stack - labelHeight
  if showCoordinates then stack = stack + labelHeight + 2 end
  local detailY = rect.h - stack - labelHeight

  -- The bearing takes the left of the detail row and the origin caption the
  -- right, so the two can never draw over one another.
  local detailWidth = math.max(1, math.floor((frame.content - 4) * 0.4))

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    valueY = top,
    valueWidth = valueWidth,
    value = value,
    unitFont = unitFont,
    showUnit = true,
    detailY = math.max(1, detailY),
    detailWidth = detailWidth,
    originX = frame.pad + detailWidth + 4,
    originWidth = math.max(1, frame.content - detailWidth - 4),
    coordinatesY = math.max(1, coordinatesY),
    radius = radius,
    centreX = centreX,
    centreY = centreY,
    showDetail = showDetail,
    showCoordinates = showCoordinates,
    showCompass = showCompass,
  }
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridNavigationSettings
---@param services table
---@return AeroGridNavigationContext
function navigation.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local span = services.span
  local presentationName = navigation.presentation(
    settings.presentation, span.colSpan, span.rowSpan)
  local layout = navigation.presentationFor(presentationName)
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
    origin = "",
    coordinates = "",
  }

  -- Subscribing in create is the mechanism: a GPS source nothing references
  -- is never read, and neither is its trigonometry ever computed.
  local service = services.navigation
  if service then
    context.service = service
    context.feed = service:subscribe(settings.source,
      settings.distanceSource ~= "" and settings.distanceSource or nil)
  end

  -- The widest distance this component can print, so the font is chosen from
  -- that rather than from the current reading.
  context.sample = {digits = navigation.DIGITS, unit = navigation.UNIT}

  local area = navigation.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts, context.sample)

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation,
    services.themeBuilder)

  context.value = primitives.value(panel.root, theme, {
    x = area.pad,
    y = area.valueY,
    w = area.valueWidth,
    text = "--",
    color = presentation.value,
    font = area.value,
  })

  -- The unit changes with range, so it is built empty and written whenever
  -- the reading is. A distance never sheds it: a number without `m` or `km`
  -- beside it is not the same reading shortened, it is a different one.
  context.unit = primitives.unit(panel.root, theme, {
    x = area.pad,
    y = area.valueY,
    text = "",
    color = theme.color.textMuted,
    font = area.unitFont,
  })

  context.detailLabel = primitives.label(panel.root, theme, {
    x = area.pad,
    y = area.detailY,
    w = area.detailWidth,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  -- Both wordings are chosen against the widths they will be given, so both
  -- widths are remembered.
  context.detailWidth = area.detailWidth
  context.originWidth = area.originWidth
  context.showDetail = area.showDetail
  context.area = area
  -- A distance always carries its unit, because the unit is its scale.
  context.showUnit = true
  context.unitText = ""
  context.originLabel = primitives.label(panel.root, theme, {
    x = area.originX,
    y = area.detailY,
    w = area.originWidth,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  if layout.showCoordinates then
    context.coordinatesLabel = primitives.label(panel.root, theme, {
      x = area.pad,
      y = area.coordinatesY,
      w = area.content,
      text = "",
      color = theme.color.textFaint,
      font = fonts.label,
    })
  end

  if layout.showCompass then
    context.compass = primitives.compass(panel.root, theme, {
      x = area.centreX,
      y = area.centreY,
      radius = math.max(1, area.radius),
      thickness = 6,
      color = presentation.accent,
    })
  end

  if not area.showDetail then
    lvgl.hide(context.detailLabel)
    lvgl.hide(context.originLabel)
  end
  if context.coordinatesLabel and not area.showCoordinates then
    lvgl.hide(context.coordinatesLabel)
  end
  -- Recorded after the rows are built, because whether there is a row at all
  -- is decided by the span and whether it is showing by the box.
  context.showCoordinates = context.coordinatesLabel ~= nil
    and area.showCoordinates == true
  context.showCompass = context.compass ~= nil and area.showCompass == true
  if context.compass and not area.showCompass then
    navigation.hideCompass(context)
  end

  local _, drawn = primitives.changed(context, navigation.render)
  navigation.apply(context, drawn)
  return context
end

--- Hide the dial and its north tick together.
---@param context AeroGridNavigationContext
function navigation.hideCompass(context)
  if not context.compass then return end
  lvgl.hide(context.compass.ring)
  lvgl.hide(context.compass.north)
end

--- Show the dial and its north tick together.
---@param context AeroGridNavigationContext
function navigation.showCompass(context)
  if not context.compass then return end
  lvgl.show(context.compass.ring)
  lvgl.show(context.compass.north)
end

--- Repaint the component from its current subscription.
---@param context AeroGridNavigationContext
--- Collect everything this panel draws.
---
--- The coordinates row is why this is a declaration. `apply` drew it from the
--- position and the refresh compared distance and bearing, which are derived
--- from the position *and the home position*: a model moving along an arc at
--- constant range changes its coordinates without moving either.
---@param context AeroGridNavigationContext
---@param out table
function navigation.render(context, out)
  local view = context.feed
  local service = context.service

  out.state = navigation.resolveState(context.settings, view)
  out.text = "--"
  out.unit = ""
  if service and type(view) == "table" then
    out.text, out.unit = navigation.distanceParts(
      view, service.describeDistanceParts)
  end
  -- Only what this panel draws. Both supporting rows are shed on a small
  -- panel and the coordinate row on all but the detailed arrangement, and
  -- fitting a caption to a width nobody sees is work with no reader. It also
  -- makes the reveal safe by construction: the key is absent while the row is
  -- shed, so `changed` sees it reappear and repaints with a wording fitted to
  -- the width the row now has. This used to be unconditional and `update`
  -- discarded the last record to compensate, which worked only as long as
  -- nobody forgot.
  if context.showDetail then
    out.detail = navigation.bearingText(view, context.themeBuilder,
      context.fonts.label, context.detailWidth)
    out.origin = navigation.originText(view, context.themeBuilder,
      context.fonts.label, context.originWidth)
  end
  if context.showCoordinates then
    out.coordinates = navigation.coordinateText(view)
  end
  -- The dial is shed on a panel too small for it, and a bearing declared
  -- while it is shed is a number that moves the whole declaration every time
  -- the model turns, repainting a panel whose visible parts have not changed.
  if context.showCompass then
    out.bearing = type(view) == "table" and view.bearing or nil
  end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridNavigationContext
---@param drawn table
function navigation.apply(context, drawn)
  local presentation = context.state(drawn.state, context.settings.accent)

  context.stateName = drawn.state
  context.text = drawn.text
  context.detail = drawn.detail
  context.origin = drawn.origin
  context.coordinates = drawn.coordinates
  context.bearing = drawn.bearing

  context.value:set({text = drawn.text, color = presentation.value})
  if (drawn.unit or "") ~= context.unitText then
    context.unitText = drawn.unit or ""
    context.unit:set({text = context.unitText})
  end
  context.primitives.followUnit(context, context.themeBuilder,
    context.area, context.area.value, drawn.text)
  context.label:set({color = presentation.label})
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  context.primitives.stylePanel(context.panel, presentation)

  if context.showDetail then
    context.detailLabel:set({text = drawn.detail})
    context.originLabel:set({text = drawn.origin})
  end
  if context.showCoordinates then
    context.coordinatesLabel:set({text = drawn.coordinates})
  end

  if context.showCompass then
    -- A bearing that does not exist hides the pointer rather than resting it
    -- at north, which would read as a real due-north fix.
    context.primitives.setCompass(
      context.compass, drawn.bearing, presentation.accent)
  end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridNavigationContext
function navigation.refresh(context)
  if not context.feed then return end
  local changed, drawn = context.primitives.changed(context, navigation.render)
  if changed then navigation.apply(context, drawn) end
end

--- Reposition after a zone change.
---@param context AeroGridNavigationContext
---@param rect AeroGridRect
function navigation.update(context, rect)
  local area = navigation.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts, context.sample)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts, context.settings.label)
  context.primitives.placeUnit(context.unit, context.themeBuilder,
    area.pad, area.valueY, area.value, context.text, area.unitFont)
  context.unit:set({font = function() return area.unitFont end})
  context.unitAnchor = nil
  context.area = area
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.valueWidth,
    font = function() return area.value end,
  })

  --- Show or hide a supporting row, positioning it only when visible.
  local reconcile = context.primitives.reconcile

  reconcile(context.detailLabel, area.showDetail,
    {x = area.pad, y = area.detailY, w = area.detailWidth})
  -- Recorded and nothing more. `render` reads all four, so a row that is shed
  -- declares nothing, a row that reappears declares a key that was missing,
  -- and a caption whose width moved declares whatever that width now fits.
  -- The discards that used to be here are gone with the guesswork.
  context.detailWidth = area.detailWidth
  context.originWidth = area.originWidth
  context.showDetail = area.showDetail
  context.showCoordinates = context.coordinatesLabel ~= nil
    and area.showCoordinates == true
  context.showCompass = context.compass ~= nil and area.showCompass == true
  reconcile(context.originLabel, area.showDetail,
    {x = area.originX, y = area.detailY, w = area.originWidth})
  reconcile(context.coordinatesLabel, area.showCoordinates,
    {x = area.pad, y = area.coordinatesY, w = area.content})

  if context.compass then
    if area.showCompass then
      context.primitives.placeCompass(
        context.compass, area.centreX, area.centreY, area.radius)
      navigation.showCompass(context)
    else
      navigation.hideCompass(context)
    end
  end
end

return navigation
