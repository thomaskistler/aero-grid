-- SPDX-License-Identifier: GPL-2.0-only

--- The radio, as far as the test suites are concerned.
---
--- Five defects reached a radio while this project's tests stayed green, and
--- every one had the same cause: a fixture encoded what we assumed rather than
--- what the firmware does, so it could not fail when the assumption was wrong.
--- A green suite meant nothing, because the mock and the code under test
--- shared the same mistake.
---
--- The values here are therefore split into two namespaces, and which one a
--- value lives in is the first thing a reviewer should look at.
---
--- `firmware` is a claim about the radio. Every entry names the firmware file
--- and symbol it was read from, and this module refuses to load if one does
--- not, so a number nobody checked cannot quietly acquire the authority of a
--- number somebody did. When one of these is wrong, the dashboard is wrong on
--- hardware and the suite will not notice.
---
--- `scaffold` is invented. Sensor ids, model names, a pilot standing in
--- Zurich. Nothing in it is a claim about anything, and a reviewer can skip it.
---
--- The obligation covers behaviour as well as values. The arc arithmetic, the
--- deferred clear ordering and the colour encoding below are reproductions of
--- firmware the dashboard depends on, and each cites its source: three of the
--- five incidents were wrong behaviour rather than a wrong constant, so a
--- citation rule that stopped at numbers would have caught almost none of them.

local support = {}

--------------------------------------------------------------------------
-- The firmware namespace, and the obligation that comes with it
--------------------------------------------------------------------------

local firmware = {}
local citations = {}

local function refuse(message)
  -- Level 0: the message is about this file, not about the caller's line.
  error("tests/support/edgetx.lua: " .. message, 0)
end

--- Record a value, arithmetic, or message that EdgeTX really produces.
---
--- The citation is not documentation, it is the price of entry. An uncited
--- claim is indistinguishable from a guess, and a guess is what shipped five
--- times. There is deliberately no way to skip this and no warning-only mode:
--- the module raises before any test runs, and the suite does not start.
---
---@param name string Key within `firmware`.
---@param file string Path in the EdgeTX tree, starting at `radio/src/`.
---@param symbol string Function, macro, enum, or member the value comes from.
---@param value any The value itself, which may be a table.
---@return any value
local function claim(name, file, symbol, value)
  if type(name) ~= "string" or name == "" then
    refuse("a claim needs a name")
  end
  if citations[name] then
    refuse("duplicate claim for " .. name)
  end
  if type(file) ~= "string" or not string.match(file, "^radio/src/") then
    refuse(name .. " cites " .. tostring(file) .. ", which is not a path in "
      .. "the EdgeTX tree. Cite the file you read it from, starting at "
      .. "radio/src/, or move the value to scaffold if it is invented.")
  end
  if type(symbol) ~= "string" or symbol == "" then
    refuse(name .. " cites " .. file .. " but names no symbol in it. Name the "
      .. "function, macro, enum, or member, so the next reader can check it "
      .. "without searching.")
  end
  if value == nil then
    refuse(name .. " claims nothing")
  end

  citations[name] = {file = file, symbol = symbol}
  rawset(firmware, name, value)
  return value
end

--- Where a firmware value came from.
---@param name string
---@return table citation `{file, symbol}`
function support.citation(name)
  local citation = citations[name]
  if not citation then refuse("no such firmware value: " .. tostring(name)) end
  return {file = citation.file, symbol = citation.symbol}
end

--------------------------------------------------------------------------
-- Fonts
--------------------------------------------------------------------------

-- EdgeTX exports font constants as LcdFlags, not as indices: FONT(xx) is
-- `unsigned(FONT_##xx##_INDEX) << 8u`, so SMLSIZE reaches a script as 768. The
-- fixtures used to publish 2 through 6, which made STRING, a widget option
-- type that really is 3, collide with SMLSIZE. On a radio they are 3 and 768
-- and cannot be confused; here they could be, and nothing would have noticed a
-- component asking for a font where an option type belongs.
local FONTS_H = "radio/src/gui/colorlcd/fonts.h"
local LUA_CONSTANTS = "radio/src/lua/api_general.cpp"

claim("TINSIZE", LUA_CONSTANTS, "LROT_NUMENTRY(TINSIZE, FONT(XXS))", 2 * 256)
claim("SMLSIZE", LUA_CONSTANTS, "LROT_NUMENTRY(SMLSIZE, FONT(XS))", 3 * 256)
claim("MIDSIZE", LUA_CONSTANTS, "LROT_NUMENTRY(MIDSIZE, FONT(L))", 4 * 256)
claim("DBLSIZE", LUA_CONSTANTS, "LROT_NUMENTRY(DBLSIZE, FONT(XL))", 5 * 256)
claim("XXLSIZE", LUA_CONSTANTS, "LROT_NUMENTRY(XXLSIZE, FONT(XXL))", 6 * 256)
claim("BOLD", LUA_CONSTANTS, "LROT_NUMENTRY(BOLD, FONT(BOLD))", 1 * 256)
claim("FONT_MASK", FONTS_H, "FONT_MASK", 0x0F00)

-- A widget option type, sharing no numbering with the fonts above.
claim("STRING", LUA_CONSTANTS, "LROT_NUMENTRY(STRING, WidgetOption::String)", 3)

--- Line heights of the font set a 480 x 272 radio is built with.
---
--- `radio/src/fonts/CMakeLists.txt` selects `sml` for 320 x 240 and `lrg` for
--- 800 x 480; everything else, this display included, falls through to `std`.
--- Reading these out of the wrong set is an easy and expensive mistake: the
--- `sml` figures are 54, 33, 23, 14 and 10, and adopting them would rescale
--- every text fitting decision the dashboard makes.
claim("FONT_HEIGHT", "radio/src/fonts/lvgl/std/",
  "lv_font_en_{bold_XXL,bold_XL,L,XS,XXS}.c lv_font_t.line_height", {
    [firmware.XXLSIZE] = 69,
    [firmware.DBLSIZE] = 40,
    [firmware.MIDSIZE] = 29,
    [firmware.SMLSIZE] = 17,
    [firmware.TINSIZE] = 12,
  })

local FONT_NAMES = {
  [firmware.TINSIZE] = "TINSIZE",
  [firmware.SMLSIZE] = "SMLSIZE",
  [firmware.MIDSIZE] = "MIDSIZE",
  [firmware.DBLSIZE] = "DBLSIZE",
  [firmware.XXLSIZE] = "XXLSIZE",
  [firmware.BOLD] = "BOLD",
}

--- Name a font constant, so a failure reads as a font rather than as a number.
--- The real values are four figures, and "expected 1536, got 1280" tells a
--- reader nothing that "expected XXLSIZE, got DBLSIZE" does not tell them at
--- a glance.
---@param value any
---@return string
function support.fontName(value)
  return FONT_NAMES[value] or ("unknown font " .. tostring(value))
end

--------------------------------------------------------------------------
-- Colours
--------------------------------------------------------------------------

local COLORS_H = "radio/src/gui/colorlcd/colors.h"
local COLOR_API = "radio/src/lua/api_colorlcd.cpp"

claim("RGB_FLAG", COLORS_H, "RGB_FLAG", 0x8000)

-- COLOR2FLAGS(color) is `LcdFlags(unsigned(color) << 16u)` and the theme role
-- constants are exported through it, so a script receives the role index
-- shifted into the upper half rather than the index itself.
-- COLOR_THEME_PRIMARY1 is therefore zero, which is worth knowing before
-- writing `if role then`.
claim("COLOR_THEME", COLOR_API,
  "LROT_NUMENTRY(COLOR_THEME_*, COLOR2FLAGS(*_INDEX))", {
    primary1 = 0 * 65536,
    primary2 = 1 * 65536,
    primary3 = 2 * 65536,
    secondary1 = 3 * 65536,
    secondary2 = 4 * 65536,
    secondary3 = 5 * 65536,
    focus = 6 * 65536,
    edit = 7 * 65536,
    active = 8 * 65536,
    warning = 9 * 65536,
    disabled = 10 * 65536,
  })

--- The EdgeTX Default theme, exactly as the firmware ships it.
---
--- These were once invented to match the role *names*, with a green ACTIVE, an
--- amber WARNING and an orange EDIT. The firmware ships none of those: ACTIVE
--- is yellow, EDIT is green and WARNING is red. Mapping dashboard accents onto
--- them by name therefore drew healthy panels yellow and warnings in a red
--- indistinguishable from critical, and the fixture agreed with the mistake so
--- no test could see it.
---
--- The firmware stores these as RGB565 through its RGB() macro; they are
--- written here as the 24-bit values that macro is given.
claim("DEFAULT_COLORS", "radio/src/gui/colorlcd/colors.cpp", "defaultColors", {
  primary1 = 0x000000,
  primary2 = 0xFFFFFF,
  primary3 = 0x0C3F66,
  secondary1 = 0x125E99,
  secondary2 = 0xB6E0F2,
  secondary3 = 0xE4EEF2,
  focus = 0x14A1E5,
  edit = 0x009909,
  active = 0xFFDE00,
  warning = 0xE00000,
  disabled = 0x8C8C8C,
})

--------------------------------------------------------------------------
-- Screen geometry
--------------------------------------------------------------------------

-- Registered beside the colour constants and exported through COLOR2FLAGS, so
-- it arrives shifted left sixteen bits: a TX16S reports 2949120, not 45. A
-- host that never unshifts it falls back to a hard-coded default and is then
-- wrong on every radio whose display class scales the constant.
claim("MENU_HEADER_HEIGHT_PX", "radio/src/gui/colorlcd/libui/etx_lv_theme.h",
  "EdgeTxStyles::MENU_HEADER_HEIGHT", 45)
claim("MENU_HEADER_HEIGHT_FLAGS", LUA_CONSTANTS,
  "LROT_NUMENTRY(MENU_HEADER_HEIGHT, COLOR2FLAGS(...))",
  firmware.MENU_HEADER_HEIGHT_PX * 65536)

-- The width the firmware keeps clear beside the EdgeTX button. Not exported to
-- Lua at all, which is why the host cannot read it and the dashboard has to
-- carry the number itself.
claim("MENU_HEADER_BUTTONS_LEFT",
  "radio/src/gui/colorlcd/mainview/datastructs_screen.h",
  "MENU_HEADER_BUTTONS_LEFT", 47)

--------------------------------------------------------------------------
-- The instruction budget
--------------------------------------------------------------------------

-- MAX_INSTRUCTIONS is (20000/100), used as the LUA_MASKCOUNT interval, and
-- luaHook raises "CPU limit" once its counter passes 100. So the allowance is
-- 20000 instructions, observed 200 at a time.
claim("INSTRUCTION_BUDGET", "radio/src/lua/widgets.cpp",
  "MAX_INSTRUCTIONS", 20000)
claim("INSTRUCTION_HOOK_COUNT", "radio/src/lua/widgets.cpp",
  "lua_sethook(L, luaHook, LUA_MASKCOUNT, MAX_INSTRUCTIONS)", 200)

--------------------------------------------------------------------------
-- Telemetry units
--------------------------------------------------------------------------

-- getFieldInfo reports a sensor's unit as one of these, and only for telemetry
-- sources: luaGetFieldInfo pushes `unit` inside a MIXSRC_FIRST_TELEM bound, so
-- a switch or a trim carries no unit at all.
claim("UNIT", "radio/src/dataconstants.h", "enum TelemetryUnit", {
  RAW = 0,
  VOLTS = 1,
  AMPS = 2,
  METERS_PER_SECOND = 5,
  FEET_PER_SECOND = 6,
  KMH = 7,
  METERS = 9,
  PERCENT = 13,
  DB = 17,
  DBM = 29,
  CELLS = 38,
  DATETIME = 39,
  GPS = 40,
  -- A sensor whose value is a string rather than a number. Crossfire and
  -- ELRS publish the aircraft's flight mode this way, as `FM`.
  TEXT = 42,
})

--------------------------------------------------------------------------
-- LVGL objects
--------------------------------------------------------------------------

local LVGL_CPP = "radio/src/lua/lua_lvgl_widget.cpp"
local LVGL_H = "radio/src/lua/lua_lvgl_widget.h"

claim("INVALID_OBJECT_MESSAGE", LVGL_CPP, "LvglWidgetObjectBase::checkLvgl",
  "Invalid object (it has been probably been cleared).")

--- A border width only reaches LVGL when the object is built, or when its
--- opacity moves.
---
--- `LvglWidgetBorderedObject::setOpacity` is the only caller of
--- `lv_obj_set_style_border_width`, and it runs behind
--- `LvglParamFuncOrValue::changedValue`, which returns false when the value it
--- is handed equals the one it already holds. `refresh()` passes the current
--- opacity, so a `set{thickness = n}` on an existing object updates the C++
--- member and stops there. A mock that simply stored the thickness reported a
--- weight the radio was never given, which is how a panel could claim a
--- heavier outline for its critical state and draw the resting one.
claim("BORDER_WIDTH_APPLIED_AT", LVGL_CPP,
  "LvglWidgetBorderedObject::setOpacity lv_obj_set_style_border_width",
  "build")

--- A corner radius is applied in `build` and never again.
--- `LvglWidgetRectangle::build` is the only caller of
--- `lv_obj_set_style_radius` for a rectangle, and `LvglWidgetRectangle` adds
--- no refresh of its own, so `rounded` passed to `set` is parsed and then
--- ignored. It is also raised to the border thickness when thinner:
--- `(rounded >= thickness) ? rounded : thickness`.
claim("ROUNDED_APPLIED_AT", LVGL_CPP,
  "LvglWidgetRectangle::build lv_obj_set_style_radius", "build")

--- Format of the error an unrecognized property raises.
--- An unknown key is not ignored on a radio: parseParam falls through to
--- luaL_error, so a misspelled property stops the script rather than quietly
--- doing nothing.
claim("INVALID_PROPERTY_FORMAT", LVGL_CPP, "LvglWidgetObjectBase::parseParam",
  "Invalid property '%s'")

local function keysOf(inherited, ...)
  local set = {}
  for key in pairs(inherited or {}) do set[key] = true end
  for _, key in ipairs({...}) do set[key] = true end
  return set
end

-- The chain of parseParam overrides for each class, read from the class
-- declarations in lua_lvgl_widget.h. Note that left, right, top and bottom are
-- nested inside borderPad rather than being keys in their own right, and that
-- children, type and name are accepted and ignored rather than rejected.
local OBJECT_BASE = keysOf(nil, "x", "y", "w", "h", "color", "opacity",
  "visible", "size", "pos", "floating", "children", "type", "name")
local OBJECT = keysOf(OBJECT_BASE, "flexFlow", "flexPad", "borderPad", "active")
local BOX = keysOf(OBJECT, "align", "scrollBar", "scrollDir", "scrollTo",
  "scrolled")
local BORDERED = keysOf(BOX, "thickness", "filled")
local ROUND = keysOf(BORDERED, "radius")

claim("PROPERTY_KEYS", LVGL_H, "LvglWidget* parseParam overrides", {
  box = BOX,
  rectangle = keysOf(BORDERED, "rounded"),
  arc = keysOf(ROUND, "rounded", "startAngle", "endAngle",
    "bgColor", "bgOpacity", "bgStartAngle", "bgEndAngle"),
  label = keysOf(OBJECT_BASE, "align", "text", "font"),
  image = keysOf(OBJECT, "file", "fill"),
})

--- Keys EdgeTX reads as a colour.
claim("COLOR_PROPERTY_KEYS", LVGL_CPP,
  "LvglWidgetObjectBase::parseParam color", {color = true, bgColor = true})

--------------------------------------------------------------------------
-- Seal the namespace
--------------------------------------------------------------------------

-- Anything that reached `firmware` without going through claim() is caught
-- here, before a single test runs.
for name in pairs(firmware) do
  if not citations[name] then
    refuse("firmware." .. name .. " has no citation.\n"
      .. "  Every value in the firmware namespace is a claim about the radio, "
      .. "and an uncited claim is indistinguishable from a guess.\n"
      .. "  Add it with claim(name, file, symbol, value), naming the file "
      .. "under radio/src/ and the symbol you read it from,\n"
      .. "  or put it in support.scaffold if it is invented test data.")
  end
end

setmetatable(firmware, {
  __newindex = function(_, name)
    refuse("firmware." .. tostring(name) .. " was assigned directly. Add it "
      .. "with claim(name, file, symbol, value) so it carries a citation.")
  end,
  __metatable = false,
})

support.firmware = firmware

--------------------------------------------------------------------------
-- The scaffold namespace: invented, and owed nothing
--------------------------------------------------------------------------

--- Values this suite made up. A reviewer can skip all of it.
---
--- The display size is here rather than in `firmware` deliberately. Which
--- panel to test against is a choice we made, not something read out of the
--- firmware: EdgeTX sets LCD_W and LCD_H per target, and 480 x 272 is simply
--- the TX16S-class screen this project aims at.
support.scaffold = {
  DISPLAY_WIDTH = 480,
  DISPLAY_HEIGHT = 272,
  MODEL_FILENAME = "test-model.yml",
  MODEL_NAME = "Test Model",
  MODEL_BITMAP = "plane.png",
  MODEL_LABELS = "fpv",
  -- A pilot in Zurich, with the model a little to the north east.
  PILOT_LATITUDE = 47.3700,
  PILOT_LONGITUDE = 8.5400,
  MODEL_LATITUDE = 47.3769,
  MODEL_LONGITUDE = 8.5417,
}

--------------------------------------------------------------------------
-- Installers
--------------------------------------------------------------------------

--- Publish the constants any Lua module may read.
---
--- Deliberately small, and deliberately separate from the rest. The unit suite
--- installs this and the colour surface and nothing else, which is what proves
--- a lib module works without a host: if one call installed everything, a
--- module that had quietly started reading `lvgl` or `model` would keep
--- passing here and fail on a radio.
function support.constants()
  TINSIZE = firmware.TINSIZE
  SMLSIZE = firmware.SMLSIZE
  MIDSIZE = firmware.MIDSIZE
  DBLSIZE = firmware.DBLSIZE
  XXLSIZE = firmware.XXLSIZE
  BOLD = firmware.BOLD
  STRING = firmware.STRING
end

--- Publish `lcd`, and the theme role constants it answers for.
---
---@param options? table `{roles = <role name to 24-bit colour>}`, to test a
---   palette other than the one the firmware ships.
---@return table handle
function support.lcd(options)
  options = options or {}

  --- Pack a 24-bit colour into RGB565, as EdgeTX's RGB() macro does.
  local function toRgb565(rgb)
    local red = math.floor(rgb / 65536) % 256
    local green = math.floor(rgb / 256) % 256
    local blue = rgb % 256
    return math.floor(red * 31 / 255) * 2048
      + math.floor(green * 63 / 255) * 32
      + math.floor(blue * 31 / 255)
  end

  --- Build the LcdFlags word EdgeTX hands a script for a colour.
  ---
  --- One encoder, because the firmware has one shape. luaRGB returns
  --- COLOR2FLAGS(RGB(r, g, b)) | RGB_FLAG and luaLcdGetColor returns
  --- colorToRGB(flags) & (COLOR_MASK(~0u) | RGB_FLAG): RGB565 in the upper
  --- half, RGB_FLAG in the lower. Encoding the two separately is exactly how
  --- the read side came to be corrected while the write side spent a day
  --- returning a bare 24-bit value, which made a palette token and a display
  --- value the same number and left nothing able to tell them apart.
  ---
  --- Cached because both firmware entry points are C functions that cost a
  --- script no VM instructions at all. The dashboard's budget should measure
  --- the dashboard, not arithmetic the radio does for free.
  local cache = {}
  local function toLcdFlags(rgb)
    local cached = cache[rgb]
    if cached then return cached end

    cached = toRgb565(rgb) * 65536 + firmware.RGB_FLAG
    cache[rgb] = cached
    return cached
  end

  local theme = firmware.COLOR_THEME
  COLOR_THEME_PRIMARY1 = theme.primary1
  COLOR_THEME_PRIMARY2 = theme.primary2
  COLOR_THEME_PRIMARY3 = theme.primary3
  COLOR_THEME_SECONDARY1 = theme.secondary1
  COLOR_THEME_SECONDARY2 = theme.secondary2
  COLOR_THEME_SECONDARY3 = theme.secondary3
  COLOR_THEME_FOCUS = theme.focus
  COLOR_THEME_EDIT = theme.edit
  COLOR_THEME_ACTIVE = theme.active
  COLOR_THEME_WARNING = theme.warning
  COLOR_THEME_DISABLED = theme.disabled

  -- Role constant to 24-bit colour, so getColor can answer by role.
  local palette = options.roles or firmware.DEFAULT_COLORS
  local roles = {}
  for name, role in pairs(theme) do roles[role] = palette[name] end

  lcd = {
    -- EdgeTX accepts lcd.RGB(r, g, b) or a single packed lcd.RGB(rgb), and
    -- returns a flag word either way.
    RGB = function(red, green, blue)
      if green ~= nil then red = red * 65536 + green * 256 + blue end
      return toLcdFlags(red)
    end,
    -- luaLcdGetColor answers nil for a role it does not recognize.
    getColor = function(role)
      local rgb = roles[role]
      if rgb == nil then return nil end
      return toLcdFlags(rgb)
    end,
  }

  return {
    toRgb565 = toRgb565,
    toLcdFlags = toLcdFlags,
    roles = roles,
    palette = palette,
  }
end

--- Publish `lvgl`, and the screen geometry a host reads from globals.
---@return table handle
function support.lvgl()
  MENU_HEADER_HEIGHT = firmware.MENU_HEADER_HEIGHT_FLAGS

  local objects = {}
  local pendingClears = {}
  local deferCleanup = false
  local appMode = false
  local validateProperties = true

  --- Emulate the firmware's post-callback ref cleanup.
  ---
  --- LvglWidgetObjectBase::clear only sets clearRequest and destroys windows.
  --- The reference cleanup happens later, in callRefs, and clearChildRefs then
  --- invalidates every reference in that object's child list, including ones
  --- created after the clear but within the same callback. Modelling clear()
  --- as an immediate flag hid a real defect, so this mirrors the ordering.
  local function settle()
    if deferCleanup then return end
    if #pendingClears == 0 then return end

    local pending = pendingClears
    pendingClears = {}
    for _, object in ipairs(pending) do
      object.clearRequest = false
      for _, child in ipairs(object.children) do
        child.invalid = true
      end
      object.children = {}
    end
  end

  --- Model how the firmware actually places a round object.
  ---
  --- EdgeTX positions an arc by its centre but stores a corner, and
  --- LvglWidgetRoundObject::refresh subtracts the radius twice: once inside
  --- setRadius, and again through the inherited setPos, which receives members
  --- that already hold a corner. Every update therefore walks an arc up and to
  --- the left by its own radius. A mock that records the coordinates it was
  --- handed cannot see that, which is why dials drifted off the radio while
  --- these tests stayed green.
  local function newRoundGeometry(properties)
    local fwX = properties.x or 0
    local fwY = properties.y or 0
    local fwRadius = properties.radius or 0
    local drawn = {x = 0, y = 0}

    -- LvglWidgetRoundObject::setPos, which subtracts the radius before
    -- delegating to LvglWidgetObject::setPos.
    local function setPos(nx, ny)
      fwX = nx - fwRadius
      fwY = ny - fwRadius
      drawn.x, drawn.y = fwX, fwY
    end

    local function setRadius(r)
      fwX = fwX + fwRadius
      fwY = fwY + fwRadius
      fwRadius = r
      setPos(fwX, fwY)
    end

    -- build() runs setPos then setRadius and never calls refresh, which is why
    -- a dial is only ever misplaced after its first update.
    setPos(fwX, fwY)
    setRadius(fwRadius)

    return {
      drawn = drawn,
      radius = function() return fwRadius end,
      -- update(): getParams overwrites only the supplied members, then
      -- refresh() runs setRadius followed by the inherited setPos.
      refresh = function(changes)
        if changes.x ~= nil then fwX = changes.x end
        if changes.y ~= nil then fwY = changes.y end
        if changes.radius ~= nil then fwRadius = changes.radius end
        setRadius(fwRadius)
        setPos(fwX, fwY)
      end,
    }
  end

  --- Reject exactly what the radio rejects.
  ---
  --- An unknown property raises on hardware, so a mock that accepts every key
  --- turns a misspelling into a silent no-op there and a pass here. A colour
  --- must additionally be a word lcd.RGB produced: the dashboard holds its
  --- palette twice, as 24-bit tokens for arithmetic and as display values for
  --- drawing, and handing an object the former paints a colour belonging to no
  --- theme at all. The radio cannot report that; this can.
  local propertyKeys = firmware.PROPERTY_KEYS
  local colorKeys = firmware.COLOR_PROPERTY_KEYS
  local rgbFlag = firmware.RGB_FLAG

  local function checkProperties(kind, properties)
    local accepted = propertyKeys[kind]
    if not accepted then return end

    for key, value in pairs(properties) do
      if not accepted[key] then
        error(string.format(firmware.INVALID_PROPERTY_FORMAT, tostring(key))
          .. " on " .. kind, 0)
      end
      if colorKeys[key]
          and (type(value) ~= "number" or value % 65536 ~= rgbFlag) then
        error(kind .. "." .. key .. " is not a colour lcd.RGB returned: "
          .. tostring(value), 0)
      end
    end
  end

  local function assertUsable(object)
    if object.invalid then error(firmware.INVALID_OBJECT_MESSAGE, 0) end
  end

  -- The body is repeated rather than shared, and validation is exchanged
  -- rather than tested for, because both a second call and an upvalue test
  -- cost the measured callback instructions the radio never pays. parseParam
  -- is C++; charging our stand-in for it to a Lua budget measures the fixture.
  --- `writes` counts calls from Lua into LVGL on this object. It is this
  --- harness's own bookkeeping, not a firmware value: nothing in EdgeTX
  --- exposes it. It exists so a test can see work that leaves no trace on
  --- screen, such as a panel repositioning a label it has hidden, which is
  --- otherwise invisible to every assertion and therefore free to grow.
  --- firmware: a Lua label is `lv_label_create` with a font style and nothing
  --- else (`etx_label_create`, `gui/colorlcd/libui/etx_lv_theme.cpp`), so its
  --- long mode is LVGL's default, which `lv_label_constructor` sets to
  --- `LV_LABEL_LONG_WRAP` (`thirdparty/lvgl/src/widgets/lv_label.c`). And a
  --- height of zero is not zero: `LvglSimpleWidgetObject::parseParam` turns it
  --- into `LV_SIZE_CONTENT` (`lua/lua_lvgl_widget.cpp`).
  ---
  --- Together those mean a label with an explicit width and `h = 0` whose
  --- text is wider than that width **wraps onto another line and grows
  --- downward**, into whatever the panel draws beneath it. Nothing about the
  --- text's content changes, so no assertion about what a label says can see
  --- it; only its height can.
  ---
  --- The line count is estimated from the same mean advance the dashboard
  --- uses, because this harness cannot measure glyphs either. The estimate is
  --- this harness's own; the behaviour being modelled -- that overflow grows
  --- the object rather than clipping it -- is the firmware's.
  local ADVANCE_RATIO = 0.58

  local function wrappedHeight(properties)
    local text = properties.text
    local width = properties.w
    if type(text) ~= "string" or text == "" then return nil end
    if type(width) ~= "number" or width <= 0 then return nil end

    local heights = firmware.FONT_HEIGHT
    local height = heights[properties.font and properties.font() or nil]
    if type(height) ~= "number" then height = heights[firmware.SMLSIZE] end

    local needed = math.floor(#text * height * ADVANCE_RATIO + 0.5)
    local lines = math.max(1, math.ceil(needed / width))
    return lines * height, lines
  end

  local function setChecked(object, changes)
    assertUsable(object)
    object.writes = object.writes + 1
    checkProperties(object.kind, changes)
    for key, value in pairs(changes) do object.properties[key] = value end
    if object.kind == "label" then
      object.drawnHeight, object.lines = wrappedHeight(object.properties)
    end
    if object.round then object.round.refresh(changes) end
  end

  --- No write counting here. Turning property validation off is what the
  --- budget harness does before it measures, and the counters have to go
  --- with it: a real object's setter is C++, so counting the call in Lua
  --- would bill the script for work the radio does not do.
  --- No wrap recomputation here, for the same reason there is no write
  --- counting: this is the setter the budget harness swaps in before it
  --- measures, and LVGL lays a label out in C. Charging a Lua stand-in for
  --- it to a widget callback measures the fixture and slowly squeezes the
  --- thing being measured.
  local function setUnchecked(object, changes)
    assertUsable(object)
    for key, value in pairs(changes) do object.properties[key] = value end
    if object.round then object.round.refresh(changes) end
  end

  local function clearObject(object)
    assertUsable(object)
    object.cleared = true
    if not object.clearRequest then
      object.clearRequest = true
      pendingClears[#pendingClears + 1] = object
    end
  end

  local function newObject(kind, parent, properties)
    if validateProperties then checkProperties(kind, properties) end
    local object = {
      kind = kind,
      parent = parent,
      properties = properties,
      children = {},
      cleared = false,
      hidden = false,
      invalid = false,
      writes = 0,
      visibilityCalls = 0,
      set = validateProperties and setChecked or setUnchecked,
      clear = clearObject,
    }

    -- A label's drawn height follows its text, because `h = 0` is
    -- `LV_SIZE_CONTENT` and the default long mode wraps.
    if kind == "label" then
      object.drawnHeight, object.lines = wrappedHeight(properties)
    end

    if kind == "arc" then object.round = newRoundGeometry(properties) end
    -- A rectangle's border width and corner radius reach LVGL when the object
    -- is built and never again, so what the radio actually paints is fixed
    -- here. `properties` keeps whatever Lua last passed; `painted` is what is
    -- on the screen, and the two diverge exactly where the firmware discards
    -- an update.
    if kind == "rectangle" then
      object.painted = {
        borderWidth = properties.filled and 0 or (properties.thickness or 0),
        -- LvglWidgetRectangle::build raises a radius thinner than the border.
        radius = math.max(properties.rounded or 0,
          (properties.rounded or 0) > 0 and (properties.thickness or 0) or 0),
      }
    end

    if parent then parent.children[#parent.children + 1] = object end
    objects[#objects + 1] = object
    return object
  end

  local function constructor(kind)
    return function(first, second)
      if second then return newObject(kind, first, second) end
      return newObject(kind, nil, first)
    end
  end

  local function plainHide(object) object.hidden = true end
  local function plainShow(object) object.hidden = false end

  local function countedHide(object)
    object.visibilityCalls = object.visibilityCalls + 1
    object.hidden = true
  end

  local function countedShow(object)
    object.visibilityCalls = object.visibilityCalls + 1
    object.hidden = false
  end

  lvgl = {
    box = constructor("box"),
    rectangle = constructor("rectangle"),
    label = constructor("label"),
    arc = constructor("arc"),
    image = constructor("image"),
    -- `visibilityCalls` is counted for the same reason as `writes`: telling
    -- an already-hidden object to hide again changes nothing on screen and
    -- so cannot be seen by any assertion about what is drawn.
    hide = countedHide,
    show = countedShow,
    isAppMode = function() return appMode end,
  }

  local width = support.scaffold.DISPLAY_WIDTH
  local height = support.scaffold.DISPLAY_HEIGHT
  local handle = {settle = settle, objects = objects}

  --- Turn property validation on or off for every object, existing and future.
  --- Called outside the instruction hook, so the exchange is never counted.
  function handle.setPropertyValidation(enabled)
    validateProperties = enabled
    local method = enabled and setChecked or setUnchecked
    for _, object in ipairs(objects) do object.set = method end
  end

  --- Swap the visibility counters in or out. Swapped rather than branched,
  --- so that a measured callback pays nothing at all for them, the same way
  --- property validation is swapped out rather than tested for.
  function handle.setCallCounting(enabled)
    lvgl.hide = enabled and countedHide or plainHide
    lvgl.show = enabled and countedShow or plainShow
  end

  --- Withhold deferred cleanup, as the firmware withholds it while the widget
  --- is off screen or once an error has been reported.
  function handle.setDeferCleanup(enabled) deferCleanup = enabled end

  function handle.setAppMode(enabled) appMode = enabled end

  --- The App mode zone: one widget over the whole display, at the origin.
  --- x and y are always zero for a widget; xabs and yabs carry where the zone
  --- really sits, and those six keys are the whole table
  --- (radio/src/lua/lua_widget_factory.cpp).
  function handle.appZone()
    appMode = true
    return {x = 0, y = 0, xabs = 0, yabs = 0, w = width, h = height}
  end

  --- The ordinary Full screen zone, with EdgeTX's own top bar above it.
  --- ViewMainDecoration::getWidgetsZone starts the widget zone at
  --- MENU_HEADER_HEIGHT and takes the same amount off its height whenever the
  --- bar is shown, so the zone begins below the button rather than under it.
  function handle.fullScreenZone()
    appMode = false
    return {
      x = 0, y = 0,
      xabs = 0, yabs = firmware.MENU_HEADER_HEIGHT_PX,
      w = width, h = height - firmware.MENU_HEADER_HEIGHT_PX,
    }
  end

  return handle
end

--- Publish the radio state services read through EdgeTX's global functions.
---
--- Everything here is driven by one mutable table, so a test changes the radio
--- rather than stubbing a function. The sensor ids and readings are scaffold;
--- the *shapes* are not, and each entry point cites the firmware it imitates.
---
---@param hostIo table The real `io`, since the caller replaces the global.
---@return table handle
function support.radio(hostIo)
  local UNIT = firmware.UNIT
  local scaffold = support.scaffold

  --- Timer key set, as `luaModelGetTimer` pushes it.
  ---
  --- The firmware pushes mode, start, value, countdownBeep, minuteBeep,
  --- persistent, name, showElapsed, switch, countdownStart and extraHaptic,
  --- and answers nil beyond MAX_TIMERS. `showElapsed` matters rather than
  --- merely being present: `model_service` reads it and flips a countdown to
  --- count up, and while the fixture omitted it that branch was permanently
  --- false and never reached a component.
  local function timer(name, start, value, persistent)
    return {
      mode = 1, start = start, value = value, countdownBeep = 0,
      minuteBeep = false, persistent = persistent or 0, name = name,
      showElapsed = false, switch = 0, countdownStart = 0, extraHaptic = 0,
    }
  end

  local radio = {
    rssi = 80,
    -- The model's RF alarm thresholds, which getRSSI reports alongside the
    -- reading. Nothing on the dashboard consults them yet; they are here
    -- because the radio returns them, not because a test needs them.
    rfAlarms = {warning = 45, critical = 42},
    modelFilename = scaffold.MODEL_FILENAME,
    fields = {
      RxBt = {id = 100, name = "RxBt", desc = "Rx battery", unit = UNIT.VOLTS},
      Curr = {id = 103, name = "Curr", desc = "Current", unit = UNIT.AMPS},
      Alt = {id = 106, name = "Alt", desc = "Altitude", unit = UNIT.METERS},
      ["Alt+"] = {id = 108, name = "Alt+", desc = "Altitude max", unit = UNIT.METERS},
      GPS = {id = 109, name = "GPS", desc = "GPS", unit = UNIT.GPS},
      GSpd = {id = 112, name = "GSpd", desc = "GPS speed", unit = UNIT.KMH},
      Dist = {id = 115, name = "Dist", desc = "Distance", unit = UNIT.METERS},
      -- A switch and a trim are not telemetry sources, so luaGetFieldInfo
      -- pushes no unit for them at all. That absence is load bearing: the
      -- mock uses it to decide what a dead link zeroes.
      sa = {id = 300, name = "sa", desc = "Switch A"},
      ["trim-ail"] = {id = 310, name = "trim-ail", desc = "Aileron trim"},
      ["tx-voltage"] = {id = 320, name = "tx-voltage", desc = "Tx voltage"},
    },
    values = {
      [100] = 24.0,
      [103] = 10,
      [106] = 100,
      [108] = 180,
      [109] = {
        lat = scaffold.MODEL_LATITUDE,
        lon = scaffold.MODEL_LONGITUDE,
        ["pilot-lat"] = scaffold.PILOT_LATITUDE,
        ["pilot-lon"] = scaffold.PILOT_LONGITUDE,
        delay = 1,
      },
      [112] = 42,
      [115] = 812,
      [300] = 1024,
      [310] = 240,
      [320] = 7.9,
    },
    sensors = {
      [0] = {name = "RxBt", prec = 2},
      [1] = {name = "Curr", prec = 1},
      [2] = {name = "Alt", prec = 0},
    },
    timers = {[0] = timer("Flight", 300, 90, 1)},
    globals = {[0] = 45},
    -- A global variable holds a value per flight mode, and
    -- luaModelGetGlobalVariable(index, flight_mode) reads the one stored for
    -- the mode it is given. A mock that ignores its second argument answers
    -- the same number whatever mode is asked for, so a component reading the
    -- wrong mode, or no mode at all, is invisible. Index 1 therefore carries
    -- its own value in flight mode 2, and inherits everywhere else.
    globalsByMode = {[1] = {[2] = 60}},
    globalDetails = {
      [0] = {name = "Rates", min = -100, max = 100, prec = 1, unit = UNIT.RAW},
    },
    --- The radio's battery meter range, as a 2S LiPo, which is what the
    --- fixture transmitter has. Every radio carries one of these.
    battMin = 6.4,
    battMax = 8.4,
    battWarn = 6.6,
    flightMode = 1,
    --- firmware: `MAX_FLIGHT_MODES` is 9 and `LEN_FLIGHT_MODE_NAME` is 10 on
    --- colour targets (`radio/src/dataconstants.h`). `luaGetFlightMode` reads
    --- `g_model.flightModeData[mode].name`, so every mode has its own name and
    --- an unnamed one is the empty string.
    ---
    --- Named per index rather than one name for every mode, because a mock
    --- that answered the same name whatever it was asked cannot tell a host
    --- reading the active mode apart from one reading all nine, and the
    --- dashboard now does both.
    flightModeNames = {
      [0] = "Normal",
      [1] = "Sport",
      [2] = "",
      [3] = "Launch",
      [4] = "LongRange7",
    },
  }

  -- Sixteen generic sensors, so a layout that fills the grid can reference a
  -- distinct live source per cell instead of sixteen names the radio rejects.
  for index = 1, 16 do
    local name = "S" .. index
    radio.fields[name] = {id = 400 + index, name = name, unit = UNIT.METERS}
    radio.values[400 + index] = index * 3
    radio.sensors[index + 2] = {name = name, prec = 1}
  end

  -- The remaining sources the service diagnostics layouts reference.
  radio.fields["trim-ele"] = {id = 311, name = "trim-ele", desc = "Elevator trim"}
  radio.fields["trim-rud"] = {id = 312, name = "trim-rud", desc = "Rudder trim"}
  radio.fields["trim-thr"] = {id = 313, name = "trim-thr", desc = "Throttle trim"}
  radio.fields.GPS2 = {id = 118, name = "GPS2", desc = "GPS 2", unit = UNIT.GPS}
  radio.values[311] = -120
  radio.values[312] = 0
  radio.values[313] = 64
  radio.values[118] = radio.values[109]
  radio.timers[1] = timer("Up", 0, 64)
  radio.timers[2] = timer("Glide", 60, 12)
  for index = 1, 3 do
    radio.globals[index] = index * 10
    radio.globalDetails[index] = {
      name = "GV" .. (index + 1), min = -100, max = 100, prec = 0,
      unit = UNIT.VOLTS,
    }
  end

  -- Vertical speed, which the metric's altitude preset takes as its secondary
  -- reading. It is never derived from altitude; an absent sensor simply leaves
  -- the secondary row unavailable.
  radio.fields.VSpd = {
    id = 120, name = "VSpd", desc = "Vertical speed",
    unit = UNIT.METERS_PER_SECOND,
  }
  radio.values[120] = 2.5
  radio.sensors[19] = {name = "VSpd", prec = 1}

  -- A flight pack. EdgeTX returns a table of individual cell voltages for the
  -- base cells source and a plain number for its extremes, which is exactly
  -- the shape mismatch cell-battery has to survive.
  radio.fields.Cels = {id = 130, name = "Cels", desc = "Cells", unit = UNIT.CELLS}
  radio.fields["Cels-"] = {id = 131, name = "Cels-", desc = "Cell min", unit = UNIT.CELLS}
  radio.fields["Cels+"] = {id = 132, name = "Cels+", desc = "Cell max", unit = UNIT.CELLS}
  radio.values[130] = {4.11, 4.13, 4.09, 4.12}
  radio.values[131] = 4.09
  radio.values[132] = 4.13
  radio.sensors[20] = {name = "Cels", prec = 2}

  -- Link sensors. FrSky populates RSSI in dB; ELRS populates 1RSS in dBm
  -- alongside RQly as a percentage, and the two protocols never both apply.
  --- firmware: Crossfire and ELRS publish the aircraft's flight mode as a
  --- text sensor named `FM`: `CS(FLIGHT_MODE_ID, 0, STR_SENSOR_FLIGHT_MODE,
  --- UNIT_TEXT, 0)` in `radio/src/telemetry/crossfire.cpp`, where
  --- `STR_SENSOR_FLIGHT_MODE` is `"FM"` (`telemetry/sensor_names.h`).
  --- `getValue` pushes the stored string rather than a number for it:
  --- `case UNIT_TEXT: lua_pushstring(L, telemetryItems[...].text)`
  --- (`radio/src/lua/api_general.cpp`). The text is capped at
  --- `TELEMETRY_SENSOR_TEXT_LENGTH`, which is 16.
  ---
  --- It is here because nothing in this harness has ever carried a text
  --- sensor, so the telemetry service's handling of one was entirely
  --- unexercised whether or not a component ever reads it.
  radio.fields.FM = {id = 145, name = "FM", desc = "Flight mode", unit = UNIT.TEXT}
  radio.fields.RSSI = {id = 140, name = "RSSI", desc = "RSSI", unit = UNIT.DB}
  radio.fields.RQly = {id = 141, name = "RQly", desc = "Link quality", unit = UNIT.PERCENT}
  radio.fields["RQly-"] = {
    id = 142, name = "RQly-", desc = "Link quality min", unit = UNIT.PERCENT,
  }
  radio.fields["1RSS"] = {id = 143, name = "1RSS", desc = "Antenna 1", unit = UNIT.DBM}
  radio.values[140] = 78
  radio.values[141] = 96
  -- A string, because `getValue` pushes one for a `UNIT_TEXT` sensor. A
  -- number here would let the service treat text as a reading and pass.
  radio.values[145] = "ANGLE"
  radio.values[142] = 62
  radio.values[143] = -72
  radio.sensors[21] = {name = "RSSI", prec = 0}
  radio.sensors[22] = {name = "RQly", prec = 0}

  -- Further GPS sources, so a layout that fills the grid with navigation
  -- panels really does carry more than one subscription.
  radio.fields.GPS3 = {id = 119, name = "GPS3", desc = "GPS 3", unit = UNIT.GPS}
  radio.fields.GPS4 = {id = 121, name = "GPS4", desc = "GPS 4", unit = UNIT.GPS}
  radio.values[119] = radio.values[109]
  radio.values[121] = radio.values[109]

  --- Does this radio's protocol populate an RSSI sensor at all?
  --- Some do not, and EdgeTX's getRSSI() then reads zero on a perfectly live
  --- link. That is a different situation from a dead link, and the two must
  --- not be simulated by the same flag or a test cannot tell them apart
  --- either.
  radio.rssiAbsent = false

  --- Files the radio reports through `fstat`, keyed by absolute path.
  --- Model bitmaps live under /IMAGES/ on the SD card, which the host running
  --- these tests does not have, so the mock answers for them directly.
  radio.files = {["/IMAGES/" .. scaffold.MODEL_BITMAP] = 4096}

  --- Reverse index from source id to field, rebuilt whenever a test adds one.
  --- It exists so the mock costs a table lookup rather than a scan: getValue
  --- is a C function in the firmware and costs no VM instructions at all, so a
  --- mock that searched would show up in the budget measurement.
  local fieldsById = {}

  local function indexFields()
    fieldsById = {}
    for _, field in pairs(radio.fields) do fieldsById[field.id] = field end
  end

  indexFields()

  function getValue(source)
    local field
    if type(source) == "string" then
      field = radio.fields[source]
      source = field and field.id or nil
    else
      field = fieldsById[source]
    end
    if source == nil then return nil end

    -- EdgeTX returns integer zero for every telemetry source while telemetry
    -- is not streaming. A mock that kept reporting real values instead would
    -- let a freshness bug pass, because nothing would ever look like a dead
    -- link.
    --
    -- The RSSI indicator is not the same thing as the telemetry stream: on a
    -- protocol that populates no RSSI sensor, getRSSI() reads zero while
    -- values keep arriving. `rssiAbsent` simulates that, and nothing else.
    if field and field.unit and radio.rssi == 0 and not radio.rssiAbsent then
      return 0
    end

    return radio.values[source]
  end

  --- luaGetFieldInfo pushes id, name and desc, and pushes `unit` only for a
  --- source between MIXSRC_FIRST_TELEM and MIXSRC_LAST_TELEM.
  function getFieldInfo(name)
    return radio.fields[name]
  end

  --- luaGetRSSI pushes min((uint8_t)99, TELEMETRY_RSSI()), then
  --- g_model.rfAlarms.warning and .critical. A reading above 99 is a number
  --- no radio can produce, so the mock cannot hand one out either.
  function getRSSI()
    local rssi = radio.rssi
    if rssi > 99 then rssi = 99 end
    return rssi, radio.rfAlarms.warning, radio.rfAlarms.critical
  end

  --- firmware: `luaGetFlightMode` takes an optional mode index and falls back
  --- to `mixerCurrentFlightMode` when it is absent or out of range:
  --- `if (mode < 0 || mode >= MAX_FLIGHT_MODES) mode = mixerCurrentFlightMode`
  --- (`radio/src/lua/api_general.cpp`). It always returns two values, the
  --- index and `g_model.flightModeData[mode].name`, and an unnamed mode
  --- returns an empty string rather than nothing.
  ---
  --- The argument is honoured here because the dashboard reads every mode's
  --- name to size its panel. A mock that ignored it would answer the active
  --- mode's name nine times and the panel would be sized from one name while
  --- claiming to be sized from all of them.
  --- firmware: `luaGetGeneralSettings` (`radio/src/lua/api_general.cpp`)
  --- returns one table, with the battery figures already in volts:
  ---
  ---     lua_pushtablenumber(L, "battWarn", (g_eeGeneral.vBatWarn) * 0.1f);
  ---     lua_pushtablenumber(L, "battMin", (90+g_eeGeneral.vBatMin) * 0.1f);
  ---     lua_pushtablenumber(L, "battMax", (120+g_eeGeneral.vBatMax) * 0.1f);
  ---
  --- The settings screen holds the range between 3.0 V and 16.0 V and will
  --- not let the two cross, so a range from a real radio is always the right
  --- way round (`radio/src/gui/colorlcd/radio/radio_hardware.cpp`).
  ---
  --- A fresh table each call, because the firmware builds one with
  --- `lua_newtable` every time; a mock handing back the same table would let
  --- a component keep a reference and never notice the pilot changing it.
  function getGeneralSettings()
    return {
      battWarn = radio.battWarn,
      battMin = radio.battMin,
      battMax = radio.battMax,
      imperial = 0,
      language = "EN",
      voice = "en",
      gtimer = 0,
    }
  end

  function getFlightMode(index)
    local mode = index
    if type(mode) ~= "number" or mode < 0 or mode >= 9 then
      mode = radio.flightMode
    end
    return mode, radio.flightModeNames[mode] or ""
  end

  model = {
    -- luaModelGetInfo pushes name, extendedLimits, jitterFilter, bitmap,
    -- labels and filename. `bitmap` is a bare filename, not a path: the
    -- dashboard is the one that knows it lives under /IMAGES/.
    getInfo = function()
      return {
        filename = radio.modelFilename,
        name = scaffold.MODEL_NAME,
        bitmap = scaffold.MODEL_BITMAP,
        labels = scaffold.MODEL_LABELS,
        extendedLimits = false,
        jitterFilter = 0,
      }
    end,
    getTimer = function(index) return radio.timers[index] end,
    getSensor = function(index) return radio.sensors[index] end,
    getGlobalVariable = function(index, flightMode)
      local perMode = radio.globalsByMode[index]
      local value = perMode and perMode[flightMode]
      if value ~= nil then return value end
      return radio.globals[index]
    end,
    getGlobalVariableDetails = function(index)
      return radio.globalDetails[index]
    end,
  }

  -- EdgeTX's monotonic clock, in 10ms ticks. Controllable so scheduling is
  -- deterministic rather than dependent on wall time.
  local clock = 0

  function getTime()
    return clock
  end

  function loadScript(filename)
    return loadfile(filename)
  end

  --- firmware: `luaFstat` (`radio/src/lua/api_filesystem.cpp`) returns one
  --- table of `size`, `attrib` and `time`, and returns no values at all for a
  --- file it cannot stat. `time` is a date-time table unpacked from FatFs's
  --- packed `fdate` and `ftime`: year is the field plus 1980, and seconds are
  --- the field doubled, which is why FAT timestamps are even. The host
  --- diagnostics view reads `time.year` and the fields beside it, so the
  --- table is populated rather than carried empty: a mock that answered `{}`
  --- would let that view report a blank timestamp and pass.
  ---
  --- The values are this harness's own, not a claim about any particular
  --- file. Only the shape and the ranges are the firmware's.
  function fstat(filename)
    local function stat(size)
      return {
        size = size,
        attrib = 32,
        time = {year = 2026, mon = 9, day = 18, hour = 17, min = 4, sec = 0},
      }
    end

    -- The radio's own SD card comes first, so a test can describe a model
    -- bitmap that the host filesystem does not have.
    local size = radio.files[filename]
    if size then return stat(size) end

    local handle = hostIo.open(filename, "rb")
    if not handle then return end
    size = handle:seek("end")
    handle:close()
    return stat(size)
  end

  local handle = {state = radio}

  --- Reset the radio to the state every test starts from.
  function handle.reset()
    indexFields()
    radio.rssi = 80
    radio.rssiAbsent = false
    radio.values[100] = 24.0
    radio.values[103] = 10
    radio.values[106] = 100
    -- Vertical speed was missing here, so a test that moved it left the next
    -- one reading its value. Found when one did.
    radio.values[120] = 2.5
    radio.values[300] = 1024
    radio.values[130] = {4.11, 4.13, 4.09, 4.12}
    radio.values[131] = 4.09
    radio.values[140] = 78
    radio.values[141] = 96
    radio.values[145] = "ANGLE"
    radio.battMin = 6.4
    radio.battMax = 8.4
    radio.battWarn = 6.6
    radio.values[109].lat = scaffold.MODEL_LATITUDE
    radio.values[109].lon = scaffold.MODEL_LONGITUDE
    radio.values[109]["pilot-lat"] = scaffold.PILOT_LATITUDE
    radio.values[109]["pilot-lon"] = scaffold.PILOT_LONGITUDE
  end

  --- Advance the simulated clock.
  function handle.tick(amount)
    clock = clock + (amount or 1)
  end

  handle.indexFields = indexFields

  return handle
end

return support
