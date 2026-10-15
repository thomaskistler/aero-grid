-- SPDX-License-Identifier: GPL-2.0-only

local details = { RUNTIME_API = 1 }

function details.close(context)
    if context.locationOverlay then
        context.locationOverlay:clear()
        lvgl.hide(context.locationOverlay)
    end
    context.locationDetails = nil
    context.touchTapHandled = true
end

--- Copy the fix once so neither the QR code nor its caption moves while scanning.
function details.open(context, view, accent)
    assert(type(lvgl.qrcode) == "function", "location details require the EdgeTX LVGL QR-code API")
    local snapshot = {
        valid = view and view.fix == true,
        stale = view and view.state == "stale",
        latitude = view and view.latitude,
        longitude = view and view.longitude,
    }
    if snapshot.valid then
        snapshot.coordinates = string.format("%.6f, %.6f", snapshot.latitude, snapshot.longitude)
        snapshot.url = string.format(
            "https://www.google.com/maps/search/?api=1&query=%.6f,%.6f",
            snapshot.latitude,
            snapshot.longitude
        )
    end
    local width, height = context.zone.w, context.zone.h
    local overlay = context.locationOverlay
    if not overlay then
        overlay = lvgl.box(context.page, { x = 0, y = 0, w = width, h = height })
        context.locationOverlay = overlay
        context.pageBuiltFullscreen = true
    end
    overlay:set({ w = width, h = height })
    lvgl.show(overlay)
    context.locationDetails = snapshot
    lvgl.rectangle(overlay, {
        x = 0,
        y = 0,
        w = width,
        h = height,
        filled = true,
        color = lcd.RGB(0x000000),
        opacity = 160,
    })
    local builder, primitives, theme = context.themeBuilder, context.primitives, context.theme
    local rect = {
        w = math.min(width - 32, 440),
        h = math.min(height - 24, 248),
    }
    rect.x, rect.y = math.floor((width - rect.w) / 2), math.floor((height - rect.h) / 2)
    local fonts = builder.typography(2, 2)
    fonts.label, fonts.badge = 0, 0
    local state = not snapshot.valid and "unavailable" or snapshot.stale and "stale" or "normal"
    local presentation = builder.state(theme, state, accent)
    local frame = builder.frame(theme, rect, fonts)
    local card, _, badge =
        primitives.panelWithHeader(overlay, rect, theme, presentation, frame, fonts, "GPS LOCATION", builder)
    snapshot.panel = card
    primitives.setBadge(snapshot, builder, badge, frame, fonts.badge, presentation.badge or "", presentation.accent)
    local function label(x, y, w, text, color, font)
        return primitives.label(card.root, theme, {
            x = x,
            y = y,
            w = w,
            text = text,
            font = font or fonts.label,
            color = color or theme.color.text,
        })
    end
    local status = snapshot.stale and "LAST KNOWN POSITION" or "GPS FIX"
    local latitude = snapshot.valid and string.format("LAT  %.6f", snapshot.latitude) or ""
    local longitude = snapshot.valid and string.format("LON  %.6f", snapshot.longitude) or ""
    local textWidth = math.max(
        builder.measureText(fonts.label, status),
        builder.measureText(fonts.label, latitude),
        builder.measureText(fonts.label, longitude),
        builder.measureText(fonts.label, "SCAN FOR GOOGLE MAPS"),
        builder.measureText(SMLSIZE, "Position frozen while open")
    )
    local gap = 16
    local bodyBottom = rect.h - 35
    local bodyTop = frame.top + 4
    local size = math.floor(math.min(bodyBottom - bodyTop, frame.content - textWidth - gap))
    local left = math.floor((rect.w - size - gap - textWidth) / 2)
    local top = bodyTop + math.floor((bodyBottom - bodyTop - size) / 2)
    local textX = left + size + gap
    local textTop = bodyTop + math.floor((bodyBottom - bodyTop - 148) / 2)
    if snapshot.valid then
        -- Keep an explicit white quiet zone independent of the dashboard theme.
        lvgl.rectangle(card.root, {
            x = left,
            y = top,
            w = size,
            h = size,
            filled = true,
            color = lcd.RGB(0xFFFFFF),
        })
        snapshot.code = lvgl.qrcode(card.root, {
            x = left + 8,
            y = top + 8,
            w = size - 16,
            data = snapshot.url,
            color = lcd.RGB(0x000000),
            bgColor = lcd.RGB(0xFFFFFF),
        })
        label(
            textX,
            textTop,
            textWidth,
            status,
            snapshot.stale and context.theme.color.amber or context.theme.color.text
        )
        label(textX, textTop + 35, textWidth, latitude)
        label(textX, textTop + 62, textWidth, longitude)
        label(textX, textTop + 100, textWidth, "SCAN FOR GOOGLE MAPS", theme.color.textMuted)
        label(textX, textTop + 129, textWidth, "Position frozen while open", theme.color.textFaint, SMLSIZE)
    else
        label(frame.pad, bodyTop + 12, frame.content, "No valid GPS position")
        label(frame.pad, bodyTop + 45, frame.content, "A map code is available after a GPS fix.", theme.color.textMuted)
    end
    local hint = "Tap anywhere or RTN to return"
    local hintWidth = builder.measureText(SMLSIZE, hint)
    label(math.floor((rect.w - hintWidth) / 2), rect.h - 24, hintWidth, hint, theme.color.textFaint, SMLSIZE)
end

function details.handle(context, event)
    if event == _G.EVT_VIRTUAL_EXIT or event == _G.EVT_EXIT_BREAK or event == _G.EVT_TOUCH_TAP then
        details.close(context)
    end
    return true
end

return details
