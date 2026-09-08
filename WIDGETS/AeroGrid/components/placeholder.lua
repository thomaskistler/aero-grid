-- SPDX-License-Identifier: GPL-2.0-only

--- Development component used to verify AeroGrid placement and resizing.

---@class AeroGridPlaceholderConfig
---@field title? string
---@field subtitle? string
---@field accent? "cyan"|"green"|"amber"|"orange"

---@class AeroGridPlaceholderContext
---@field panel any
---@field border any
---@field accent any
---@field title any
---@field subtitle any

local placeholder = {
  id = "placeholder",
  apiVersion = 1,
}

local colors = {
  surface = lcd.RGB(29, 35, 40),
  border = lcd.RGB(52, 59, 64),
  text = lcd.RGB(244, 246, 247),
  muted = lcd.RGB(167, 176, 182),
}

local accents = {
  cyan = lcd.RGB(112, 214, 243),
  green = lcd.RGB(85, 217, 144),
  amber = lcd.RGB(242, 184, 75),
  orange = lcd.RGB(255, 118, 46),
}

--- Return the label width inside a panel with fixed horizontal padding.
---@param rect AeroGridRect
---@return integer
local function contentWidth(rect)
  return math.max(1, rect.w - 16)
end

--- Create a placeholder panel inside an LVGL parent container.
---@param parent any Parent LVGL object supplied by the AeroGrid host.
---@param rect AeroGridRect Pixel bounds relative to the parent.
---@param config AeroGridPlaceholderConfig
---@return AeroGridPlaceholderContext
function placeholder.create(parent, rect, config)
  local accentColor = accents[config.accent] or colors.muted
  local panel = lvgl.box(parent, {
    x = rect.x,
    y = rect.y,
    w = rect.w,
    h = rect.h,
    color = colors.surface,
  })

  local border = lvgl.rectangle(panel, {
    x = 0,
    y = 0,
    w = rect.w,
    h = rect.h,
    color = colors.border,
    filled = false,
    rounded = 4,
    thickness = 1,
  })

  local accent = lvgl.rectangle(panel, {
    x = 0,
    y = 0,
    w = 4,
    h = rect.h,
    color = accentColor,
    filled = true,
    rounded = 2,
  })

  local title = lvgl.label(panel, {
    x = 8,
    y = 6,
    w = contentWidth(rect),
    h = 0,
    text = tostring(config.title or "PLACEHOLDER"),
    color = colors.text,
    font = function() return BOLD end,
  })

  local subtitle = lvgl.label(panel, {
    x = 8,
    y = 28,
    w = contentWidth(rect),
    h = 0,
    text = tostring(config.subtitle or ""),
    color = colors.muted,
    font = function() return SMLSIZE end,
  })

  return {
    panel = panel,
    border = border,
    accent = accent,
    title = title,
    subtitle = subtitle,
  }
end

--- Resize and reposition an existing placeholder without recreating LVGL objects.
---@param context AeroGridPlaceholderContext
---@param rect AeroGridRect
function placeholder.resize(context, rect)
  context.panel:set({x = rect.x, y = rect.y, w = rect.w, h = rect.h})
  context.border:set({w = rect.w, h = rect.h})
  context.accent:set({h = rect.h})
  context.title:set({w = contentWidth(rect)})
  context.subtitle:set({w = contentWidth(rect)})
end

return placeholder