-- SPDX-License-Identifier: GPL-2.0-only

--- Shared LVGL building blocks drawn from host theme tokens.
--- Components compose these instead of styling panels themselves, so the
--- dashboard keeps one coherent visual language.

local primitives = {}

--- Width reserved for a panel's state badge on its header row.
primitives.BADGE_WIDTH = 56

--- Return the usable content width inside a padded panel.
---@param theme AeroGridTheme
---@param width integer
---@return integer
function primitives.contentWidth(theme, width)
  return math.max(1, width - theme.spacing.padding * 2)
end

--- Create a panel's header row: a quiet label beside a state badge.
--- The badge sits next to the label rather than over it, because the source
--- name and the state must be readable at the same time.
---@param parent any
---@param theme AeroGridTheme
---@param frame table Result of theme.frame.
---@param fonts table
---@param text any Label text; upper-cased for the quiet label style.
---@param presentation table Result of theme.state.
---@return any label
---@return any badge
function primitives.header(parent, theme, frame, fonts, text, presentation)
  local label = primitives.label(parent, theme, {
    x = frame.labelX,
    y = frame.compact,
    w = frame.labelWidth,
    text = string.upper(tostring(text == nil and "" or text)),
    color = presentation.label,
    font = fonts.label,
  })

  local badge = primitives.badge(parent, theme, {
    x = frame.badgeX,
    y = frame.compact,
    w = frame.badgeWidth,
    text = "",
    color = theme.color.amber,
    font = fonts.badge,
  })

  if frame.labelHidden then lvgl.hide(label) end

  return label, badge
end

--- Reposition an existing header row after a geometry change.
---@param label any
---@param badge any
---@param frame table
function primitives.placeHeader(label, badge, frame)
  label:set({x = frame.labelX, y = frame.compact, w = frame.labelWidth})
  badge:set({x = frame.badgeX, y = frame.compact, w = frame.badgeWidth})
  if frame.labelHidden then lvgl.hide(label) else lvgl.show(label) end
end

--- Create a component panel: an elevated fill with a narrow semantic accent.
--- The accent stripe carries state, so it is never purely decorative.
---
--- The background is a filled rectangle rather than a colored box: EdgeTX's
--- `lvgl.box` parses `color` but never paints it, so a box keeps the radio
--- theme's own styling and the dashboard would render in EdgeTX's palette.
---
--- A panel is defined by that fill against the darker screen rather than by an
--- outline, so the border object is built but left hidden unless the state has
--- something to say with it. It is built at the focus weight whatever the
--- current state asks for, because `thickness` is effectively a build-time
--- property on a radio: `LvglWidgetBorderedObject::setOpacity` is the only
--- place that pushes it to LVGL, and its own `changedValue` guard skips the
--- call when the opacity has not moved, so a later `set{thickness=...}` is
--- discarded. Showing and hiding an object of fixed weight is therefore the
--- only way a border can change after the panel exists.
---@param parent any
---@param rect AeroGridRect
---@param theme AeroGridTheme
---@param presentation table Result of theme.state.
---@return table panel
function primitives.panel(parent, rect, theme, presentation)
  local spacing = theme.spacing

  local root = lvgl.box(parent, {
    x = rect.x,
    y = rect.y,
    w = rect.w,
    h = rect.h,
  })

  local background = lvgl.rectangle(root, {
    x = 0,
    y = 0,
    w = rect.w,
    h = rect.h,
    color = theme.color.surface,
    filled = true,
    rounded = spacing.radius,
  })

  local border = lvgl.rectangle(root, {
    x = 0,
    y = 0,
    w = rect.w,
    h = rect.h,
    color = presentation.border,
    filled = false,
    rounded = spacing.radius,
    thickness = spacing.borderFocus,
  })

  local accent = lvgl.rectangle(root, {
    x = 0,
    y = spacing.radius,
    w = spacing.accentWidth,
    h = primitives.accentHeight(spacing, rect.h),
    color = presentation.accent,
    filled = true,
    -- LVGL clamps a corner radius to half the shorter side, so asking for the
    -- stripe's full width is how a narrow rectangle is made into a pill.
    rounded = spacing.accentWidth,
  })

  local panel = {
    root = root,
    background = background,
    border = border,
    accent = accent,
    spacing = spacing,
    width = rect.w,
    height = rect.h,
  }

  primitives.stylePanel(panel, presentation)
  return panel
end

--- Height of the accent pill inside a panel.
---
--- The stripe is inset from top and bottom by the panel's corner radius,
--- which is where the left edge stops curving, so it only ever runs alongside
--- a straight edge and never has to agree with a corner about its own shape.
--- A full height stripe met both corners at exactly the point each was
--- curving, and its square shoulders sat outside the arc.
---
--- Only the height is computed, because only the height changes: the inset is
--- the radius, so the stripe's `y` is fixed for the life of the panel and a
--- reflow updates one property rather than two. A panel shorter than twice
--- the radius keeps a one pixel stripe rather than an inverted one; no cell of
--- a 4 x 4 grid on a supported display is anywhere near that small.
---@param spacing table
---@param height integer Panel height.
---@return integer
function primitives.accentHeight(spacing, height)
  local extent = height - spacing.radius * 2
  if extent < 1 then return 1 end
  return extent
end

--- Resize a panel without recreating its LVGL objects.
---
--- A hidden border is deliberately left alone. It is hidden on a healthy
--- panel, which is most panels for most of a flight, and an object nobody can
--- see does not need resizing: it is brought up to date by `stylePanel` on the
--- state change that reveals it. A reflow batch pays for four panels at once,
--- so a `set` call saved here is saved four times per callback. A border that
--- is already on screen is resized immediately, because the state change that
--- would otherwise fix it may never come: a panel that was critical before the
--- reflow and is critical after it does not repaint at all.
---@param panel table
---@param rect AeroGridRect
function primitives.resizePanel(panel, rect)
  panel.width = rect.w
  panel.height = rect.h
  panel.root:set({x = rect.x, y = rect.y, w = rect.w, h = rect.h})
  panel.background:set({w = rect.w, h = rect.h})
  panel.accent:set({h = primitives.accentHeight(panel.spacing, rect.h)})
  if panel.borderVisible then
    panel.border:set({w = rect.w, h = rect.h})
  end
end

--- Apply a new state presentation to an existing panel.
--- A border weight cannot be changed after the object is built, so a state
--- with nothing to say with an outline hides it rather than thinning it.
---@param panel table
---@param presentation table
function primitives.stylePanel(panel, presentation)
  panel.accent:set({color = presentation.accent})

  if presentation.borderWidth <= 0 then
    panel.borderVisible = false
    lvgl.hide(panel.border)
    return
  end

  -- Size and colour together, because this is where a border hidden through a
  -- reflow learns the panel changed shape while it was invisible.
  panel.borderVisible = true
  panel.border:set({
    w = panel.width,
    h = panel.height,
    color = presentation.border,
  })
  lvgl.show(panel.border)
end

--- Create a quiet uppercase label.
---@param parent any
---@param theme AeroGridTheme
---@param options table
---@return any
function primitives.label(parent, theme, options)
  local font = options.font
  return lvgl.label(parent, {
    x = options.x,
    y = options.y,
    w = options.w,
    h = 0,
    text = tostring(options.text or ""),
    color = options.color or theme.color.textMuted,
    font = function() return font end,
  })
end

--- Create a dominant numeric reading.
--- Geometry stays fixed as values change so neighbouring content never shifts.
---@param parent any
---@param theme AeroGridTheme
---@param options table
---@return any
function primitives.value(parent, theme, options)
  local font = options.font
  return lvgl.label(parent, {
    x = options.x,
    y = options.y,
    w = options.w,
    h = 0,
    text = tostring(options.text or "--"),
    color = options.color or theme.color.text,
    font = function() return font end,
  })
end

--- Create a horizontal progress bar with a muted track.
--- An optional marker fraction draws a persistent tick, which a range that
--- crosses zero needs so the reader can see which side of zero a value is on.
---@param parent any
---@param theme AeroGridTheme
---@param options table
---@return table bar
function primitives.bar(parent, theme, options)
  local spacing = theme.spacing
  local height = options.h or spacing.barHeight

  local track = lvgl.rectangle(parent, {
    x = options.x,
    y = options.y,
    w = options.w,
    h = height,
    color = theme.color.track,
    filled = true,
    rounded = 2,
  })

  local fill = lvgl.rectangle(parent, {
    x = options.x,
    y = options.y,
    w = primitives.barFill(options.w, options.fraction),
    h = height,
    color = options.color or theme.color.cyan,
    filled = true,
    rounded = 2,
  })

  local bar = {
    track = track,
    fill = fill,
    width = options.w,
    height = height,
    markerX = options.x,
  }

  -- Created last so it stays above the fill: a marker the fill can hide is
  -- not a reference point.
  if options.marker ~= nil then
    local fraction = type(options.marker) == "number" and options.marker or 0
    bar.marker = primitives.marker(parent, theme, {
      x = options.x + primitives.barFill(options.w, fraction),
      y = options.y,
      h = height,
    })
    bar.markerFraction = fraction
    -- A marker requested without a position yet is created hidden, so a bound
    -- that only arrives later can reveal it without a rebuild.
    if type(options.marker) ~= "number" then
      bar.markerFraction = nil
      lvgl.hide(bar.marker)
    end
  end

  return bar
end

--- Create the thin neutral tick used by bars and bipolar bars.
---@param parent any
---@param theme AeroGridTheme
---@param options table
---@return any
function primitives.marker(parent, theme, options)
  return lvgl.rectangle(parent, {
    x = options.x,
    y = options.y,
    w = options.w or 2,
    h = options.h or 2,
    color = options.color or theme.color.textMuted,
    filled = true,
  })
end

--- Convert a 0..1 fraction into a pixel width inside a bar.
---@param width integer
---@param fraction any
---@return integer
function primitives.barFill(width, fraction)
  if type(fraction) ~= "number" or fraction ~= fraction then return 0 end
  if fraction < 0 then fraction = 0 end
  if fraction > 1 then fraction = 1 end

  return math.max(0, math.floor(width * fraction + 0.5))
end

--- Update a bar's filled portion and color.
---@param bar table
---@param fraction number
---@param color? integer
function primitives.setBar(bar, fraction, color)
  local changes = {w = primitives.barFill(bar.width, fraction)}
  if color then changes.color = color end
  bar.fill:set(changes)
end

--- Reposition an existing bar without recreating it.
---@param bar table
---@param x integer
---@param y integer
---@param width integer
---@param fraction number Refilled against the new width.
function primitives.placeBar(bar, x, y, width, fraction)
  bar.width = width
  bar.track:set({x = x, y = y, w = width})
  bar.fill:set({x = x, y = y, w = primitives.barFill(width, fraction)})
  if bar.marker and bar.markerFraction then
    bar.markerX = x
    bar.marker:set({
      x = x + primitives.barFill(width, bar.markerFraction),
      y = y,
    })
  elseif bar.marker then
    bar.markerX = x
    bar.marker:set({y = y})
  end
end

--- Move a bar's marker to a new fraction of its track.
--- Bounds are often unknown when a panel is built, because a global variable's
--- range only arrives once EdgeTX has been asked for its details, so the tick
--- has to be placeable after the fact.
---@param bar table
---@param fraction? number Nil hides the marker.
function primitives.setBarMarker(bar, fraction)
  local marker = bar.marker
  if not marker then return end

  if type(fraction) ~= "number" then
    lvgl.hide(marker)
    bar.markerFraction = nil
    return
  end

  bar.markerFraction = fraction
  marker:set({x = (bar.markerX or bar.x or 0) + primitives.barFill(bar.width, fraction)})
  lvgl.show(marker)
end

--- Create a centered bipolar bar with a persistent neutral marker.
---
--- Trims and signed global variables are read against their own centre, so the
--- fill grows outward from the middle and the neutral tick stays visible at
--- every deflection. The bar may run horizontally or vertically, because a
--- trim's axis is not exposed by EdgeTX and the layout has to state it.
---@param parent any
---@param theme AeroGridTheme
---@param options table
---@return table bar
function primitives.bipolarBar(parent, theme, options)
  local vertical = options.vertical == true
  local thickness = options.thickness or theme.spacing.barHeight
  local width = vertical and thickness or options.w
  local height = vertical and options.h or thickness

  local track = lvgl.rectangle(parent, {
    x = options.x,
    y = options.y,
    w = width,
    h = height,
    color = theme.color.track,
    filled = true,
    rounded = 2,
  })

  local fill = lvgl.rectangle(parent, {
    x = options.x,
    y = options.y,
    w = width,
    h = height,
    color = options.color or theme.color.cyan,
    filled = true,
    rounded = 2,
  })

  local bar = {
    track = track,
    fill = fill,
    x = options.x,
    y = options.y,
    w = width,
    h = height,
    vertical = vertical,
  }

  -- The marker is created after the fill so the fill can never hide it.
  bar.marker = primitives.marker(parent, theme, {
    x = vertical and options.x or (options.x + math.floor(width / 2) - 1),
    y = vertical and (options.y + math.floor(height / 2) - 1) or options.y,
    w = vertical and width or 2,
    h = vertical and 2 or height,
  })

  primitives.setBipolarBar(bar, options.fraction, options.color)
  return bar
end

--- Update a bipolar bar from a signed -1..1 fraction.
---@param bar table
---@param fraction any
---@param color? integer
function primitives.setBipolarBar(bar, fraction, color)
  if type(fraction) ~= "number" or fraction ~= fraction then fraction = 0 end
  if fraction > 1 then fraction = 1 end
  if fraction < -1 then fraction = -1 end

  local magnitude = fraction < 0 and -fraction or fraction
  local changes

  if bar.vertical then
    local centre = math.floor(bar.h / 2)
    -- At least one pixel, so a centred trim still reads as a bar rather than
    -- as nothing at all.
    local length = math.max(1, math.floor(magnitude * centre + 0.5))
    -- Positive deflection grows upward, matching a stick's own direction.
    changes = {
      x = bar.x,
      w = bar.w,
      h = length,
      y = bar.y + (fraction >= 0 and (centre - length) or centre),
    }
  else
    local centre = math.floor(bar.w / 2)
    local length = math.max(1, math.floor(magnitude * centre + 0.5))
    changes = {
      y = bar.y,
      h = bar.h,
      w = length,
      x = bar.x + (fraction >= 0 and centre or (centre - length)),
    }
  end

  if color then changes.color = color end
  bar.fill:set(changes)
end

--- Reposition an existing bipolar bar without recreating it.
---@param bar table
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param fraction any Refilled against the new geometry.
function primitives.placeBipolarBar(bar, x, y, width, height, fraction)
  bar.x, bar.y, bar.w, bar.h = x, y, width, height
  bar.track:set({x = x, y = y, w = width, h = height})
  bar.marker:set({
    x = bar.vertical and x or (x + math.floor(width / 2) - 1),
    y = bar.vertical and (y + math.floor(height / 2) - 1) or y,
    w = bar.vertical and width or 2,
    h = bar.vertical and 2 or height,
  })
  primitives.setBipolarBar(bar, fraction)
end

--- Create a radial arc gauge with a background track.
---
--- `x` and `y` are the arc's **centre**, not its top-left corner. EdgeTX's
--- `LvglWidgetArc::build` calls `setPos(x, y)` on a round object, and
--- `LvglWidgetRoundObject::setPos` stores `x - radius, y - radius`, so a
--- caller passing a corner draws the arc one radius up and to the left of
--- where it meant to. Use `primitives.arcBounds` to place one inside a panel.
---@param parent any
---@param theme AeroGridTheme
---@param options table
---@return table radial
function primitives.radial(parent, theme, options)
  local startAngle = options.startAngle or 135
  local sweep = options.sweep or 270

  local arc = lvgl.arc(parent, {
    x = options.x,
    y = options.y,
    radius = options.radius,
    thickness = options.thickness or 6,
    color = options.color or theme.color.cyan,
    startAngle = startAngle,
    endAngle = startAngle + primitives.arcSweep(sweep, options.fraction),
    bgColor = theme.color.track,
    bgOpacity = 255,
    bgStartAngle = startAngle,
    rounded = true,
  })

  return {
    arc = arc,
    startAngle = startAngle,
    sweep = sweep,
    centreX = options.x,
    centreY = options.y,
    radius = options.radius,
  }
end

--- Apply changes to an arc, always restating its centre.
---
--- An arc is positioned by its centre, but the firmware stores the corner as
--- `centre - radius`, and `LvglWidgetRoundObject::refresh` subtracts the radius
--- twice: once inside `setRadius`, and again through the inherited
--- `setPos(x, y)` that follows it, which is handed members already holding a
--- corner. Every `set` call therefore walks an arc up and to the left by its
--- own radius, whatever keys it carries, until it leaves the panel. Restating
--- the centre replaces the drifted members with absolute coordinates, so the
--- doubled subtraction lands where it should. `build` does not call `refresh`,
--- which is why a dial is only ever wrong after its first update.
---@param object any
---@param centreX integer
---@param centreY integer
---@param changes table
local function setRound(object, centreX, centreY, changes)
  changes.x = centreX
  changes.y = centreY
  object:set(changes)
end

--- Reposition a radial gauge, keeping centre coordinates in one place.
---@param radial table
---@param centreX integer
---@param centreY integer
---@param radius integer
function primitives.placeRadial(radial, centreX, centreY, radius)
  radial.centreX = centreX
  radial.centreY = centreY
  radial.radius = radius
  setRound(radial.arc, centreX, centreY, {radius = radius})
end

--- Report the rectangle an arc of a given centre and radius occupies.
--- Components lay out in corner coordinates, so this is the translation
--- between the two, in one place rather than in every caller.
---@param centreX integer
---@param centreY integer
---@param radius integer
---@param thickness? integer Stroke width, when the painted box is wanted.
---@return table rect
function primitives.arcBounds(centreX, centreY, radius, thickness)
  local half = math.floor((thickness or 0) / 2)
  local extent = radius + half
  return {x = centreX - extent, y = centreY - extent, w = extent * 2, h = extent * 2}
end

--- Convert a 0..1 fraction into arc degrees.
---@param sweep number
---@param fraction any
---@return integer
function primitives.arcSweep(sweep, fraction)
  if type(fraction) ~= "number" or fraction ~= fraction then return 0 end
  if fraction < 0 then fraction = 0 end
  if fraction > 1 then fraction = 1 end

  return math.floor(sweep * fraction + 0.5)
end

--- Update a radial gauge's swept angle and color.
---@param radial table
---@param fraction number
---@param color? integer
function primitives.setRadial(radial, fraction, color)
  local changes = {
    endAngle = radial.startAngle + primitives.arcSweep(radial.sweep, fraction),
  }
  if color then changes.color = color end
  setRound(radial.arc, radial.centreX, radial.centreY, changes)
end

--- Angular width of the compass pointer, in degrees.
--- Wide enough to read at arm's length on a 480 x 272 display without
--- implying more precision than a telemetry bearing carries.
primitives.POINTER_SWEEP = 30

--- Convert a compass bearing into the angle LVGL's arc uses.
--- LVGL measures zero at three o'clock and increases clockwise; a compass
--- measures zero at twelve o'clock and also increases clockwise, so the two
--- differ by a quarter turn.
---@param bearing number Degrees clockwise from north.
---@return integer
function primitives.arcAngle(bearing)
  return math.floor((bearing + 270) % 360 + 0.5) % 360
end

--- Create a north-up bearing dial.
---
--- The ring is the arc's background and the pointer is its indicator, so one
--- LVGL object carries both. Nothing here rotates with the aircraft: EdgeTX
--- reports neither model heading nor transmitter orientation, so the dial is
--- always north-up and the tick at twelve o'clock is north.
---@param parent any
---@param theme AeroGridTheme
---@param options table
---@return table compass
function primitives.compass(parent, theme, options)
  local radius = options.radius
  local thickness = options.thickness or 6

  local ring = lvgl.arc(parent, {
    x = options.x,
    y = options.y,
    radius = radius,
    thickness = thickness,
    color = options.color or theme.color.cyan,
    -- The pointer is the foreground arc and starts with no length, so a dial
    -- without a bearing shows a ring and nothing resembling a direction.
    -- Opacity is deliberately not used to hide it: the compass ring did not
    -- render on a radio while the identically shaped radial did, and passing
    -- `opacity` was the only difference between them.
    startAngle = 0,
    endAngle = 0,
    bgColor = theme.color.textFaint,
    bgOpacity = 255,
    bgStartAngle = 0,
    rounded = true,
  })

  local compass = {
    ring = ring,
    centreX = options.x,
    centreY = options.y,
    radius = radius,
    thickness = thickness,
  }

  -- Drawn inside the ring rather than outside it, so the dial's footprint is
  -- exactly the arc's own bounds and the tick cannot be hidden by the pointer.
  compass.north = primitives.marker(parent, theme, {
    x = options.x - 1,
    y = options.y - radius + thickness,
    w = 2,
    h = math.max(3, math.floor(radius / 4)),
    color = theme.color.textMuted,
  })

  primitives.setCompass(compass, options.bearing, options.color)
  return compass
end

--- Point a compass at a bearing, or at nothing when there is none.
--- A withheld bearing hides the pointer instead of resting it at north, which
--- would read as a valid due-north fix.
---@param compass table
---@param bearing any Degrees clockwise from north.
---@param color? integer
function primitives.setCompass(compass, bearing, color)
  local changes = {}
  if color then changes.color = color end

  if type(bearing) ~= "number" or bearing ~= bearing then
    -- A zero length arc draws nothing, which hides the pointer without
    -- touching opacity.
    changes.startAngle = 0
    changes.endAngle = 0
    compass.bearing = nil
  else
    local half = math.floor(primitives.POINTER_SWEEP / 2)
    local centre = primitives.arcAngle(bearing)
    changes.startAngle = (centre - half) % 360
    changes.endAngle = (centre + half) % 360
    compass.bearing = bearing
  end

  setRound(compass.ring, compass.centreX, compass.centreY, changes)
end

--- Reposition a compass without recreating it.
---@param compass table
---@param centreX integer
---@param centreY integer
---@param radius integer
function primitives.placeCompass(compass, centreX, centreY, radius)
  compass.centreX = centreX
  compass.centreY = centreY
  compass.radius = radius

  setRound(compass.ring, centreX, centreY, {radius = radius})

  compass.north:set({
    x = centreX - 1,
    y = centreY - radius + compass.thickness,
    h = math.max(3, math.floor(radius / 4)),
  })
end

--- Create the short state badge shown when color alone is insufficient.
---@param parent any
---@param theme AeroGridTheme
---@param options table
---@return any
function primitives.badge(parent, theme, options)
  local font = options.font
  return lvgl.label(parent, {
    x = options.x,
    y = options.y,
    w = options.w,
    h = 0,
    text = tostring(options.text or ""),
    color = options.color or theme.color.amber,
    font = function() return font end,
  })
end

--- Create an image loaded from an SD-card path.
---
--- EdgeTX's `lvgl.image` wraps `StaticImage`, which clears its source when the
--- file cannot be decoded and reports nothing back to Lua. A component must
--- therefore decide on a fallback before creating one, rather than after.
---@param parent any
---@param options table
---@return any
function primitives.image(parent, options)
  return lvgl.image(parent, {
    x = options.x,
    y = options.y,
    w = options.w,
    h = options.h,
    file = tostring(options.file or ""),
    fill = options.fill == true,
  })
end

--- Convert a value into a signed -1..1 fraction of a bipolar range.
--- Each side is measured against its own bound, so an asymmetric range such as
--- -20 to 100 still reads as centred at zero.
---@param value any
---@param low any
---@param high any
---@return number
function primitives.signedFraction(value, low, high)
  if type(value) ~= "number" or value ~= value then return 0 end

  local bound = value >= 0 and high or low
  if type(bound) ~= "number" or bound == 0 then return 0 end

  local fraction = value / (bound < 0 and -bound or bound)
  if fraction > 1 then return 1 end
  if fraction < -1 then return -1 end
  return fraction
end

return primitives
