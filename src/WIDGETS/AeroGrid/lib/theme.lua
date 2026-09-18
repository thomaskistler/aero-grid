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

  return {
    mode = mode,
    rgb = tokens,
    color = toDisplay(tokens),
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

--- Width reserved for a panel's state badge on its header row.
local BADGE_WIDTH = 56

--- Narrowest header label worth drawing, about two characters at SMLSIZE.
--- A label squeezed below this says nothing and only clips, so it is dropped.
local MIN_LABEL_WIDTH = 24

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
  -- Short panels cannot afford the standard vertical rhythm, but the
  -- horizontal padding has a floor their height has no say in: the accent
  -- stripe occupies the left edge, and content that started at the stripe's
  -- own right edge read as crowded against it on every panel under 80 px
  -- tall, which is most of a four-row dashboard.
  local tight = rect.h < 80
  local pad = tight and spacing.paddingTight or spacing.padding
  local compact = tight and 2 or spacing.paddingCompact

  local content = math.max(1, rect.w - pad * 2)
  -- The badge may never take so much of a narrow panel that the label beside
  -- it is squeezed to nothing: both have to be readable at once, which is the
  -- whole reason the badge is not drawn over the label.
  local badgeWidth = math.min(BADGE_WIDTH, math.max(1, math.floor(content / 2)))
  local badgeX = math.max(pad, rect.w - pad - badgeWidth)
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

  local labelWidth = math.max(1, badgeX - labelX - 4)

  return {
    width = rect.w,
    height = rect.h,
    pad = pad,
    compact = compact,
    content = content,
    labelHeight = labelHeight,
    badgeWidth = badgeWidth,
    badgeX = badgeX,
    labelX = labelX,
    labelWidth = labelWidth,
    -- A panel narrow enough that the obstruction leaves no room beside it
    -- drops its label rather than clipping one glyph of it. The reading is
    -- what a pilot needs; the label is the part that can be given up.
    labelHidden = reserved ~= nil and labelWidth < MIN_LABEL_WIDTH,
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
--- question already answered, and drawing one on every panel spends the
--- border on decoration at exactly the moment it should mean something. A
--- border therefore appears only where it is the message: focus, editing, and
--- the two alarm states. Those are all drawn at the focus weight, because a
--- one-pixel alarm outline on a 480 x 272 panel is not an alarm.
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
    presentation.badge = "STALE"
    presentation.dim = true
  elseif state == "warning" then
    presentation.accent = color.amber
    presentation.border = color.amber
    presentation.borderWidth = resolved.spacing.borderFocus
    presentation.badge = "WARN"
  elseif state == "critical" then
    presentation.accent = color.critical
    presentation.border = color.critical
    presentation.value = color.text
    presentation.badge = "CRIT"
    presentation.borderWidth = resolved.spacing.borderFocus
  elseif state == "unavailable" then
    presentation.accent = color.textFaint
    presentation.value = color.textFaint
    presentation.label = color.textFaint
    presentation.badge = "NO SOURCE"
    presentation.dim = true
  elseif state == "editing" then
    presentation.border = color.cyan
    presentation.borderWidth = resolved.spacing.borderFocus
    presentation.badge = "EDIT"
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
