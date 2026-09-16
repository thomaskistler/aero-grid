-- SPDX-License-Identifier: GPL-2.0-only

--- Development component that proves the AeroGrid host lifecycle contract.
--- It is deliberately authored independently of `placeholder` so the host is
--- exercised with two separately loaded modules that declare different spans,
--- settings, and callbacks.

---@class AeroGridHeartbeatSettings
---@field label? string
---@field accent? "cyan"|"green"|"amber"|"orange"

---@class AeroGridHeartbeatContext
---@field panel table
---@field label any
---@field counter any
---@field bar table
---@field ticks integer Foreground refresh callbacks received.
---@field backgroundTicks integer Background callbacks received.
---@field events integer Input events consumed.
---@field phase integer Current activity-bar phase.

local heartbeat = {
  id = "heartbeat",
  apiVersion = 1,
  -- Restricted on purpose: the host must reject unsupported spans visibly.
  supportedSpans = {"1x1", "2x1", "2x2", "4x1"},
  settings = {
    {key = "label", label = "Label", type = "string", default = "HEARTBEAT"},
    {key = "accent", label = "Accent", type = "string", default = "amber"},
  },
}

local PHASES = 8

--- Vertical position of the bottom-aligned activity bar.
---@param theme AeroGridTheme
---@param height integer
---@return integer
local function barY(theme, height)
  return math.max(1, height - theme.spacing.padding - theme.spacing.barHeight)
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
---@param settings AeroGridHeartbeatSettings Host-resolved settings.
---@param services table Host-provided shared objects.
---@return AeroGridHeartbeatContext
function heartbeat.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local spacing = theme.spacing
  local presentation = services.state("normal", settings.accent)

  local panel = primitives.panel(parent, rect, theme, presentation)
  local width = primitives.contentWidth(theme, rect.w)

  local label = primitives.value(panel.root, theme, {
    x = spacing.padding,
    y = spacing.paddingCompact,
    w = width,
    text = tostring(settings.label),
    color = presentation.value,
    font = fonts.label,
  })

  local counter = primitives.label(panel.root, theme, {
    x = spacing.padding,
    y = spacing.paddingCompact + 22,
    w = width,
    text = "0 / 0",
    color = presentation.label,
    font = fonts.label,
  })

  local bar = primitives.bar(panel.root, theme, {
    x = spacing.padding,
    y = barY(theme, rect.h),
    w = width,
    fraction = 1 / PHASES,
    color = presentation.accent,
  })

  return {
    panel = panel,
    theme = theme,
    primitives = primitives,
    label = label,
    counter = counter,
    bar = bar,
    ticks = 0,
    backgroundTicks = 0,
    events = 0,
    phase = 1,
    text = "0 / 0",
  }
end

--- Reposition an existing heartbeat without recreating LVGL objects.
---@param context AeroGridHeartbeatContext
---@param rect AeroGridRect
function heartbeat.update(context, rect)
  local theme = context.theme
  local width = context.primitives.contentWidth(theme, rect.w)

  context.primitives.resizePanel(context.panel, rect)
  context.label:set({w = width})
  context.counter:set({w = width})
  context.bar.width = width
  context.bar.track:set({w = width, y = barY(theme, rect.h)})
  context.bar.fill:set({y = barY(theme, rect.h)})
  context.primitives.setBar(context.bar, context.phase / PHASES)
end

--- Advance the visible activity indicator once per host refresh.
---@param context AeroGridHeartbeatContext
function heartbeat.refresh(context)
  context.ticks = context.ticks + 1
  context.phase = context.phase % PHASES + 1
  context.primitives.setBar(context.bar, context.phase / PHASES)

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

--- Count input events without consuming them, so host routing stays observable.
---@param context AeroGridHeartbeatContext
---@return boolean consumed
function heartbeat.event(context)
  context.events = context.events + 1
  return false
end

return heartbeat
