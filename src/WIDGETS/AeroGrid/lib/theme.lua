-- SPDX-License-Identifier: GPL-2.0-only

--- Semantic theme tokens, theme modes, and state resolution.
--- The host owns every color. Components receive resolved tokens and must not
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
---@field green integer
---@field amber integer
---@field orange integer
---@field critical integer

---@class AeroGridTheme
---@field mode "modern"|"edgetx"|"custom"
---@field rgb AeroGridThemeTokens 24-bit values, kept for contrast math and tests.
---@field color table<string, integer> Display values produced by lcd.RGB.
---@field spacing table
---@field accent string Default semantic accent token name.
---@field warnings string[] Things the layout asked for that cannot be honoured.
---@field notices table[] `{severity, text}` records of the host adapting.

local theme = {}

--- Badge column width per font, since typography varies by span.
local badgeWidths = {}

--- Record something the host did on its own behalf, rather than a failure.
---
--- A contrast correction is the legibility pass doing its job, not a problem,
--- and reporting it as an error would put a permanent banner on the screen of
--- every radio using a derived palette. Severity separates a routine
--- adjustment from the radio refusing to answer at all, which is still not a
--- failure but is worth knowing about.
---@param notices table[]
---@param severity "info"|"warning"
---@param text string
function theme.notice(notices, severity, text)
  notices[#notices + 1] = {severity = severity, text = text}
end

--- The designed instrument palette from the project specification.
---
--- Panels are defined by their fill against a darker screen, not by an
--- outline, so the separation between `canvas` and `surface` is the whole of
--- the dashboard's structure and has to be seen from arm's length. The
--- original pairing measured 1.122, which reads as one flat dark field with
--- faint boxes drawn on it. The elevation is now 1.316, reached from both
--- ends: the screen was deepened as well as the panel lifted, because
--- deepening costs nothing elsewhere while lifting the panel spends contrast
--- that every token measured against it has to give up.
---
--- `track` moved with the surface deliberately. It is read against the fill
--- drawn on top of it, and it would otherwise have fallen through the 2.0
--- floor the moment the panel was lifted.
local MODERN = {
  canvas = 0x0A0C0E,
  surface = 0x212830,
  surfaceRaised = 0x2E3841,
  border = 0x3A434B,
  track = 0x545F6A,
  text = 0xF4F6F7,
  textMuted = 0xA7B0B6,
  textFaint = 0x69737A,
  cyan = 0x70D6F3,
  green = 0x55D990,
  amber = 0xF2B84B,
  orange = 0xFF762E,
  critical = 0xF05252,
}

theme.MODES = {modern = true, edgetx = true, custom = true}

--- Accent tokens a component may legitimately select.
--- Warning and freshness states override these, so `critical` is not selectable.
theme.ACCENTS = {cyan = true, green = true, amber = true, orange = true}

--- Custom mode may only override this small set of global roles.
theme.CUSTOM_KEYS = {canvas = true, surface = true, text = true, accent = true}

--- Shared spacing baseline at 480 x 272, subject to hardware verification.
---
--- The accent stripe is a rounded pill inset from the panel's top and bottom
--- rather than a full-height bar. A bar running the whole height meets the
--- panel's own rounded corners exactly where both are curving, and the two
--- radii fight: the stripe's square shoulder sits outside the corner arc. The
--- inset is the corner radius, which is where the panel's left edge becomes
--- straight, so the pill only ever runs alongside a straight edge.
local SPACING = {
  outerMargin = 4,
  gutter = 4,
  padding = 8,
  --- Horizontal padding on a panel too short for the standard vertical rhythm.
  --- It is not smaller than the standard padding, despite the name of the case
  --- it serves: the accent stripe occupies the left edge, and content starting
  --- at the stripe's own right edge reads as crowded against it. The floor is
  --- `accentWidth + accentGap`, which a test pins at every span.
  paddingTight = 8,
  --- Right-hand margin. Deliberately smaller than the left padding: the left
  --- exists to clear the accent, and the right has nothing to clear. Making
  --- them equal spent four pixels of every panel on symmetry, which on a
  --- single cell is the difference between a four-character header label and
  --- a three-character one.
  paddingRight = 4,
  paddingCompact = 6,
  radius = 8,
  accentWidth = 4,
  --- Clear space between the accent stripe and the content beside it.
  accentGap = 4,
  barHeight = 4,
  borderFocus = 2,
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
--- says where one panel ends and the next begins. It matches what Modern's own
--- pairing achieves, because a derived palette sitting at the old 1.10 looked
--- flat next to Modern on the same radio one page apart.
local MIN_ELEVATION_CONTRAST = 1.30
--- Separation between a panel and a raised surface drawn on it.
local MIN_RAISE_CONTRAST = 1.20

--- Split a 24-bit color into channels.
---@param rgb integer
---@return integer red
---@return integer green
---@return integer blue
local function channels(rgb)
  return math.floor(rgb / 65536) % 256,
    math.floor(rgb / 256) % 256,
    rgb % 256
end

--- Combine channels into a 24-bit color, clamping each to the display range.
---@param red number
---@param green number
---@param blue number
---@return integer
local function pack(red, green, blue)
  local function clamp(value)
    value = math.floor(value + 0.5)
    if value < 0 then return 0 end
    if value > 255 then return 255 end
    return value
  end
  return clamp(red) * 65536 + clamp(green) * 256 + clamp(blue)
end

--- Expand an EdgeTX RGB565 value into a 24-bit color.
--- `lcd.getColor()` returns RGB565, so theme derivation must widen it first.
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
    if value <= 0.03928 then return value / 12.92 end
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
  if a < b then a, b = b, a end
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

  return pack(
    red + (target - red) * ratio,
    green + (target - green) * ratio,
    blue + (target - blue) * ratio)
end

--- Report whether a value is a usable 24-bit color.
---@param value any
---@return boolean
local function isColor(value)
  return type(value) == "number"
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
--- Derived EdgeTX themes frequently pair colors that are legible on the radio's
--- own light surfaces but not on the dashboard's dark instrument panels.
---@param tokens table
---@param key string
---@param background integer
---@param minimum number
---@param notices table[]
local function correctContrast(tokens, key, background, minimum, notices)
  if theme.contrast(background, tokens[key]) >= minimum then return end

  local candidate = betterContrast(background, MODERN[key], theme.shade(background, 0.85))
  if theme.contrast(background, candidate) < minimum then
    candidate = betterContrast(background, 0xFFFFFF, 0x000000)
  end

  tokens[key] = candidate
  theme.notice(notices, "info", key .. " was corrected for contrast")
end

--- Find a color separated from a base by at least a minimum contrast ratio.
--- Both directions are tried, because a derived theme may be light or dark.
---@param base integer
---@param minimum number
---@return integer
local function separated(base, minimum)
  for _, amount in ipairs({0.08, 0.16, 0.24, 0.36, 0.5, 0.7}) do
    local lighter = theme.shade(base, amount)
    if theme.contrast(base, lighter) >= minimum then return lighter end

    local darker = theme.shade(base, -amount)
    if theme.contrast(base, darker) >= minimum then return darker end
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
  if theme.contrast(background, tokens[key]) >= minimum then return end

  -- Lighten on dark surfaces and darken on light ones so the hue survives.
  local direction = luminance(background) < 0.18 and 1 or -1
  for _, amount in ipairs({0.2, 0.35, 0.5, 0.65, 0.8}) do
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

--- Guarantee that a derived palette is structurally visible and legible.
--- Modern is exempt because its values are specified directly.
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
  for _, key in ipairs({"cyan", "green", "amber", "orange"}) do
    correctAccent(tokens, key, tokens.surface, MIN_ACCENT_CONTRAST, notices)
  end

  -- Critical red is never adjusted: an alarm must look the same on every
  -- radio. If the surface would swallow it, shift the surface's lightness
  -- instead, keeping its hue, since surface is a token we may choose.
  if theme.contrast(tokens.surface, tokens.critical) < MIN_ACCENT_CONTRAST then
    local replacement = betterContrast(tokens.critical, 0x000000, 0xFFFFFF)

    for _, amount in ipairs({0.1, 0.2, 0.3, 0.45, 0.6, 0.75, 0.9}) do
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
    for _, key in ipairs({"cyan", "green", "amber", "orange"}) do
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
  return pack(br * keep + orr * fraction, bg * keep + og * fraction,
    bb * keep + ob * fraction)
end

--- Derive the tinted panel surface an alert state draws on.
---
--- Warning and critical colour the panel's field rather than its outline. Area
--- is seen in peripheral vision where a line is not, which is what a panel has
--- to do on a moving aircraft: an outline has to be looked at, a tinted field
--- is noticed while looking somewhere else.
---
--- The tint is mixed from the state's own accent rather than stated, so a
--- derived palette tints from whatever surface the radio gave it instead of
--- from a colour chosen against Modern's. It is mixed by the smallest amount
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
---@return integer? surface Nil when no tint satisfies the guarantees.
function theme.alertSurface(tokens, accent)
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
    if a < b then a, b = b, a end
    return (a + 0.05) / (b + 0.05)
  end

  -- Hue first, then lightness, and both directions of lightness.
  --
  -- Mixing alone is only enough on a dark surface. Modern's panel is very
  -- dark, so taking it toward a bright accent lightens it and every guarantee
  -- survives. A palette derived from a radio whose own surface is mid grey
  -- behaves oppositely: lightening closes the gap to the muted and faint text
  -- drawn on it, and the EdgeTX default leaves faint at 1.99 against a floor
  -- of 1.8 before anything is tinted at all, so there is no room to lighten.
  -- Darkening the same mix keeps the hue and opens that gap instead.
  for _, fraction in ipairs({0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40}) do
    local mixed = blend(surface, accent, fraction)

    for _, amount in ipairs({0, -0.2, -0.35, -0.5, 0.15}) do
      local candidate = amount == 0 and mixed or theme.shade(mixed, amount)
      local candidateLum = luminance(candidate)

      -- Cheapest to fail first: a candidate too close to the resting surface
      -- is the common rejection, and testing it first skips the rest.
      if ratio(surfaceLum, candidateLum) >= MIN_TINT_SEPARATION
          and ratio(canvasLum, candidateLum) >= MIN_ELEVATION_CONTRAST
          and ratio(candidateLum, faintLum) >= MIN_FAINT_CONTRAST
          and ratio(candidateLum, accentLum) >= MIN_ACCENT_CONTRAST
          and ratio(candidateLum, mutedLum) >= MIN_MUTED_CONTRAST
          and ratio(candidateLum, textLum) >= MIN_TEXT_CONTRAST then
        return candidate
      end
    end
  end

  -- Nothing satisfied every guarantee. The panel keeps its resting surface and
  -- says so through its accent and badge alone, which is worse than a tint and
  -- better than an illegible one.
  return nil
end

--- Read one EdgeTX theme role and widen it to 24-bit.
---@param env table Resolved EdgeTX environment.
---@param role any Value of a COLOR_THEME_* constant.
---@return integer? color
--- Extract the RGB565 payload from an EdgeTX colour flag word.
---
--- `lcd.getColor` does not return a bare RGB565. `luaLcdGetColor` returns
--- `colorToRGB(flags) & (COLOR_MASK(~0u) | RGB_FLAG)`, and the colour lives in
--- the upper half: `COLOR_VAL(flags)` is `flags >> 16`, with `RGB_FLAG`
--- (`0x8000`) set in the lower half. Reading the low 16 bits instead leaves
--- red 16, green 0 and blue 0 for every role of every theme, which drew every
--- panel on the dashboard in a dark red belonging to no EdgeTX theme at all.
---@param flags integer
---@return integer rgb565
local function colorValue(flags)
  return math.floor(flags / 65536) % 65536
end

local function readRole(env, role)
  if type(role) ~= "number" then return nil end

  local ok, value = pcall(env.getColor, role)
  if not ok or type(value) ~= "number" then return nil end

  return theme.fromRgb565(colorValue(value))
end

--- Collect the EdgeTX color environment, allowing tests to inject one.
---@param env? table
---@return table? resolved
local function resolveEnv(env)
  env = env or {}
  local getColor = env.getColor
  if getColor == nil and type(lcd) == "table" then getColor = lcd.getColor end
  if type(getColor) ~= "function" then return nil end

  local roles = env.roles or {
    primary1 = COLOR_THEME_PRIMARY1,
    primary2 = COLOR_THEME_PRIMARY2,
    primary3 = COLOR_THEME_PRIMARY3,
    secondary1 = COLOR_THEME_SECONDARY1,
    secondary2 = COLOR_THEME_SECONDARY2,
    secondary3 = COLOR_THEME_SECONDARY3,
    focus = COLOR_THEME_FOCUS,
    edit = COLOR_THEME_EDIT,
    active = COLOR_THEME_ACTIVE,
    warning = COLOR_THEME_WARNING,
    disabled = COLOR_THEME_DISABLED,
  }

  return {getColor = getColor, roles = roles}
end

--- Derive dashboard tokens from the active EdgeTX theme.
--- Roles without a suitable EdgeTX equivalent keep their Modern values, and
--- critical red stays dashboard-controlled so alarms remain recognizable.
---@param notices table[]
---@param env? table
---@return table tokens
local function deriveFromEdgeTx(notices, env)
  local resolved = resolveEnv(env)
  local tokens = {}
  for key, value in pairs(MODERN) do tokens[key] = value end

  if not resolved then
    theme.notice(notices, "warning",
      "EdgeTX colors unavailable; using Modern palette")
    return tokens
  end

  -- Structure follows the radio; meaning does not.
  --
  -- EdgeTX's roles are menu chrome, and their names do not describe their
  -- colours. In the shipped EdgeTX Default theme `ACTIVE` is yellow, `EDIT` is
  -- green and `WARNING` is red, so mapping our accents onto them by name
  -- scrambled every semantic on the dashboard: healthy read as caution, and a
  -- warning was rendered in a red indistinguishable from critical. A pilot
  -- cannot be asked to relearn what a colour means per radio theme, so the
  -- accents stay exactly as Modern defines them and only the surfaces and text
  -- follow the radio.
  local roles = resolved.roles
  local mapping = {
    canvas = roles.secondary1,
    surface = roles.secondary1,
    border = roles.primary3,
    text = roles.primary2,
    textMuted = roles.primary3,
    textFaint = roles.disabled,
  }

  local found = false
  for key, role in pairs(mapping) do
    local color = readRole(resolved, role)
    if color then
      tokens[key] = color
      found = true
    end
  end

  if not found then
    theme.notice(notices, "warning",
      "EdgeTX theme roles unreadable; using Modern palette")
    return tokens
  end

  return tokens
end

--- Apply the limited custom override set over the Modern palette.
---@param overrides any
---@param warnings string[]
---@return table tokens
---@return string accent
local function applyCustom(overrides, warnings)
  local tokens = {}
  for key, value in pairs(MODERN) do tokens[key] = value end
  local accent = "cyan"

  if overrides ~= nil and type(overrides) ~= "table" then
    warnings[#warnings + 1] = "theme overrides must be a mapping"
    return tokens, accent
  end

  for key, value in pairs(overrides or {}) do
    if not theme.CUSTOM_KEYS[key] then
      warnings[#warnings + 1] = "theme override " .. tostring(key) .. " is not customizable"
    elseif key == "accent" then
      if theme.ACCENTS[value] then
        accent = value
      else
        warnings[#warnings + 1] = "theme accent " .. tostring(value) .. " is not a semantic accent"
      end
    elseif isColor(value) then
      tokens[key] = value
    else
      warnings[#warnings + 1] = "theme override " .. key .. " must be a 24-bit color"
    end
  end

  -- Overridden surfaces can easily break the default text and accent tokens.
  return tokens, accent
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

--- Resolve the active theme.
---
--- Two outcomes are kept apart. A warning is something the layout or the
--- widget option asked for that cannot be honoured, such as a theme mode that
--- does not exist or an override key that is not customizable: an authoring
--- mistake whose author needs to see it. A notice is the host adapting exactly
--- as designed, such as the legibility pass nudging a token, or the radio
--- declining to hand over its palette.
---@param mode? string One of modern, edgetx, or custom.
---@param overrides? table Custom mode overrides.
---@param env? table Optional injected EdgeTX color environment.
---@return AeroGridTheme
function theme.build(mode, overrides, env)
  local warnings = {}
  local notices = {}
  local accent = "cyan"
  local tokens

  -- What was asked for, kept apart from what was settled on. A mode this
  -- does not have falls back to Modern, and the result then reports `modern`
  -- as though that is what the layout said, so the fallback is invisible in
  -- the mode alone. The diagnostics view reads this.
  local requested = mode
  if mode ~= nil and not theme.MODES[mode] then
    warnings[#warnings + 1] = "unknown theme mode " .. tostring(mode)
    mode = nil
  end
  mode = mode or "modern"

  if mode == "edgetx" then
    tokens = deriveFromEdgeTx(notices, env)
  elseif mode == "custom" then
    tokens, accent = applyCustom(overrides, warnings)
  else
    tokens = {}
    for key, value in pairs(MODERN) do tokens[key] = value end
  end

  -- Critical red is never theme-derived so alarms stay recognizable.
  tokens.critical = MODERN.critical

  -- Derived palettes are guaranteed legible; Modern is specified directly.
  if mode ~= "modern" then
    enforceLegibility(tokens, notices)
  end

  -- Alert tints come last, after the legibility pass has finished moving the
  -- surface about. That ordering is load bearing: the pass shifts the surface
  -- to keep critical red visible and then re-derives everything measured
  -- against it, so a tint mixed earlier would be mixed from a surface that no
  -- longer exists.
  local alertRgb = {
    warning = theme.alertSurface(tokens, tokens.amber),
    critical = theme.alertSurface(tokens, tokens.critical),
  }
  local alertColor = {}
  for name, value in pairs(alertRgb) do alertColor[name] = lcd.RGB(value) end
  for _, name in ipairs({"warning", "critical"}) do
    if not alertRgb[name] then
      theme.notice(notices, "warning",
        "no legible " .. name .. " tint; the panel keeps its resting surface")
    end
  end

  return {
    mode = mode,
    requested = requested,
    rgb = tokens,
    color = toDisplay(tokens),
    -- Kept apart from `color` because these are per state rather than per
    -- token, and mirrored in 24-bit so contrast arithmetic has values it can
    -- actually work on.
    alertRgb = alertRgb,
    alertColor = alertColor,
    spacing = SPACING,
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
  if not theme.ACCENTS[name] then name = resolved.accent end
  return resolved.color[name]
end

--- Line heights of EdgeTX's 480 x 272 "std" font set, in pixels.
--- Other display classes ship shorter or taller sets, so these are a
--- calibrated approximation; callers must still clamp content to the panel.
---@param font any One of the EdgeTX size constants.
---@return integer
function theme.fontHeight(font)
  if font == XXLSIZE then return 69 end
  if font == DBLSIZE then return 40 end
  if font == MIDSIZE then return 29 end
  if font == SMLSIZE then return 17 end
  if font == TINSIZE then return 12 end
  return 21
end

--- Choose the largest primary font whose line height fits the space available.
--- The specification asks for the largest value that fits at every span, which
--- depends on the panel's real height rather than on its cell count alone.
---@param available integer Vertical pixels the value may occupy.
---@return any font
function theme.fitPrimary(available)
  local ordered = {XXLSIZE, DBLSIZE, MIDSIZE, SMLSIZE}

  for _, font in ipairs(ordered) do
    if theme.fontHeight(font) <= available then return font end
  end

  return SMLSIZE
end

--- Mean character advance as a fraction of a font's line height.
--- EdgeTX's fonts are proportional and the Lua API offers no text measurement
--- outside a draw callback, so width has to be estimated. The ratio is
--- deliberately generous: overestimating shrinks a reading that would have
--- fit, while underestimating clips it, and the specification requires text to
--- abbreviate or reduce before it clips.
local ADVANCE_RATIO = 0.58

--- Estimate the rendered width of a string in a given font.
---@param font any
---@param text any
---@return integer
function theme.textWidth(font, text)
  local length = #tostring(text == nil and "" or text)
  return math.floor(length * theme.fontHeight(font) * ADVANCE_RATIO + 0.5)
end

--- Choose the largest font in which a string fits both a width and a height.
--- `fitPrimary` only answers the vertical question, which leaves a long value
--- in a narrow cell overflowing sideways. Callers pass the widest string the
--- component can ever display, not the current one, so the chosen size stays
--- stable as values change.
---@param text any Widest string the caller will render.
---@param width integer Horizontal pixels available.
---@param height integer Vertical pixels available.
---@return any font
function theme.fitText(text, width, height)
  local ordered = {XXLSIZE, DBLSIZE, MIDSIZE, SMLSIZE}

  for _, font in ipairs(ordered) do
    if theme.fontHeight(font) <= height and theme.textWidth(font, text) <= width then
      return font
    end
  end

  return SMLSIZE
end

--- Decide what a panel of this size carries, and how large its reading is.
---
--- Every component used to answer this for itself, with a private copy of the
--- same ladder: reserve the supporting rows I want, shed them if the reading
--- gets uncomfortable, then fit the reading to what is left. Eight copies,
--- and two panels of identical size disagreed because each had shed a
--- different amount and then measured a different string against the result.
--- At `2 x 2` the four panels of the span gallery landed on four different
--- fonts, a range of four to one, on panels the same size to the pixel.
---
--- So composition is decided here, from the panel's box alone, and is the same
--- answer for every component of that size. A component asks whether it has a
--- supporting row and a visualization; it does not decide.
---
--- The reading then takes what the composition leaves. Deciding the font from
--- the box rather than from the string is what makes two panels of one size
--- agree, because they are answering the same question.
---@param resolved AeroGridTheme
---@param rect AeroGridRect
---@param frame table Result of theme.frame.
---@return table ladder `{rows, visual, room}`
function theme.ladder(resolved, rect, frame)
  local spacing = resolved.spacing
  local rowHeight = frame.labelHeight + 2
  local barHeight = spacing.barHeight + 2
  local fixed = frame.top + frame.bottom

  -- Granted in order of what a panel loses least by dropping. A visualization
  -- is a shape and survives being small; a supporting row is text and does
  -- not, so the row is the first thing a short panel gives up.
  local visual = fixed + barHeight + theme.fontHeight(SMLSIZE) <= rect.h
  local used = fixed + (visual and barHeight or 0)
  local rows = used + rowHeight + theme.fontHeight(MIDSIZE) <= rect.h and 1 or 0

  return {
    rows = rows,
    visual = visual,
    room = math.max(1, rect.h - used - rows * rowHeight),
  }
end

--- Choose the font and the wording a reading is drawn in.
---
--- The forms are offered longest first and are all derived from the widest
--- value the component can ever print, never from the current one, so a
--- reading does not resize or reword as it changes.
---
--- **A form may drop redundancy, never magnitude.** A unit the panel's own
--- label already states, a name, a suffix: those are abbreviation. A digit of
--- precision, or a field of a clock, is not. `4.44V` to `4.44` removes
--- something the panel says elsewhere; `1:04:12` to `04:12` removes an hour
--- and reports a different reading, which no font size is worth. Callers
--- therefore offer only lossless forms, and where the shortest of them still
--- will not fit, the font steps down instead.
---
--- One step is the intent, and it is what happens almost everywhere: a
--- reading two sizes below its neighbours is the disagreement this exists to
--- remove. It is not a cap, because the alternative to stepping again is
--- clipping, and the specification is explicit that text reduces to a smaller
--- font before it clips. A panel that needs two steps is telling us its
--- column is genuinely too narrow for the reading, which happens where a dial
--- takes half the width, and a smaller number is better than half a number.
---@param forms string[] Lossless wordings, longest first.
---@param width integer Pixels available.
---@param room integer Vertical pixels the composition left.
---@return any font
---@return integer index Form chosen, from 1.
function theme.fitReading(forms, width, room)
  local ordered = {XXLSIZE, DBLSIZE, MIDSIZE, SMLSIZE}
  local start = #ordered

  for index = 1, #ordered do
    if theme.fontHeight(ordered[index]) <= room then start = index break end
  end

  -- The target the box allows, then down until something fits.
  for step = start, #ordered do
    for index = 1, #forms do
      if theme.textWidth(ordered[step], forms[index]) <= width then
        return ordered[step], index
      end
    end
  end

  return ordered[#ordered], #forms
end

--- Fit a heading to its column, stepping the font down rather than wrapping.
---
--- A Lua label is `lv_label_create` with a font style and nothing else
--- (`etx_label_create`, `gui/colorlcd/libui/etx_lv_theme.cpp`), so its long
--- mode is LVGL's default, which `lv_label_constructor` sets to
--- `LV_LABEL_LONG_WRAP`. A height of zero is not zero either:
--- `LvglSimpleWidgetObject::parseParam` turns it into `LV_SIZE_CONTENT`. So a
--- heading wider than its column **wrapped and grew downward over the
--- reading**: `TRANSMITTER` in a single cell's 52 pixel column took three
--- lines and 51 pixels of a 65 pixel panel. Nothing about the text changed,
--- so no assertion about what a label says could see it.
---
--- Lua cannot call `lv_label_set_long_mode`, so clipping and dots are not
--- available to choose. The levers are the text, the width and the font, and
--- of those only the font is free: a heading is a name the layout author
--- chose, and shortening `TRANSMITTER` to `TRANS` is the same loss of
--- identity as `ACROTRAINER` to `ACRO`.
---
--- So the font steps down first, which costs nothing. Where even the smallest
--- font cannot fit the name, it is cut to what fits **and the caller is told
--- what was dropped**, so the author can choose a shorter heading. Being told
--- is what makes it an abbreviation rather than a quiet corruption.
---@param text any
---@param width? integer Column available; nil or zero fits nothing.
---@param font any Preferred font, stepped down from.
---@return string text Text that fits.
---@return any font Font it fits at.
---@return string? dropped Full text, when it had to be cut.
function theme.fitHeading(text, width, font)
  local wanted = string.upper(tostring(text == nil and "" or text))
  if wanted == "" then return wanted, font end
  if type(width) ~= "number" or width <= 0 then return wanted, font end

  -- The overwhelmingly common case, and the one every panel pays for at
  -- build: a short heading at the font the panel already chose. Answered
  -- before any ladder is built, because building one to discard it is a cost
  -- every component pays for the rare heading that needs it.
  if theme.textWidth(font, wanted) <= width then return wanted, font end

  local ladder = {}
  local height = theme.fontHeight(font)
  for _, candidate in ipairs({SMLSIZE, TINSIZE}) do
    if theme.fontHeight(candidate) < height then
      ladder[#ladder + 1] = candidate
    end
  end
  if #ladder == 0 then ladder[1] = font end

  for _, candidate in ipairs(ladder) do
    if theme.textWidth(candidate, wanted) <= width then
      return wanted, candidate
    end
  end

  -- Nothing fits. Cut to the smallest font's capacity rather than wrapping
  -- over the reading, and hand back what was lost so it can be reported.
  local smallest = ladder[#ladder]
  local advance = math.max(1, theme.textWidth(smallest, "M"))
  local room = math.max(1, math.floor(width / advance))
  return string.sub(wanted, 1, room), smallest, wanted
end

--- Choose the longest of several wordings that fits a width.
---
--- Supporting rows were the one place nothing was fitted. The dominant reading
--- goes through `fitText` in every component; a supporting row went through
--- nothing at all, so `16.4V PACK` was drawn into 48 pixels of a panel that
--- needed 99, and `BRG 009 N` into 38 of 89. A row cannot shrink its font the
--- way a reading can, because it is already the smallest the dashboard uses,
--- so the only thing left to vary is the words.
---
--- `navigation` already did this for one of its two captions, with a private
--- ladder of phrasings. This is that, shared, so a component says what it
--- means at a length it has room for rather than clipping mid-word.
---
--- The last variant is returned when none fits: it is the shortest the caller
--- offered, and a caller wanting a guaranteed fit ends its list with something
--- very short.
---@param variants string[] Wordings, longest first.
---@param font any
---@param width? integer Pixels available; nil returns the longest wording.
---@return string
function theme.fitLabel(variants, font, width)
  if type(width) ~= "number" then return variants[1] end

  for index = 1, #variants do
    if theme.textWidth(font, variants[index]) <= width then
      return variants[index]
    end
  end

  return variants[#variants]
end

--- Every badge the dashboard may print, and the whole of that vocabulary.
---
--- A closed set, and a short one, because the badge column is reserved on
--- every panel whether or not a badge is showing. Its width is whatever the
--- longest word needs, so a long word is not paid for by the state that uses
--- it; it is paid for by every header on the dashboard.
---
--- The set had grown to thirteen strings, nine of which did not fit the 56 px
--- the column reserved. `NO SOURCE` is the theme's own default for an
--- unavailable panel, needed 89 px, and was therefore clipped on every panel
--- at every span. Widening the column to 89 px would have fixed that by
--- taking the width out of the header label instead, which on a single cell
--- had about four characters to give.
---
--- So the vocabulary was cut rather than the column widened, to one rule:
--- **a badge names the state, and the panel's supporting row says why.** A
--- badge is read at a glance from arm's length and has room for one word. A
--- detail row has room for a sentence, is fitted to its width, and is where
--- the difference between a cells sensor that returned a number and one that
--- returned nonsense actually belongs.
---
--- Components therefore no longer override it. `NOT CELLS` against
--- `BAD CELLS` spent nine characters separating two failure modes of one
--- component, and `NO SENSOR` against `NO SOURCE` were near-identical strings
--- for two situations with the same fix. Every one of those distinctions was
--- already being drawn in the same component's detail row.
theme.BADGES = {
  stale = "STALE",
  warning = "WARN",
  critical = "CRIT",
  editing = "EDIT",
  -- Nothing usable from the source: unconfigured, unrecognized, or answering
  -- with a shape this component cannot read. All three want the same fix and
  -- the detail row says which it is.
  unavailable = "N/A",
}

--- Widest string the badge vocabulary can produce, in pixels.
---
--- Resolved once and cached. Not computed at load, because the font constants
--- are EdgeTX globals and a module that read them while being loaded would
--- depend on the order the host happens to load its modules in; and not per
--- call, because `theme.frame` runs for every component of every reflow and
--- this never changes.
---@param font any Badge font, from theme.typography.
---@return integer
function theme.badgeWidth(font)
  local cached = badgeWidths[font]
  if cached then return cached end

  local widest = 0
  for _, text in pairs(theme.BADGES) do
    local width = theme.textWidth(font, text)
    if width > widest then widest = width end
  end

  badgeWidths[font] = widest
  return widest
end

--- Narrowest header label worth drawing, about three characters at SMLSIZE.
--- A label squeezed below this says nothing and only clips, so it is dropped.
--- Three rather than two because the catalogue's own short labels are three
--- and four characters: ALT, NAV, TRIM, LINK, MODE, PACK.
local MIN_LABEL_WIDTH = 30

--- Resolve the padded content geometry every component panel shares.
---
--- Components derive their regions from this rather than repeating the same
--- arithmetic, so a header row sits in the same place on every panel and a
--- state badge never lands on top of the label it accompanies. Every
--- measurement comes from a real font line height, because EdgeTX's fonts are
--- far taller than they look and fixed offsets overflow on the radio.
---
--- A panel may also be handed a corner the dashboard does not own. In App mode
--- EdgeTX paints its menu button over the top-left of the screen, above
--- everything the widget draws, and it cannot be hidden because it is the only
--- route to the radio's menus. Laying the header and the content start out
--- around that corner here means the one shared helper handles it once,
--- instead of ten components each compensating and disagreeing about how.
---@param resolved AeroGridTheme
---@param rect AeroGridRect
---@param fonts table Typography roles for this component's span.
---@param reserved? table Width and height of an obstructed top-left corner.
---@return table frame
function theme.frame(resolved, rect, fonts, reserved)
  local spacing = resolved.spacing
  -- Short panels cannot afford the standard vertical rhythm, but the left
  -- padding has a floor their height has no say in: the accent occupies that
  -- edge, and content starting at the accent's own right edge read as crowded
  -- against it on every panel under 80 px tall.
  local tight = rect.h < 80
  local pad = tight and spacing.paddingTight or spacing.padding
  local compact = tight and 2 or spacing.paddingCompact
  local padRight = spacing.paddingRight

  local content = math.max(1, rect.w - pad - padRight)

  -- The badge takes exactly what its vocabulary needs, and is clamped to the
  -- content rather than to half of it. The old half-content clamp protected
  -- the label by clipping the badge, which is the wrong way round: a
  -- half-drawn state word is worse than an absent one, because CRIT and CRI
  -- are not equally alarming, while a shortened source name is merely less
  -- informative. The label now yields to the badge and is dropped outright
  -- when what is left would only clip.
  local badgeWidth = theme.badgeWidth(fonts.badge)
  if badgeWidth > content then badgeWidth = content end
  local badgeX = math.max(pad, rect.w - padRight - badgeWidth)
  local labelHeight = theme.fontHeight(fonts.label)
  local labelX = pad
  local top = compact + labelHeight + 2

  if reserved then
    -- The header shares the obstructed band, so it moves along to its right
    -- rather than below it, which would cost the panel a whole row.
    if compact < reserved.h then labelX = reserved.w + 4 end
    -- Content starts below the obstruction. This is the only space the panel
    -- actually loses, and it loses it once rather than per element.
    if top < reserved.h then top = reserved.h end
  end

  -- The badge column is reserved whether or not a badge is showing, and the
  -- label's width does not depend on whether one is.
  --
  -- Handing the label the empty column and taking it back when a badge
  -- appears would reflow the label at exactly the moment a panel changes
  -- state, which is the text-jumping the specification forbids and is worse
  -- than a permanently shorter label: a header that moves draws the eye to
  -- itself rather than to the reading that just went critical. Every
  -- component in the catalogue can reach a badged state, so a column that was
  -- conditional would be conditional on nothing in practice anyway.
  local labelWidth = badgeX - labelX - 4
  local labelHidden = labelWidth < MIN_LABEL_WIDTH
  -- A hidden label has no width rather than a token one, so a panel too narrow
  -- to carry both still has coherent geometry.
  if labelHidden then labelWidth = 0 end

  return {
    width = rect.w,
    height = rect.h,
    pad = pad,
    padRight = padRight,
    compact = compact,
    content = content,
    labelHeight = labelHeight,
    badgeWidth = badgeWidth,
    badgeX = badgeX,
    labelX = labelX,
    labelWidth = labelWidth,
    -- Dropped rather than clipped, which is the judgement the obstructed
    -- corner already made and which applies to a narrow panel for the same
    -- reason: the reading and its state are what a pilot needs, and the source
    -- name is the part that can be given up.
    labelHidden = labelHidden,
    top = top,
    bottom = 4,
    reserved = reserved,
  }
end

--- Font roles for a component span.
--- Sizes are EdgeTX globals, read at call time so tests can install mocks.
---@param colSpan integer
---@param rowSpan integer
---@return table fonts
function theme.typography(colSpan, rowSpan)
  local cells = (colSpan or 1) * (rowSpan or 1)
  local primary = MIDSIZE

  if cells >= 4 then
    primary = XXLSIZE
  elseif cells >= 2 then
    primary = DBLSIZE
  end

  return {
    primary = primary,
    secondary = cells >= 4 and MIDSIZE or SMLSIZE,
    unit = cells >= 4 and MIDSIZE or SMLSIZE,
    label = SMLSIZE,
    badge = SMLSIZE,
  }
end

--- Resolve a component state into concrete presentation values.
--- Warning, critical, stale, and unavailable states deliberately override a
--- component's decorative accent, and each carries a text badge because color
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
function theme.modern()
  local copy = {}
  for key, value in pairs(MODERN) do copy[key] = value end
  return copy
end

return theme
