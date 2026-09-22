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

--- Memo for theme.riderDepth, which reads the firmware's font metrics.
local riderDepth

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
  -- a mode we removed, and both are worth saying.
  if type(mode) == "string" and string.match(mode, "^%s*$") then mode = nil end

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
--- EdgeTX's fonts are proportional, so width has to be estimated where it is
--- not measured. The ratio is deliberately generous: overestimating shrinks a
--- reading that would have fit, while underestimating clips it, and the
--- specification requires text to abbreviate or reduce before it clips.
local ADVANCE_RATIO = 0.58

--- Estimate the rendered width of a string in a given font.
---
--- **Generous on purpose, and therefore wrong for placement.** Every
--- character is charged the same 0.58 of a line height, so a decimal point
--- costs what a digit does. Against the real advances of the font EdgeTX
--- ships, `7.9` comes out **68% too wide** and `88.8` 58% too wide -- at
--- XXLSIZE that is roughly 48 pixels of empty space. Deciding *whether*
--- something fits may err that way. Deciding *where* something starts may
--- not: see `theme.measureText`.
---@param font any
---@param text any
---@return integer
function theme.textWidth(font, text)
  local length = #tostring(text == nil and "" or text)
  return math.floor(length * theme.fontHeight(font) * ADVANCE_RATIO + 0.5)
end

--- Measure the rendered width of a string, asking the radio where it can.
---
--- `lcd.sizeText(text, flags)` is `luaLcdSizeText`, which calls
--- `getTextWidth` -> `lv_txt_get_width(s, len, getFont(flags), 0,
--- LV_TEXT_FLAG_EXPAND)`: it sums the real per-glyph advances out of the font
--- and nothing else. Three things make it usable here where the estimate used
--- to be the only option:
---
---  * it takes no draw context. Unlike every other `lcd` drawing function it
---    carries no `luaLcdAllowed` or `luaLcdBuffer` guard, so it answers from
---    a `create` or an `update` as readily as from a paint;
---  * our size constants are the flags it wants. `SMLSIZE` and the rest are
---    `FONT(XS)` and friends, which is exactly what `getFont` indexes;
---  * the font it consults is decompressed once and cached, so the cost is a
---    C loop over the string rather than a decode per call.
---
--- The estimate remains the fallback, because a host without `lcd.sizeText`
--- -- the unit tests are one -- still has to produce a number.
--- **Fitting measures too, and the estimate is only the fallback.** It used
--- to decide whether something fits while `readingWidth` decided where to
--- put it, and the two disagreed by far more than a rounding. The estimate is
--- one allowance per character, sized between a digit and a capital: at
--- MIDSIZE it allows 16.8 px where `8` advances 12 and `M` advances 19.
---
--- So it was wrong in **both** directions, and the safety argument that used
--- to sit here -- that it never reports less than the measurement, so
--- anything the fit accepts the placement can draw -- was simply false.
---
---  * On digits it over-reports, by about half again at the larger fonts:
---    `88.8` at XXLSIZE estimates 160 px and advances 102. That costs
---    nothing but sizes -- a unit shed that would have fitted, a reading
---    stepped down that had room. `tx-battery` took its font from the band
---    rather than from this ladder to escape it, which is a component
---    working around a shared helper rather than one with a special
---    visualization.
---  * On capitals it under-reports, and that clips. `model-identity` sizes
---    its panel against a row of `M` because that is the widest name EdgeTX
---    will store, and at `1 x 2` the estimate called `MMMMMM` 101 px where
---    MIDSIZE draws it in 116 -- eleven pixels past 105 px of content, in
---    the component whose entire reading is the name.
---
--- Measuring removes both, and removes the disagreement as well: the
--- function that decides the font and the function that places the string
--- now answer from the same advances. The estimate remains underneath, in
--- `measureText`, for a host with no `lcd.sizeText` -- which is a host that
--- can only guess anyway.
---@param font any
---@param text any
---@return integer
function theme.measureText(font, text)
  local sizeText = type(lcd) == "table" and lcd.sizeText
  if type(sizeText) ~= "function" then
    return theme.textWidth(font, text)
  end

  local width = sizeText(tostring(text == nil and "" or text), font)
  if type(width) ~= "number" then return theme.textWidth(font, text) end
  return width
end

--- Distance from the bottom of a font's line box to its baseline.
---
--- `getFontHeight` is `lv_font_get_line_height`, so `lcd.sizeText` hands Lua a
--- line height and nothing else: **EdgeTX does not expose ascent or baseline
--- to a script at all**. The numbers are fixed properties of the generated
--- fonts, read from `radio/src/fonts/lvgl/std/lv_font_en_*.c`, and the flags
--- map to those files through `api_general.cpp` and `gui/colorlcd/fonts.cpp`:
--- TINSIZE is `FONT(XXS)`, SMLSIZE `FONT(XS)`, MIDSIZE `FONT(L)`, DBLSIZE
--- `FONT(bold XL)` and XXLSIZE `FONT(bold XXL)`. Their line heights are 12,
--- 17, 29, 40 and 69, which is where `fontHeight` above comes from, and the
--- table below is the `base_line` beside each.
---
--- With both, a baseline is exact rather than approximate: `lv_draw_sw_letter`
--- places a glyph at `pos.y + (line_height - base_line) - box_h - ofs_y`, so
--- the baseline of a label whose top is `y` sits at `y + line_height -
--- base_line`.
---@param font any
---@return integer
function theme.fontBaseLine(font)
  if font == XXLSIZE then return 15 end
  if font == DBLSIZE then return 9 end
  if font == MIDSIZE then return 6 end
  if font == SMLSIZE then return 4 end
  if font == TINSIZE then return 3 end
  return 5
end

--- Pixels from the top of a font's line box down to its baseline.
---@param font any
---@return integer
function theme.fontAscent(font)
  return theme.fontHeight(font) - theme.fontBaseLine(font)
end

--- The font a unit rides at beside a reading of a given size.
---
--- Two steps down the reading ladder wherever there are two, which lands the
--- unit between two fifths and three fifths of the number's line height at
--- every pairing this dashboard produces: 29 against 69, 17 against 40, 17
--- against 29, 12 against 17. A unit larger than that competes with the
--- number, and a unit smaller stops being legible at arm's length.
---@param font any
---@return any
function theme.unitFont(font)
  if font == XXLSIZE then return MIDSIZE end
  if font == DBLSIZE then return SMLSIZE end
  if font == MIDSIZE then return SMLSIZE end
  return TINSIZE
end

--- Where the top of a unit's label goes so its baseline meets the reading's.
---
--- Aligning the two **tops** is wrong by the difference in ascent, which for
--- an XXLSIZE reading beside a MIDSIZE unit is 54 against 23: the unit would
--- float 31 pixels above where it belongs. Aligning **bottoms** is wrong by
--- the difference in `base_line`, which is smaller but still 9 pixels for
--- that pair, so the unit would sit visibly low. Neither approximation is
--- needed, because both terms are known.
---@param readingFont any
---@param unitFont any
---@param readingY integer Top of the reading's label.
---@return integer
function theme.unitTop(readingFont, unitFont, readingY)
  return readingY + theme.fontAscent(readingFont) - theme.fontAscent(unitFont)
end

--- Air between a reading and the unit riding beside it.
---
--- A twelfth of the unit's line height, which is one pixel at SMLSIZE and
--- TINSIZE and two at MIDSIZE. It was a fifth, and that was chosen while the
--- reading's width was being estimated 58% high: the gap was never what the
--- user was looking at, it was an overlong measurement with a gap on the end,
--- and shrinking the constant alone would have left most of the space.
---
--- It is small rather than zero because a glyph's advance already carries its
--- own right side bearing, so a number and a unit set flush are not actually
--- touching -- the mock shows them close, and close is what this is. A
--- proportional gap on top of a proportional bearing keeps the pair looking
--- the same at every size.
---@param unitFont any
---@return integer
function theme.unitGap(unitFont)
  return math.max(1, math.floor(theme.fontHeight(unitFont) / 12 + 0.5))
end

--- Width a reading and its inline unit occupy together.
---@param font any
---@param digits any
---@param unitFont any
---@param unit any
---@return integer
--- **Measured, not estimated, and the slot rule is what forced it.** The
--- estimate is generous by design so that text shrinks rather than clips,
--- which is the right bias when the alternative is a clipped reading and no
--- way to know. It is the wrong bias when the answer can simply be correct:
--- generosity then refuses things that fit.
---
--- `navigation` at `2 x 2` is where that stopped being theoretical. Its
--- widest distance, `888.88km`, measures 113 px at `DBLSIZE` and its slot is
--- 113 px, so it fits exactly -- and the estimate calls it 160 and sheds the
--- dial beside it. A panel lost a compass to a safety margin protecting it
--- from a problem it did not have.
---
--- This is one function rather than the whole boundary. The remaining
--- fitters -- `fitText`, `fitReading`, `fitHeading`, `fitLabel` -- still
--- estimate, because their callers ask about strings they may abbreviate
--- rather than about a pair that must fit or lose its neighbour. Every
--- caller of this one runs at build or reflow, never per frame, so the
--- measurement costs nothing a panel pays repeatedly.
function theme.readingWidth(font, digits, unitFont, unit)
  local width = theme.measureText(font, digits)
  if unit == nil or unit == "" then return width end
  return width + theme.unitGap(unitFont) + theme.measureText(unitFont, unit)
end

--- Choose the font for a reading that carries its unit beside it.
---
--- **The unit never costs the reading a size.** It rides at whatever font the
--- number was going to take, or it is dropped. That is the specification's own
--- order -- a form may drop redundancy, never magnitude -- and the unit is
--- redundancy, because the panel's heading names what is being measured.
---
--- What changes is how often that happens. A unit used to be a character of
--- the reading itself, so a `V` beside an XXLSIZE number cost 40 pixels; at
--- two steps down it costs 23 including its gap. It therefore fits in a great
--- many places it did not, which is the whole of the improvement. Buying it
--- with a size of the number would be paying for redundancy with magnitude,
--- and the first thing a pilot reads is how big the number is.
---
--- The caller passes the widest digits it will ever print, never the current
--- ones, so neither the font nor the unit's presence changes as the value
--- does.
--- **Some units cannot be dropped**, and those callers say so. A distance's
--- unit changes with its range, so `1.23km` and `1.23m` are different
--- readings rather than one abbreviated; the unit is magnitude there, not
--- redundancy. For those the pair is what the ladder is walked against, and
--- the number steps down until both fit, because the alternative is a
--- distance with no scale on it.
---@param digits string Widest digits the caller will ever print.
---@param unit any Unit text, or nil/empty for none.
---@param width integer Pixels available.
---@param room integer Vertical pixels the composition left.
---@param required? boolean The unit carries magnitude and may not be dropped.
---@return any font
---@return any unitFont
---@return boolean showUnit
---@return boolean fits Whether what will be drawn actually fits.
function theme.fitReadingUnit(digits, unit, width, room, required)
  local bare = unit == nil or unit == ""
  if required and not bare then
    local ordered = theme.READING_FONTS
    local start = #ordered
    for index = 1, #ordered do
      if theme.fontAscent(ordered[index]) <= room then start = index break end
    end
    for step = start, #ordered do
      local font = ordered[step]
      local rider = theme.unitFont(font)
      if theme.readingWidth(font, digits, rider, unit) <= width then
        return font, rider, true, true
      end
    end
    local last = ordered[#ordered]
    return last, theme.unitFont(last), true, false
  end

  local font, _, fits = theme.fitReading({digits}, width, room)
  local rider = theme.unitFont(font)
  local showUnit = fits and not bare
    and theme.readingWidth(font, digits, rider, unit) <= width
  return font, rider, showUnit, fits
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
--- **It is not told what the component draws, and no longer needs to be.**
--- It used to be, and the reason is worth keeping because the interface was
--- designed around it: the tertiary quarter was reserved only when the panel
--- actually drew a supporting row, so a component had to declare its
--- intention or be charged a quarter of the panel for a row it would never
--- fill. Three components default their row off and all three lost a font
--- size to that.
---
--- The bands are fixed proportions now, so there is nothing for a
--- declaration to correct: a panel reserves its bottom quarter whether or
--- not it draws into it. The `draws` argument was removed rather than left
--- accepted and ignored, because an argument that no longer reaches
--- anything is worse than an absent one -- a caller passes it, believes it
--- was honoured, and nothing says otherwise.
---
--- What a component draws still decides where its *own* row is placed and
--- whether it is drawn at all. That lives in `theme.panel` and in the
--- components, which is where it always was; only the band arithmetic has
--- stopped asking.
---@param resolved AeroGridTheme
---@param rect AeroGridRect
---@param frame table Result of theme.frame.
---@return table ladder `{rows, visual, bands, room}`
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

  -- The bands the panel's *furniture* lives in: the heading at the top, the
  -- supporting row at the bottom. The reading no longer takes the band
  -- between them -- see `theme.readingRoom` -- but the two outer bands are
  -- unchanged, and a row that would not fit its quarter still does not.
  --
  -- It stays here rather than moving into each component, because two panels
  -- of one size agreeing is the whole reason this function exists. A band
  -- rule applied by some components and not others would reintroduce exactly
  -- the disagreement it replaced.
  --
  -- **The bands do not depend on what the panel draws**, which is why
  -- nothing about `draws` reaches them. The tertiary quarter used to be
  -- reserved only when the floor was spoken for -- by a supporting row or by
  -- a bar -- and given to the body otherwise, so a panel drawing no row read
  -- at a size a panel drawing one could not. That is a layout that depends
  -- on content, and the user rejected it on a radio after it had been
  -- measured as correct here. `theme.bands` records what went with it.
  --
  -- `draws` still narrows the *grants* below, because a component may
  -- decline a row it was offered and the row's own placement follows that.
  -- It cannot widen them: a component may not claim a row the panel is too
  -- short to hold, which is the whole point of deciding composition here.
  local bands = theme.bands(frame, rect, true)

  -- The first row of the panel the widget owns, and the first row it has
  -- promised to something else. The reading is centred between them.
  local top = frame.reserved and frame.reserved.h or 0
  local centre = rect.h / 2
  -- Where a supporting row's glyphs begin, which is what the reading has to
  -- clear -- not where its quarter begins. A row is centred in its quarter,
  -- and measuring the quarter instead would charge the reading the whole of
  -- the air above the row.
  local floorY = rows > 0
    and theme.centreInBand(bands.tertiary, frame.labelHeight)
    or (rect.h - frame.bottom)

  return {
    rows = rows,
    visual = visual,
    bands = bands,
    room = theme.readingRoom(frame, rect, rows, visual, centre, floorY),
    -- The panel's own vertical centre, which is where the reading's ink
    -- goes whatever else the panel carries. Held here so the one place that
    -- decides the font and the one that decides the position read the same
    -- number; they were separate once and a reading was sized against a band
    -- it was not drawn in.
    centre = centre,
    -- The first row of the panel the widget actually owns: zero everywhere,
    -- and the bottom of EdgeTX's menu button on the one panel it reaches
    -- into. Nothing centred may start above it, because what is drawn there
    -- is painted over.
    top = top,
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
--- The ladder a reading is sized from, largest first.
---
--- It no longer has to answer what a reading would give up for something
--- beside it, because a reading gives up nothing: it takes the size the
--- panel allows and the decoration fits in what is left or is shed. The
--- companion `readingStep`, which existed only so `navigation` could say
--- "one size smaller than that", went with the rule it served.
theme.READING_FONTS = {XXLSIZE, DBLSIZE, MIDSIZE, SMLSIZE}

--- **It can fail, and it says so.** When even the shortest form will not fit
--- at the smallest font, there is no font that fits and nothing honest to
--- return, so it returns the smallest of each and a third value of `false`.
--- Measuring the answer again in the caller is how `tx-battery` came to take
--- width for a battery the reading needed, so the verdict is here rather than
--- in every caller's own guard.
---
--- **Two kinds of caller, and they are allowed to differ.** One *draws*: it
--- has offered every form it has, and when none of them fits at the smallest
--- font there is nothing further it can do, so it draws the smallest and the
--- verdict is information rather than a decision. `flight-timer`,
--- `flight-mode` and `model-identity` are all of this kind. The other
--- *allocates*: it is deciding whether to spend the panel's width on
--- something else -- a battery, a unit -- and for it the verdict is the
--- decision, because spending width the reading has already failed to fit in
--- makes a bad situation worse. `glyphFor` and `fitReadingUnit` are of this
--- kind. The difference is not two assumptions about one function; it is one
--- answer used for two purposes.
---@param forms string[] Lossless wordings, longest first.
---@param width integer Pixels available.
---@param room integer Vertical pixels the composition left.
---@return any font
---@return integer index Form chosen, from 1.
---@return boolean fits Whether the chosen form actually fits the width.
function theme.fitReading(forms, width, room)
  local ordered = theme.READING_FONTS
  local start = #ordered

  -- **The band holds the ink, not the line box.** Same rule as
  -- `theme.bandFont`, and it has to be the same rule: a font chosen one way
  -- and a band measured the other is the disagreement the shared ladder
  -- exists to remove.
  for index = 1, #ordered do
    if theme.fontAscent(ordered[index]) <= room then start = index break end
  end

  -- The target the box allows, then down until something fits.
  for step = start, #ordered do
    for index = 1, #forms do
      if theme.measureText(ordered[step], forms[index]) <= width then
        return ordered[step], index, true
      end
    end
  end

  return ordered[#ordered], #forms, false
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
--- badge is read at a glance from arm's length and is one word from a closed
--- set the theme owns. A detail row is a vocabulary the component owns, is
--- fitted to whatever width its panel gives it, and is where the difference
--- between a pack that has not been detected and a source answering wrongly
--- actually belongs.
---
--- **The row's defence is its vocabulary and not its width**, which matters
--- because the width changed: a two-item row now takes the panel's two slot
--- centres and gets 40% of the content where the column split it replaced
--- reached all of it. `NO CELLS` against `CELLS ERR`, and `DOWN` against
--- `NO RSS`, still say different things at that width. A component whose
--- shortest wordings collapse onto one another has lost the distinction
--- however wide its panel happens to be.
---
--- **The row says what to do, not merely which failure occurred**, and that
--- is narrower than it first looks. `cell-battery` once drew `NOT CELS`,
--- `BAD CELS` and `NO CELS` for three shapes. Two of them -- a source that
--- is not cells at all, and one reporting nonsense -- are one thing to a
--- pilot: something is arriving and is wrong, go and fix it. They print one
--- wording now, and the row is not poorer for it. The five shapes behind
--- them are still separated where the difference can be used, which is the
--- diagnostics view.
---
--- Components therefore no longer override the badge. `NOT CELLS` against
--- `BAD CELLS` spent nine characters separating two failure modes of one
--- component -- and those two have since turned out to be one failure mode
--- with two causes, which is the stronger version of the same argument.
--- `NO SENSOR` against `NO SOURCE` were near-identical strings for two
--- situations with the same fix. Every one of those distinctions was already
--- being drawn, or has since been found not to be a distinction at all.
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
  -- **The heading is pinned to the top of its band, not centred in it.** A
  -- heading is furniture: it says what the panel is, and it should land in
  -- the same place whatever size the panel happens to be. Centring it in a
  -- band that is a quarter of the panel's extent made it drift down as
  -- panels grew -- 0 px from the top on a one-row panel, 13 on two rows, 21
  -- on three and 30 on four, so a column of panels of different heights had
  -- its headings at four different offsets.
  --
  -- The proportional band was designed for the **reading**, where growing
  -- with the panel is the point. Applying the same rule to the heading is
  -- what produced the drift.
  --
  -- **The band still exists and the body still starts below it.** Only the
  -- heading's own position moves; the quarter is still reserved and `top` is
  -- still measured from where a centred heading would have ended. That is
  -- deliberate rather than incidental: `top` feeds `theme.ladder`, which
  -- decides whether a panel is granted a supporting row and a
  -- visualization, and `theme.bands`, which decides where the reading sits.
  -- Letting the body rise into the space the heading vacated would change
  -- what every panel in the catalogue draws, which is a different decision
  -- from where the heading sits.
  local extent = math.max(1, (rect.h - 4) - compact)
  local centred = theme.clampToPanel(
    theme.centreInBand({y = compact, h = math.floor(extent / 4)}, labelHeight),
    fonts.label, rect.h)
  local top = math.max(compact + labelHeight + 2, centred + labelHeight + 2)

  -- Not clamped, and it cannot need to be. `clampToPanel` exists because a
  -- heading centred in a band could be pushed off a short panel -- at one
  -- row the centred value is -1 px and the clamp lifted it to 0. Pinned, the
  -- heading starts at the panel's own top inset, which is 2 px on a short
  -- panel and 6 on any other, against a clamp that binds only above
  -- `rect.h - 13`. The nearest that comes to binding is 2 against 40.
  local labelY = compact

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
    labelY = labelY,
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

--- Where the two content slots are centred, as fractions of the content width.
---
--- Positions come from the **panel**, never from what is in them. That is the
--- whole of the arrangement: a slot cannot move because its contents changed
--- width, so a reading gaining a digit does not shift the battery beside it,
--- and across a row of equal-width panels every reading lands at the same x.
--- Two earlier proposals were rejected for failing exactly that, and the
--- design guide records both with the geometry that ruled them out.
---
--- Tightened is the arrangement; strict is the fallback. Strict cannot
--- collide *provided each element fits its half*, because the two own
--- disjoint regions; tightening trades that guarantee for the elements
--- sitting closer together.
theme.SLOT_TIGHT = {0.30, 0.70}
theme.SLOT_STRICT = {0.25, 0.75}

--- The x coordinates the two slots are centred on.
---@param frame table Result of theme.frame.
---@param slots? table One of theme.SLOT_TIGHT or theme.SLOT_STRICT.
---@return integer left
---@return integer right
function theme.slotCentres(frame, slots)
  slots = slots or theme.SLOT_TIGHT
  return frame.pad + math.floor(frame.content * slots[1] + 0.5),
    frame.pad + math.floor(frame.content * slots[2] + 0.5)
end

--- Left edge of a block of `width` centred on `centre`.
---@param centre integer
---@param width integer
---@return integer
function theme.slotX(centre, width)
  return centre - math.floor(width / 2)
end

--- Whether the two slots can hold this pair without the elements meeting.
---
--- **Asked of the widest string the component can ever print, never of the
--- value on screen, and decided once at build.** Deciding it from the current
--- reading would make the arrangement a function of the data: a voltage
--- crossing `9.9` to `10.0` would flip the whole panel between two layouts and
--- every element in it would jump. That is the moves-when-content-changes
--- objection that ruled out centring, in a worse form, because a drift becomes
--- a switch.
---
--- Asking the widest form instead fixes the arrangement for the life of the
--- panel, so one with room to spare today keeps the layout it will need at its
--- widest, and nothing it can ever display rearranges it.
---
--- **It can fail, and it says so.** Strict halves cannot collide only while
--- each element fits its own half; where the reading is wider than half the
--- content, no pair of slots separates them and there is nothing honest to
--- return. A caller that ignores the verdict gets strict halves and an
--- overlap; a caller deciding whether to keep a visualization at all has to
--- check it, and now can. The failing answer being indistinguishable from a
--- good one is the shape that has cost this project a defect three times.
---
--- **Both edges, not only the shared one.** A reading centred on the left
--- slot has a panel edge on one side and the visualization on the other, and
--- this used to check only the second. That was safe only because the
--- reading was fitted into half the panel before it ever arrived here, so it
--- could not reach the first. Readings now take the size the whole panel
--- allows -- a decoration does not cost magnitude -- and a `-120.00` at
--- MIDSIZE in a single cell is 74 pixels wide against a left slot with 26 to
--- its left. It cleared the dial and hung eleven pixels off the panel.
---
--- So the verdict is what it always claimed to be: whether this pair of
--- slots can hold both elements. Answering for one boundary and being read
--- as answering for the arrangement is the same shape as every other defect
--- in this file's history.
---@param frame table Result of theme.frame.
---@param readingWidth integer Widest the reading and its unit will ever be.
---@param visualWidth integer Width of the element in the right slot.
---@return table slots theme.SLOT_TIGHT, or theme.SLOT_STRICT where they meet.
---@return boolean fits Whether either arrangement actually separates them.
function theme.slotsFor(frame, readingWidth, visualWidth)
  local halfReading = math.ceil(readingWidth / 2)
  for _, slots in ipairs({theme.SLOT_TIGHT, theme.SLOT_STRICT}) do
    local left, right = theme.slotCentres(frame, slots)
    local readingStart = left - halfReading
    local readingEnd = left + halfReading
    local visualStart = right - math.floor(visualWidth / 2)
    if visualStart >= readingEnd and readingStart >= frame.pad then
      return slots, true
    end
  end
  return theme.SLOT_STRICT, false
end

--- How much vertical room the reading is sized against.
---
--- **Half the panel where the panel carries anything else, the whole panel
--- where it does not.** There is no band for the reading any more: the
--- panel's height is the budget, halved when something else has to share the
--- panel with it.
---
--- **Four things count as sharing, and the rule was stated with two.** A
--- heading and a supporting row are the two the user named. A visualization
--- is the third and was found by measurement rather than by argument: an
--- 80 x 65 panel is granted a bar and refused a heading and a row, so on the
--- two-item statement its reading took the whole 65 px, and XXLSIZE ink
--- centred on the panel ends at 59 against a bar whose track starts at 55.
--- A bar is furniture in exactly the sense the rule means -- something else
--- on the panel that the reading must not be sized as though it were alone.
---
--- The fourth is EdgeTX's menu button, which is the same thing seen from the
--- panel's side. A panel the button reaches into is not a panel with nothing
--- on it but a reading, and the user's rule for the corner -- that it keeps
--- the half while the button is drawn and follows every other panel once the
--- widget goes fullscreen and the button is hidden -- falls out of counting
--- the button as furniture rather than being a case bolted on beside the
--- rule.
---
--- **The button also caps the room, because it is the one piece of furniture
--- the panel does not own.** A heading and a row are drawn by the widget and
--- can be reasoned with; the button is painted over the widget by the
--- firmware and cannot. So the reading may never be larger than what the
--- button leaves below it, and on a 117 x 65 corner that is 20 px rather
--- than the 32 px half. Without the cap the sweep finds fifteen readings
--- drawn under the button, including `tx-battery` at a shipped `2 x 2`.
---
--- **The alternative was centring in the region below the button**, which is
--- the other reading of the user's question, and it was measured rather than
--- argued away: on a 238 x 134 corner the region below the button is 89 px,
--- its centre is 89.5, and a DBLSIZE reading centred there runs from 74 to
--- 105 against a supporting row's quarter that starts at 103. It collides at
--- the shipped corner panel *and* costs that panel a font size, so the
--- region is not what the reading is centred in -- the panel is, and the
--- button clamps.
---
--- **Asked of what the panel reserves, never of what the component draws.**
--- A heading is present when the panel is wide enough to keep one, a row or
--- a visualization when it is tall enough to be granted one. That is the
--- guarantee the fixed bands were chosen for and it is kept here: two panels
--- of one size get one answer, whatever is configured into them. It is also
--- why the bar had to count as furniture rather than be dodged by asking
--- whether one is drawn -- the question the interface deliberately does not
--- offer.
---
--- Which means the whole-panel budget is reachable only by a panel too
--- narrow for a heading, too short for a bar, and clear of the button --
--- measured, narrower than 95 px and shorter than 48. The grid is fixed at
--- four by four, so the only way to build one is a small zone:
--- `testAReadingAloneTakesTheWholePanel` reflows to 380 x 188, whose cell is
--- 92 by 44 and takes MIDSIZE where a half of it would take SMLSIZE. A rule
--- whose second half fires on nothing is a rule with one half, so the case
--- is constructed rather than assumed.
---
--- **And "the whole panel" is not literally `rect.h`.** A reading centred on
--- the panel and sized to its full height hangs a descending unit off the
--- bottom edge, so the containment cap below binds on every lone panel --
--- the budget is the height less twice the rider's depth. That is worth
--- stating rather than leaving as a surprise, because the phrase promises
--- more than the geometry can give.
---@param frame table Result of theme.frame.
---@param rect AeroGridRect
---@param rows integer Supporting rows the panel grants.
---@param visual boolean Whether the panel grants a visualization.
---@return integer
function theme.readingRoom(frame, rect, rows, visual, centre, floorY)
  local reserved = frame.reserved
  local shared = reserved ~= nil
    or not frame.labelHidden
    or (rows or 0) > 0
    or visual == true
  local room = shared and math.floor(rect.h / 2) or rect.h
  if reserved then
    room = math.min(room, math.max(1, rect.h - reserved.h))
  end
  -- **And never deep enough to reach the supporting row.** A reading centred
  -- on the panel is symmetric about that centre, so what it may occupy
  -- before its baseline meets the row is twice the clearance -- less twice
  -- the strip a descending unit claims below that baseline, which is
  -- symmetric too because the ink grows in both directions while the rider
  -- hangs off the bottom.
  --
  -- This binds on exactly the panels where the half is generous enough to
  -- reach: a Full screen two-row span is 108 px, its row's glyphs start at
  -- 83, and XXLSIZE plus a MIDSIZE rider ends at 87.
  if centre and floorY then
    room = math.min(room, math.max(1,
      2 * math.floor(floorY - centre) - 2 * theme.riderDepth()))
  end
  return room
end

--- How far below a reading's ink anything riding on its baseline can reach.
---
--- A unit sits on the reading's baseline, so its own ink ends where the
--- reading's does -- but a *descending* unit carries glyphs into the strip
--- between that baseline and the bottom of its line box, and nothing
--- reserves that strip. `rpm`, `mph`, `deg`, `g`, `km/h`, `m/s` and `ml/m`
--- are all in `telemetry_service`'s table and all descend.
---
--- **This is what made the safety argument behind `theme.bandFont` true by
--- luck.** That argument is that the unreserved strip below a reading's
--- baseline is safe while nothing descends into it, and
--- `testReadingsDoNotDescendOverAnything` is what holds it -- and it held
--- because the middle-band budget happened to leave nine pixels of slack on
--- the panels where a descender could reach a supporting row. Sizing against
--- half the panel spends that slack, and the check went red on a Full screen
--- `2 x 2`: `rpm` two pixels into `CUR 10.0A`. So the depth is reserved
--- rather than left to the budget.
---
--- Measured from the real fonts at call time rather than written down: the
--- deepest a rider can reach is the largest `height - ascent` across the
--- unit fonts the reading ladder can produce.
---@return integer
function theme.riderDepth()
  if riderDepth then return riderDepth end
  local deepest = 0
  for _, font in ipairs(theme.READING_FONTS) do
    local rider = theme.unitFont(font)
    local below = theme.fontHeight(rider) - theme.fontAscent(rider)
    if below > deepest then deepest = below end
  end
  riderDepth = deepest
  return deepest
end

--- The proportional vertical bands a panel divides into.
---
--- **A label band of one quarter, a body of one half, a tertiary of one
--- quarter, and no redistribution.** The three are fixed proportions of the
--- panel's extent, and an absent part does not give its share to anything:
--- a panel that draws no supporting row reserves the bottom quarter anyway
--- and leaves it empty.
---
--- **Corrected: a part used to give its quarter to the body.** That made two
--- panels of one size lay their readings out differently according to what
--- was *in* them -- a body of a half where a supporting row was drawn and a
--- body of three quarters where it was not -- so a reading moved up or down
--- the panel depending on whether the panel beside it had a row. The user
--- saw that on a radio and rejected it, after it had been measured as
--- correct here. It is the same objection that produced the slots: a
--- position derived from the panel cannot move because of what is in it,
--- and a position derived from the content can.
---
--- What it costs is stated rather than discovered: a one-row panel that
--- draws no supporting row now sizes its reading against a half rather than
--- three quarters. The design guide carries the figures and the acceptance.
---
--- **The bands tile the extent exactly and the rounding goes to the body.**
--- `floor(extent / 4)` twice leaves one or two pixels over on most panels,
--- and the body is where a pixel is worth something -- it is measured
--- against a font ladder, where the label and the tertiary hold one line of
--- `SMLSIZE` whatever is left.
---@param frame table Result of theme.frame.
---@param rect AeroGridRect
---@param hasLabel boolean
---@return table bands `{label, body, tertiary}`, each `{y, h}`.
function theme.bands(frame, rect, hasLabel)
  local top = frame.compact
  local extent = math.max(1, (rect.h - frame.bottom) - top)
  local quarter = math.floor(extent / 4)
  local labelHeight = hasLabel and quarter or 0

  -- **Always reserved, drawn into or not.** This used to be the question
  -- `hasTertiary` answered, and with it went `floorHeight` -- how much a bar
  -- takes off the panel's floor -- and `rowHeight`, how much two supporting
  -- rows need when a quarter will not hold them. All three sized this band
  -- from what the panel was going to put in it, which is exactly the
  -- dependence on content this rule removes. A quarter is a quarter.
  --
  -- A bar still sits on the panel's floor, which is this band's own floor,
  -- so a bar is drawn *inside* the tertiary quarter rather than beneath it.
  -- It is shorter than the quarter at every span this dashboard builds, so
  -- a panel drawing a bar and a supporting row has room for the row above
  -- it; `testTertiaryQuarterHoldsItsFurniture` is what holds that.
  local tertiaryHeight = quarter

  -- **Where the heading's font overflows its band, the body yields too.** The
  -- label band is a quarter, and on a short panel a quarter is smaller than
  -- any font the dashboard has, so the heading keeps its size and spills
  -- downward. `theme.clampToPanel` keeps it on the panel; this keeps it off
  -- the reading. Without it a 40 px panel drew its heading through its own
  -- number, which is the same "the font wins" decision followed one step
  -- further than the mocks followed it.
  local bodyTop = top + labelHeight
  if hasLabel and frame.top > bodyTop then bodyTop = frame.top end
  local bodyHeight = math.max(1, (top + extent) - tertiaryHeight - bodyTop)

  return {
    label = {y = top, h = labelHeight},
    body = {y = bodyTop, h = bodyHeight},
    tertiary = {y = bodyTop + bodyHeight, h = tertiaryHeight},
    extent = extent,
  }
end

--- The largest reading font whose ink fits a band.
---
--- This inverts the older rule. There the composition came from the box and
--- the font from the composition; here the band comes from the panel and the
--- font from the band, which means the font does not consult the content at
--- all and therefore cannot resize with it. The stability guarantee the
--- fitter had to be careful to preserve now holds by construction.
---
--- Chosen by **ink** -- the font's ascent -- rather than by its line height,
--- which carries a descent and a leading that no digit, minus, point or
--- colon in this catalogue draws into. On the twenty-one body bands this
--- dashboard can build, the two rules disagree on four: 23 px takes MIDSIZE
--- rather than SMLSIZE, 34 px DBLSIZE rather than MIDSIZE, and 54 and 62 px
--- XXLSIZE rather than DBLSIZE. A 62 px band drew a reading filling half of
--- it where the next font up fills 87%.
---
--- **This was decided the other way first**, on a 36 px band and a 51 px
--- band, and the correction is worth knowing rather than quietly made: 36 px
--- is not a band this dashboard builds at all, and the enumeration that said
--- it was had been taken over the panels one generator happened to render.
--- The design guide carries the record.
---
--- **What it costs is a strip nothing reserves**, between a reading's
--- baseline and the bottom of its line box. Whatever is drawn beneath a
--- reading may sit there, which is safe only while nothing descends into it
--- -- so `testReadingsDoNotDescendOverAnything` constructs the strings that
--- can: the units `telemetry_service` renders with a descender, and
--- `model-identity`'s model name, which is free text.
---@param height integer Band height in pixels.
---@return any font
function theme.bandFont(height)
  local ordered = theme.READING_FONTS
  for index = 1, #ordered do
    if theme.fontAscent(ordered[index]) <= height then return ordered[index] end
  end
  return ordered[#ordered]
end

--- Where a block of `height` starts, to sit centred in a band.
---
--- **The font wins.** Where the block is taller than its band it stays centred
--- and overflows symmetrically rather than being shrunk to fit: a reading may
--- drop redundancy and never magnitude, and shrinking a number to satisfy a
--- decorative band is paying magnitude for layout.
---@param band table `{y, h}`.
---@param height integer
---@return integer
function theme.centreInBand(band, height)
  return band.y + math.floor((band.h - height) / 2)
end

--- Where a block of `height` starts, to sit centred on the panel.
---
--- **The reading's centre is the panel's centre, always**, whatever else the
--- panel carries and however large that is. The counterpart to the
--- panel-derived budget, and the two are not separable: sizing a reading
--- against the panel and then placing it in a band is how a `metric` bar
--- first found itself underneath its own reading.
---
--- **Corrected: this used to centre the block in the body band.** The bands
--- were symmetric and the reading was centred in the middle one, so the
--- arithmetic said centred -- but the heading is pinned to the top of its
--- band while a supporting row is centred in its own, so the slack collected
--- above the reading and not below it. On a `3 x 2` `flight-timer` that is
--- 22 px of clear space above the reading against 12 below, in a panel whose
--- reading was, by measurement, within a pixel of the panel's centre the
--- whole time. The user read the panel as uncentred from a radio, and what
--- they were reading was the gap, not the number.
---@param ladder table Result of theme.ladder.
---@param height integer
---@return integer
function theme.bodyTop(ladder, height)
  -- Never above the first row the panel owns -- the panel's own top edge,
  -- or the bottom of EdgeTX's menu button on the one panel it covers. Where
  -- the block is taller than what is left, centring would push its first
  -- pixels under the button or off the edge, where they are simply painted
  -- over; the overflow goes downward only, which is the decision
  -- `clampToPanel` makes at the same edge for the same reason. The room the
  -- font was chosen from carries the same cap, so the downward overflow
  -- cannot reach the panel's floor.
  return math.max(ladder.top, math.floor(ladder.centre - height / 2))
end

--- Keep a label's glyphs on the panel, whatever its band says.
---
--- **The font wins, and then it is clamped.** On a 53 px panel the label band
--- is 11 px and the heading is SMLSIZE at 17, while the smallest font the
--- dashboard has is TINSIZE at 12 -- so "let the band win" is not an available
--- answer there, in any component. Centring the heading in a band smaller than
--- itself puts a pixel of it above the panel's top edge, where it is simply
--- clipped. The band yields; the panel does not.
---
--- The alternative, falling back to the older stacking below a size threshold,
--- was rejected deliberately: two layout rules with a threshold between them
--- is a worse thing to own than one rule that bends at the bottom of its
--- range, because every component and every future addition would then have to
--- be reasoned about twice, on either side of a line whose position is itself
--- arbitrary.
---
--- Only the ascent is protected. A line box's descent and leading carry no
--- glyphs for the strings this dashboard draws, so clamping the box rather
--- than the ink would push every heading down for slack nothing marks.
---@param y integer
---@param font any
---@param panelHeight integer
---@return integer
function theme.clampToPanel(y, font, panelHeight)
  local ink = theme.fontAscent(font)
  local top = math.max(0, y)
  return math.min(top, math.max(0, panelHeight - ink))
end

--- Lay out a standard panel into a table the component owns.
---
--- **Most panels are one arrangement with different words in it**: a
--- heading, a reading, an optional visualization beside it, an optional
--- supporting row beneath. Every decision that arrangement needs already
--- lives here -- the frame, the ladder, the bands, the band font, the slots,
--- the fitter -- and the *assembly* of those decisions was copied into each
--- component, which is why the same band was called `valueY`, `nameY` and
--- `clockY` in three files and why one mistake had to be fixed in nine.
---
--- **It fills `out` rather than returning a fresh table.** A reflow runs
--- `REFLOW_BATCH` components per callback, and the reflow callback has about
--- four hundred instructions of headroom against the slowest loader stage;
--- allocating a region table and its sub-tables per component per reflow is
--- the one cost that could make sharing this more expensive than copying it.
--- The component keeps one table for the life of the panel and this
--- overwrites it.
---
--- **`spec.draws` is what the panel will put on the screen, never what its
--- height would permit.** That distinction is a defect shape this project
--- has now paid for twice -- once placing a row, once reserving a band -- so
--- the interface does not offer the other question. A component that wants a
--- supporting row says it draws one; the ladder may still refuse it on a
--- panel too short to hold it, because composition is decided here so that
--- two panels of one size agree.
---
--- What it deliberately does not do: compasses, battery glyphs, trim cells,
--- and anything a diagnostics view draws. A builder that can express every
--- panel expresses nothing, and those are the components whose arrangement
--- is genuinely their own.
---@param resolved AeroGridTheme
---@param rect AeroGridRect
---@param fonts table Typography roles for this span.
---@param spec table
--- `frame`: this component's frame, from its own `themeBuilder.frame`.
--- `forms`: reading wordings, longest first, widest the component can print.
--- `draws`: `{rows = boolean, visual = boolean}` -- what will be drawn.
--- `bar`: true where the visualization is a full-width bar, which spans the
---   panel by design and is exempt from the slot rule.
--- `compact`: `function(rect, half) -> size` for a visual that stands beside
---   the reading and therefore takes the right slot. Its absence is what
---   says a panel has one element rather than two.
--- `unit`: a unit that rides beside the reading, or nil for none.
--- `unitRequired`: the unit carries magnitude and may not be dropped -- a
---   distance's `km` against a voltage's `V`.
--- `rowItems`: 1 or 2, what the supporting row will actually hold. Not what
---   the component could put there: a row of two on a panel drawing one
---   puts a lone caption on the left slot, which is a defect this project
---   has already shipped once.
---@param out table The component's own region table, overwritten in place.
---@return table out
function theme.panel(resolved, rect, fonts, spec, out)
  -- **`spec.frame`, not `theme.frame`.** The host wraps `frame` per component
  -- to lay a panel out around the corner EdgeTX paints its menu button over,
  -- and that wrapper is reachable only through the `themeBuilder` a component
  -- was handed. Calling the module's own function here skips it, and the
  -- panel in the grid's top left draws its heading under the button -- which
  -- is precisely the defect the shared frame exists to prevent, reintroduced
  -- by the helper meant to share it.
  local frame = spec.frame
  local draws = spec.draws
  local ladder = theme.ladder(resolved, rect, frame)

  -- The component's intent, narrowed by what the panel can hold. A component
  -- may decline what it was granted and may not claim what it was not.
  local rows = draws.rows == true and ladder.rows > 0
  local visual = draws.visual == true and ladder.visual

  -- **A reading beside a compact visual gets a slot; one on its own gets the
  -- box.** A bar spans the panel by design and is exempt, so only a compact
  -- visual makes this a two-element panel. The visual is bounded by the slot
  -- it lives in as well as by the panel, so a narrow panel shrinks it rather
  -- than letting it reach across the middle into the reading.
  local half = math.floor(frame.content / 2)
  local compact = visual and spec.compact ~= nil
  local size = compact and math.min(spec.compact(rect, half), half) or 0

  -- The reading's forms, or the reading and a unit it may not drop. A unit
  -- that carries magnitude -- a distance's `km` -- is part of the reading
  -- and the pair is what the ladder is walked against; one that is
  -- redundancy is bought with width after the font is chosen.
  --
  -- **Fitted against the whole content box, never against the slot.** The
  -- reading does not know there is a dial and must not: a reading that
  -- shrinks to make room for a decoration has paid for the decoration with
  -- magnitude, and magnitude is the first thing a pilot reads. Whether the
  -- dial survives is settled below, by the one place that knows how wide the
  -- reading turned out to be.
  local font, formIndex, unitFont, showUnit
  if spec.unit ~= nil then
    font, unitFont, showUnit = theme.fitReadingUnit(
      spec.forms[1], spec.unit, frame.content, ladder.room, spec.unitRequired)
    formIndex = 1
  else
    font, formIndex = theme.fitReading(spec.forms, frame.content, ladder.room)
  end

  -- **One name for the reading's band.** Three components called this
  -- `valueY`, `nameY` and `clockY`, and one carried two of them for one
  -- thing. The name is `valueY` here and a component that wants another word
  -- for it has to write the alias itself, which is the point: the divergence
  -- has to be deliberate to happen at all.
  local height = theme.fontHeight(font)
  local width = spec.unit ~= nil
    and theme.readingWidth(font, spec.forms[formIndex], unitFont,
      showUnit and spec.unit or nil)
    or theme.measureText(font, spec.forms[formIndex])

  -- Asked of the widest string the component can ever print, so a panel's
  -- arrangement is fixed for its life rather than flipping as its value
  -- changes.
  --
  -- **This is the only place the dial's fate is decided, and it is the place
  -- that knows the reading's width.** It used to be decided twice: once
  -- above, by fitting the reading into half a panel so a dial would have
  -- somewhere to go, and again here, by shedding the dial if that had not
  -- been enough. A reading could therefore lose a size to buy room for a
  -- visualization that was then dropped anyway -- paying for something it
  -- did not get. Splitting one question across two places is the seam that
  -- has produced eight defects in this dashboard, so it is answered once.
  --
  -- The reading has already taken the size the panel allows. If the dial
  -- separates from it, the panel carries both; if it does not, the dial
  -- goes. Nothing is refitted, because nothing was narrowed.
  local slots
  if compact then
    local separated
    slots, separated = theme.slotsFor(frame, width, size)
    if not separated then
      compact, size, slots, visual = false, 0, nil, false
    end
  end

  -- Computed once, and only where a compact visual makes them mean
  -- anything. The reading and the visual both want them, and asking twice is
  -- two multiplications and two roundings per panel per reflow -- the kind of
  -- cost that turns a shared helper into a more expensive copy. A bar-backed
  -- panel has no slots at all and must not pay for them; the two-item
  -- supporting row asks separately because it splits whether or not the body
  -- above it does.
  local slotLeft, slotRight
  local centre
  if compact then
    slotLeft, slotRight = theme.slotCentres(frame, slots)
    centre = slotLeft
  else
    centre = frame.pad + math.floor(frame.content / 2)
  end

  out.frame = frame
  out.pad = frame.pad
  out.content = frame.content
  out.ladder = ladder

  -- A lone reading centres across the whole content box. A reading with a
  -- compact visual beside it takes the left slot, which is the caller's
  -- business until a component in this set has one.
  -- Reading and visual share the body band and are centred on each other, so
  -- the block the band centres is the deeper of the two.
  --
  -- **Measured as ink, not as line box.** A font's line height carries a
  -- descent and a leading that nothing in this catalogue draws into, so
  -- centring the box centres a rectangle that is taller than the glyphs and
  -- leaves the number sitting high in its band. `theme.bodyTop` is given the
  -- ink height for that reason, and the line box is then placed so the ink
  -- lands where the band wants it -- which for a non-descending string means
  -- the box top and the ink top are the same pixel.
  local ink = theme.fontAscent(font)
  local blockHeight = math.max(ink, size)
  local blockTop = theme.bodyTop(ladder, blockHeight)

  out.value = font
  out.formIndex = formIndex
  out.unitFont = unitFont
  out.showUnit = showUnit == true
  out.valueCentre = centre
  out.valueX = theme.slotX(centre, width)
  out.valueWidth = width
  -- Only where there is one. A panel with no compact visual writes three
  -- nils per reflow otherwise, and `out` is reused rather than rebuilt so
  -- they have to be cleared rather than simply absent -- which is the cost
  -- of the table the component owns, paid where it is actually owed.
  if compact then
    out.visualSize = size
    out.visualCentreX = slotRight
    out.visualCentreY = blockTop + math.floor(blockHeight / 2)
  elseif out.visualSize ~= nil then
    out.visualSize, out.visualCentreX, out.visualCentreY = nil, nil, nil
  end
  -- The room the reading had, which is not the width it draws in: the drawn
  -- box hugs the measured string so its slot can centre it, and a later
  -- question about whether a unit still fits has to be asked against the
  -- room. **A slotted reading's room is its slot, not the panel** -- asking
  -- the whole box would tell a unit arriving at runtime that it fits beside
  -- a reading sharing the panel with a dial.
  --
  -- It is not simply half the panel, because the reading is no longer fitted
  -- to half the panel. It is centred on the left slot, so what it can occupy
  -- is symmetric about that centre: bounded on one side by the content edge
  -- and on the other by where the dial begins. The slots that decided the
  -- dial's fate are the slots that answer this, so the two cannot drift.
  if compact then
    local visualStart = slotRight - math.floor(size / 2)
    out.valueBudget = 2 * math.max(1,
      math.min(slotLeft - frame.pad, visualStart - slotLeft))
  else
    out.valueBudget = frame.content
  end
  -- The line box's top, which for a string that does not descend is also
  -- the ink's top. `height` is the box and `ink` is what is drawn; the block
  -- was measured in ink, so the offset inside it is too.
  out.valueY = blockTop + math.floor((blockHeight - ink) / 2)

  -- A bar spans the panel by design and sits on its floor rather than in a
  -- band; a supporting row sits in the tertiary band above it.
  local barY = math.max(1, rect.h - frame.bottom - resolved.spacing.barHeight)
  out.barY = barY
  out.showVisual = visual
  out.showDetail = rows
  -- A bar owns the panel's floor, so a supporting row sits above it; where
  -- there is no bar the row takes the tertiary band the panel reserved.
  -- Asked of what the component draws rather than of `spec.bar`, because a
  -- panel that can draw a bar and currently does not still keeps its floor
  -- clear for one.
  out.detailY = spec.bar and math.max(1, barY - frame.labelHeight - 2)
    or theme.centreInBand(ladder.bands.tertiary, frame.labelHeight)
  -- **A row of one centres across the content box; a row of two takes the
  -- panel's two slot centres.** Which it is is the component's to say,
  -- because a span knows only what is permitted -- `metric` may carry a
  -- secondary reading at `2 x 2` and whether it does depends on a source
  -- being configured. Two boxes centred that far apart can each be half the
  -- distance between them before they meet, and that is the budget each
  -- wording is fitted to.
  if spec.rowItems == 2 then
    -- The row's own slots, which are the tightened pair whatever the body
    -- fell back to: a row is two labels and cannot collide the way a reading
    -- and a dial can.
    local left, right = theme.slotCentres(frame)
    local budget = math.max(1, right - left - 4)
    out.detailCentre, out.detailWidth = left, budget
    out.detailX = left - math.floor(budget / 2)
    out.rowRightCentre, out.rowRightWidth = right, budget
    out.rowRightX = right - math.floor(budget / 2)
  else
    out.detailCentre = frame.pad + math.floor(frame.content / 2)
    out.detailWidth = frame.content
    out.detailX = frame.pad
    if out.rowRightCentre ~= nil then
      out.rowRightCentre, out.rowRightWidth, out.rowRightX = nil, nil, nil
    end
  end

  return out
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
