-- SPDX-License-Identifier: GPL-2.0-only

-- Frozen synchronous resolver from e71dce9, before bounded theme resolution.
-- Test oracle only: intentionally independent contrast/tint algorithms.
return function(catalog)
    local theme = {}
    local CHART_COLORS = {
        chartCyan = "cyan",
        chartGreen = "green",
        chartAmber = "amber",
        chartOrange = "orange",
        chartGrid = "border",
    }
    function theme.notice(notices, severity, text)
        notices[#notices + 1] = { severity = severity, text = text }
    end
    local MIN_TEXT_CONTRAST = 4.5
    local MIN_MUTED_CONTRAST = 3.0
    local MIN_FAINT_CONTRAST = 1.8
    local MIN_ACCENT_CONTRAST = 2.5
    local MIN_TRACK_CONTRAST = 2.0
    local MIN_TINT_SEPARATION = 1.30
    local MIN_ELEVATION_CONTRAST = 1.30
    local MIN_RAISE_CONTRAST = 1.20

    local function channels(rgb)
        return math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
    end

    local function pack(red, green, blue)
        local function clamp(value)
            value = math.floor(value + 0.5)
            if value < 0 then
                return 0
            end
            if value > 255 then
                return 255
            end
            return value
        end
        return clamp(red) * 65536 + clamp(green) * 256 + clamp(blue)
    end

    local function luminance(rgb)
        local function channel(value)
            value = value / 255
            if value <= 0.03928 then
                return value / 12.92
            end
            return ((value + 0.055) / 1.055) ^ 2.4
        end

        local red, green, blue = channels(rgb)
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    end

    function theme.contrast(first, second)
        local a, b = luminance(first), luminance(second)
        if a < b then
            a, b = b, a
        end
        return (a + 0.05) / (b + 0.05)
    end

    function theme.shade(rgb, amount)
        local red, green, blue = channels(rgb)
        local target = amount >= 0 and 255 or 0
        local ratio = amount >= 0 and amount or -amount

        return pack(red + (target - red) * ratio, green + (target - green) * ratio, blue + (target - blue) * ratio)
    end

    local function betterContrast(background, first, second)
        if theme.contrast(background, first) >= theme.contrast(background, second) then
            return first
        end
        return second
    end

    local function correctContrast(tokens, key, background, minimum, notices)
        if theme.contrast(background, tokens[key]) >= minimum then
            return
        end

        local candidate = betterContrast(background, tokens[key], theme.shade(background, 0.85))
        if theme.contrast(background, candidate) < minimum then
            candidate = betterContrast(background, 0xFFFFFF, 0x000000)
        end

        tokens[key] = candidate
        theme.notice(notices, "info", key .. " was corrected for contrast")
    end

    local function separated(base, minimum)
        for _, amount in ipairs({ 0.08, 0.16, 0.24, 0.36, 0.5, 0.7 }) do
            local lighter = theme.shade(base, amount)
            if theme.contrast(base, lighter) >= minimum then
                return lighter
            end

            local darker = theme.shade(base, -amount)
            if theme.contrast(base, darker) >= minimum then
                return darker
            end
        end

        return betterContrast(base, 0xFFFFFF, 0x000000)
    end

    local function correctAccent(tokens, key, background, minimum, notices)
        if theme.contrast(background, tokens[key]) >= minimum then
            return
        end

        local direction = luminance(background) < 0.18 and 1 or -1
        for _, amount in ipairs({ 0.2, 0.35, 0.5, 0.65, 0.8 }) do
            local candidate = theme.shade(tokens[key], direction * amount)
            if theme.contrast(background, candidate) >= minimum then
                tokens[key] = candidate
                theme.notice(notices, "info", key .. " was corrected for contrast")
                return
            end
        end

        tokens[key] = betterContrast(background, 0xFFFFFF, 0x000000)
        theme.notice(notices, "info", key .. " was replaced for contrast")
    end

    local function enforceLegibility(tokens, notices)
        if theme.contrast(tokens.canvas, tokens.surface) < MIN_ELEVATION_CONTRAST then
            tokens.surface = separated(tokens.canvas, MIN_ELEVATION_CONTRAST)
            theme.notice(notices, "info", "surface was lifted to elevate panels")
        end
        tokens.surfaceRaised = separated(tokens.surface, MIN_RAISE_CONTRAST)
        if theme.contrast(tokens.surface, tokens.border) < 1.25 then
            tokens.border = separated(tokens.surface, 1.25)
        end
        if theme.contrast(tokens.surface, tokens.track) < MIN_TRACK_CONTRAST then
            tokens.track = separated(tokens.surface, MIN_TRACK_CONTRAST)
        end

        correctContrast(tokens, "text", tokens.surface, MIN_TEXT_CONTRAST, notices)
        correctContrast(tokens, "textMuted", tokens.surface, MIN_MUTED_CONTRAST, notices)
        correctContrast(tokens, "textFaint", tokens.surface, MIN_FAINT_CONTRAST, notices)

        for _, key in ipairs({ "cyan", "green", "amber", "orange", "blue" }) do
            correctAccent(tokens, key, tokens.surface, MIN_ACCENT_CONTRAST, notices)
        end

        if theme.contrast(tokens.surface, tokens.critical) < MIN_ACCENT_CONTRAST then
            local replacement = betterContrast(tokens.critical, 0x000000, 0xFFFFFF)

            for _, amount in ipairs({ 0.1, 0.2, 0.3, 0.45, 0.6, 0.75, 0.9 }) do
                local darker = theme.shade(tokens.surface, -amount)
                if theme.contrast(darker, tokens.critical) >= MIN_ACCENT_CONTRAST then
                    replacement = darker
                    break
                end
                local lighter = theme.shade(tokens.surface, amount)
                if theme.contrast(lighter, tokens.critical) >= MIN_ACCENT_CONTRAST then
                    replacement = lighter
                    break
                end
            end

            tokens.surface = replacement
            theme.notice(notices, "info", "surface was shifted to keep critical visible")

            tokens.surfaceRaised = separated(tokens.surface, MIN_RAISE_CONTRAST)
            tokens.border = separated(tokens.surface, 1.25)
            tokens.track = separated(tokens.surface, MIN_TRACK_CONTRAST)
            if theme.contrast(tokens.canvas, tokens.surface) < MIN_ELEVATION_CONTRAST then
                tokens.canvas = separated(tokens.surface, MIN_ELEVATION_CONTRAST)
                theme.notice(notices, "info", "canvas was moved to keep panels elevated")
            end
            correctContrast(tokens, "text", tokens.surface, MIN_TEXT_CONTRAST, notices)
            correctContrast(tokens, "textMuted", tokens.surface, MIN_MUTED_CONTRAST, notices)
            correctContrast(tokens, "textFaint", tokens.surface, MIN_FAINT_CONTRAST, notices)
            for _, key in ipairs({ "cyan", "green", "amber", "orange", "blue" }) do
                correctAccent(tokens, key, tokens.surface, MIN_ACCENT_CONTRAST, notices)
            end
        end
    end

    local function blend(base, other, fraction)
        local br, bg, bb = channels(base)
        local orr, og, ob = channels(other)
        local keep = 1 - fraction
        return pack(br * keep + orr * fraction, bg * keep + og * fraction, bb * keep + ob * fraction)
    end

    function theme.alertSurface(tokens, accent, preferred, faintTextUsed, separation)
        local surface = tokens.surface

        local surfaceLum = luminance(surface)
        local canvasLum = luminance(tokens.canvas)
        local textLum = luminance(tokens.text)
        local mutedLum = luminance(tokens.textMuted)
        local faintLum = luminance(tokens.textFaint)
        local accentLum = luminance(accent)

        local function ratio(a, b)
            if a < b then
                a, b = b, a
            end
            return (a + 0.05) / (b + 0.05)
        end

        local function legible(candidateLum)
            return ratio(surfaceLum, candidateLum) >= (separation or MIN_TINT_SEPARATION)
                and ratio(canvasLum, candidateLum) >= (separation or MIN_ELEVATION_CONTRAST)
                and (faintTextUsed == false or ratio(candidateLum, faintLum) >= MIN_FAINT_CONTRAST)
                and ratio(candidateLum, accentLum) >= MIN_ACCENT_CONTRAST
                and ratio(candidateLum, mutedLum) >= MIN_MUTED_CONTRAST
                and ratio(candidateLum, textLum) >= MIN_TEXT_CONTRAST
        end

        if preferred and legible(luminance(preferred)) then
            return preferred
        end

        for _, fraction in ipairs({ 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40 }) do
            local mixed = blend(surface, accent, fraction)

            for _, amount in ipairs({ 0, -0.2, -0.35, -0.5, 0.15 }) do
                local candidate = amount == 0 and mixed or theme.shade(mixed, amount)
                local candidateLum = luminance(candidate)

                if legible(candidateLum) then
                    return candidate
                end
            end
        end

        return nil
    end

    local function toDisplay(tokens)
        local colors = {}
        for key, value in pairs(tokens) do
            colors[key] = lcd.RGB(value)
        end
        return colors
    end

    function theme.build(mode)
        if not catalog.themes["modern-dark"] then
            error("theme catalog is not configured")
        end
        local warnings = {}
        local notices = {}
        local requested = mode

        if type(mode) == "string" and string.match(mode, "^%s*$") then
            mode = nil
        end

        if mode ~= nil and not catalog.themes[mode] then
            warnings[#warnings + 1] = "unknown theme " .. tostring(mode)
            mode = nil
        end
        mode = mode or "modern-dark"

        local definition = catalog.themes[mode]
        local tokens = {}
        for key, value in pairs(definition.colors) do
            tokens[key] = value
        end
        local accent = definition.accent

        if definition.correctForContrast then
            enforceLegibility(tokens, notices)
        end
        for key, fallback in pairs(CHART_COLORS) do
            if tokens[key] and key ~= "chartGrid" and definition.correctForContrast then
                correctAccent(tokens, key, tokens.surface, MIN_TEXT_CONTRAST, notices)
            end
            tokens[key] = tokens[key] or tokens[fallback]
        end

        local separation = definition.tintSeparation or (definition.light and 1.08 or nil)
        local function alertSurface(accentColor, preferred, faintTextUsed)
            if not definition.correctForContrast and preferred ~= nil then
                return preferred
            end
            return theme.alertSurface(tokens, accentColor, preferred, faintTextUsed, separation)
        end
        local alertRgb = {
            warning = alertSurface(tokens.amber, definition.warningBg),
            critical = alertSurface(tokens.critical, definition.criticalBg),
            active = alertSurface(tokens.blue, definition.activeBg, false),
        }
        local alertColor = {}
        for name, value in pairs(alertRgb) do
            alertColor[name] = lcd.RGB(value)
        end
        for _, name in ipairs({ "warning", "critical", "active" }) do
            if not alertRgb[name] then
                theme.notice(notices, "warning", "no legible " .. name .. " tint; the panel keeps its resting surface")
            end
        end

        local colors = toDisplay(tokens)
        return {
            mode = mode,
            label = definition.label,
            light = definition.light == true,
            requested = requested,
            rgb = tokens,
            color = colors,
            chartColor = {
                cyan = colors.chartCyan,
                green = colors.chartGreen,
                amber = colors.chartAmber,
                orange = colors.chartOrange,
                grid = colors.chartGrid,
                flightBand = lcd.RGB(definition.light and 0x000000 or 0xFFFFFF),
            },
            alertRgb = alertRgb,
            alertColor = alertColor,
            spacing = definition.spacing,
            accent = accent,
            warnings = warnings,
            notices = notices,
        }
    end

    return theme
end
