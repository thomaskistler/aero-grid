-- SPDX-License-Identifier: GPL-2.0-only

--- Shared LVGL building blocks drawn from host theme tokens.
--- Components compose these instead of styling panels themselves, so the
--- dashboard keeps one coherent visual language.

local primitives = {}

--- Return the usable content width inside a padded panel.
---@param theme AeroGridTheme
---@param width integer
---@return integer
function primitives.contentWidth(theme, width)
  return math.max(1, width - theme.spacing.padding * 2)
end

--- Create a component panel with a border and a narrow semantic accent.
--- The accent stripe carries state, so it is never purely decorative.
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
    color = theme.color.surface,
  })

  local border = lvgl.rectangle(root, {
    x = 0,
    y = 0,
    w = rect.w,
    h = rect.h,
    color = presentation.border,
    filled = false,
    rounded = spacing.radius,
    thickness = presentation.borderWidth,
  })

  local accent = lvgl.rectangle(root, {
    x = 0,
    y = 0,
    w = spacing.accentWidth,
    h = rect.h,
    color = presentation.accent,
    filled = true,
    rounded = spacing.radius,
  })

  return {root = root, border = border, accent = accent}
end

--- Resize a panel without recreating its LVGL objects.
---@param panel table
---@param rect AeroGridRect
function primitives.resizePanel(panel, rect)
  panel.root:set({x = rect.x, y = rect.y, w = rect.w, h = rect.h})
  panel.border:set({w = rect.w, h = rect.h})
  panel.accent:set({h = rect.h})
end

--- Apply a new state presentation to an existing panel.
---@param panel table
---@param presentation table
function primitives.stylePanel(panel, presentation)
  panel.border:set({color = presentation.border, thickness = presentation.borderWidth})
  panel.accent:set({color = presentation.accent})
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
    color = theme.color.surfaceRaised,
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

  return {track = track, fill = fill, width = options.w}
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

--- Create a radial arc gauge with a background track.
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
    bgColor = theme.color.surfaceRaised,
    bgOpacity = 255,
    bgStartAngle = startAngle,
    rounded = true,
  })

  return {arc = arc, startAngle = startAngle, sweep = sweep}
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
  radial.arc:set(changes)
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

return primitives
