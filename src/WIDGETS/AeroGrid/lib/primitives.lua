-- SPDX-License-Identifier: GPL-2.0-only

--- Shared LVGL building blocks drawn from host theme tokens.
--- Components compose these instead of styling panels themselves, so the
--- dashboard keeps one coherent visual language.

local primitives = {}

--- Width reserved for a panel's state badge on its header row.
primitives.BADGE_WIDTH = 56

--- Headings that had to be cut, waiting for the host to collect them.
---
--- This is the host's own bookkeeping and it lives here, beside the objects,
--- because it cannot live on them: an LVGL object is userdata on a radio and
--- holds no fields, so `label.headingDropped = x` raises rather than being
--- stored. Writing it there passed every test in a suite whose stand-in was a
--- plain table, and broke every panel on the first radio that ran it.
---
--- A list rather than a value because a dashboard builds many panels, and a
--- drain rather than a read because what the host wants is exactly the
--- headings this build produced: the report is a by-product of the drawing,
--- not a second opinion assembled alongside it. `header` is the only writer,
--- so it holds at most one entry per panel per build and cannot grow while
--- the dashboard is merely running.
primitives.headingReports = {}

--- Collect and clear the headings cut since the last call.
---@return table[] reports Each carries `requested` and `drawn`.
function primitives.takeHeadingReports()
  local reports = primitives.headingReports
  if #reports == 0 then return reports end
  primitives.headingReports = {}
  return reports
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

--- Decide whether anything a component draws has changed since it last drew.
---
--- Repainting is expensive and a component is refreshed tens of times a
--- second, so every one of them short-circuits. The bug is always the same:
--- the short-circuit compares a hand-written list of fields, `apply` draws
--- something that is not on it, and that something then freezes on screen
--- while the panel looks perfectly healthy. Four instances have been found in
--- this catalogue. The first three were fixed one at a time, by adding the
--- missed field to the list, which is exactly why there was a fourth.
---
--- The list is the defect, so this removes the list. A component writes
--- everything it draws into one table, and `apply` is handed that table and
--- may draw nothing else. The comparison is then over the same values the
--- panel is painted from, by construction rather than by remembering: a field
--- `apply` reads but `render` never wrote is `nil` on screen, which is loud,
--- and a field `render` writes but `apply` ignores costs a comparison and
--- nothing worse.
---
--- Two tables are kept and swapped rather than allocated, because this runs on
--- every refresh of every component and the host pays it inside one
--- instruction budget.
---@param context table Component context; owns `rendered` and `scratch`.
---@param render fun(context: table, out: table)
---@return boolean changed
---@return table drawn Values to paint from.
function primitives.changed(context, render)
  local out = context.scratch
  if not out then out = {}; context.scratch = out end

  -- Cleared rather than replaced, so a key the component stops writing cannot
  -- linger and compare equal forever.
  for key in pairs(out) do out[key] = nil end
  render(context, out)

  local previous = context.rendered
  if previous then
    local same = true
    for key, value in pairs(out) do
      if previous[key] ~= value then same = false break end
    end

    -- A key that stopped being written cannot be seen by comparing what is
    -- here, and one can stop: `variable-indicator` drops its zero tick when
    -- the range no longer spans zero. Counting is only reached once the
    -- values have all matched, which is the cheap path taken on most frames.
    if same then
      local before, now = 0, 0
      for _ in pairs(previous) do before = before + 1 end
      for _ in pairs(out) do now = now + 1 end
      if before == now then return false, previous end
    end
  end

  context.rendered = out
  context.scratch = previous
  return true, out
end

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
function primitives.header(parent, theme, frame, fonts, text, presentation,
    themeBuilder)
  -- Fitted, because nothing else was fitting it. Every other string in this
  -- dashboard is either sized by the ladder or shortened by `fitLabel`; the
  -- heading went through neither and was handed to LVGL, whose default long
  -- mode wraps and whose content height then grows over the reading.
  local fit = themeBuilder and themeBuilder.fitHeading
  local heading, font, dropped = text, fonts.label, nil
  if fit then
    heading, font, dropped = fit(text, frame.labelWidth, fonts.label)
  else
    heading = string.upper(tostring(text == nil and "" or text))
  end

  local label = primitives.label(parent, theme, {
    x = frame.labelX,
    y = frame.compact,
    w = frame.labelWidth,
    text = heading,
    color = presentation.label,
    font = font,
  })
  -- Kept for the host to collect, beside the object rather than on it.
  if dropped then
    local reports = primitives.headingReports
    reports[#reports + 1] = {requested = dropped, drawn = heading}
  end

  local badge = primitives.badge(parent, theme, {
    x = frame.badgeX,
    y = frame.compact,
    w = frame.badgeWidth,
    text = "",
    color = theme.color.amber,
    font = fonts.badge,
  })

  if frame.labelHidden then lvgl.hide(label) end

  return label, badge, dropped
end

--- Set a heading's text, fitted to the column it has.
---
--- The two components that rewrite their own heading at runtime -- a timer
--- taking its name from the model, a variable indicator from the radio --
--- have to go through this rather than writing the label directly, or they
--- reintroduce exactly the overflow `header` now prevents.
---@param label any
---@param themeBuilder table
---@param frame table
---@param fonts table
---@param text any
---@param color? any
---@return string? dropped
function primitives.setHeading(label, themeBuilder, frame, fonts, text, color)
  -- Refitted every time rather than guarded on the text being unchanged. The
  -- guard was written, measured, and removed: `fitHeading` answers a heading
  -- that already fits in one width comparison, which is cheaper than the two
  -- the guard itself cost, so skipping the work was four instructions worse
  -- than doing it on the layout it was meant to help.
  local heading, font, dropped =
    themeBuilder.fitHeading(text, frame.labelWidth, fonts.label)

  local changes = {text = heading, font = function() return font end}
  if color ~= nil then changes.color = color end
  label:set(changes)
  return dropped
end

--- Reposition an existing header row after a geometry change.
---
--- `text` is the heading the panel currently shows, and the caller passes it
--- because the label cannot be asked. On a radio a label is userdata, so
--- `label.headingText` reads as nil rather than returning what was drawn:
--- reading it here meant a reflow silently never refitted, which is the same
--- defect as writing it, one step quieter.
---@param label any
---@param badge any
---@param frame table
---@param text? any Heading currently shown; omitted leaves the text alone.
function primitives.placeHeader(label, badge, frame, themeBuilder, fonts, text)
  local changes = {x = frame.labelX, y = frame.compact, w = frame.labelWidth}

  -- The column is what the badge leaves, so a reflow can change it and a
  -- heading that fitted before may not now. Refitted here rather than left,
  -- because a heading that only fits at the span it was built at is a
  -- heading that wraps the first time the zone moves.
  -- Refitted on every reflow, for the same reason: the column is what the
  -- badge leaves and a reflow can move it, and checking whether it moved
  -- costs more than refitting does.
  if themeBuilder and fonts and text ~= nil then
    local heading, font = themeBuilder.fitHeading(
      text, frame.labelWidth, fonts.label)
    changes.text = heading
    changes.font = function() return font end
  end

  label:set(changes)
  badge:set({x = frame.badgeX, y = frame.compact, w = frame.badgeWidth})
  if frame.labelHidden then lvgl.hide(label) else lvgl.show(label) end
end

--- Show or hide a supporting object, positioning it only when it is visible.
---
--- Four components had written this out privately and `trim-panel` had not
--- written it at all, which is why it was repositioning eight labels it had
--- just hidden. Moving a hidden object is not merely wasted: it is invisible
--- work, and invisible work is the one kind the suite cannot see either.
--- `settled` lets a caller that already knows visibility has not moved skip
--- the show or hide entirely, which matters where a panel repeats the pair
--- per indicator rather than once. Omitting it is always safe: nil reads as
--- "it may have changed", which is what every caller did before.
---@param object? any LVGL object, or nil when the component never built one.
---@param visible boolean
---@param changes? table Geometry to apply when the object is shown.
---@param settled? boolean Visibility is unchanged since the last call.
function primitives.reconcile(object, visible, changes, settled)
  if not object then return end
  if visible then
    if changes then object:set(changes) end
    if not settled then lvgl.show(object) end
  elseif not settled then
    lvgl.hide(object)
  end
end

--- Show or hide a bar, positioning and filling it only when it is visible.
---
--- A bar is two or three LVGL objects that always move together, which the
--- single-object `reconcile` cannot express, so five components wrote the
--- pair out by hand and a sixth wrote a `reconcile` per object and then
--- forgot the marker. That last one is why this exists rather than a note
--- asking people to remember: `placeBar` knows a bar may carry a neutral
--- marker, and a caller reconciling `track` and `fill` individually silently
--- leaves the marker where it was.
---@param bar? table Bar returned by `primitives.bar`, or nil when none exists.
---@param visible boolean
---@param x integer
---@param y integer
---@param width integer
---@param fraction number
---@param settled? boolean Visibility is unchanged since the last call.
function primitives.reconcileBar(bar, visible, x, y, width, fraction, settled)
  if not bar then return end

  if visible then
    primitives.placeBar(bar, x, y, width, fraction)
  end
  if settled then return end

  local show = visible and lvgl.show or lvgl.hide
  show(bar.track)
  show(bar.fill)
  if bar.marker then show(bar.marker) end
end

--- Angles of the two quarter bands that carry the accent round the corners.
--- LVGL measures zero at three o'clock and increases clockwise, so the upper
--- left quarter runs from nine o'clock to twelve, and the lower left from six
--- o'clock to nine.
primitives.ACCENT_TOP = {start = 180, finish = 270}
primitives.ACCENT_BOTTOM = {start = 90, finish = 180}

--- Create a component panel: an elevated fill with a narrow semantic accent.
--- The accent carries state, so it is never purely decorative.
---
--- The accent is not a stripe drawn on the panel. It is the panel: the base
--- rectangle is filled in the accent colour at the panel's own size and corner
--- radius, and the surface is then drawn over it inset from the left by the
--- accent width, with the same radius. What stays visible on the left is a
--- band of exactly that width whose ends follow the panel's corner arc, not
--- because they were made to match it but because they are it.
---
--- A stripe cannot do this. A 4 px wide rectangle asking for the panel's 8 px
--- radius cannot render an 8 px corner, so a full height stripe ends in
--- shoulders that sit outside the panel's own arc and protrude past the curve.
--- Insetting the stripe from top and bottom avoided the collision by keeping
--- it away from the corners, which is the version that was asked to run the
--- full height instead.
---
--- Rasterising both rectangles confirms the layering rather than assuming it:
--- on 117 x 65, 238 x 65, 480 x 65 and 238 x 134 panels the accent is exactly
--- `accentWidth` wide on every row, reaches every row, and no accent pixel
--- falls right of the left corner region, so nothing fringes along the top,
--- right or bottom. It holds whatever LVGL does with a radius it considers too
--- large, because both rectangles ask for the same one.
---
--- The background is a filled rectangle rather than a colored box: EdgeTX's
--- `lvgl.box` parses `color` but never paints it, so a box keeps the radio
--- theme's own styling and the dashboard would render in EdgeTX's palette.
---
--- The border object is built but left hidden unless the state has something
--- to say with it, and it is built at the focus weight whatever the current
--- state asks for, because `thickness` is effectively a build-time property on
--- a radio: `LvglWidgetBorderedObject::setOpacity` is the only place that
--- pushes it to LVGL, and its own `changedValue` guard skips the call when the
--- opacity has not moved, so a later `set{thickness=...}` is discarded.
---@param parent any
---@param rect AeroGridRect
---@param theme AeroGridTheme
---@param presentation table Result of theme.state.
---@return table panel
function primitives.panel(parent, rect, theme, presentation)
  local spacing = theme.spacing
  local radius = spacing.radius

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
    rounded = radius,
  })

  local border = lvgl.rectangle(root, {
    x = 0,
    y = 0,
    w = rect.w,
    h = rect.h,
    color = presentation.border,
    filled = false,
    rounded = radius,
    thickness = spacing.borderFocus,
  })

  -- Everything carrying the accent lives inside a column exactly one accent
  -- width across, and the renderer keeps it there. LVGL intersects a child's
  -- clip area with its parent's coordinates unless the parent carries
  -- LV_OBJ_FLAG_OVERFLOW_VISIBLE (`lv_refr.c`, `refr_obj`), and EdgeTX never
  -- sets that flag anywhere, so a container is a rectangular mask. That is the
  -- only masking primitive available to us: `lv_obj_set_style_clip_corner`
  -- would clip to a parent's rounded corners instead, but EdgeTX neither calls
  -- it nor exposes it to Lua.
  --
  -- The box paints nothing. `LvglWidgetBox::build` creates a bare `lv_obj` and
  -- its `setColor` is the base class's empty virtual, which is hard-won
  -- constraint 2 read in our favour for once: here an unpainted container is
  -- exactly what is wanted.
  local column = lvgl.box(root, {
    x = 0,
    y = 0,
    w = spacing.accentWidth,
    h = rect.h,
  })

  -- The straight run, between the two corners. A plain rectangle with no
  -- `rounded` key, so its ends are square and meet the arcs flush.
  local accent = lvgl.rectangle(column, {
    x = 0,
    y = radius,
    w = spacing.accentWidth,
    h = primitives.accentHeight(spacing, rect.h),
    color = presentation.accent,
    filled = true,
  })

  local panel = {
    root = root,
    background = background,
    border = border,
    column = column,
    accent = accent,
    spacing = spacing,
    -- The resting surface, so a state that does not tint can put it back.
    surface = theme.color.surface,
    surfaceColor = theme.color.surface,
    width = rect.w,
    height = rect.h,
    -- Reused for every corner update. `setRound` fills in x and y, so the
    -- table always carries the same three keys and never grows.
    arcChanges = {},
  }

  -- One quarter-circle band per corner, continuing the stripe around the
  -- panel's own corner arc. Centred on the corner centres and given the
  -- panel's corner radius, so each band's outer edge is the panel's own curve;
  -- the column then removes everything right of it. What survives is the part
  -- of the panel's corner that lies inside the accent's own width, which
  -- narrows from the full width at the tangent to nothing where the curve
  -- leaves the column. The arcs are children of the column, not of the root,
  -- or there would be nothing doing the clipping.
  panel.topArc = primitives.accentArc(column, spacing, radius, radius,
    primitives.ACCENT_TOP, presentation.accent)
  panel.bottomArc = primitives.accentArc(column, spacing, radius,
    rect.h - radius, primitives.ACCENT_BOTTOM, presentation.accent)

  primitives.stylePanel(panel, presentation)
  return panel
end

--- Create one corner band of the panel accent.
---
--- The band's outer edge lands exactly on the panel's own corner arc. LVGL
--- draws an arc between `radius` and `radius - width` measured from the centre
--- (`lv_draw_arc.c`: `rout = radius`, `rin = radius - w`), and the object's
--- box is `2 * radius` square centred on the position EdgeTX was given
--- (`LvglWidgetArc::build` calls `setRadius`, and `get_center` in `lv_arc.c`
--- takes `min(w, h) / 2`). Passing the panel's corner centre and its corner
--- radius therefore puts the outer edge on the same circle the panel's fill
--- is rounded by, and the inner edge one accent width inside it.
---
--- Nothing is passed for the background arc. `bgOpacity` defaults to
--- `LV_OPA_TRANSP`, so the unused half of the object is invisible without
--- touching `opacity`, which is what stopped a compass ring rendering on a
--- radio once.
---@param parent any
---@param spacing table
---@param centreX integer
---@param centreY integer
---@param angles table One of ACCENT_TOP or ACCENT_BOTTOM.
---@param color integer
---@return table band
function primitives.accentArc(parent, spacing, centreX, centreY, angles, color)
  local arc = lvgl.arc(parent, {
    x = centreX,
    y = centreY,
    radius = spacing.radius,
    thickness = spacing.accentWidth,
    color = color,
    startAngle = angles.start,
    endAngle = angles.finish,
  })

  return {arc = arc, centreX = centreX, centreY = centreY, angles = angles}
end

--- Move a corner band, restating its centre.
---
--- Constraint 11: every `set` on a round object walks it up and left by its
--- own radius unless the centre is restated, so this goes through the one
--- helper that does rather than becoming another hand-rolled copy of it. The
--- radius never changes, so position alone is restated.
---@param band table
---@param centreX integer
---@param centreY integer
---@param changes table Reusable change table, so a reflow allocates nothing.
function primitives.placeAccentArc(band, centreX, centreY, changes)
  band.centreX = centreX
  band.centreY = centreY
  setRound(band.arc, centreX, centreY, changes)
end

--- Height of the accent stripe inside a panel.
---
--- The inset is the panel's corner radius, and it is forced rather than
--- chosen. A stripe with square ends occupies `x` from 0 to `accentWidth`, and
--- it can only sit inside the panel where the panel's own left boundary has
--- reached `x = 0`. For a corner radius `R` that is true only for `y >= R`:
--- above it the fill has curved away to the right, so a stripe pixel there
--- would be drawn outside the card, in the gutter. Rasterising confirms it at
--- every panel size, with the first fully enclosed row at exactly `R`.
---
--- Anything that makes the stripe longer therefore has to make the corner less
--- round. There is no separate inset to tune, and inventing one lets the
--- stripe escape the panel.
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
--- state change that reveals it. A border that is already on screen is resized
--- immediately, because the state change that would otherwise fix it may never
--- come: a panel that was critical before the reflow and is critical after it
--- does not repaint at all.
---@param panel table
---@param rect AeroGridRect
function primitives.resizePanel(panel, rect)
  local spacing = panel.spacing
  panel.width = rect.w
  panel.height = rect.h
  panel.root:set({x = rect.x, y = rect.y, w = rect.w, h = rect.h})
  panel.background:set({w = rect.w, h = rect.h})
  -- The mask follows the panel's height, or a shorter panel keeps clipping to
  -- the old one and a taller one loses its bottom corner.
  panel.column:set({h = rect.h})
  panel.accent:set({h = primitives.accentHeight(spacing, rect.h)})

  -- The top corner never moves, so it is deliberately not touched: an arc that
  -- is not set cannot drift. Only the bottom one follows the height, and its
  -- radius is unchanged, so the update restates position alone.
  primitives.placeAccentArc(panel.bottomArc, spacing.radius,
    rect.h - spacing.radius, panel.arcChanges)

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
  -- An alert tints the panel's field rather than outlining it, so the surface
  -- is per state now and not merely per theme. A state with no tint of its own
  -- restores the resting one, or a panel stays coloured after the reading that
  -- alarmed it has recovered.
  local surface = presentation.surface or panel.surface
  if surface ~= panel.surfaceColor then
    panel.surfaceColor = surface
    panel.background:set({color = surface})
  end

  -- A component calls this on every repaint, and a panel's state changes far
  -- less often than its reading does, so nothing is touched unless it actually
  -- moved. Three objects carry the accent now rather than one, which made
  -- repainting it unconditionally the largest single cost in a steady frame.
  local accent = presentation.accent
  if accent ~= panel.accentColor then
    panel.accentColor = accent
    panel.accent:set({color = accent})
    -- The corner bands are the same stripe, so a state that dims the accent
    -- dims all three. They are arcs, so the centre is restated with the
    -- colour, or constraint 11 walks them out of the panel.
    local changes = panel.arcChanges
    changes.color = accent
    setRound(panel.topArc.arc, panel.topArc.centreX, panel.topArc.centreY,
      changes)
    setRound(panel.bottomArc.arc, panel.bottomArc.centreX,
      panel.bottomArc.centreY, changes)
  end

  if presentation.borderWidth <= 0 then
    if panel.borderVisible ~= false then
      panel.borderVisible = false
      lvgl.hide(panel.border)
    end
    return
  end

  -- Size as well as colour, because this is where a border hidden through a
  -- reflow learns the panel changed shape while it was invisible.
  if not panel.borderVisible or panel.borderColor ~= presentation.border then
    panel.borderVisible = true
    panel.borderColor = presentation.border
    panel.border:set({
      w = panel.width,
      h = panel.height,
      color = presentation.border,
    })
    lvgl.show(panel.border)
  end
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

--------------------------------------------------------------------------
-- Battery glyph
--------------------------------------------------------------------------

--- Smallest battery this host will draw, in pixels.
--- It stands upright, so the height is what has to be found and the width
--- follows it. Below roughly this size the level inside stops being readable
--- and the shape stops being a battery, so a panel that cannot give it this
--- much sheds it the way it sheds any other visual.
primitives.GLYPH_MIN_HEIGHT = 26
primitives.GLYPH_MIN_WIDTH = 13

--- How much taller than wide a cell stands.
primitives.GLYPH_ASPECT = 2

--- Pixels between the outline and the level inside it.
primitives.GLYPH_GAP = 1

--- The level a cell has to stand out from, in 24 bits.
---
--- The empty part of a cell is the panel showing through, so what the level
--- is read against is whatever tint the panel is wearing. Returned from the
--- theme's `rgb` mirror rather than its display values, because `contrast` is
--- arithmetic on colour channels and a display value is an `LcdFlags` word
--- rather than a colour. The resolved theme keeps both for this reason, and
--- confusing them is how a first pass at this measured the Modern critical
--- accent against its own alarm tint at 1.01 when the true figure is 3.14.
---@param theme AeroGridTheme
---@param state? string State name, for the tint the panel is wearing.
---@return integer
function primitives.batteryBackdropRgb(theme, state)
  return (theme.alertRgb and theme.alertRgb[state]) or theme.rgb.surface
end

--- Line heights per pixel of outline.
---
--- The stroke has to look right against **the number beside it**, not against
--- the panel: the ladder puts different fonts at the same span, so a cell
--- drawn from its span would carry the same weight beside a MIDSIZE reading
--- as beside an XXLSIZE one, which is what made it look heavy at small sizes.
--- Sixteen leaves the largest reading's cell where it already was and thins
--- every smaller one: 4 pixels at XXLSIZE, 3 at DBLSIZE, 2 at MIDSIZE and
--- below.
primitives.GLYPH_STROKE_RATIO = 16

--- Thinnest outline that still reads as a drawn cell rather than a hairline.
primitives.GLYPH_STROKE_MIN = 2

--- Widths per pixel of outline, as a ceiling.
--- The stroke is taken out of the interior twice over, so a narrow cell has
--- to be outlined more lightly than its reading would ask for or there is
--- nothing left inside to show a level in.
primitives.GLYPH_STROKE_WIDTH_RATIO = 6

--- Weight of a cell's outline, for the reading it stands beside.
---
--- Fixed when the glyph is built and never restated, which is not a choice: a
--- border width only reaches LVGL through
--- `LvglWidgetBorderedObject::setOpacity`, which runs behind `changedValue`,
--- so a thickness passed to a later `set` updates the C++ member and stops
--- there. The reading's font is known at build, so this can be answered then.
---@param themeBuilder table
---@param font any The font the reading resolved to.
---@param width integer The cell's own width.
---@return integer
function primitives.batteryStroke(themeBuilder, font, width)
  local fromFont = math.floor(
    themeBuilder.fontHeight(font) / primitives.GLYPH_STROKE_RATIO + 0.5)
  local fromWidth = math.floor(width / primitives.GLYPH_STROKE_WIDTH_RATIO)

  if fromWidth < fromFont then fromFont = fromWidth end
  if fromFont < primitives.GLYPH_STROKE_MIN then
    return primitives.GLYPH_STROKE_MIN
  end
  return fromFont
end

--- Work out the parts of an upright battery of a given size.
---
--- Separate from building it so a component can ask what a glyph would occupy
--- before deciding whether to have one, and so the arithmetic is testable
--- without an LVGL object anywhere near it.
---@param x integer
---@param y integer
---@param width integer
---@param height integer Total height, terminal included.
---@param border integer Outline weight, from `batteryStroke`. Passed in
--- rather than derived here, because it is fixed when the glyph is built and
--- a later reflow recomputing it would produce an interior that disagrees
--- with the outline LVGL is actually drawing.
---@return table
function primitives.batteryGeometry(x, y, width, height, border)
  -- The terminal sits on top, a little under half the width and a twelfth of
  -- the height, which keeps it a contact rather than a second cell at every
  -- size this draws at.
  local nubWidth = math.max(4, math.floor(width * 0.45 + 0.5))
  local nubHeight = math.max(2, math.floor(height / 12 + 0.5))
  local bodyHeight = math.max(1, height - nubHeight)
  local inset = border + primitives.GLYPH_GAP

  return {
    x = x,
    y = y,
    width = width,
    height = height,
    border = border,
    bodyY = y + nubHeight,
    bodyHeight = bodyHeight,
    nubX = x + math.floor((width - nubWidth) / 2),
    nubY = y,
    nubWidth = nubWidth,
    nubHeight = nubHeight,
    inset = inset,
    interiorX = x + inset,
    interiorY = y + nubHeight + inset,
    interiorWidth = math.max(1, width - inset * 2),
    interiorHeight = math.max(1, bodyHeight - inset * 2),
  }
end

--- Convert a 0..1 fraction into the height of a glyph's level.
---@param glyph table
---@param fraction any
---@return integer
function primitives.batteryFill(glyph, fraction)
  return primitives.barFill(glyph.interiorHeight, fraction)
end

--- Create an upright battery with a proportional level inside it.
---
--- A battery rather than a bar because a bar says "some of something" and a
--- battery says which something, which is the whole of what a pack panel is
--- for. `cell-battery` wants the same shape, which is why this is here beside
--- the bar rather than inside `tx-battery`.
---
--- Four rectangles, because `lvgl.box` accepts a `color` and silently ignores
--- it: `LvglWidgetBox::build` creates a bare `lv_obj` and its `setColor` is
--- the base class's empty virtual, so only a filled `lvgl.rectangle` paints.
---
--- **The outline, the terminal and the level are one colour, and the state
--- carries it**, so a critical pack is red throughout. The empty part of the
--- cell is the panel showing through, which is the thing to check rather than
--- assume: a red cell on a red-tinted panel is the case most likely to
--- disappear. Measured, the Modern critical accent stands at **3.14** against
--- its own alarm tint and the EdgeTX one at **4.05**, and the worst pairing
--- across both palettes and every state is 3.07. Nothing is drawn behind the
--- level, because nothing needs to be.
---@param parent any
---@param theme AeroGridTheme
---@param options table x, y, w, h, fraction, color, border
---@return table glyph
function primitives.batteryGlyph(parent, theme, options)
  local border = options.border or primitives.GLYPH_STROKE_MIN
  local geometry = primitives.batteryGeometry(
    options.x, options.y, options.w, options.h, border)
  local color = options.color or theme.color.cyan

  local shell = lvgl.rectangle(parent, {
    x = geometry.x,
    y = geometry.bodyY,
    w = geometry.width,
    h = geometry.bodyHeight,
    color = color,
    filled = false,
    thickness = geometry.border,
    rounded = 3,
  })

  local nub = lvgl.rectangle(parent, {
    x = geometry.nubX,
    y = geometry.nubY,
    w = geometry.nubWidth,
    h = geometry.nubHeight,
    color = color,
    filled = true,
    rounded = 1,
  })

  -- Grown from the bottom, because a cell drains downward.
  local height = primitives.batteryFill(geometry, options.fraction)
  local fill = lvgl.rectangle(parent, {
    x = geometry.interiorX,
    y = geometry.interiorY + geometry.interiorHeight - height,
    w = geometry.interiorWidth,
    h = height,
    color = color,
    filled = true,
    rounded = 1,
  })

  local glyph = primitives.batteryGeometry(
    options.x, options.y, options.w, options.h, border)
  glyph.shell = shell
  glyph.nub = nub
  glyph.fill = fill
  return glyph
end

--- Update a glyph's level and colour.
--- The outline and the terminal take the colour too, so a state change moves
--- the whole cell rather than just what is inside it.
---@param glyph table
---@param fraction number
---@param color? integer
function primitives.setBatteryGlyph(glyph, fraction, color)
  local height = primitives.batteryFill(glyph, fraction)
  local changes = {
    y = glyph.interiorY + glyph.interiorHeight - height,
    h = height,
  }
  if color then
    changes.color = color
    glyph.shell:set({color = color})
    glyph.nub:set({color = color})
  end
  glyph.fill:set(changes)
end

--- Move and resize a glyph without rebuilding it.
---
--- **The outline keeps the weight it was built with.** It is not restated
--- because restating it would change nothing on a radio -- a border width
--- never reaches LVGL after build -- and the interior is measured from the
--- weight that is actually drawn, so recomputing it here would inset the
--- level against an outline that does not exist.
---
--- The consequence is worth knowing: a reflow that moves the reading to a
--- different font leaves the cell outlined for the font it was built beside.
--- A zone change from 238 x 134 to 238 x 110 steps the reading from XXLSIZE
--- to DBLSIZE and the stroke stays at 4 where a fresh build would give 3.
---@param glyph table
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param fraction number Refilled against the new interior.
function primitives.placeBatteryGlyph(glyph, x, y, width, height, fraction)
  local next = primitives.batteryGeometry(x, y, width, height, glyph.border)
  for key, value in pairs(next) do glyph[key] = value end

  local level = primitives.batteryFill(glyph, fraction)
  glyph.shell:set({x = glyph.x, y = glyph.bodyY,
    w = glyph.width, h = glyph.bodyHeight})
  glyph.nub:set({x = glyph.nubX, y = glyph.nubY,
    w = glyph.nubWidth, h = glyph.nubHeight})
  glyph.fill:set({
    x = glyph.interiorX,
    y = glyph.interiorY + glyph.interiorHeight - level,
    w = glyph.interiorWidth,
    h = level,
  })
end

--- Show or hide a glyph, positioning it only when it is visible.
---
--- All three rectangles together, for the reason `reconcileBar` exists: a
--- shape made of several objects that move as one cannot be reconciled one
--- object at a time without something eventually being left behind. That is
--- exactly how `metric` came to hide a bar and leave its marker floating.
---@param glyph? table
---@param visible boolean
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param fraction number
---@param settled? boolean Visibility is known not to have moved.
function primitives.reconcileBatteryGlyph(glyph, visible, x, y, width, height,
    fraction, settled)
  if not glyph then return end

  if visible then
    primitives.placeBatteryGlyph(glyph, x, y, width, height, fraction)
  end
  if settled then return end

  local change = visible and lvgl.show or lvgl.hide
  change(glyph.shell)
  change(glyph.nub)
  change(glyph.fill)
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
--- where it meant to. The square it covers is centre plus or minus `radius`;
--- `lv_draw_arc.c` sets `rout = radius` and draws the stroke inward, so
--- thickness does not widen it.
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
