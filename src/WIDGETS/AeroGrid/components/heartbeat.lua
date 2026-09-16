-- SPDX-License-Identifier: GPL-2.0-only

--- Development component that proves the AeroGrid host lifecycle contract.
--- It is deliberately authored independently of `placeholder` so the host is
--- exercised with two separately loaded modules that declare different spans,
--- settings, and callbacks.

---@class AeroGridHeartbeatSettings
---@field label? string
---@field accent? "cyan"|"green"|"amber"|"orange"

---@class AeroGridHeartbeatContext
---@field panel any
---@field border any
---@field label any
---@field counter any
---@field bar any
---@field width integer Current panel width in pixels.
---@field ticks integer Foreground refresh callbacks received.
---@field backgroundTicks integer Background callbacks received.
---@field phase integer Current activity-bar phase.
---@field text string Last rendered counter text.

local heartbeat = {
  id = "heartbeat",
  apiVersion = 1,
  -- Restricted on purpose: the host must reject unsupported spans visibly.
  supportedSpans = {"1x1", "2x1", "2x2", "4x1"},
  settings = {
    {key = "label", type = "string", default = "HEARTBEAT"},
    {key = "accent", type = "string", default = "amber"},
  },
}

local PHASES = 8

local colors = {
  surface = lcd.RGB(24, 29, 34),
  border = lcd.RGB(52, 59, 64),
  track = lcd.RGB(40, 46, 52),
  text = lcd.RGB(244, 246, 247),
  muted = lcd.RGB(167, 176, 182),
}

local accents = {
  cyan = lcd.RGB(112, 214, 243),
  green = lcd.RGB(85, 217, 144),
  amber = lcd.RGB(242, 184, 75),
  orange = lcd.RGB(255, 118, 46),
}

--- Return the content width inside a panel with fixed horizontal padding.
---@param width integer
---@return integer
local function contentWidth(width)
  return math.max(1, width - 16)
end

--- Return the activity-bar width for the current phase.
---@param width integer
---@param phase integer
---@return integer
local function barWidth(width, phase)
  return math.max(1, math.floor(contentWidth(width) * phase / PHASES))
end

--- Compose the counter line shown under the label.
---@param context AeroGridHeartbeatContext
---@return string
local function counterText(context)
  return tostring(context.ticks) .. " / " .. tostring(context.backgroundTicks)
end

--- Create a heartbeat panel inside an LVGL parent container.
---@param parent any Parent LVGL object supplied by the AeroGrid host.
---@param rect AeroGridRect Pixel bounds relative to the parent.
---@param settings AeroGridHeartbeatSettings Host-resolved settings with defaults applied.
---@return AeroGridHeartbeatContext
function heartbeat.create(parent, rect, settings)
  local accentColor = accents[settings.accent] or colors.muted

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

  local label = lvgl.label(panel, {
    x = 8,
    y = 6,
    w = contentWidth(rect.w),
    h = 0,
    text = tostring(settings.label),
    color = colors.text,
    font = function() return BOLD end,
  })

  local counter = lvgl.label(panel, {
    x = 8,
    y = 28,
    w = contentWidth(rect.w),
    h = 0,
    text = "0 / 0",
    color = colors.muted,
    font = function() return SMLSIZE end,
  })

  local bar = lvgl.rectangle(panel, {
    x = 8,
    y = 50,
    w = barWidth(rect.w, 1),
    h = 4,
    color = accentColor,
    filled = true,
    rounded = 2,
  })

  return {
    panel = panel,
    border = border,
    label = label,
    counter = counter,
    bar = bar,
    width = rect.w,
    ticks = 0,
    backgroundTicks = 0,
    phase = 1,
    text = "0 / 0",
  }
end

--- Reposition an existing heartbeat without recreating LVGL objects.
---@param context AeroGridHeartbeatContext
---@param rect AeroGridRect
function heartbeat.resize(context, rect)
  context.width = rect.w
  context.panel:set({x = rect.x, y = rect.y, w = rect.w, h = rect.h})
  context.border:set({w = rect.w, h = rect.h})
  context.label:set({w = contentWidth(rect.w)})
  context.counter:set({w = contentWidth(rect.w)})
  context.bar:set({w = barWidth(rect.w, context.phase)})
end

--- Advance the visible activity indicator once per host refresh.
---@param context AeroGridHeartbeatContext
function heartbeat.refresh(context)
  context.ticks = context.ticks + 1
  context.phase = context.phase % PHASES + 1
  context.bar:set({w = barWidth(context.width, context.phase)})

  -- Only touch the label when its rendered text actually changes.
  local text = counterText(context)
  if text ~= context.text then
    context.text = text
    context.counter:set({text = text})
  end
end

--- Keep counting while the dashboard screen is not visible.
---@param context AeroGridHeartbeatContext
function heartbeat.background(context)
  context.backgroundTicks = context.backgroundTicks + 1
end

return heartbeat
