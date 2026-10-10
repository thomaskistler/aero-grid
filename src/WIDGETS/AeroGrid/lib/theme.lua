-- SPDX-License-Identifier: GPL-2.0-only

--- Semantic theme tokens, theme modes, and state resolution.
--- The host owns every color. Panels receive resolved tokens and must not
--- define their own background palettes.

---@class AeroGridThemeTokens
---@field canvas integer
---@field surface integer
---@field surfaceRaised integer
---@field border integer
---@field track integer
---@field text integer
---@field textMuted integer
---@field textFaint integer
---@field cyan integer
---@field blue integer Active-flight indication.
---@field green integer
---@field amber integer
---@field orange integer
---@field critical integer

---@class AeroGridTheme
---@field mode string
---@field rgb AeroGridThemeTokens 24-bit values, kept for contrast math and tests.
---@field color table<string, integer> Display values produced by lcd.RGB.
---@field spacing table
---@field accent string Default semantic accent token name.
---@field warnings string[] Things the layout asked for that cannot be honoured.
---@field notices table[] `{severity, text}` records of the host adapting.

local typography, panelLayout = ...
assert(type(typography) == "table" and type(typography.install) == "function", "lib/typography.lua has no installer")
assert(
    type(panelLayout) == "table" and type(panelLayout.install) == "function",
    "lib/panel_layout.lua has no installer"
)

local theme = { RUNTIME_API = 1 }
local catalog = {}

--- Record something the host did on its own behalf, rather than a failure.
---
--- A contrast correction is the legibility pass doing its job, not a problem,
--- and reporting it as an error would put a permanent banner on the screen of
--- every radio using custom colors. Severity separates routine corrections
--- from invalid theme configuration.
---@param notices table[]
---@param severity "info"|"warning"
---@param text string
function theme.notice(notices, severity, text)
    notices[#notices + 1] = { severity = severity, text = text }
end

theme.MODES = {}

--- Accent tokens a panel may legitimately select.
--- Warning and freshness states override these, so `critical` is not selectable.
theme.ACCENTS = { cyan = true, green = true, amber = true, orange = true }

local COLOR_KEYS = {
    "canvas",
    "surface",
    "surfaceRaised",
    "border",
    "track",
    "text",
    "textMuted",
    "textFaint",
    "cyan",
    "blue",
    "green",
    "amber",
    "orange",
    "critical",
}
local SPACING_KEYS = {
    "outerMargin",
    "gutter",
    "padding",
    "paddingTight",
    "paddingRight",
    "paddingCompact",
    "radius",
    "accentWidth",
    "accentGap",
    "barHeight",
    "borderFocus",
}

--- Minimum acceptable contrast ratio between text and its surface.
local MIN_TEXT_CONTRAST = 4.5
--- Muted text may sit lower, but must stay clearly readable in flight.
local MIN_MUTED_CONTRAST = 3.0
--- Faint text is supporting detail, but must never vanish into the surface.
local MIN_FAINT_CONTRAST = 1.8
--- Accents and state colors must remain visible as shapes and badges.
local MIN_ACCENT_CONTRAST = 2.5
--- A track is read against the value drawn on it, so it must be seen. Panel
--- elevation may be subtle; a dial someone navigates by may not.
local MIN_TRACK_CONTRAST = 2.0
--- Separation between an alert's tinted panel and an untinted one beside it.
---
--- The same figure as the elevation floor, and for the same reason: a panel is
--- told apart from the screen at 1.30 and reads as a card, so a panel told
--- apart from its neighbour by as much reads as a different card. Below that
--- the tint is a colour cast nobody notices, which defeats the point of
--- tinting rather than outlining.
local MIN_TINT_SEPARATION = 1.30
--- Separation between the screen and a panel drawn on it.
---
--- This is a target rather than a floor in everything but name: panels carry
--- no resting outline, so the fill against the screen is the only thing that
--- says where one panel ends and the next begins. Custom palettes use the
--- same separation target as Modern Dark.
local MIN_ELEVATION_CONTRAST = 1.30
--- Separation between a panel and a raised surface drawn on it.
local MIN_RAISE_CONTRAST = 1.20

--- Split a 24-bit color into channels.
---@param rgb integer
---@return integer red
---@return integer green
---@return integer blue
local function channels(rgb)
    return math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
end

--- Combine channels into a 24-bit color, clamping each to the display range.
---@param red number
---@param green number
---@param blue number
---@return integer
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

--- Expand an EdgeTX RGB565 value into a 24-bit color.
--- Used to check palette contrast at the radio's color precision.
---@param value integer
---@return integer
function theme.fromRgb565(value)
    local red = math.floor(value / 2048) % 32
    local green = math.floor(value / 32) % 64
    local blue = value % 32

    return pack(red * 255 / 31, green * 255 / 63, blue * 255 / 31)
end

--- Relative luminance using the standard sRGB transfer function.
---@param rgb integer
---@return number
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

--- Contrast ratio between two colors, from 1 (identical) to 21.
---@param first integer
---@param second integer
---@return number
function theme.contrast(first, second)
    local a, b = luminance(first), luminance(second)
    if a < b then
        a, b = b, a
    end
    return (a + 0.05) / (b + 0.05)
end

--- Move a color toward white or black by a fraction.
---@param rgb integer
---@param amount number Positive lightens, negative darkens.
---@return integer
function theme.shade(rgb, amount)
    local red, green, blue = channels(rgb)
    local target = amount >= 0 and 255 or 0
    local ratio = amount >= 0 and amount or -amount

    return pack(red + (target - red) * ratio, green + (target - green) * ratio, blue + (target - blue) * ratio)
end

--- Report whether a value is a usable 24-bit color.
---@param value any
---@return boolean
local function isColor(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value == math.floor(value)
        and value >= 0
        and value <= 0xFFFFFF
end

--- Choose whichever of two candidates contrasts better with a background.
---@param background integer
---@param first integer
---@param second integer
---@return integer
local function betterContrast(background, first, second)
    if theme.contrast(background, first) >= theme.contrast(background, second) then
        return first
    end
    return second
end

--- Force a foreground token to a readable contrast against its surface.
--- A named palette can pair colors that are not legible together.
---@param tokens table
---@param key string
---@param background integer
---@param minimum number
---@param notices table[]
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

--- Find a color separated from a base by at least a minimum contrast ratio.
--- Both directions are tried, because a custom theme may be light or dark.
---@param base integer
---@param minimum number
---@return integer
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

--- Push a semantic color until it is legible on a background, keeping its hue.
---@param tokens table
---@param key string
---@param background integer
---@param minimum number
---@param notices table[]
local function correctAccent(tokens, key, background, minimum, notices)
    if theme.contrast(background, tokens[key]) >= minimum then
        return
    end

    -- Lighten on dark surfaces and darken on light ones so the hue survives.
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

--- Guarantee that a custom palette is structurally visible and legible.
--- Built-in palettes are exempt because their values are specified directly.
---@param tokens table
---@param notices table[]
local function enforceLegibility(tokens, notices)
    -- Structural separation: panels, elevation, and borders must be visible.
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

    -- Decorative accents may be nudged to stay visible on the panel surface.
    for _, key in ipairs({ "cyan", "green", "amber", "orange", "blue" }) do
        correctAccent(tokens, key, tokens.surface, MIN_ACCENT_CONTRAST, notices)
    end

    -- Critical red is never adjusted: an alarm must look the same on every
    -- radio. If the surface would swallow it, shift the surface's lightness
    -- instead, keeping its hue, since surface is a token we may choose.
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

        -- The surface moved, so everything measured against it must be rechecked.
        tokens.surfaceRaised = separated(tokens.surface, MIN_RAISE_CONTRAST)
        tokens.border = separated(tokens.surface, 1.25)
        tokens.track = separated(tokens.surface, MIN_TRACK_CONTRAST)
        -- Elevation included. The shift above answers only to critical red, so it
        -- can land next to the canvas and leave the panels invisible against the
        -- screen; the canvas moves rather than the surface, because moving the
        -- surface back is exactly what this branch just refused to do, and
        -- nothing but elevation is measured against the canvas.
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

--- Blend two colours, channel by channel.
---@param base integer
---@param other integer
---@param fraction number Amount of `other` to take.
---@return integer
local function blend(base, other, fraction)
    local br, bg, bb = channels(base)
    local orr, og, ob = channels(other)
    local keep = 1 - fraction
    return pack(br * keep + orr * fraction, bg * keep + og * fraction, bb * keep + ob * fraction)
end

--- Derive the tinted panel surface an alert state draws on.
---
--- Warning and critical colour the panel's field rather than its outline. Area
--- is seen in peripheral vision where a line is not, which is what a panel has
--- to do on a moving aircraft: an outline has to be looked at, a tinted field
--- is noticed while looking somewhere else.
---
--- The tint is mixed from the state's own accent rather than stated, so a
--- custom palette tints from its configured surface instead of
--- from a colour chosen against Modern Dark's. It is mixed by the smallest amount
--- that is actually noticeable beside an untinted panel, because every step
--- past that spends contrast the text drawn on it has to give back.
---
--- Every guarantee the resting surface carries is re-checked against the tint,
--- since none of them transfer: a surface is legible or not on its own terms,
--- and there was previously only ever one surface to check. The accent is in
--- that set and is the reason this can fail rather than merely compromise. A
--- critical panel carries a red accent and a red badge on what is now a red
--- field, and mush is the obvious outcome; it survives because the tint is
--- taken far darker than the accent rather than toward its lightness.
---@param tokens table Resolved 24-bit tokens.
---@param accent integer Accent this state draws, which the tint is mixed from.
---@param preferred? integer Preferred surface, subject to the same contrast guarantees.
---@param faintTextUsed? boolean False for states whose panels draw no faint supporting text.
---@param separation? number Built-in light theme's softer surface separation.
---@return integer? surface Nil when no tint satisfies the guarantees.
function theme.alertSurface(tokens, accent, preferred, faintTextUsed, separation)
    local surface = tokens.surface

    -- Each guarantee is a contrast ratio against a colour that does not change
    -- while the search runs, so their luminances are taken once rather than for
    -- every candidate. `theme.contrast` recomputes both sides on each call and
    -- luminance is three floating point powers, so measuring the naive way cost
    -- over seven hundred of them and put the loader's theme step 1600
    -- instructions up, on a budget of 20000. Measured, not guessed at.
    local surfaceLum = luminance(surface)
    local canvasLum = luminance(tokens.canvas)
    local textLum = luminance(tokens.text)
    local mutedLum = luminance(tokens.textMuted)
    local faintLum = luminance(tokens.textFaint)
    local accentLum = luminance(accent)

    --- Contrast between two already-measured luminances.
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

    -- Hue first, then lightness, and both directions of lightness.
    --
    -- On a mid-grey custom surface, lightening can erase text contrast.
    -- Darkening the same mix keeps the hue and opens that gap instead.
    for _, fraction in ipairs({ 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40 }) do
        local mixed = blend(surface, accent, fraction)

        for _, amount in ipairs({ 0, -0.2, -0.35, -0.5, 0.15 }) do
            local candidate = amount == 0 and mixed or theme.shade(mixed, amount)
            local candidateLum = luminance(candidate)

            -- Cheapest to fail first: a candidate too close to the resting surface
            -- is the common rejection, and testing it first skips the rest.
            if legible(candidateLum) then
                return candidate
            end
        end
    end

    -- Nothing satisfied every guarantee. The panel keeps its resting surface and
    -- says so through its accent and badge alone, which is worse than a tint and
    -- better than an illegible one.
    return nil
end

--- Validate complete named themes from the shared YAML catalog.
---@param document any
---@return table? validated
---@return string? error
function theme.validateCatalog(document)
    if type(document) ~= "table" or document.version ~= 1 then
        return nil, "theme catalog must have version 1"
    end
    if type(document.themes) ~= "table" or #document.themes == 0 then
        return nil, "theme catalog must have a non-empty theme sequence"
    end
    local count = 0
    for key in pairs(document.themes) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil, "theme catalog themes must be a sequence"
        end
        count = count + 1
    end
    if count ~= #document.themes then
        return nil, "theme catalog themes must be a contiguous sequence"
    end

    local validated = {}
    local names = {}
    local allowedFields = {
        version = true,
        name = true,
        label = true,
        accent = true,
        light = true,
        correctForContrast = true,
        colors = true,
        spacing = true,
        tintSeparation = true,
    }
    local colorFields, spacingFields = {}, {}
    for _, key in ipairs(COLOR_KEYS) do
        colorFields[key] = true
    end
    for _, key in ipairs({ "warningBg", "criticalBg", "activeBg" }) do
        colorFields[key] = true
    end
    for _, key in ipairs(SPACING_KEYS) do
        spacingFields[key] = true
    end
    for index, definition in ipairs(document.themes) do
        if type(definition) ~= "table" then
            return nil, "theme " .. index .. " must be a mapping"
        end
        local name = definition.name
        if type(name) ~= "string" or not string.match(name, "^[%w_-]+$") then
            return nil, "theme " .. index .. " has an invalid name"
        end
        if definition.version ~= 1 then
            return nil, "theme " .. name .. " must have version 1"
        end
        if validated[name] then
            return nil, "duplicate theme name " .. name
        end
        if type(definition.label) ~= "string" or definition.label == "" then
            return nil, "theme " .. name .. " must have a label"
        end
        for key in pairs(definition) do
            if not allowedFields[key] then
                return nil, "theme " .. name .. " has unknown field " .. tostring(key)
            end
        end
        if type(definition.colors) ~= "table" or type(definition.spacing) ~= "table" then
            return nil, "theme " .. name .. " must define colors and spacing mappings"
        end
        if not theme.ACCENTS[definition.accent] then
            return nil, "theme " .. name .. " has an invalid accent"
        end
        if definition.light ~= nil and type(definition.light) ~= "boolean" then
            return nil, "theme " .. name .. " light must be a boolean"
        end
        if definition.correctForContrast ~= nil and type(definition.correctForContrast) ~= "boolean" then
            return nil, "theme " .. name .. " correctForContrast must be a boolean"
        end

        local colors = {}
        for key in pairs(definition.colors) do
            if not colorFields[key] then
                return nil, "theme " .. name .. " has unknown color " .. tostring(key)
            end
        end
        for _, key in ipairs(COLOR_KEYS) do
            if not isColor(definition.colors[key]) then
                return nil, "theme " .. name .. " color " .. key .. " must be a 24-bit color"
            end
            colors[key] = definition.colors[key]
        end
        for _, key in ipairs({ "warningBg", "criticalBg", "activeBg" }) do
            if definition.colors[key] ~= nil and not isColor(definition.colors[key]) then
                return nil, "theme " .. name .. " color " .. key .. " must be a 24-bit color"
            end
            colors[key] = definition.colors[key]
        end
        local spacing = {}
        for key in pairs(definition.spacing) do
            if not spacingFields[key] then
                return nil, "theme " .. name .. " has unknown spacing " .. tostring(key)
            end
        end
        for _, key in ipairs(SPACING_KEYS) do
            local value = definition.spacing[key]
            if
                type(value) ~= "number"
                or value ~= value
                or value == math.huge
                or value == -math.huge
                or value < 0
                or value ~= math.floor(value)
            then
                return nil, "theme " .. name .. " spacing " .. key .. " must be a non-negative integer"
            end
            spacing[key] = value
        end
        if
            definition.tintSeparation ~= nil
            and (
                type(definition.tintSeparation) ~= "number"
                or definition.tintSeparation ~= definition.tintSeparation
                or definition.tintSeparation < 1
                or definition.tintSeparation == math.huge
            )
        then
            return nil, "theme " .. name .. " tintSeparation must be at least 1"
        end

        validated[name] = {
            label = definition.label,
            colors = colors,
            spacing = spacing,
            accent = definition.accent,
            light = definition.light == true,
            correctForContrast = definition.correctForContrast ~= false,
            warningBg = colors.warningBg,
            criticalBg = colors.criticalBg,
            activeBg = colors.activeBg,
            tintSeparation = definition.tintSeparation,
        }
        names[#names + 1] = { name = name, label = definition.label }
    end
    if not validated["modern-dark"] then
        return nil, "theme catalog must define the modern-dark theme"
    end
    return { themes = validated, names = names }
end

--- Install a validated catalog for theme resolution.
---@param document any
---@return boolean success
---@return string? error
function theme.setCatalog(document)
    local validated, err = theme.validateCatalog(document)
    if not validated then
        return false, err
    end
    catalog = validated
    theme.MODES = {}
    for name in pairs(catalog.themes) do
        theme.MODES[name] = true
    end
    return true
end

--- Convert a 24-bit token table into display values.
--- EdgeTX accepts a single packed argument and returns an RGB565 flag.
---@param tokens table
---@return table
local function toDisplay(tokens)
    local colors = {}
    for key, value in pairs(tokens) do
        colors[key] = lcd.RGB(value)
    end
    return colors
end

--- Resolve one complete named theme.
---@param mode? string Theme name selected in widget settings.
---@return AeroGridTheme
function theme.build(mode)
    if not catalog.themes["modern-dark"] then
        error("theme catalog is not configured")
    end
    local warnings = {}
    local notices = {}
    local requested = mode

    -- **An empty option is an unset option, not a wrong one.** A string widget
    -- option reaches a Lua widget as `option->deflt.stringValue`, and
    -- `LuaWidgetFactory::parseOptionDefaults` sets that default by calling
    -- `.clear()` on it (`lua/lua_widget_factory.cpp`), so an option the user
    -- has never touched arrives as the empty string. It is pushed to Lua
    -- unconditionally with `lua_pushstring(..., stringValue.c_str())`, so
    -- there is no `nil` to distinguish "unset" from "set to nothing" -- the
    -- firmware has no representation for the difference and neither can we.
    --
    -- Warning about it put red diagnostic text across the dashboard of
    -- everyone who added this widget and left its settings alone, which is
    -- every first run.
    --
    -- Whitespace goes the same way, because a name typed and then cleared can
    -- leave a space behind and the user has no way to see the difference.
    -- **A mode that is genuinely a name and genuinely not ours still warns**,
    -- which is the whole value of the warning: `nonsense` is someone's typo or
    -- a theme we removed, and both are worth saying.
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

    -- Alert tints come last, after the legibility pass has finished moving the
    -- surface about. That ordering is load bearing: the pass shifts the surface
    -- to keep critical red visible and then re-derives everything measured
    -- against it, so a tint mixed earlier would be mixed from a surface that no
    -- longer exists.
    local separation = definition.tintSeparation or (definition.light and 1.08 or nil)
    local alertRgb = {
        warning = theme.alertSurface(tokens, tokens.amber, definition.warningBg, nil, separation),
        critical = theme.alertSurface(tokens, tokens.critical, definition.criticalBg, nil, separation),
        active = theme.alertSurface(tokens, tokens.blue, definition.activeBg, false, separation),
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

    return {
        mode = mode,
        label = definition.label,
        requested = requested,
        rgb = tokens,
        color = toDisplay(tokens),
        -- Kept apart from `color` because these are per state rather than per
        -- token, and mirrored in 24-bit so contrast arithmetic has values it can
        -- actually work on.
        alertRgb = alertRgb,
        alertColor = alertColor,
        spacing = definition.spacing,
        accent = accent,
        warnings = warnings,
        notices = notices,
    }
end

--- Return the display color for a semantic accent name.
---@param resolved AeroGridTheme
---@param name? string
---@return integer color
function theme.accentColor(resolved, name)
    if not theme.ACCENTS[name] then
        name = resolved.accent
    end
    return resolved.color[name]
end

--- Resolve a panel state into concrete presentation values.
--- Warning, critical, stale, and unavailable states deliberately override a
--- panel's decorative accent, and each carries a text badge because color
--- alone is not sufficient to communicate state.
---
--- A resting panel carries no outline. Its fill against the darker screen is
--- what makes it a panel, so an outline on top of that is a second answer to a
--- question already answered.
---
--- The two kinds of thing a panel has to say are then kept apart, and said by
--- different means. **The fill is a condition of the data** and **the outline
--- is where the interaction is.** A warning or a critical reading tints the
--- panel's field, which is seen in peripheral vision where a line is not;
--- selection and editing draw the outline and are the only things that do.
--- Before this the border carried both at once, so a panel could not be
--- alarming and focused at the same time without one meaning overwriting the
--- other.
---
--- Stale and unavailable are deliberately in neither group. They dim rather
--- than colour, because absent data is not an alarm and a panel that shouted
--- every time a sensor went quiet would teach a pilot to ignore it.
---@param resolved AeroGridTheme
---@param state? string
---@param accentName? string
---@return table presentation
function theme.state(resolved, state, accentName)
    local color = resolved.color
    local presentation = {
        state = state or "normal",
        accent = theme.accentColor(resolved, accentName),
        value = color.text,
        label = color.textMuted,
        border = color.border,
        borderWidth = 0,
        badge = nil,
        dim = false,
    }

    if state == "selected" then
        presentation.border = color.cyan
        presentation.borderWidth = resolved.spacing.borderFocus
    elseif state == "stale" then
        -- Freshness overrides the decorative accent: stale data must not look healthy.
        presentation.accent = color.textFaint
        presentation.value = color.textMuted
        presentation.label = color.textFaint
        presentation.badge = theme.BADGES.stale
        presentation.dim = true
    elseif state == "active" then
        presentation.accent = color.blue
        presentation.surface = resolved.alertColor.active
        presentation.badge = "IN-FLIGHT"
    elseif state == "warning" then
        -- The field carries the alarm, not the frame. `borderWidth` stays zero, so
        -- the panel draws no outline and the border keeps one meaning.
        presentation.accent = color.amber
        presentation.surface = resolved.alertColor.warning
        presentation.badge = theme.BADGES.warning
    elseif state == "critical" then
        presentation.accent = color.critical
        presentation.surface = resolved.alertColor.critical
        presentation.value = color.text
        presentation.badge = theme.BADGES.critical
    elseif state == "unavailable" then
        presentation.accent = color.textFaint
        presentation.value = color.textFaint
        presentation.label = color.textFaint
        presentation.badge = theme.BADGES.unavailable
        presentation.dim = true
    elseif state == "editing" then
        presentation.border = color.cyan
        presentation.borderWidth = resolved.spacing.borderFocus
        presentation.badge = theme.BADGES.editing
    end

    return presentation
end

--- Expose the Modern palette for tests and documentation.
---@return table
function theme.modernDark()
    local copy = {}
    for key, value in pairs(catalog.themes["modern-dark"].colors) do
        copy[key] = value
    end
    return copy
end

typography.install(theme)
panelLayout.install(theme)

return theme
