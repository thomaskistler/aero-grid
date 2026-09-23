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
    supportedSpans = { "1x1", "2x1", "2x2", "4x1" },
    -- Faster than a telemetry readout because it animates, but still far below
    -- the frame rate.
    refreshInterval = 10,
    settings = {
        { key = "label", label = "Label", type = "string", default = "HEARTBEAT" },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "amber",
            choices = { "cyan", "green", "amber", "orange" },
        },
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
    local themeBuilder = services.themeBuilder
    local fonts = services.fonts
    local presentation = services.state("normal", settings.accent)

    -- Through the shared frame like every other component, so a heartbeat in
    -- the top-left cell of an App mode screen is laid out around the EdgeTX
    -- menu button rather than underneath it.
    local frame = themeBuilder.frame(theme, rect, fonts)
    local panel = primitives.panel(parent, rect, theme, presentation)
    local width = frame.content

    local label = primitives.value(panel.root, theme, {
        x = frame.labelX,
        y = frame.compact,
        w = frame.labelWidth,
        text = tostring(settings.label),
        color = presentation.value,
        font = fonts.label,
    })

    local counter = primitives.label(panel.root, theme, {
        x = frame.pad,
        y = frame.top,
        w = width,
        text = "0 / 0",
        color = presentation.label,
        font = fonts.label,
    })

    local bar = primitives.bar(panel.root, theme, {
        x = frame.pad,
        y = barY(theme, rect.h),
        w = width,
        fraction = 1 / PHASES,
        color = presentation.accent,
    })

    if frame.labelHidden then
        lvgl.hide(label)
    end

    return {
        panel = panel,
        theme = theme,
        themeBuilder = themeBuilder,
        fonts = fonts,
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
    local frame = context.themeBuilder.frame(theme, rect, context.fonts)
    local width = frame.content

    context.primitives.resizePanel(context.panel, rect)
    context.label:set({ x = frame.labelX, y = frame.compact, w = frame.labelWidth })
    context.counter:set({ x = frame.pad, y = frame.top, w = width })
    context.bar.width = width
    context.bar.track:set({ x = frame.pad, w = width, y = barY(theme, rect.h) })
    context.bar.fill:set({ x = frame.pad, y = barY(theme, rect.h) })
    context.primitives.setBar(context.bar, context.phase / PHASES)
    if frame.labelHidden then
        lvgl.hide(context.label)
    else
        lvgl.show(context.label)
    end
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
        context.counter:set({ text = text })
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
