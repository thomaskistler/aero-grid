-- SPDX-License-Identifier: GPL-2.0-only

--- Semantic theme tokens, theme modes, and state resolution.
--- The host owns every color. Components receive resolved tokens and must not
--- define their own background palettes.

---@class AeroGridThemeTokens
---@field canvas integer
---@field surface integer
---@field surfaceRaised integer
---@field border integer
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
---@field warnings string[] Non-fatal problems encountered while resolving.

local theme = {}

--- The designed instrument palette from the project specification.
local MODERN = {
  canvas = 0x101316,
  surface = 0x1A1F23,
  surfaceRaised = 0x22282D,
  border = 0x343B40,
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
local SPACING = {
  outerMargin = 4,
  gutter = 4,
  padding = 8,
  paddingCompact = 6,
  radius = 4,
  accentWidth = 4,
  barHeight = 4,
  borderThin = 1,
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
---@param warnings string[]
local function correctContrast(tokens, key, background, minimum, warnings)
  if theme.contrast(background, tokens[key]) >= minimum then return end

  local candidate = betterContrast(background, MODERN[key], theme.shade(background, 0.85))
  if theme.contrast(background, candidate) < minimum then
    candidate = betterContrast(background, 0xFFFFFF, 0x000000)
  end

  tokens[key] = candidate
  warnings[#warnings + 1] = key .. " was corrected for contrast"
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
---@param warnings string[]
local function correctAccent(tokens, key, background, minimum, warnings)
  if theme.contrast(background, tokens[key]) >= minimum then return end

  -- Lighten on dark surfaces and darken on light ones so the hue survives.
  local direction = luminance(background) < 0.18 and 1 or -1
  for _, amount in ipairs({0.2, 0.35, 0.5, 0.65, 0.8}) do
    local candidate = theme.shade(tokens[key], direction * amount)
    if theme.contrast(background, candidate) >= minimum then
      tokens[key] = candidate
      warnings[#warnings + 1] = key .. " was corrected for contrast"
      return
    end
  end

  tokens[key] = betterContrast(background, 0xFFFFFF, 0x000000)
  warnings[#warnings + 1] = key .. " was replaced for contrast"
end

--- Guarantee that a derived palette is structurally visible and legible.
--- Modern is exempt because its values are specified directly.
---@param tokens table
---@param warnings string[]
local function enforceLegibility(tokens, warnings)
  -- Structural separation: panels, elevation, and borders must be visible.
  if theme.contrast(tokens.canvas, tokens.surface) < 1.10 then
    tokens.surface = separated(tokens.canvas, 1.10)
  end
  tokens.surfaceRaised = separated(tokens.surface, 1.08)
  if theme.contrast(tokens.surface, tokens.border) < 1.25 then
    tokens.border = separated(tokens.surface, 1.25)
  end

  correctContrast(tokens, "text", tokens.surface, MIN_TEXT_CONTRAST, warnings)
  correctContrast(tokens, "textMuted", tokens.surface, MIN_MUTED_CONTRAST, warnings)
  correctContrast(tokens, "textFaint", tokens.surface, MIN_FAINT_CONTRAST, warnings)

  -- Accents carry state, so each one must remain visible on the panel surface.
  for _, key in ipairs({"cyan", "green", "amber", "orange", "critical"}) do
    correctAccent(tokens, key, tokens.surface, MIN_ACCENT_CONTRAST, warnings)
  end
end

--- Read one EdgeTX theme role and widen it to 24-bit.
---@param env table Resolved EdgeTX environment.
---@param role any Value of a COLOR_THEME_* constant.
---@return integer? color
local function readRole(env, role)
  if type(role) ~= "number" then return nil end

  local ok, value = pcall(env.getColor, role)
  if not ok or type(value) ~= "number" then return nil end

  return theme.fromRgb565(value)
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
---@param warnings string[]
---@param env? table
---@return table tokens
local function deriveFromEdgeTx(warnings, env)
  local resolved = resolveEnv(env)
  local tokens = {}
  for key, value in pairs(MODERN) do tokens[key] = value end

  if not resolved then
    warnings[#warnings + 1] = "EdgeTX colors unavailable; using Modern palette"
    return tokens
  end

  local roles = resolved.roles
  local mapping = {
    canvas = roles.secondary1,
    surface = roles.secondary1,
    border = roles.primary3,
    text = roles.primary2,
    textMuted = roles.primary3,
    textFaint = roles.disabled,
    cyan = roles.focus,
    green = roles.active,
    amber = roles.warning,
    orange = roles.edit,
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
    warnings[#warnings + 1] = "EdgeTX theme roles unreadable; using Modern palette"
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
---@param mode? string One of modern, edgetx, or custom.
---@param overrides? table Custom mode overrides.
---@param env? table Optional injected EdgeTX color environment.
---@return AeroGridTheme
function theme.build(mode, overrides, env)
  local warnings = {}
  local accent = "cyan"
  local tokens

  if mode ~= nil and not theme.MODES[mode] then
    warnings[#warnings + 1] = "unknown theme mode " .. tostring(mode)
    mode = nil
  end
  mode = mode or "modern"

  if mode == "edgetx" then
    tokens = deriveFromEdgeTx(warnings, env)
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
    enforceLegibility(tokens, warnings)
  end

  return {
    mode = mode,
    rgb = tokens,
    color = toDisplay(tokens),
    spacing = SPACING,
    accent = accent,
    warnings = warnings,
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
    borderWidth = resolved.spacing.borderThin,
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
