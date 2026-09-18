-- SPDX-License-Identifier: GPL-2.0-only

--- Development component used to verify AeroGrid placement and resizing.
--- All colors come from host theme tokens; components never define palettes.

---@class AeroGridPlaceholderSettings
---@field title? string
---@field subtitle? string
---@field accent? "cyan"|"green"|"amber"|"orange"

---@class AeroGridPlaceholderContext
---@field panel table
---@field title any
---@field subtitle any

local placeholder = {
  id = "placeholder",
  apiVersion = 1,
  supportedSpans = {"any"},
  settings = {
    {key = "title", label = "Title", type = "string", default = "PLACEHOLDER"},
    {key = "subtitle", label = "Subtitle", type = "string", default = ""},
    {key = "accent", label = "Accent", type = "string", default = "cyan"},
  },
}

--- Create a placeholder panel inside an LVGL parent container.
---@param parent any Parent LVGL object supplied by the AeroGrid host.
---@param rect AeroGridRect Pixel bounds relative to the parent.
---@param settings AeroGridPlaceholderSettings Host-resolved settings.
---@param services table Host-provided shared objects.
---@return AeroGridPlaceholderContext
function placeholder.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local themeBuilder = services.themeBuilder
  local fonts = services.fonts
  local presentation = services.state("normal", settings.accent)

  -- Through the shared frame like every other component, so a placeholder in
  -- the top-left cell of an App mode screen is laid out around the EdgeTX
  -- menu button rather than underneath it.
  local frame = themeBuilder.frame(theme, rect, fonts)
  local panel = primitives.panel(parent, rect, theme, presentation)

  local title = primitives.value(panel.root, theme, {
    x = frame.labelX,
    y = frame.compact,
    w = frame.labelWidth,
    text = tostring(settings.title),
    color = presentation.value,
    font = fonts.label,
  })

  local subtitle = primitives.label(panel.root, theme, {
    x = frame.pad,
    y = frame.top,
    w = frame.content,
    text = tostring(settings.subtitle),
    color = presentation.label,
    font = fonts.label,
  })

  if frame.labelHidden then lvgl.hide(title) end

  return {
    panel = panel,
    theme = theme,
    themeBuilder = themeBuilder,
    fonts = fonts,
    primitives = primitives,
    title = title,
    subtitle = subtitle,
  }
end

--- Resize and reposition without recreating LVGL objects.
---@param context AeroGridPlaceholderContext
---@param rect AeroGridRect
function placeholder.update(context, rect)
  local frame = context.themeBuilder.frame(context.theme, rect, context.fonts)

  context.primitives.resizePanel(context.panel, rect)
  context.title:set({x = frame.labelX, y = frame.compact, w = frame.labelWidth})
  context.subtitle:set({x = frame.pad, y = frame.top, w = frame.content})
  if frame.labelHidden then
    lvgl.hide(context.title)
  else
    lvgl.show(context.title)
  end
end

return placeholder
