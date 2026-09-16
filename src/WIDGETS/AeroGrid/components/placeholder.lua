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
  local fonts = services.fonts
  local spacing = theme.spacing
  local presentation = services.state("normal", settings.accent)

  local panel = primitives.panel(parent, rect, theme, presentation)
  local width = primitives.contentWidth(theme, rect.w)

  local title = primitives.value(panel.root, theme, {
    x = spacing.padding,
    y = spacing.paddingCompact,
    w = width,
    text = tostring(settings.title),
    color = presentation.value,
    font = fonts.label,
  })

  local subtitle = primitives.label(panel.root, theme, {
    x = spacing.padding,
    y = spacing.paddingCompact + 22,
    w = width,
    text = tostring(settings.subtitle),
    color = presentation.label,
    font = fonts.label,
  })

  return {
    panel = panel,
    theme = theme,
    primitives = primitives,
    title = title,
    subtitle = subtitle,
  }
end

--- Resize and reposition without recreating LVGL objects.
---@param context AeroGridPlaceholderContext
---@param rect AeroGridRect
function placeholder.update(context, rect)
  local width = context.primitives.contentWidth(context.theme, rect.w)

  context.primitives.resizePanel(context.panel, rect)
  context.title:set({w = width})
  context.subtitle:set({w = width})
end

return placeholder
