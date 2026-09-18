-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

--- The minimal EdgeTX surface the pure-Lua modules need.
---
--- Deliberately only `constants()` and `lcd()`. No `lvgl`, no `getValue`, no
--- `model`: that is what proves a lib module works without a host, and it only
--- proves it while the surface stays this small. If one call installed the
--- whole radio, a module that had quietly started reading a host global would
--- keep passing here and fail on hardware.
---
--- Every value in it is a claim about the radio carrying the firmware file and
--- symbol it came from; see `tests/support/edgetx.lua`.
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
local firmware = edgetx.firmware

edgetx.constants()
local lcdMock = edgetx.lcd()
local toRgb565 = lcdMock.toRgb565
local toLcdFlags = lcdMock.toLcdFlags

-- The minimal surface is the point, so it is asserted rather than assumed. A
-- lib module that quietly started reaching for a host global would otherwise
-- keep passing here, which is the whole reason this suite is separate.
for _, name in ipairs({"lvgl", "model", "getValue", "getFieldInfo", "getRSSI",
    "getTime", "getFlightMode", "fstat", "loadScript"}) do
  assert(_G[name] == nil,
    "the unit suite installed " .. name .. ", which it is meant to do without")
end

local function loadModule(relative)
  local chunk, err = loadfile(root .. "/src/WIDGETS/AeroGrid/" .. relative)
  assert(chunk, err)
  return chunk()
end

local grid = loadModule("lib/grid.lua")
local yaml = loadModule("lib/yaml.lua")
local layout = loadModule("lib/layout.lua")
local layoutStore = loadModule("lib/layout_store.lua")
local componentHost = loadModule("lib/component_host.lua")
local theme = loadModule("lib/theme.lua")
local primitives = loadModule("lib/primitives.lua")
local services = loadModule("lib/services.lua")
local telemetryService = loadModule("lib/telemetry_service.lua")
local modelService = loadModule("lib/model_service.lua")
local controlService = loadModule("lib/control_service.lua")
local extremaService = loadModule("lib/extrema_service.lua")
local navigationService = loadModule("lib/navigation_service.lua")

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
  end
end

--- Compare font constants by name.
---
--- The real constants are LcdFlags, so a mismatch otherwise reads "expected
--- 1536, got 1280", which tells a reader nothing. Correcting the fixture to
--- the radio's values is only worth doing if a failure stays legible.
local function assertFont(actual, expected, message)
  if actual ~= expected then
    error((message or "wrong font") .. ": expected "
      .. edgetx.fontName(expected) .. ", got " .. edgetx.fontName(actual), 2)
  end
end

local function testGridGeometry()
  local zone = {w = 480, h = 272}
  local left = assert(grid.rect(zone, {col = 0, row = 0, colSpan = 2, rowSpan = 2}, 4, 4, 4))
  local right = assert(grid.rect(zone, {col = 2, row = 0, colSpan = 2, rowSpan = 4}, 4, 4, 4))

  assertEqual(left.x, 0)
  assertEqual(left.y, 0)
  assertEqual(left.w, 238)
  assertEqual(left.h, 134)
  assertEqual(right.x, 242)
  assertEqual(right.y, 0)
  assertEqual(right.w, 238)
  assertEqual(right.h, 272)
end

local function testValidation()
  local document = assert(yaml.parse([[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: altitude
    type: placeholder
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      title: "Altitude #1"
      warning: 120.5
      enabled: true
  - id: speed
    type: placeholder
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
]]))

  local normalized, errors = layout.validate(document, grid)
  assertEqual(#errors, 0)
  assertEqual(#normalized.components, 2)
  assertEqual(normalized.components[1].config.title, "Altitude #1")
  assertEqual(normalized.components[1].config.warning, 120.5)
  assertEqual(normalized.components[1].config.enabled, true)
end

local function testOverlapIsRejected()
  local document = assert(yaml.parse([[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: first
    type: placeholder
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: second
    type: placeholder
    col: 1
    row: 1
    colSpan: 1
    rowSpan: 1
]]))

  local normalized, errors = layout.validate(document, grid)
  assertEqual(#normalized.components, 1)
  assertEqual(#errors, 1)
  assert(string.match(errors[1], "overlaps first"), errors[1])
end

local function testLayoutPath()
  local path = layoutStore.path("/WIDGETS/AeroGrid", "My Model.yml", "nav 1")
  assert(string.match(path, "^/WIDGETS/AeroGrid/layouts/My%-Model%-%x%x%x%x%-%-nav%-1%-%x%x%x%x%.yaml$"), path)
  assertEqual(layoutStore.path("/WIDGETS/AeroGrid", "model.yml", "main"),
    "/WIDGETS/AeroGrid/layouts/model--main.yaml")
end

--- Real EdgeTX model filenames must all resolve to distinct, path-safe layouts.
local function testModelFilenameResolution()
  local names = {
    "model1.yml", "MODEL01.yml", "Kavan Sonic.yml", "FPV-7in.yml",
    "Heli_450.yml", "..%2fescape.yml", "model1.yml.bak", "",
  }
  local seen = {}

  for _, name in ipairs(names) do
    local path = layoutStore.path("/WIDGETS/AeroGrid", name, "main")
    local segment = string.match(path, "^/WIDGETS/AeroGrid/layouts/([^/]+)%.yaml$")
    assert(segment, "unsafe layout path for " .. name .. ": " .. path)
    assert(not string.find(segment, "%.%."), "traversal survived for " .. name)
    assert(not seen[path], "filename collision for " .. name .. ": " .. path)
    seen[path] = true
  end

  -- Distinct dashboard IDs must not collide for one model either.
  assert(layoutStore.path("/WIDGETS/AeroGrid", "model1.yml", "main")
    ~= layoutStore.path("/WIDGETS/AeroGrid", "model1.yml", "nav"))
end

--- Unknown top-level keys are retained so newer authoring tools survive a load.
local function testUnknownKeysArePreserved()
  local document = assert(yaml.parse([[
version: 1
vendorExtra: keep-me
grid:
  columns: 4
  rows: 4
components:
  - id: only
    type: placeholder
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    futureKey: keep-me-too
]]))

  local normalized, errors = layout.validate(document, grid)
  assertEqual(#errors, 0)
  assertEqual(normalized.vendorExtra, "keep-me")
  assertEqual(normalized.components[1].futureKey, "keep-me-too")
end

--- Malformed documents must degrade into errors rather than raising.
--- Documents this loader cannot interpret fail closed; documents with merely
--- bad entries keep loading their valid components.
local function testMalformedInput()
  local cases = {
    {name = "scalar component entry", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - bare-scalar\n"},
    {name = "numeric component entry", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - 42\n"},
    {name = "components mapping", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  nope: 1\n"},
    {name = "missing grid", fatal = true, text = "version: 1\ncomponents: []\n"},
    {name = "future version", fatal = true, text = "version: 99\ngrid:\n  columns: 4\n  rows: 4\ncomponents: []\n"},
    {name = "wrong grid size", fatal = true, text = "version: 1\ngrid:\n  columns: 3\n  rows: 3\ncomponents: []\n"},
    {name = "unsafe type", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - id: a\n    type: ../evil\n    col: 0\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n"},
    {name = "fractional span", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - id: a\n    type: placeholder\n    col: 0\n    row: 0\n    colSpan: 1.5\n    rowSpan: 1\n"},
    {name = "out of bounds", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - id: a\n    type: placeholder\n    col: 3\n    row: 0\n    colSpan: 2\n    rowSpan: 1\n"},
    {name = "duplicate id", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - id: a\n    type: placeholder\n    col: 0\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n  - id: a\n    type: placeholder\n    col: 1\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n"},
  }

  for _, case in ipairs(cases) do
    local document = yaml.parse(case.text)
    if document then
      local ok, normalized, errors = pcall(layout.validate, document, grid)
      assert(ok, case.name .. " raised: " .. tostring(normalized))
      if case.fatal then
        assertEqual(normalized, nil, case.name .. " should fail closed")
      else
        assert(normalized, case.name .. " returned no layout")
        assert(#errors > 0, case.name .. " reported no error")
      end
    end
  end

  -- A non-table document must be rejected without raising.
  local ok, result = pcall(layout.validate, "not a document", grid)
  assert(ok, "string document raised")
  assertEqual(result, nil)
end

--- One invalid entry must not prevent surrounding valid entries from loading.
local function testInvalidEntryIsIsolated()
  local document = assert(yaml.parse([[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: good
    type: placeholder
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
  - bare-scalar
  - id: alsogood
    type: placeholder
    col: 1
    row: 0
    colSpan: 1
    rowSpan: 1
]]))

  local normalized, errors = layout.validate(document, grid)
  assertEqual(#normalized.components, 2)
  assertEqual(normalized.components[1].id, "good")
  assertEqual(normalized.components[2].id, "alsogood")
  assertEqual(#errors, 1)
end

local function testComponentContract()
  local valid = {id = "demo", apiVersion = 1, create = function() end}
  assert(componentHost.validateModule(valid, "demo"))

  local function rejects(module, typeName, pattern)
    local ok, err = componentHost.validateModule(module, typeName)
    assertEqual(ok, false)
    assert(string.match(err, pattern), err)
  end

  rejects("not a table", "demo", "must return a table")
  rejects({id = "demo", apiVersion = 2, create = function() end}, "demo", "incompatible")
  rejects({id = "../evil", apiVersion = 1, create = function() end}, "../evil", "invalid id")
  rejects({id = "other", apiVersion = 1, create = function() end}, "demo", "does not match type")
  rejects({id = "demo", apiVersion = 1}, "demo", "no create function")
  rejects({id = "demo", apiVersion = 1, create = function() end, refresh = 5}, "demo", "refresh must be a function")
  rejects({id = "demo", apiVersion = 1, create = function() end, supportedSpans = 5}, "demo", "supportedSpans")
end

local function testSupportedSpans()
  local restricted = {supportedSpans = {"1x1", "2x2"}}
  assertEqual(componentHost.supportsSpan(restricted, 1, 1), true)
  assertEqual(componentHost.supportsSpan(restricted, 2, 2), true)
  assertEqual(componentHost.supportsSpan(restricted, 4, 1), false)
  assertEqual(componentHost.supportsSpan({supportedSpans = {"any"}}, 4, 4), true)
  assertEqual(componentHost.supportsSpan({}, 3, 2), true)
  assertEqual(componentHost.spanName(2, 3), "2x3")
end

local function testSettingsResolution()
  local module = {
    settings = {
      {key = "title", type = "string", default = "DEFAULT"},
      {key = "limit", type = "number", default = 10},
      {key = "shown", type = "boolean", default = true},
      "malformed",
    },
  }

  local settings, warnings = componentHost.resolveSettings(
    module, {title = "Given", limit = "not a number", extra = "kept"})

  assertEqual(settings.title, "Given")
  assertEqual(settings.limit, 10)
  assertEqual(settings.shown, true)
  assertEqual(settings.extra, "kept")
  assertEqual(#warnings, 2)

  local defaults = componentHost.resolveSettings(module, nil)
  assertEqual(defaults.title, "DEFAULT")
end

--- A raising callback disables only its own component, and only reports once.
local function testLifecycleIsolation()
  local entry = {
    placement = {id = "bad"},
    instance = {},
    module = {refresh = function() error("boom", 0) end},
  }

  local ok, err = componentHost.dispatch(entry, "refresh")
  assertEqual(ok, false)
  assertEqual(err, "boom")
  assertEqual(entry.failed, true)

  local secondOk, secondError = componentHost.dispatch(entry, "refresh")
  assertEqual(secondOk, false)
  assertEqual(secondError, nil)

  -- Absent optional callbacks are a no-op success.
  local healthy = {placement = {id = "ok"}, instance = {}, module = {}}
  assertEqual(componentHost.dispatch(healthy, "background"), true)
  assertEqual(healthy.failed, nil)
end

--- Colors must survive the RGB565 round trip EdgeTX uses for theme roles.
local function testColorConversion()
  local function toRgb565(rgb)
    local red = math.floor(rgb / 65536) % 256
    local green = math.floor(rgb / 256) % 256
    local blue = rgb % 256
    return math.floor(red * 31 / 255) * 2048
      + math.floor(green * 63 / 255) * 32
      + math.floor(blue * 31 / 255)
  end

  assertEqual(theme.fromRgb565(toRgb565(0x000000)), 0x000000)
  assertEqual(theme.fromRgb565(toRgb565(0xFFFFFF)), 0xFFFFFF)

  -- Widening is lossy, so require closeness rather than equality.
  local widened = theme.fromRgb565(toRgb565(0x70D6F3))
  local red = math.floor(widened / 65536) % 256
  assert(math.abs(red - 0x70) <= 8, "red channel drifted: " .. red)

  assertEqual(math.floor(theme.contrast(0x000000, 0xFFFFFF) + 0.5), 21)
  assertEqual(theme.contrast(0x123456, 0x123456), 1)
  assertEqual(theme.shade(0x000000, 1), 0xFFFFFF)
  assertEqual(theme.shade(0xFFFFFF, -1), 0x000000)
end

--- Modern mode must reproduce the palette defined in the specification.
local function testModernTheme()
  local resolved = theme.build("modern")

  assertEqual(resolved.mode, "modern")
  assertEqual(#resolved.warnings, 0)
  assertEqual(#resolved.notices, 0)
  assertEqual(resolved.rgb.canvas, 0x0A0C0E)
  assertEqual(resolved.rgb.critical, 0xF05252)
  -- The palette is held twice and the two forms are not interchangeable: rgb
  -- is the 24-bit token contrast arithmetic runs on, color is what a radio
  -- is given to draw with. Asserting they are equal, as this did, asserted
  -- the one thing about them that is false on hardware.
  assertEqual(resolved.color.canvas, toLcdFlags(0x0A0C0E))
  assertEqual(resolved.spacing.gutter, 4)

  -- Panels carry no resting outline, so the fill against the screen is the
  -- only thing separating one panel from the next, and the separation is a
  -- number rather than a matter of taste. The pairing this replaced measured
  -- 1.122, which read as one flat field with faint boxes on it.
  local elevation = theme.contrast(resolved.rgb.canvas, resolved.rgb.surface)
  assert(elevation >= 1.30,
    string.format("panels are not elevated above the screen: %.3f", elevation))
  assert(theme.contrast(resolved.rgb.surface, resolved.rgb.surfaceRaised) >= 1.20,
    "a raised surface is not separated from the panel it sits on")
  -- Lifting the panel spends contrast every token measured against it has to
  -- give up, and the track is the one with the least to spare.
  assert(theme.contrast(resolved.rgb.surface, resolved.rgb.track) >= 2.0,
    "the track vanished into a lifted surface")

  -- The corner radius is pinned as a number on purpose. Everything that draws
  -- a corner reads it from here, so a test comparing a drawn corner against
  -- this token agrees with any value at all, including the 4 px the design
  -- was rejected for. Eight is the design, and this is where it is stated.
  assertEqual(resolved.spacing.radius, 8)
  -- Content clears the accent stripe rather than starting at its right edge.
  assert(resolved.spacing.paddingTight
    >= resolved.spacing.accentWidth + resolved.spacing.accentGap,
    "a short panel's padding leaves content against the accent stripe")

  -- An unknown mode degrades to Modern and says so.
  local fallback = theme.build("neon")
  assertEqual(fallback.mode, "modern")
  assert(string.match(fallback.warnings[1], "unknown theme mode"), fallback.warnings[1])

  -- No mode at all is Modern without complaint.
  assertEqual(theme.build().mode, "modern")
end

--- EdgeTX mode derives tokens, corrects contrast, and keeps critical red.
local function testEdgeTxTheme()
  local roles = {
    primary1 = 1, primary2 = 2, primary3 = 3,
    secondary1 = 4, secondary2 = 5, secondary3 = 6,
    focus = 7, edit = 8, active = 9, warning = 10, disabled = 11,
  }
  -- A pale EdgeTX theme whose own muted and faint colors would be unreadable
  -- for us. `secondary1` is deliberately dark enough that the legibility pass
  -- has no reason to move the canvas: the assertion below is the regression
  -- test for the flag-word decode, and it can only say the radio's colour
  -- survived if nothing legitimately moved it afterwards. The correction path
  -- is exercised by the hostile palette further down, which is its own test.
  local values = {
    [1] = 0x000000, [2] = 0xF0F0F0, [3] = 0x9E9E9E,
    [4] = 0x142838, [5] = 0x3F7CA8, [6] = 0xC8D8E4,
    [7] = 0x1E88E5, [8] = 0xFF8F00, [9] = 0x43A047,
    [10] = 0xF9A825, [11] = 0x757575,
  }

  -- `lcd.getColor` returns an LcdFlags word: the colour sits in the upper
  -- half with RGB_FLAG set in the lower. Handing back a bare RGB565 is the
  -- shape the firmware never produces. Both sides share one encoder, so
  -- neither can be corrected without the other.
  local asFlags = toLcdFlags

  local resolved = theme.build("edgetx", nil, {
    roles = roles,
    getColor = function(role) return asFlags(values[role]) end,
  })

  assertEqual(resolved.mode, "edgetx")

  -- The canvas has to be the radio's own colour, not merely different from
  -- Modern's. Reading the low half of the flag word `lcd.getColor` returns
  -- yielded red 16, green 0, blue 0 for every role of every theme: a value
  -- that satisfies "was it derived?" while being wrong for all of them, and
  -- which drew every panel dark red on a radio while this suite stayed green.
  assertEqual(resolved.rgb.canvas, theme.fromRgb565(toRgb565(values[4])),
    "the radio's own colour did not survive being read")
  assertEqual(resolved.rgb.text, theme.fromRgb565(toRgb565(values[2])),
    "the radio's own colour did not survive being read")
  assertEqual(resolved.rgb.critical, theme.modern().critical)
  assert(theme.contrast(resolved.rgb.surface, resolved.rgb.text) >= 4.5,
    "derived text is unreadable")
  -- A derived palette has to be elevated to the same degree Modern is, not
  -- merely to two colours that are not identical. `> 1` is satisfied by any
  -- pair at all, and a derived palette sitting at the old 1.10 floor looked
  -- flat next to Modern on the same radio one page apart.
  assert(theme.contrast(resolved.rgb.surface, resolved.rgb.surfaceRaised) >= 1.20,
    "surfaces were not separated")
  assert(theme.contrast(resolved.rgb.canvas, resolved.rgb.surface) >= 1.30,
    "a derived palette is flatter than Modern")

  -- Correcting a token for contrast is the legibility pass working, so it is
  -- a notice rather than a warning. Reporting it as a failure would put a
  -- permanent banner on every radio running a derived palette.
  assertEqual(#resolved.warnings, 0,
    "a derived palette reported its own legibility pass as a problem")

  -- Structure follows the radio; meaning does not. EdgeTX's roles are menu
  -- chrome and their names do not describe their colours: the shipped theme
  -- has a yellow ACTIVE, a green EDIT and a red WARNING. Mapping accents onto
  -- them by name rendered a warning in a red indistinguishable from critical,
  -- and drew healthy panels in yellow.
  local modern = theme.modern()
  for _, key in ipairs({"cyan", "green", "amber", "orange", "critical"}) do
    assertEqual(resolved.rgb[key], modern[key],
      key .. " was taken from the radio instead of keeping its meaning")
  end

  -- A theme that genuinely needs correcting still records it, so the guard
  -- that the legibility pass does something is kept rather than weakened: a
  -- surface this close to the accents leaves them unreadable untouched.
  local hostile = theme.build("edgetx", nil, {
    roles = roles,
    getColor = function(role)
      if role == 4 then return asFlags(0x70D6F3) end
      return asFlags(values[role])
    end,
  })
  assertEqual(#hostile.warnings, 0,
    "a derived palette reported its own legibility pass as a problem")
  assert(#hostile.notices > 0, "the legibility pass recorded nothing at all")
  for _, notice in ipairs(hostile.notices) do
    assertEqual(notice.severity, "info", notice.text)
  end

  -- A radio without color support falls back. Still not a failure, but the
  -- radio declined to answer, which is worth more than a contrast nudge.
  local missing = theme.build("edgetx", nil, {getColor = false})
  assertEqual(missing.rgb.canvas, theme.modern().canvas)
  assertEqual(#missing.warnings, 0)
  assertEqual(missing.notices[1].severity, "warning")
  assert(string.match(missing.notices[1].text, "unavailable"), missing.notices[1].text)

  -- Unreadable roles also fall back rather than producing an invisible theme.
  local broken = theme.build("edgetx", nil, {
    roles = roles,
    getColor = function() error("no colors", 0) end,
  })
  assertEqual(broken.rgb.canvas, theme.modern().canvas)
  local brokenText = {}
  for index, notice in ipairs(broken.notices) do brokenText[index] = notice.text end
  assert(string.match(table.concat(brokenText, "\n"), "unreadable"))
end

--- Custom mode accepts only the documented override set.
local function testCustomTheme()
  local resolved = theme.build("custom", {
    canvas = 0x000000,
    surface = 0x141414,
    accent = "green",
    border = 0xFF00FF,
    text = "white",
  })

  assertEqual(resolved.rgb.canvas, 0x000000)
  -- A custom surface is honoured only as far as it stays legible, exactly as
  -- a custom surface that would swallow text is. 0x141414 on a black canvas
  -- measures 1.15, and a panel that close to the screen has no edge at all
  -- now that nothing draws an outline, so the legibility pass lifts it and
  -- records having done so.
  assert(theme.contrast(resolved.rgb.canvas, resolved.rgb.surface) >= 1.30,
    "a custom surface was left flat against its own canvas")
  local lifted = {}
  for index, notice in ipairs(resolved.notices) do lifted[index] = notice.text end
  assert(string.match(table.concat(lifted, "\n"), "lifted to elevate"),
    "the host adapted a custom palette without saying so")
  assertEqual(resolved.accent, "green")
  assertEqual(resolved.rgb.border, theme.modern().border)

  local joined = table.concat(resolved.warnings, "\n")
  assert(string.match(joined, "border is not customizable"), joined)
  assert(string.match(joined, "text must be a 24%-bit color"), joined)

  -- An invalid accent is rejected and reported.
  local badAccent = theme.build("custom", {accent = "magenta"})
  assertEqual(badAccent.accent, "cyan")
  assert(string.match(table.concat(badAccent.warnings, "\n"), "not a semantic accent"))

  -- A light custom surface must force readable text.
  local light = theme.build("custom", {surface = 0xFFFFFF})
  assert(theme.contrast(light.rgb.surface, light.rgb.text) >= 4.5,
    "custom light surface left text unreadable")

  -- Overrides must be a mapping.
  local wrong = theme.build("custom", "nope")
  assert(string.match(table.concat(wrong.warnings, "\n"), "must be a mapping"))
end

--- Typography must grow with the component's span.
local function testTypography()
  assertFont(theme.typography(1, 1).primary, MIDSIZE)
  assertFont(theme.typography(2, 1).primary, DBLSIZE)
  assertFont(theme.typography(1, 2).primary, DBLSIZE)
  assertFont(theme.typography(2, 2).primary, XXLSIZE)
  assertFont(theme.typography(2, 2).unit, MIDSIZE)
  assertFont(theme.typography(1, 1).unit, SMLSIZE)
  assertFont(theme.typography(1, 1).label, SMLSIZE)
end

--- Every state must be distinguishable by more than color alone.
---
--- A presentation carries display values, because a component hands them
--- straight to an LVGL object. They are compared against `lcd.RGB(token)`
--- rather than against the token, which is the difference between asserting
--- what the radio is given and asserting a mock's identity function.
local function testStates()
  local resolved = theme.build("modern")
  local modern = theme.modern()

  local normal = theme.state(resolved, "normal", "green")
  assertEqual(normal.accent, lcd.RGB(modern.green))
  assertEqual(normal.badge, nil)
  assertEqual(normal.value, lcd.RGB(modern.text))

  -- Warning and freshness states override a decorative accent.
  assertEqual(theme.state(resolved, "warning", "green").accent, lcd.RGB(modern.amber))
  assertEqual(theme.state(resolved, "critical", "green").accent, lcd.RGB(modern.critical))
  assertEqual(theme.state(resolved, "stale", "green").value, lcd.RGB(modern.textMuted))
  assertEqual(theme.state(resolved, "unavailable", "green").value,
    lcd.RGB(modern.textFaint))

  -- Each non-normal state carries a text badge, and which words it uses is
  -- the contract: the badge is what makes a state legible to a colourblind
  -- pilot, so asserting only that it is non-empty asserts nothing a typo
  -- could not satisfy.
  local badges = {
    stale = "STALE", warning = "WARN", critical = "CRIT",
    unavailable = "NO SOURCE", editing = "EDIT",
  }
  for name, text in pairs(badges) do
    assertEqual(theme.state(resolved, name).badge, text,
      name .. " does not carry its own badge")
  end
  assertEqual(theme.state(resolved, "normal").badge, nil,
    "a healthy panel must not be badged")

  -- Selection, editing, and both alarm states are the only things that draw
  -- an outline, and they all draw it at the focus weight. A resting panel
  -- carries none: its fill against the darker screen is what makes it a
  -- panel, and an outline on every panel spends the border on decoration at
  -- the moment it should mean something.
  local focus = resolved.spacing.borderFocus
  assertEqual(theme.state(resolved, "normal").borderWidth, 0,
    "a resting panel drew an outline")
  assertEqual(theme.state(resolved, "stale").borderWidth, 0,
    "stale data is said with a badge and dimming, not an outline")
  assertEqual(theme.state(resolved, "unavailable").borderWidth, 0,
    "a missing source is said with a badge, not an outline")
  for _, name in ipairs({"selected", "editing", "warning", "critical"}) do
    assertEqual(theme.state(resolved, name).borderWidth, focus,
      name .. " did not draw its outline at the focus weight")
  end
  assertEqual(theme.state(resolved, "critical").border, lcd.RGB(modern.critical),
    "a critical outline must be unmistakable")

  -- An unknown accent falls back to the theme default rather than failing.
  assertEqual(theme.state(resolved, "normal", "magenta").accent, lcd.RGB(modern.cyan))
  assertEqual(theme.accentColor(resolved, "amber"), lcd.RGB(modern.amber))
end

--- Fractions must be clamped so bad readings cannot draw outside a panel.
local function testPrimitiveMath()
  assertEqual(primitives.barFill(100, 0.5), 50)
  assertEqual(primitives.barFill(100, -1), 0)
  assertEqual(primitives.barFill(100, 2), 100)
  assertEqual(primitives.barFill(100, 0 / 0), 0)
  assertEqual(primitives.barFill(100, "half"), 0)

  assertEqual(primitives.arcSweep(270, 0), 0)
  assertEqual(primitives.arcSweep(270, 1), 270)
  assertEqual(primitives.arcSweep(270, 2), 270)
  assertEqual(primitives.arcSweep(270, nil), 0)

  local resolved = theme.build("modern")
  assertEqual(primitives.contentWidth(resolved, 100), 100 - resolved.spacing.padding * 2)
  assertEqual(primitives.contentWidth(resolved, 4), 1, "width must never collapse")
end

--- Empty flow collections are the natural way to express "no entries".
local function testEmptyCollections()
  local document = assert(yaml.parse(
    "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents: []\n"))
  assertEqual(type(document.components), "table")
  assertEqual(#document.components, 0)

  local normalized, errors = layout.validate(document, grid)
  assertEqual(#errors, 0, table.concat(errors, "\n"))
  assertEqual(#normalized.components, 0)

  -- A bare key with no value is equally valid and equally empty.
  local bare = assert(yaml.parse(
    "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n"))
  assertEqual(#select(1, layout.validate(bare, grid)).components, 0)

  assertEqual(type(assert(yaml.parse("a: {}\n")).a), "table")
end

--- The layout schema accepts an optional theme block.
local function testLayoutTheme()
  local document = assert(yaml.parse([[
version: 1
theme:
  mode: custom
  overrides:
    canvas: 0x000000
grid:
  columns: 4
  rows: 4
components: []
]]))

  local normalized, errors = layout.validate(document, grid)
  assertEqual(#errors, 0)
  assertEqual(normalized.theme.mode, "custom")
  assertEqual(normalized.theme.overrides.canvas, 0x000000)

  -- A malformed theme block is reported without blocking the layout.
  local broken = assert(yaml.parse(
    "version: 1\ntheme: nope\ngrid:\n  columns: 4\n  rows: 4\ncomponents: []\n"))
  local _, brokenErrors = layout.validate(broken, grid)
  assert(string.match(table.concat(brokenErrors, "\n"), "theme must be a mapping"))
end

--- A hostile surface must never swallow text, accents, or state badges.
local function testDerivedThemesStayLegible()
  -- The last two are surfaces that force the critical-red shift: red is never
  -- adjusted, so the surface moves instead, and that move answers only to red.
  -- It can land next to the canvas and leave panels with no edge at all now
  -- that nothing draws an outline, which is why the canvas moves after it.
  local surfaces = {0xFFFFFF, 0x000000, 0x69737A, 0x808080, 0xF2B84B, 0x101316,
    0x1B3A57, 0x8B1A1A}

  for _, surface in ipairs(surfaces) do
    local resolved = theme.build("custom", {surface = surface, canvas = surface})
    local tokens = resolved.rgb
    local label = string.format("surface 0x%06X", surface)

    assert(theme.contrast(tokens.surface, tokens.text) >= 4.5, label .. ": text")
    assert(theme.contrast(tokens.surface, tokens.textMuted) >= 3.0, label .. ": muted")
    assert(theme.contrast(tokens.surface, tokens.textFaint) >= 1.8, label .. ": faint")

    -- Structural separation must be visible in either direction.
    assert(theme.contrast(tokens.surface, tokens.surfaceRaised) >= 1.20,
      label .. ": elevation vanished")
    assert(theme.contrast(tokens.canvas, tokens.surface) >= 1.30,
      label .. ": the panel is not elevated above the screen")
    -- A track carries meaning: the filled portion is read against it, so it
    -- needs far more separation than panel elevation does. Reusing
    -- surfaceRaised for a compass dial made the dial invisible on a radio.
    assert(theme.contrast(tokens.surface, tokens.track) >= 2.0,
      label .. ": track vanished into the surface")
    assert(theme.contrast(tokens.surface, tokens.border) >= 1.25,
      label .. ": border vanished")

    -- Every decorative accent must remain visible on the panel surface.
    for _, key in ipairs({"cyan", "green", "amber", "orange"}) do
      assert(theme.contrast(tokens.surface, tokens[key]) >= 2.5,
        label .. ": accent " .. key .. " vanished")
    end

    -- Critical red is an alarm: it must look identical on every radio, so it
    -- is never adjusted. The surface moves instead to keep it visible.
    assertEqual(tokens.critical, theme.modern().critical,
      label .. ": critical red was altered")
    assert(theme.contrast(tokens.surface, tokens.critical) >= 2.5,
      label .. ": critical red vanished into the surface")

    -- The unavailable state must stay readable against its own panel.
    --
    -- Readability is a property of the 24-bit tokens, because that is what
    -- the contrast arithmetic is defined on; the state's own `value` is a
    -- display value bound for an LVGL object. Feeding one to `theme.contrast`
    -- measures the luminance of a flag word, which means nothing. So the
    -- state is pinned to the token it must come from, and the token is what
    -- is measured.
    local unavailable = theme.state(resolved, "unavailable")
    assertEqual(unavailable.badge, "NO SOURCE", label .. ": badge text")
    assertEqual(unavailable.value, lcd.RGB(tokens.textFaint),
      label .. ": unavailable text left the resolved palette")
    assert(theme.contrast(tokens.surface, tokens.textFaint) >= 1.8,
      label .. ": unavailable text vanished")
  end
end

--- Freshness must override a component's decorative accent.
local function testStaleOverridesAccent()
  local resolved = theme.build("modern")
  local modern = theme.modern()

  local normal = theme.state(resolved, "normal", "green")
  local stale = theme.state(resolved, "stale", "green")

  assertEqual(normal.accent, lcd.RGB(modern.green))
  assert(stale.accent ~= lcd.RGB(modern.green), "stale kept the decorative accent")
  assertEqual(stale.accent, lcd.RGB(modern.textFaint))
end

--- A module whose metatable raises must be rejected, not crash the host.
local function testHostileModule()
  local hostile = setmetatable({}, {
    __index = function() error("gotcha", 0) end,
  })

  local ok, valid = pcall(componentHost.validateModule, hostile, "hostile")
  assert(ok, "hostile module escaped validation")
  assertEqual(valid, false)

  -- Dispatch must also refuse to consult a raising metatable.
  local entry = {placement = {id = "h"}, instance = {}, module = hostile}
  local dispatched, result = pcall(componentHost.dispatch, entry, "refresh")
  assert(dispatched, "hostile module escaped dispatch: " .. tostring(result))
end

--- Threshold direction may be stated explicitly when one bound is configured.
local function testMetricDirection()
  local metric = loadModule("components/metric.lua")

  -- A single threshold defaults to rising.
  local rising = {critical = 110}
  assertEqual(metric.resolveState(rising, 120, false), "critical")
  assertEqual(metric.resolveState(rising, 10, false), "normal")

  -- An explicit falling direction reverses it, which a battery needs.
  local falling = {critical = 3.3, direction = "falling"}
  assertEqual(metric.resolveState(falling, 3.0, false), "critical")
  assertEqual(metric.resolveState(falling, 4.1, false), "normal")

  -- Two thresholds still infer direction without configuration.
  local inferred = {warning = 21.0, critical = 19.8}
  assertEqual(metric.resolveState(inferred, 20.5, false), "warning")
  assertEqual(metric.resolveState(inferred, 19.0, false), "critical")
  assertEqual(metric.resolveState(inferred, 24.0, false), "normal")

  -- An explicit rising direction overrides the inference.
  local forced = {warning = 21.0, critical = 19.8, direction = "rising"}
  assertEqual(metric.resolveState(forced, 24.0, false), "critical")

  -- Missing and non-numeric readings are unavailable, not zero.
  assertEqual(metric.resolveState(inferred, nil, false), "unavailable")
  assertEqual(metric.resolveState(inferred, 0 / 0, false), "unavailable")
  assertEqual(metric.resolveState(inferred, 24.0, true), "stale")

  -- A zero-width range must not divide by zero.
  assertEqual(metric.fraction({min = 5, max = 5}, 5), 0)
  assertEqual(metric.fraction({min = 0, max = 10}, 20), 1)
  assertEqual(metric.fraction({min = 0, max = 10}, -5), 0)
  assertEqual(metric.format(nil, 2), "--")
  assertEqual(metric.format(1.239, 2), "1.24")
end

--- Content must stack inside the panel using real font heights, never
--- overlapping and never running past the bottom edge.
local function testContentFitsPanel()
  local metric = loadModule("components/metric.lua")
  local heightOf = theme.fontHeight

  -- Panel heights for spans at 480 x 272 with 4 px gutters, plus tight cases.
  local cases = {
    {name = "2x2", w = 238, h = 134, colSpan = 2, rowSpan = 2},
    {name = "2x1", w = 238, h = 65, colSpan = 2, rowSpan = 1},
    {name = "1x1", w = 117, h = 65, colSpan = 1, rowSpan = 1},
    {name = "tiny", w = 60, h = 40, colSpan = 1, rowSpan = 1},
  }

  for _, case in ipairs(cases) do
    local layout = metric.presentationFor(case.colSpan, case.rowSpan)
    layout.visual = "bar"
    local fonts = theme.typography(case.colSpan, case.rowSpan)
    local area = metric.regionsFor(
      theme.build("modern"), theme, {x = 0, y = 0, w = case.w, h = case.h},
      layout, fonts)

    local valueBottom = area.valueY + heightOf(area.primary)
    assert(valueBottom <= case.h, case.name
      .. ": value overflows the panel, ends at " .. valueBottom
      .. " in " .. case.h)

    -- Assertions use the resolved flags: a short panel sheds optional detail.
    if area.showUnit then
      assert(area.unitY >= valueBottom, case.name
        .. ": unit overlaps the value, unit at " .. area.unitY
        .. ", value ends at " .. valueBottom)
      assert(area.unitY + heightOf(fonts.unit) <= case.h, case.name
        .. ": unit overflows the panel")
    end

    if area.showVisual then
      local unitBottom = area.showUnit
        and (area.unitY + heightOf(fonts.unit)) or valueBottom
      assert(area.barY >= unitBottom, case.name
        .. ": bar overlaps content above it")
      assert(area.barY + 4 <= case.h, case.name .. ": bar overflows the panel")
    end

    if area.showRange then
      assert(area.rangeY + heightOf(fonts.label) <= area.barY, case.name
        .. ": range overlaps the bar")
    end

    -- The label row must clear the value.
    assert(area.valueY >= heightOf(fonts.label), case.name
      .. ": value overlaps the label")
  end

  -- A short panel must reduce the primary font rather than overflow.
  local short = metric.regionsFor(
    theme.build("modern"), theme, {x = 0, y = 0, w = 238, h = 65},
    {showUnit = true, showVisual = true, showRange = false, visual = "bar"},
    theme.typography(2, 1))
  local tall = metric.regionsFor(
    theme.build("modern"), theme, {x = 0, y = 0, w = 238, h = 134},
    {showUnit = true, showVisual = true, showRange = true, visual = "bar"},
    theme.typography(2, 2))
  assert(heightOf(short.primary) < heightOf(tall.primary),
    "a short panel did not reduce its primary font")
end

--- Components sharing an interval must not all fall due on the same frame.
local function testRefreshScheduling()
  assertEqual(componentHost.refreshInterval({refreshInterval = 20}), 20)
  assertEqual(componentHost.refreshInterval({}), 0)
  assertEqual(componentHost.refreshInterval({refreshInterval = -5}), 0)

  -- An interval of zero or one cannot be staggered.
  assertEqual(componentHost.phaseOffset(0, 7), 0)
  assertEqual(componentHost.phaseOffset(1, 7), 0)

  -- Sixteen components sharing a 20 tick interval must land on distinct
  -- frames, so the host never pays for all of them at once.
  local used = {}
  for ordinal = 1, 16 do
    local offset = componentHost.phaseOffset(20, ordinal)
    assert(offset >= 0 and offset < 20, "offset outside the interval: " .. offset)
    assert(not used[offset], "two components share phase " .. offset)
    used[offset] = true
  end

  -- More components than frames must wrap rather than fail.
  assertEqual(componentHost.phaseOffset(4, 5), 0)
  assertEqual(componentHost.phaseOffset(4, 6), 1)

  -- The contract rejects a nonsensical interval rather than misscheduling.
  local function rejects(interval)
    local ok = componentHost.validateModule(
      {id = "d", apiVersion = 1, create = function() end,
       refreshInterval = interval}, "d")
    assertEqual(ok, false, "accepted interval " .. tostring(interval))
  end
  rejects(-1)
  rejects(1.5)
  rejects("fast")
  assert(componentHost.validateModule(
    {id = "d", apiVersion = 1, create = function() end, refreshInterval = 0}, "d"))
end

--- Every origin wording must fit the width it is given, and must step down
--- through phrasings that still read as sentences rather than being clipped.
local function testOriginCaptionFits()
  local navigation = loadModule("components/navigation.lua")
  local fix = {known = true, fix = true, home = true, state = "normal"}
  local noHome = {known = true, fix = true, home = false, state = "normal"}
  local noSource = {known = false}

  -- With no layout context the caller gets the full wording.
  assertEqual(navigation.originText(fix), "NORTH UP FROM HOME")

  -- The caption row on a 2 x 2 panel is about 131px.
  assertEqual(navigation.originText(fix, theme, SMLSIZE, 131), "NORTH UP")
  assertEqual(navigation.originText(noHome, theme, SMLSIZE, 131), "NO HOME POS")
  assertEqual(navigation.originText(noSource, theme, SMLSIZE, 131), "NO GPS SOURCE")

  -- Generous width keeps the full wording.
  assertEqual(navigation.originText(fix, theme, SMLSIZE, 400), "NORTH UP FROM HOME")

  -- Whatever the width, the chosen wording must fit it, or be the shortest
  -- available when nothing does. Nothing may simply be clipped.
  for _, view in ipairs({fix, noHome, noSource, {known = true, fix = false}}) do
    local variants = navigation.originVariants(view)
    local shortest = variants[#variants]
    for width = 10, 400, 7 do
      local text = navigation.originText(view, theme, SMLSIZE, width)
      local fitted = theme.textWidth(SMLSIZE, text) <= width
      assert(fitted or text == shortest,
        "caption '" .. text .. "' neither fits " .. width .. "px nor is shortest")
      -- A wording must never be a truncation of a longer one with a dangling
      -- word; each rung is checked to be one of the declared phrasings.
      local declared = false
      for _, candidate in ipairs(variants) do
        if candidate == text then declared = true end
      end
      assert(declared, "caption '" .. text .. "' is not a declared wording")
    end
  end
end

testGridGeometry()
testValidation()
testOverlapIsRejected()
testLayoutPath()
testModelFilenameResolution()
testUnknownKeysArePreserved()
testMalformedInput()
testInvalidEntryIsIsolated()
testComponentContract()
testSupportedSpans()
testSettingsResolution()
testLifecycleIsolation()
testColorConversion()
testModernTheme()
testEdgeTxTheme()
testCustomTheme()
testTypography()
testStates()
testPrimitiveMath()
testEmptyCollections()
testLayoutTheme()
testDerivedThemesStayLegible()
testStaleOverridesAccent()
testHostileModule()
testOriginCaptionFits()
testRefreshScheduling()
testMetricDirection()
testContentFitsPanel()

--- A published snapshot must be readable and impossible to corrupt, because
--- several components share the same one.
local function testSnapshotsAreImmutable()
  local state = {value = 1, name = "RxBt"}
  local view = services.snapshot(state)

  assertEqual(view.value, 1)
  assertEqual(view.name, "RxBt")

  local ok, err = pcall(function() view.value = 2 end)
  assertEqual(ok, false, "a snapshot accepted a write")
  assert(string.match(tostring(err), "read%-only"), tostring(err))

  -- The mutable state stays reachable to the service and invisible to callers.
  state.value = 7
  assertEqual(view.value, 7, "the view lost sight of its state")
  assertEqual(getmetatable(view), false, "the snapshot exposed its metatable")
end

--- A service update is charged to the same instruction budget as everything
--- else, so the registry must serve exactly one due service per cycle, skip
--- services nothing subscribed to, and retire one that raises.
local function testServiceScheduling()
  local function fake(id, interval, behavior)
    return {
      id = id,
      interval = interval,
      revision = 0,
      count = 1,
      due = 0,
      updates = 0,
      update = function(self)
        self.updates = self.updates + 1
        if behavior == "raise" then error(id .. " failed", 0) end
      end,
    }
  end

  local runtime = services.runtime(services.environment({}))
  local first, second, third = fake("a", 10), fake("b", 10), fake("c", 10)
  services.register(runtime, first, 0)
  services.register(runtime, second, 0)
  services.register(runtime, third, 0)

  -- Registration staggers services so they never fall due together.
  assertEqual(first.due, 0)
  assertEqual(second.due, 1)
  assertEqual(third.due, 2)

  assertEqual(services.update(runtime, 0), "a")
  assertEqual(services.update(runtime, 0), nil, "two services ran in one cycle")
  assertEqual(services.update(runtime, 1), "b")
  assertEqual(services.update(runtime, 2), "c")
  assertEqual(first.updates, 1)
  assertEqual(first.revision, 1)

  -- Nothing subscribed means nothing is read.
  local idle = fake("idle", 10)
  idle.count = 0
  services.register(runtime, idle, 0)
  for step = 3, 40 do services.update(runtime, step) end
  assertEqual(idle.updates, 0, "an unsubscribed service was polled")

  -- A service that raises is reported once and then retired.
  local broken = services.runtime(services.environment({}))
  local bad = fake("bad", 10, "raise")
  services.register(broken, bad, 0)
  local id, updateError = services.update(broken, 0)
  assertEqual(id, "bad")
  assert(string.match(tostring(updateError), "bad failed"), tostring(updateError))
  assertEqual(bad.revision, 0, "a failed update counted as a revision")
  assertEqual(services.update(broken, 100), nil, "a failed service ran again")
  assertEqual(bad.updates, 1)
end

--- Build a telemetry environment whose sensors and link state a test controls.
local function telemetryHarness()
  local harness = {
    rssi = 80,
    fields = {
      RxBt = {id = 100, name = "RxBt", unit = 1},
      Alt = {id = 103, name = "Alt", unit = 9},
    },
    values = {[100] = 24.4, [103] = 0},
    sensors = {
      [0] = {name = "RxBt", prec = 2},
      [1] = {name = "Alt", prec = 1},
    },
  }

  harness.env = services.environment({
    getFieldInfo = function(name) return harness.fields[name] end,
    getValue = function(id) return harness.values[id] end,
    getRSSI = function() return harness.rssi end,
    model = {getSensor = function(index) return harness.sensors[index] end},
  })

  harness.service = telemetryService.new(harness.env, services)
  return harness
end

--- Freshness is the subtle part of EdgeTX telemetry: the firmware returns zero
--- both for a genuine zero reading and for a sensor whose link is down.
local function testTelemetryFreshness()
  local harness = telemetryHarness()
  local service = harness.service
  local pack = service:subscribe("RxBt")
  local altitude = service:subscribe("Alt")
  local missing = service:subscribe("Nope")

  -- Two components naming one source must share a single poll.
  assert(service:subscribe("RxBt") == pack, "a duplicate subscription was made")
  assertEqual(service.count, 3)

  service:update(0)
  assertEqual(pack.value, 24.4)
  assertEqual(pack.state, "normal")
  assertEqual(pack.unitText, "V")
  assertEqual(pack.telemetry, true)

  -- Zero while the link is up is a real reading, not a missing one.
  assertEqual(altitude.value, 0)
  assertEqual(altitude.available, true)
  assertEqual(altitude.state, "normal")

  -- A sensor the radio has never seen is unavailable, not stale or zero.
  assertEqual(missing.known, false)
  assertEqual(missing.state, "unavailable")
  assertEqual(missing.value, nil)

  -- Precision comes from the model's sensor table, one search at a time.
  for step = 1, 6 do service:update(step) end
  assertEqual(pack.precision, 2)
  assertEqual(altitude.precision, 1)

  -- A dropped link must keep the last reading and mark it stale rather than
  -- replacing a valid 24.4 V with the zero EdgeTX reports.
  harness.rssi = 0
  harness.values[100] = 0
  service:update(20)
  assertEqual(pack.value, 24.4, "a stale poll overwrote the cached reading")
  assertEqual(pack.state, "stale")
  assertEqual(pack.stale, true)
  assertEqual(pack.fresh, false)

  harness.rssi = 70
  harness.values[100] = 23.9
  service:update(30)
  assertEqual(pack.value, 23.9)
  assertEqual(pack.state, "normal")

  -- A sensor that appears later must be picked up without a reload.
  harness.fields.Nope = {id = 106, name = "Nope", unit = 13}
  harness.values[106] = 42
  service:update(30 + telemetryService.RESOLVE_RETRY)
  assertEqual(missing.known, true)
  assertEqual(missing.value, 42)
  assertEqual(missing.unitText, "%")

  -- An unconfigured source still yields a usable reading.
  local none = service:subscribe("")
  assertEqual(none.state, "unavailable")
  assertEqual(telemetryService.format(none), "--")
  assertEqual(telemetryService.format(pack), "23.90")
  assertEqual(telemetryService.format(pack, 0), "24")
end

--- The link indicator is not reliable everywhere, and a sensor's extremes are
--- not always shaped like the sensor itself. Both mistakes look like a dead
--- reading on the radio, and neither is visible from a mocked value alone.
local function testTelemetryLinkHeuristics()
  local harness = telemetryHarness()
  local service = harness.service
  local pack = service:subscribe("RxBt")

  -- Some protocols never populate an RSSI sensor, so getRSSI reads zero on a
  -- perfectly live link. A telemetry source cannot return a non-zero value
  -- when EdgeTX has nothing, so that value proves the indicator is wrong.
  harness.rssi = 0
  service:update(0)
  assertEqual(pack.value, 24.4, "a live reading was discarded as stale")
  assertEqual(pack.state, "normal")

  -- Having learned that, a genuine zero from the same radio is a reading too.
  harness.values[100] = 0
  service:update(1)
  assertEqual(pack.value, 0)
  assertEqual(pack.state, "normal")

  -- A radio whose indicator does work still withholds the ambiguous zero.
  local other = telemetryHarness()
  local reading = other.service:subscribe("RxBt")
  other.service:update(0)
  assertEqual(reading.value, 24.4)
  other.rssi = 0
  other.values[100] = 0
  other.service:update(1)
  assertEqual(reading.state, "stale")
  assertEqual(reading.value, 24.4, "a stale poll overwrote the cached reading")

  -- EdgeTX returns the cells table only for the base source; "Cels-" and
  -- "Cels+" carry the same unit but return a plain number.
  harness.fields.Cels = {id = 130, name = "Cels", unit = 38}
  harness.fields["Cels-"] = {id = 131, name = "Cels-", unit = 38}
  harness.values[130] = {4.11, 4.13, 4.09}
  harness.values[131] = 4.09
  harness.rssi = 80

  local cells = service:subscribe("Cels")
  local lowest = service:subscribe("Cels-")
  service:update(2)

  assertEqual(cells.kind, "cells")
  assertEqual(type(cells.raw), "table")
  assertEqual(lowest.kind, "number", "a cells extremum was read as a table")
  assertEqual(lowest.value, 4.09)
  assertEqual(lowest.state, "normal")
end

--- Polling must stay bounded no matter how many sources a layout references.
local function testTelemetryPollingIsBounded()
  local harness = telemetryHarness()
  local service = harness.service
  local polled = {}

  harness.env.getValue = function(id)
    polled[#polled + 1] = id
    return harness.values[id]
  end

  for index = 1, 16 do
    local name = "S" .. index
    harness.fields[name] = {id = 200 + index, unit = 0}
    harness.values[200 + index] = index
    service:subscribe(name)
  end

  service:update(0)
  assert(#polled <= telemetryService.POLL_CAP,
    "one update polled " .. #polled .. " sources")

  -- Every source must still be served, in rotation, rather than starved.
  local seen = {}
  for step = 1, 8 do
    service:update(step)
    for _, id in ipairs(polled) do seen[id] = true end
  end
  for index = 1, 16 do
    assert(seen[200 + index], "source S" .. index .. " was never polled")
  end
end

--- Model facets are radio-local, so they never depend on a link, but every one
--- of them can still be missing on some firmware.
local function testModelService()
  assertEqual(modelService.formatTime(125), "2:05")
  assertEqual(modelService.formatTime(-5), "-0:05")
  assertEqual(modelService.formatTime(3725), "1:02:05")
  assertEqual(modelService.formatTime(nil), "--:--")

  local timers = {
    [0] = {value = 125, start = 300, name = "Flight", persistent = 1},
    [1] = {value = 64, start = 0, name = "Up"},
  }

  local env = services.environment({
    getValue = function(source)
      if source == "tx-voltage" then return 7.8 end
      return nil
    end,
    getFlightMode = function() return 2, "Sport" end,
    model = {
      getInfo = function()
        return {name = "Test", bitmap = "plane.png", filename = "m1.yml", labels = "fpv"}
      end,
      getTimer = function(index) return timers[index] end,
    },
  })

  local service = modelService.new(env, services)
  local identity = service:identity()
  local flightMode = service:flightMode()
  local voltage = service:txVoltage()
  local countdown = service:timer(0)
  local countUp = service:timer(1)
  local absent = service:timer(2)

  for step = 0, 3 do service:update(step) end

  assertEqual(identity.name, "Test")
  assertEqual(identity.bitmap, "plane.png")
  assertEqual(identity.bitmapPath, "/IMAGES/plane.png")
  assertEqual(flightMode.index, 2)
  assertEqual(flightMode.name, "Sport")
  assertEqual(voltage.value, 7.8)
  assertEqual(voltage.unitText, "V")

  -- A countdown keeps EdgeTX's own signed value and derives the rest.
  assertEqual(countdown.countdown, true)
  assertEqual(countdown.remaining, 125)
  assertEqual(countdown.elapsed, 175)
  assertEqual(countdown.text, "2:05")
  assertEqual(countdown.expired, false)

  assertEqual(countUp.countdown, false)
  assertEqual(countUp.elapsed, 64)
  assertEqual(countUp.text, "1:04")

  -- A timer index the radio does not have degrades instead of raising.
  assertEqual(absent.available, false)
  assertEqual(absent.text, "--:--")

  -- A countdown that runs past zero must read as expired, not as elapsed.
  timers[0].value = -8
  for step = 4, 9 do service:update(step) end
  assertEqual(countdown.expired, true)
  assertEqual(countdown.text, "-0:08")

  -- An unnamed flight mode falls back to its number.
  local unnamed = modelService.new(services.environment({
    getFlightMode = function() return 0, "" end,
  }), services)
  local mode = unnamed:flightMode()
  unnamed:update(0)
  assertEqual(mode.name, "FM0")

  -- Firmware without the model API must not raise.
  local bare = modelService.new(services.environment({model = {}}), services)
  local bareIdentity = bare:identity()
  local bareTimer = bare:timer(0)
  bare:update(0)
  assertEqual(bareIdentity.available, false)
  assertEqual(bareTimer.state, "unavailable")
end

--- Trims and global variables are both resolved by EdgeTX; the service only
--- normalizes their scale, precision, and bounds.
local function testControlService()
  local raw = 0
  local details = {name = "Rates", min = -100, max = 100, prec = 1, unit = 0}

  local env = services.environment({
    getFieldInfo = function(name)
      if name == "trim-ail" or name == "trim-thr" then return {id = 200} end
      return nil
    end,
    getValue = function() return raw end,
    getFlightMode = function() return 1 end,
    model = {
      getGlobalVariable = function(index, phase)
        assertEqual(phase, 1, "a global variable ignored the flight mode")
        return 45
      end,
      getGlobalVariableDetails = function() return details end,
    },
  })

  local service = controlService.new(env, services)
  local trim = service:trim("trim-ail")
  local variable = service:globalVariable(0)

  service:update(0)
  assertEqual(trim.available, true)
  assertEqual(trim.centered, true)
  assertEqual(trim.scale, "standard")
  assertEqual(trim.fraction, 0)

  -- EdgeTX reports eight times the stored trim.
  raw = 512
  service:update(1)
  assertEqual(trim.raw, 512)
  assertEqual(trim.value, 64)
  assertEqual(trim.fraction, 0.5)
  assertEqual(trim.centered, false)

  -- A negative trim must round toward zero like a positive one. Flooring a
  -- negative percentage reports more deflection than the trim actually has.
  raw = -240
  service:update(1)
  -- describe() reports one row per subscription, in subscription order. A
  -- count greater than zero would be satisfied by a diagnostics panel that
  -- silently dropped every row but the first.
  local rows = {}
  assertEqual(service:describe(rows), 2, "a subscription was left undescribed")
  assertEqual(rows[1].label, "TRIM-AIL")
  assertEqual(rows[1].text, "-30 -23%", "a negative trim rounded the wrong way")
  assertEqual(rows[2].label, "RATES")
  assertEqual(rows[2].text, "4.5")
  raw = 512
  service:update(1)

  -- A standard trim held at its own end stop reads exactly 1024, because
  -- EdgeTX clamps the stored value to TRIM_MAX of 128. That must not be read
  -- as leaving the standard range.
  raw = 1024
  service:update(2)
  assertEqual(trim.scale, "standard", "an end stop widened the scale")
  assertEqual(trim.fraction, 1)
  assertEqual(trim.value, 128)

  -- Auto widens once a reading really does leave the standard range, and stays
  -- widened, because EdgeTX never tells Lua whether extended trims are enabled.
  raw = 2048
  service:update(3)
  assertEqual(trim.scale, "extended")
  assertEqual(trim.fraction, 0.5)
  raw = -512
  service:update(4)
  assertEqual(trim.scale, "extended", "the scale narrowed again")
  assertEqual(trim.fraction, -0.125)

  -- A global variable uses its configured name, precision, and bounds.
  assertEqual(variable.name, "Rates")
  assertEqual(variable.value, 4.5)
  assertEqual(variable.min, -10)
  assertEqual(variable.max, 10)
  assertEqual(variable.flightMode, 1)

  -- A three-position toggle and a standard trim at its end stop report the
  -- same number, so one sample can never tell them apart. A trim parked at its
  -- stop must not be mistaken for a toggle.
  local parked = controlService.new(env, services)
  local parkedTrim = parked:trim("trim-thr")
  raw = 1024
  parked:update(0)
  assertEqual(parkedTrim.threePosition, false, "an end stop was read as a toggle")

  -- A toggle only ever reports centre or full deflection, with nothing between.
  local toggle = controlService.new(env, services)
  local switchTrim = toggle:trim("trim-thr")
  raw = 0
  toggle:update(0)
  raw = 1024
  toggle:update(1)
  assertEqual(switchTrim.threePosition, true)
  assertEqual(switchTrim.fraction, 1)

  -- An ordinary trim passes through intermediate positions on its way.
  raw = 300
  toggle:update(2)
  assertEqual(switchTrim.threePosition, false, "an ordinary trim stayed a toggle")

  -- An unknown trim source and a radio without global variables degrade.
  local bare = controlService.new(services.environment({model = {}}), services)
  local unknown = bare:trim("trim-nope")
  local noVariable = bare:globalVariable(1)
  bare:update(0)
  assertEqual(unknown.state, "unavailable")
  assertEqual(noVariable.state, "unavailable")
  assertEqual(bare:trim("").state, "unavailable")
end

--- Flight sessions are owned by the dashboard, and the arm switch is what
--- decides where one flight ends and the next begins.
local function testExtremaService()
  local harness = telemetryHarness()
  harness.fields.sa = {id = 300}
  harness.values[300] = -1024

  local runtime = services.runtime(harness.env)
  local telemetry = harness.service
  services.register(runtime, telemetry, 0)
  local service = extremaService.new(harness.env, services, runtime)
  services.register(runtime, service, 0)

  local flight = service:flight("sa")
  local altitude = service:sessionExtrema("Alt")

  -- EdgeTX's own extrema are ordinary sources, reached through the same poll.
  local peak = service:sourceExtreme("Alt", "max")
  assertEqual(peak.name, "Alt+")

  telemetry:update(0)
  service:update(0)
  assertEqual(flight.configured, true)
  assertEqual(flight.armed, false)
  assertEqual(flight.active, false)
  assertEqual(altitude.available, false)

  -- Arming starts a session and clears whatever the last one recorded.
  harness.values[103] = 10
  harness.values[300] = 1024
  telemetry:update(1)
  service:update(1)
  assertEqual(flight.armed, true)
  assertEqual(flight.active, true)
  assertEqual(flight.count, 1)

  for step, value in ipairs({10, 50, 20}) do
    harness.values[103] = value
    telemetry:update(step + 1)
    service:update(step + 1)
  end
  assertEqual(altitude.min, 10)
  assertEqual(altitude.max, 50)
  assertEqual(altitude.session, 1)
  assert(altitude.samples >= 3, "samples were not counted")

  -- Disarming freezes the session rather than discarding it.
  harness.values[300] = -1024
  telemetry:update(10)
  service:update(10)
  assertEqual(flight.active, false)
  assertEqual(altitude.max, 50)

  -- Re-arming starts a clean session.
  harness.values[300] = 1024
  harness.values[103] = 5
  telemetry:update(11)
  service:update(11)
  assertEqual(flight.count, 2)
  assertEqual(altitude.session, 2)
  assertEqual(altitude.max, 5)

  -- Without an arm source the dashboard still tracks one open session, so
  -- extrema mean something on a radio with no arm switch.
  local free = extremaService.new(harness.env, services, runtime)
  local session = free:flight()
  free:update(0)
  assertEqual(session.configured, false)
  assertEqual(session.active, true)
end

--- Navigation must never present a north-up bearing as model orientation, and
--- must withhold everything it cannot actually know.
local function testNavigationService()
  local harness = telemetryHarness()
  harness.fields.GPS = {id = 400, unit = 40}
  harness.fields.Dist = {id = 403, unit = 9}
  harness.values[400] = {
    lat = 47.3769,
    lon = 8.5417,
    ["pilot-lat"] = 47.3700,
    ["pilot-lon"] = 8.5400,
    delay = 1,
  }
  harness.values[403] = 812

  local runtime = services.runtime(harness.env)
  local telemetry = harness.service
  services.register(runtime, telemetry, 0)
  local service = navigationService.new(harness.env, services, runtime)
  services.register(runtime, service, 0)

  local view = service:subscribe("GPS")
  telemetry:update(0)
  service:update(0)

  assertEqual(view.fix, true)
  assertEqual(view.home, true)
  assertEqual(view.state, "normal")
  assertEqual(view.age, 1, "the reported fix age was ignored")
  assert(math.abs(view.distance - 777) < 20,
    "distance was " .. tostring(view.distance))
  assert(math.abs(view.bearing - 9.6) < 2, "bearing was " .. tostring(view.bearing))
  assertEqual(view.distanceSource, "computed")

  -- The reciprocal must differ, which proves the bearing runs home to model
  -- rather than the other way round.
  local reverse = navigationService.bearingBetween(47.3769, 8.5417, 47.3700, 8.5400)
  assert(math.abs(((reverse - view.bearing) % 360) - 180) < 1,
    "home-to-model and model-to-home bearings are not reciprocal")

  -- A model due west of home reads 270, not 90.
  assert(math.abs(navigationService.bearingBetween(0, 0, 0, -1) - 270) < 0.01)
  assert(math.abs(navigationService.bearingBetween(0, 0, 1, 0)) < 0.01)

  -- Without a home position a bearing would be meaningless.
  harness.values[400]["pilot-lat"] = 0
  harness.values[400]["pilot-lon"] = 0
  telemetry:update(1)
  service:update(1)
  assertEqual(view.home, false)
  assertEqual(view.bearing, nil)
  assertEqual(view.distance, nil)
  assertEqual(view.fix, true)

  -- No fix at all is reported explicitly rather than as a position of zero.
  harness.values[400].lat = 0
  harness.values[400].lon = 0
  telemetry:update(2)
  service:update(2)
  assertEqual(view.fix, false)
  assertEqual(view.state, "unavailable")

  -- A configured native distance sensor wins over the computed one.
  local native = service:subscribe("GPS2")
  harness.fields.GPS2 = harness.fields.GPS
  assertEqual(native.state, "unavailable")

  local preferring = navigationService.new(harness.env, services, runtime)
  local withNative = preferring:subscribe("GPS", "Dist")
  harness.values[400].lat = 47.3769
  harness.values[400].lon = 8.5417
  harness.values[400]["pilot-lat"] = 47.3700
  harness.values[400]["pilot-lon"] = 8.5400
  telemetry:update(3)
  preferring:update(3)
  assertEqual(withNative.distance, 812)
  assertEqual(withNative.distanceUnit, "m")
  assertEqual(withNative.distanceSource, "source")

  -- A GPS source that has never produced a table must not raise.
  local absent = preferring:subscribe("NoGps")
  preferring:update(4)
  assertEqual(absent.state, "unavailable")
  assertEqual(navigationService.formatDistance(nil), "--")
  assertEqual(navigationService.formatDistance(450), "450m")
  assertEqual(navigationService.formatDistance(12345), "12.3km")
end


--- Every line height the dashboard lays out from must be the radio's own.
---
--- `theme.fontHeight` carries five numbers that decide every vertical
--- decision the dashboard makes, and until now nothing checked them against
--- anything. They are a claim about the firmware, so they are checked against
--- the firmware: `tests/support/edgetx.lua` records the line heights of the
--- `std` font set, which is what a 480 x 272 radio is built with, along with
--- the file they were read from.
---
--- The wrong font set is the easy mistake here rather than a typo. EdgeTX also
--- ships `sml` for 320 x 240 and `lrg` for 800 x 480, and the `sml` heights
--- are 54, 33, 23, 14 and 10. Adopting those would rescale every text fitting
--- decision in the project and no test would have objected.
local function testFontHeightsMatchTheFirmware()
  local citation = edgetx.citation("FONT_HEIGHT")
  for font, height in pairs(firmware.FONT_HEIGHT) do
    assertEqual(theme.fontHeight(font), height,
      edgetx.fontName(font) .. " is not the height the radio draws it at ("
        .. citation.file .. ")")
  end
end

--- Text must be fitted by measured width as well as height, because a long
--- reading in a narrow cell clips sideways where a short one would not.
local function testTextFitting()
  assert(theme.textWidth(XXLSIZE, "1234") > theme.textWidth(SMLSIZE, "1234"),
    "a larger font must measure wider")
  assertEqual(theme.textWidth(SMLSIZE, ""), 0)
  assertEqual(theme.textWidth(SMLSIZE, nil), 0)

  -- Height alone would choose the biggest font that fits vertically, which is
  -- exactly the defect this exists to prevent.
  assertFont(theme.fitPrimary(80), XXLSIZE)
  assertFont(theme.fitText("-1234.5", 60, 80), SMLSIZE,
    "a narrow cell must reduce the font rather than clip")
  assertFont(theme.fitText("9", 400, 80), XXLSIZE,
    "a short value in a wide cell must keep the largest font")
  -- Nothing fits, so the smallest font is the honest answer.
  assertFont(theme.fitText("123456789012", 10, 10), SMLSIZE)

  -- A panel frame must keep its badge clear of its label at every width.
  local resolved = theme.build("modern")
  for _, width in ipairs({60, 117, 238, 480}) do
    local frame = theme.frame(resolved, {x = 0, y = 0, w = width, h = 134},
      theme.typography(1, 1))
    assert(frame.pad + frame.labelWidth <= frame.badgeX,
      "badge overlaps the label at width " .. width)
    assert(frame.badgeX + frame.badgeWidth <= width,
      "badge runs past the panel at width " .. width)
  end
end

--- A bipolar bar grows outward from its own centre and keeps its neutral
--- marker visible at every deflection.
local function testBipolarGeometry()
  assertEqual(primitives.signedFraction(50, -100, 100), 0.5)
  assertEqual(primitives.signedFraction(-50, -100, 100), -0.5)
  -- Each side is measured against its own bound, so an asymmetric range is
  -- still centred at zero rather than at the middle of its span.
  assertEqual(primitives.signedFraction(-10, -20, 100), -0.5)
  assertEqual(primitives.signedFraction(500, -100, 100), 1)
  assertEqual(primitives.signedFraction(0 / 0, -100, 100), 0)
  assertEqual(primitives.signedFraction(5, -100, 0), 0,
    "a bound of zero cannot produce a fraction")

  -- setBipolarBar is pure geometry, so it is checked against a recording stub
  -- rather than against a live LVGL object.
  local bar = {
    x = 10, y = 20, w = 100, h = 8, vertical = false,
    fill = {set = function(self, changes) self.last = changes end},
  }

  primitives.setBipolarBar(bar, 0.5)
  assertEqual(bar.fill.last.x, 60, "a positive fill must start at the centre")
  assertEqual(bar.fill.last.w, 25)

  primitives.setBipolarBar(bar, -0.5)
  assertEqual(bar.fill.last.x, 35, "a negative fill must end at the centre")
  assertEqual(bar.fill.last.w, 25)

  primitives.setBipolarBar(bar, 0)
  assertEqual(bar.fill.last.w, 1, "a centred bar must still be visible")

  local upright = {
    x = 0, y = 0, w = 6, h = 100, vertical = true,
    fill = {set = function(self, changes) self.last = changes end},
  }
  primitives.setBipolarBar(upright, 1)
  assertEqual(upright.fill.last.y, 0, "positive deflection must grow upward")
  assertEqual(upright.fill.last.h, 50)
  primitives.setBipolarBar(upright, -1)
  assertEqual(upright.fill.last.y, 50, "negative deflection must grow downward")
end

--- Presets supply defaults without overriding anything the layout states.
local function testMetricPresets()
  local metric = loadModule("components/metric.lua")

  local preset = {preset = "altitude"}
  metric.applyPreset(preset)
  assertEqual(preset.label, "ALT")
  assertEqual(preset.source, "Alt")
  assertEqual(preset.accent, "green")
  assertEqual(preset.max, 400)
  assertEqual(preset.extrema, "source")
  assertEqual(preset.secondarySource, "VSpd")

  -- Anything stated in the layout wins over the preset.
  local overridden = {preset = "altitude", label = "HEIGHT", max = 1200,
    source = "GAlt", extrema = "flight"}
  metric.applyPreset(overridden)
  assertEqual(overridden.label, "HEIGHT")
  assertEqual(overridden.max, 1200)
  assertEqual(overridden.source, "GAlt")
  assertEqual(overridden.extrema, "flight")

  -- An unknown preset and an unknown extrema mode both fall back safely.
  local unknown = {preset = "nonsense", extrema = "sometimes"}
  metric.applyPreset(unknown)
  assertEqual(unknown.label, "METRIC")
  assertEqual(unknown.extrema, "none")
  assertEqual(unknown.extremaMode, "max")

  -- The widest sample decides the font, so it must come from the bounds
  -- rather than from whichever value happens to be showing.
  assertEqual(metric.widestSample({min = 0, max = 1200}, 1), "1200.0")
  assertEqual(metric.widestSample({min = -50, max = 10}, 0), "-50")
end

--- Timer semantics belong to EdgeTX; the component only presents them.
local function testTimerSemantics()
  local timer = loadModule("components/flight-timer.lua")

  local countdown = {
    available = true, countdown = true, value = 90, start = 300,
    elapsed = 210, remaining = 90, expired = false, showElapsed = false,
  }

  assertEqual(timer.displayValue({display = "model"}, countdown), 90)
  assertEqual(timer.displayValue({display = "elapsed"}, countdown), 210)
  -- EdgeTX's own showElapsed preference is honoured by `model`.
  countdown.showElapsed = true
  assertEqual(timer.displayValue({display = "model"}, countdown), 210)
  countdown.showElapsed = false

  assertEqual(timer.resolveState({}, countdown), "normal")
  assertEqual(timer.resolveState({warning = 120}, countdown), "warning")
  assertEqual(timer.resolveState({critical = 120}, countdown), "critical")

  -- A countdown past zero is always critical, whatever the thresholds say.
  local expired = {
    available = true, countdown = true, value = -12, start = 300,
    elapsed = 312, remaining = -12, expired = true,
  }
  assertEqual(timer.resolveState({}, expired), "critical")
  assertEqual(timer.detailText(expired, tostring), "ELAPSED PAST ZERO")

  -- A count-up timer is judged on time used, and has no total to draw.
  local up = {available = true, countdown = false, value = 200, start = 0,
    elapsed = 200, remaining = 0, expired = false}
  assertEqual(timer.resolveState({warning = 180}, up), "warning")
  assertEqual(timer.resolveState({warning = 300}, up), "normal")
  assertEqual(timer.fraction(up), 0, "a count-up timer has no progress")
  assertEqual(timer.fraction(countdown), 0.7)
  assertEqual(timer.fraction(nil), 0)

  assertEqual(timer.resolveState({}, nil), "unavailable")
  assertEqual(timer.resolveState({}, {available = false}), "unavailable")
  assertEqual(timer.detailText(nil, tostring), "NO TIMER")
end

--- The transmitter estimate is optional and must stay off until a layout
--- states the voltage range it should be measured against.
local function testTxBatteryEstimate()
  local battery = loadModule("components/tx-battery.lua")

  assertEqual(battery.hasRange({}), false)
  assertEqual(battery.hasRange({min = 6.6}), false)
  assertEqual(battery.hasRange({min = 8.4, max = 6.6}), false,
    "an inverted range is not a range")
  assertEqual(battery.hasRange({min = 6.6, max = 8.4}), true)

  assertEqual(battery.fraction({}, 7.5), 0, "no range means no estimate")
  assertEqual(battery.fraction({min = 6.6, max = 8.6}, 7.6), 0.5)
  assertEqual(battery.fraction({min = 6.6, max = 8.6}, 9.0), 1)
  assertEqual(battery.fraction({min = 6.6, max = 8.6}, 6.0), 0)

  -- Voltage thresholds always count downward.
  local limits = {warning = 7.0, critical = 6.8}
  assertEqual(battery.resolveState(limits, 7.9, false), "normal")
  assertEqual(battery.resolveState(limits, 6.9, false), "warning")
  assertEqual(battery.resolveState(limits, 6.7, false), "critical")
  assertEqual(battery.resolveState(limits, 7.9, true), "stale")
  assertEqual(battery.resolveState(limits, nil, false), "unavailable")
end

--- Bar and radial geometry is normalized from bounds, but the displayed value
--- is never clamped: a value outside its bounds is still the real value.
local function testVariableNormalization()
  local indicator = loadModule("components/variable-indicator.lua")
  local signed = primitives.signedFraction

  assertEqual(indicator.presentation("radial"), "radial")
  assertEqual(indicator.presentation("sparkline"), "value")
  assertEqual(indicator.presentation(nil), "value")

  local range = {value = 150, min = 0, max = 100}
  assertEqual(indicator.fraction("horizontal-bar", range, signed), 1,
    "the drawing is clamped")
  assertEqual(indicator.format(range.value, 0), "150",
    "the value is not clamped")

  local bipolar = {value = -25, min = -50, max = 100}
  assertEqual(indicator.fraction("bipolar-bar", bipolar, signed), -0.5)
  assertEqual(indicator.fraction("horizontal-bar", {value = 25, min = 0, max = 100},
    signed), 0.25)
  assertEqual(indicator.fraction("radial", {value = nil, min = 0, max = 100},
    signed), 0)
  assertEqual(indicator.fraction("horizontal-bar", {value = 5, min = 5, max = 5},
    signed), 0, "a collapsed range cannot produce a fraction")

  assertEqual(indicator.crossesZero({min = -100, max = 100}), true)
  assertEqual(indicator.crossesZero({min = 0, max = 100}), false)
  assertEqual(indicator.crossesZero({min = -100, max = 0}), false)

  assertEqual(indicator.format(4.5, 1), "4.5")
  assertEqual(indicator.format(nil, 1), "--")
  assertEqual(indicator.format(0 / 0, 1), "--")
end

--- Trim presentation has to survive the two firmware behaviours the service
--- normalizes: an eight-times scale, and a three-position trim that cannot be
--- told from an end stop in a single sample.
local function testTrimPresentation()
  local trims = loadModule("components/trim-panel.lua")

  assertEqual(trims.indicatorCount("single"), 1)
  assertEqual(trims.indicatorCount("pair"), 2)
  assertEqual(trims.indicatorCount("all"), 4)
  assertEqual(trims.indicatorCount("everything"), 1)

  assertEqual(trims.captionFor("trim-ail"), "AIL")
  assertEqual(trims.captionFor("trim-t5"), "T5")
  assertEqual(trims.captionFor("sa"), "SA")
  assertEqual(trims.captionFor(nil), "--")

  local right = {available = true, raw = 240, value = 30, fraction = 0.234375,
    centered = false, threePosition = false}
  assertEqual(trims.valueText({display = "percent"}, right), "+23%")
  assertEqual(trims.valueText({display = "raw"}, right), "+30")
  assertEqual(trims.valueText({display = "none"}, right), "")

  local left = {available = true, raw = -240, value = -30, fraction = -0.234375,
    centered = false, threePosition = false}
  assertEqual(trims.valueText({display = "percent"}, left), "-23%")
  assertEqual(trims.valueText({display = "raw"}, left), "-30")

  local centred = {available = true, raw = 0, value = 0, fraction = 0,
    centered = true, threePosition = false}
  assertEqual(trims.valueText({display = "percent"}, centred), "0%")

  -- A three-position trim reports full deflection or nothing, so naming its
  -- position is honest where a percentage would not be.
  local toggle = {available = true, raw = 1024, value = 128, fraction = 1,
    centered = false, threePosition = true}
  assertEqual(trims.valueText({display = "percent"}, toggle), "3P HI")
  toggle.raw, toggle.centered, toggle.fraction = 0, true, 0
  assertEqual(trims.valueText({display = "percent"}, toggle), "3P MID")
  toggle.raw, toggle.centered, toggle.fraction = -1024, false, -1
  assertEqual(trims.valueText({display = "raw"}, toggle), "3P LO")

  assertEqual(trims.valueText({display = "percent"}, nil), "--")
  assertEqual(trims.valueText({display = "percent"}, {available = false}), "--")

  -- EdgeTX exposes no axis metadata for a trim source, so `auto` follows the
  -- panel's shape and an explicit override always wins.
  local wide = {x = 0, y = 0, w = 200, h = 60}
  local tall = {x = 0, y = 0, w = 60, h = 200}
  assertEqual(trims.isVertical({orientation = "auto"}, 1, wide), false)
  assertEqual(trims.isVertical({orientation = "auto"}, 1, tall), true)
  assertEqual(trims.isVertical({orientation = "vertical"}, 1, wide), true)
  assertEqual(trims.isVertical(
    {orientation = "vertical", orientation2 = "horizontal"}, 2, wide), false)
end

--- Identity presentation, and the file check that stands in for a decode the
--- LVGL image object never reports back to Lua.
local function testIdentityPresentation()
  local identity = loadModule("components/model-identity.lua")

  assertEqual(identity.presentationFor({presentation = "name"}, 4, 4).showImage, false)
  assertEqual(identity.presentationFor({presentation = "image"}, 1, 1).showName, false)
  assertEqual(identity.presentationFor({presentation = "both"}, 1, 1).showImage, true)
  -- `auto` spends space on a picture only when there is space to spend.
  assertEqual(identity.presentationFor({presentation = "auto"}, 1, 1).showImage, false)
  assertEqual(identity.presentationFor({presentation = "auto"}, 2, 2).showImage, true)

  local exists, checked = identity.fileExists("")
  assertEqual(exists, false)
  assertEqual(checked, true, "an empty path is answered without the filesystem")

  local previous = fstat
  fstat = nil
  local _, unchecked = identity.fileExists("/IMAGES/plane.png")
  assertEqual(unchecked, false,
    "without fstat nothing can be proven, so the fallback must stay")

  -- A firmware whose fstat raises must not take the component with it.
  fstat = function() error("no filesystem") end
  assertEqual(identity.fileExists("/IMAGES/plane.png"), false)

  fstat = function(path) return path == "/IMAGES/plane.png" and {size = 10} or nil end
  assertEqual(identity.fileExists("/IMAGES/plane.png"), true)
  assertEqual(identity.fileExists("/IMAGES/gone.png"), false)
  fstat = previous

  -- The image is created after the text and painted with `fill`, so anything
  -- it is allowed to overlap simply disappears. Every row that will be drawn
  -- has to come out of the height the image is given.
  local resolved = theme.build("modern")
  local sizes = {{234, 130}, {472, 264}, {117, 130}, {117, 60}}
  local cases = {
    {showName = true, showImage = true, showLabels = true},
    {showName = false, showImage = true, showLabels = true},
    {showName = true, showImage = true, showLabels = false},
    {showName = false, showImage = true, showLabels = false},
  }

  for _, layout in ipairs(cases) do
    for _, size in ipairs(sizes) do
      local width, height = size[1], size[2]
      local area = identity.regionsFor(resolved, theme,
        {x = 0, y = 0, w = width, h = height}, layout, theme.typography(2, 2))
      local where = width .. "x" .. height

      if area.showImage then
        local bottom = area.imageY + area.imageHeight
        assert(bottom <= height, where .. ": the image ran past the panel")
        if area.showName then
          assert(bottom <= area.nameY,
            where .. ": the image covered the model name, image ends at "
              .. bottom .. ", name starts at " .. area.nameY)
        end
        if area.showLabels then
          assert(bottom <= area.labelsY,
            where .. ": the image covered the labels row, image ends at "
              .. bottom .. ", labels start at " .. area.labelsY)
        end
      end
    end
  end
end

--- EdgeTX returns a table of cell voltages, and every part of that sentence
--- can fail: it may not be a table, it may be empty, and its entries may not
--- be voltages. Each failure needs its own answer, because each needs a
--- different fix from the pilot.
local function testCellShapes()
  local cellBattery = loadModule("components/cell-battery.lua")
  local out = {}

  assertEqual(cellBattery.summarize(nil, out).shape, "none")
  -- "Cels-" carries the cells unit but returns a plain number, so a layout
  -- can very easily point this component at one.
  assertEqual(cellBattery.summarize(4.09, out).shape, "number")
  assertEqual(cellBattery.summarize("4.09", out).shape, "invalid")
  assertEqual(cellBattery.summarize({}, out).shape, "empty")

  local pack = cellBattery.summarize({4.11, 4.13, 4.09, 4.12}, out)
  assertEqual(pack.shape, "cells")
  assertEqual(pack.count, 4)
  assertEqual(pack.lowest, 4.09)
  assertEqual(pack.highest, 4.13)
  assert(math.abs(pack.pack - 16.45) < 0.001, tostring(pack.pack))
  assert(math.abs(pack.spread - 0.04) < 0.001, tostring(pack.spread))

  -- Entries that cannot be cell voltages are rejected rather than folded in,
  -- because an average dragged down by a zero hides the cell that matters.
  local mixed = cellBattery.summarize({4.11, 0, 4.12, 99}, out)
  assertEqual(mixed.shape, "cells")
  assertEqual(mixed.count, 2)
  assertEqual(mixed.rejected, 2)
  assertEqual(mixed.lowest, 4.11)

  assertEqual(cellBattery.summarize({0, -1, 99}, out).shape, "invalid")
  -- A NaN is excluded by the bounds test rather than becoming the lowest cell.
  local nan = cellBattery.summarize({4.11, 0 / 0, 4.12}, out)
  assertEqual(nan.count, 2)
  assertEqual(nan.lowest, 4.11)

  -- The walk is bounded, because the table comes from the firmware and runs
  -- inside the host's instruction budget.
  local long = {}
  for index = 1, cellBattery.CELL_LIMIT + 8 do long[index] = 4.0 end
  assertEqual(cellBattery.summarize(long, out).count, cellBattery.CELL_LIMIT)

  -- A hole ends the walk: EdgeTX reports contiguous cells.
  assertEqual(cellBattery.summarize({4.1, 4.2, nil, 4.3}, out).count, 2)
end

--- The lowest cell is the safety reading, and the bar is scaled over the
--- usable range rather than from zero volts.
local function testCellReadings()
  local cellBattery = loadModule("components/cell-battery.lua")
  local out = {}
  local summary = cellBattery.summarize({4.11, 3.25, 4.09, 4.12}, out)
  local settings = {reading = "lowest", min = 3.3, max = 4.2,
    warning = 3.5, critical = 3.3}

  assertEqual(cellBattery.primaryValue(settings, summary), 3.25)
  -- An explicitly configured lowest-cell source wins: the receiver has seen
  -- samples between our polls that this component never will.
  assertEqual(cellBattery.primaryValue(settings, summary, 3.11), 3.11)

  local pack = {reading = "pack", min = 3.3, max = 4.2}
  assert(math.abs(cellBattery.primaryValue(pack, summary) - 15.57) < 0.001)
  local average = {reading = "average"}
  assert(math.abs(cellBattery.primaryValue(average, summary) - 3.8925) < 0.001)
  -- An explicit lowest source must not be mistaken for a pack reading.
  assert(math.abs(cellBattery.primaryValue(pack, summary, 3.11) - 15.57) < 0.001)

  -- The bar runs from the critical voltage to full. Scaled from zero, a cell
  -- at 3.3 V would read four fifths full.
  assertEqual(cellBattery.fraction(settings, 3.3, 4), 0)
  assertEqual(cellBattery.fraction(settings, 4.2, 4), 1)
  assert(math.abs(cellBattery.fraction(settings, 3.75, 4) - 0.5) < 0.001)
  assertEqual(cellBattery.fraction(settings, 2.0, 4), 0, "the drawing clamps")
  assertEqual(cellBattery.fraction(settings, 0 / 0, 4), 0)
  -- A pack reading is divided by its own cell count before being scaled.
  assert(math.abs(cellBattery.fraction(pack, 15.0, 4) - 0.5) < 0.001)
  assertEqual(cellBattery.fraction(pack, 15.0, 0), 0,
    "a pack with no known cell count cannot be scaled")

  -- Thresholds judge the worst cell even when the panel shows the pack sum.
  assertEqual(cellBattery.resolveState(settings, 15.57, 3.25, false), "critical")
  assertEqual(cellBattery.resolveState(settings, 3.45, 3.45, false), "warning")
  assertEqual(cellBattery.resolveState(settings, 3.9, 3.9, false), "normal")
  assertEqual(cellBattery.resolveState(settings, 3.9, 3.9, true), "stale")
  assertEqual(cellBattery.resolveState(settings, nil, nil, false), "unavailable")

  -- A shape problem and a missing sensor need different words.
  assertEqual(cellBattery.badgeText({shape = "number"}, "unavailable", "NO SOURCE"),
    "NOT CELLS")
  assertEqual(cellBattery.badgeText({shape = "invalid"}, "unavailable", "NO SOURCE"),
    "BAD CELLS")
  assertEqual(cellBattery.badgeText({shape = "none"}, "unavailable", "NO SOURCE"),
    "NO SOURCE")
  assertEqual(cellBattery.badgeText({shape = "cells"}, "warning", "WARN"), "WARN")
end

--- Three situations look like a zero and must not: a dead link, a protocol
--- with no RSSI sensor, and a reading that really is zero.
local function testLinkClassification()
  local linkStatus = loadModule("components/link-status.lua")

  assertEqual(linkStatus.classify(nil), "none")
  assertEqual(linkStatus.classify({name = ""}), "none")
  assertEqual(linkStatus.classify({name = "RSSI", known = false}), "absent")
  assertEqual(linkStatus.classify({name = "RSSI", known = true}), "waiting")
  assertEqual(linkStatus.classify(
    {name = "RSSI", known = true, available = true, stale = true}), "stale")
  assertEqual(linkStatus.classify(
    {name = "RSSI", known = true, available = true}), "live")

  -- Auto prefers quality, because a percentage means the same thing on every
  -- protocol where RSSI does not, but never at the cost of an empty panel.
  assertEqual(linkStatus.primaryFor({primary = "auto"}, "live", "live"), "quality")
  assertEqual(linkStatus.primaryFor({primary = "auto"}, "live", "absent"), "rssi")
  assertEqual(linkStatus.primaryFor({primary = "auto"}, "live", "none"), "rssi")
  assertEqual(linkStatus.primaryFor({primary = "auto"}, "absent", "live"), "quality")
  -- An explicit choice is never overridden, however bad the source looks.
  assertEqual(linkStatus.primaryFor({primary = "rssi"}, "absent", "live"), "rssi")
  assertEqual(linkStatus.primaryFor({primary = "quality"}, "live", "absent"),
    "quality")

  local thresholds = {warning = 50, critical = 30}
  local function state(reading)
    local name = linkStatus.resolveState(thresholds, reading)
    local _, badge = linkStatus.resolveState(thresholds, reading)
    return name, badge
  end

  -- A protocol with no RSSI sensor is a permanent property of the link, not a
  -- fade, and it must never be reported as a dead link.
  local name, badge = state({sourceState = "absent", linkDown = false})
  assertEqual(name, "unavailable")
  assertEqual(badge, "NO SENSOR")

  -- A dead link is the measurement this panel exists to report.
  name, badge = state({sourceState = "live", linkDown = true, available = true,
    value = 96})
  assertEqual(name, "critical")
  assertEqual(badge, "NO LINK")

  -- Never powered up is not an alarm.
  name, badge = state({sourceState = "waiting", linkDown = true, available = false})
  assertEqual(name, "unavailable")
  assertEqual(badge, "NO LINK")

  -- Thresholds count downward, and a genuine zero on a live link is a
  -- reading, not a missing one.
  assertEqual(state({sourceState = "live", value = 96}), "normal")
  assertEqual(state({sourceState = "live", value = 44}), "warning")
  assertEqual(state({sourceState = "live", value = 0}), "critical")
  assertEqual(state({sourceState = "stale", value = 96}), "stale")

  -- A source the radio has never heard of reads N/A, never zero.
  assertEqual(linkStatus.sourceText(nil, "none"), "--")
  assertEqual(linkStatus.sourceText({}, "absent"), "N/A")
  assertEqual(linkStatus.sourceText(
    {value = 78, precision = 0, unitText = "dB"}, "live"), "78dB")
  assertEqual(linkStatus.sourceText(
    {value = -72.4, precision = 1, unitText = "dBm"}, "live"), "-72.4dBm")

  -- The bar clamps its drawing without altering the reading, including for a
  -- dBm range that is entirely negative.
  local dbm = {min = -110, max = -30}
  assertEqual(linkStatus.fraction(dbm, -110), 0)
  assertEqual(linkStatus.fraction(dbm, -30), 1)
  assert(math.abs(linkStatus.fraction(dbm, -70) - 0.5) < 0.001)
  assertEqual(linkStatus.fraction(dbm, -200), 0)
  assertEqual(linkStatus.fraction({min = 0, max = 0}, 5), 0)
end

--- The link view is the only thing that can tell a dead link from a protocol
--- that never populates an RSSI sensor, so it has to say both.
local function testTelemetryLinkView()
  local harness = telemetryHarness()
  local service = harness.service
  local link = service:link()
  local pack = service:subscribe("RxBt")

  -- Subscribing to the link is itself a reason to run the service.
  assert(service.count >= 2, "the link subscription was not counted")

  service:update(0)
  assertEqual(link.live, true)
  assertEqual(link.rssi, 80)
  assertEqual(link.indicator, true)

  harness.rssi = 0
  harness.values[100] = 0
  service:update(1)
  assertEqual(link.live, false, "a dead link was reported as live")
  assertEqual(link.indicator, true)
  assertEqual(pack.state, "stale")

  -- A protocol with no RSSI sensor: values keep arriving while getRSSI reads
  -- zero. The indicator is wrong, and the service must say so rather than
  -- pinning every reading stale.
  local other = telemetryHarness()
  local otherLink = other.service:link()
  local reading = other.service:subscribe("RxBt")
  other.rssi = 0
  other.service:update(0)
  assertEqual(reading.value, 24.4, "a live reading was discarded as stale")
  assertEqual(otherLink.live, true,
    "the link view still trusted an indicator a reading had disproved")
  assertEqual(otherLink.indicator, false, "a broken indicator was not reported")
  assertEqual(otherLink.rssi, 0)

  -- The view is immutable like every other snapshot.
  local ok = pcall(function() otherLink.live = false end)
  assertEqual(ok, false, "the link view accepted a write")
end

--- A compass is north-up and says nothing when there is nothing to say.
local function testCompassGeometry()
  -- LVGL measures zero at three o'clock; a compass measures zero at twelve.
  assertEqual(primitives.arcAngle(0), 270)
  assertEqual(primitives.arcAngle(90), 0)
  assertEqual(primitives.arcAngle(180), 90)
  assertEqual(primitives.arcAngle(270), 180)
  assertEqual(primitives.arcAngle(359.6), 270)

  local compass = {
    ring = {set = function(self, changes) self.last = changes end},
  }

  primitives.setCompass(compass, 90)
  assertEqual(compass.bearing, 90)
  assertEqual(compass.ring.last.startAngle, 345)
  assertEqual(compass.ring.last.endAngle, 15)

  -- A withheld bearing hides the pointer rather than resting it at north,
  -- which would read as a valid due-north fix.
  primitives.setCompass(compass, nil)
  assertEqual(compass.bearing, nil)
  assertEqual(compass.ring.last.startAngle, compass.ring.last.endAngle,
    "an unknown bearing must draw a zero length pointer")
  primitives.setCompass(compass, 0 / 0)
  assertEqual(compass.ring.last.startAngle, compass.ring.last.endAngle,
    "an unknown bearing must draw a zero length pointer")

  -- EdgeTX positions an arc by its centre: LvglWidgetRoundObject::setPos
  -- stores x - radius, so a component laying out in corner coordinates has to
  -- convert, and this is where that conversion lives.
  local box = primitives.arcBounds(100, 60, 20)
  assertEqual(box.x, 80)
  assertEqual(box.y, 40)
  assertEqual(box.w, 40)
  assertEqual(box.h, 40)
  assertEqual(primitives.arcBounds(100, 60, 20, 6).x, 77)
end

--- Navigation presentations, and the three degraded states that each need
--- their own words.
local function testNavigationPresentation()
  local navigation = loadModule("components/navigation.lua")

  assertEqual(navigation.cardinal(0), "N")
  assertEqual(navigation.cardinal(44), "NE")
  assertEqual(navigation.cardinal(350), "N")
  assertEqual(navigation.cardinal(270), "W")
  assertEqual(navigation.cardinal(nil), "")

  -- Auto spends space on direction only once there is room for it.
  assertEqual(navigation.presentation("auto", 1, 1), "distance")
  assertEqual(navigation.presentation("auto", 2, 1), "bearing")
  assertEqual(navigation.presentation("auto", 2, 2), "compass")
  assertEqual(navigation.presentation("auto", 3, 2), "detailed")
  -- A stated presentation always wins, and nonsense falls back to the span.
  assertEqual(navigation.presentation("distance", 4, 4), "distance")
  assertEqual(navigation.presentation("nonsense", 1, 1), "distance")

  local contents = navigation.presentationFor("detailed")
  assertEqual(contents.showCompass, true)
  assertEqual(contents.showCoordinates, true)
  assertEqual(navigation.presentationFor("distance").showDetail, false)
  assertEqual(navigation.presentationFor("bearing").showCompass, false)

  local fix = {source = "GPS", known = true, fix = true, home = true,
    state = "normal", latitude = 47.3769, longitude = 8.5417,
    distance = 778, bearing = 9.47}

  assertEqual(navigation.bearingText(fix), "BRG 009 N")
  assertEqual(navigation.originText(fix), "NORTH UP FROM HOME")
  assertEqual(navigation.coordinateText(fix), "47.37690 8.54170")
  assertEqual(navigation.resolveState({}, fix), "normal")

  -- Distance thresholds count upward: further away is worse.
  assertEqual(navigation.resolveState({warning = 500}, fix), "warning")
  assertEqual(navigation.resolveState({critical = 700}, fix), "critical")

  -- A fix with no home position is not a broken fix. The position is still
  -- known; only the two values measured from home are withheld.
  local noHome = {source = "GPS", known = true, fix = true, home = false,
    state = "normal", latitude = 47.3769, longitude = 8.5417}
  local state, badge = navigation.resolveState({}, noHome)
  assertEqual(state, "normal")
  assertEqual(badge, "NO HOME")
  assertEqual(navigation.bearingText(noHome), "BRG --")
  assertEqual(navigation.originText(noHome), "NO HOME POSITION")
  assertEqual(navigation.coordinateText(noHome), "47.37690 8.54170")

  -- No fix is reported as such, never as a distance of zero.
  local noFix = {source = "GPS", known = true, fix = false, home = false,
    state = "unavailable"}
  state, badge = navigation.resolveState({}, noFix)
  assertEqual(state, "unavailable")
  assertEqual(badge, "NO FIX")
  assertEqual(navigation.coordinateText(noFix), "-- , --")

  -- A source the radio does not have is a different problem again.
  state, badge = navigation.resolveState({},
    {source = "GPS", known = false, fix = false, home = false})
  assertEqual(state, "unavailable")
  assertEqual(badge, "NO SOURCE")
  assertEqual(navigation.originText({source = "GPS", known = false}),
    "NO GPS SOURCE")

  -- Stale keeps the last known position visible and marked.
  local stale = {source = "GPS", known = true, fix = true, home = true,
    state = "stale", distance = 778, bearing = 9.47}
  assertEqual(navigation.resolveState({}, stale), "stale")
  assertEqual(navigation.originText(stale), "LAST KNOWN")
end

--- A dial that cannot be read is not worth the pixels, so it is dropped
--- before the dominant reading is shrunk.
local function testNavigationRegions()
  local navigation = loadModule("components/navigation.lua")
  local resolved = theme.build("modern")
  local fonts = theme.typography(2, 2)
  local layout = navigation.presentationFor("detailed")

  local large = navigation.regionsFor(resolved, theme,
    {x = 0, y = 0, w = 238, h = 134}, layout, fonts, "888.88km")
  assertEqual(large.showCompass, true)
  assertEqual(large.showCoordinates, true)
  -- The dial sits inside its own panel, measured from its centre.
  local box = primitives.arcBounds(large.centreX, large.centreY, large.radius)
  assert(box.x >= 0 and box.y >= 0, "the dial was placed off the panel")
  assert(box.x + box.w <= 238, "the dial overflowed the panel")
  assert(box.y + box.h <= 134, "the dial overflowed the panel")
  -- And never over the reading beside it.
  assert(large.pad + large.valueWidth <= box.x, "the dial overlaps the value")

  -- A panel that cannot afford everything sheds the coordinates first and the
  -- dial next, and never the distance.
  local short = navigation.regionsFor(resolved, theme,
    {x = 0, y = 0, w = 238, h = 62}, layout, fonts, "888.88km")
  assertEqual(short.showCoordinates, false)

  local tiny = navigation.regionsFor(resolved, theme,
    {x = 0, y = 0, w = 58, h = 40}, layout, fonts, "888.88km")
  assertEqual(tiny.showCompass, false, "an unreadable dial was kept")
  assertEqual(tiny.radius, 0)
  assertEqual(tiny.valueWidth, tiny.content, "the reading did not reclaim the room")
end

--- Every region of the three telemetry components, at every span they claim,
--- must clear every other region. Two rows resolved onto the same line draw
--- over each other on the radio and look like one unreadable smear, and
--- nothing about the resolved numbers says so unless it is asserted.
local function testTelemetryContentFitsPanel()
  local cellBattery = loadModule("components/cell-battery.lua")
  local linkStatus = loadModule("components/link-status.lua")
  local navigationComponent = loadModule("components/navigation.lua")
  local resolved = theme.build("modern")
  local heightOf = theme.fontHeight

  -- Panel sizes for spans at 480 x 272 with 4 px gutters, plus tight cases.
  local cases = {
    {name = "2x2", w = 238, h = 134, colSpan = 2, rowSpan = 2},
    {name = "2x1", w = 238, h = 65, colSpan = 2, rowSpan = 1},
    {name = "1x1", w = 117, h = 65, colSpan = 1, rowSpan = 1},
    {name = "shrunk", w = 158, h = 68, colSpan = 2, rowSpan = 2},
    {name = "tiny", w = 60, h = 40, colSpan = 1, rowSpan = 1},
  }

  for _, case in ipairs(cases) do
    local rect = {x = 0, y = 0, w = case.w, h = case.h}
    local fonts = theme.typography(case.colSpan, case.rowSpan)
    local labelHeight = heightOf(fonts.label)

    --- Shared assertions: the reading fits its own region in both axes, and
    --- clears the header above it and whatever row sits below it.
    local function assertReading(what, area, valueFont, valueWidth, sample)
      local bottom = area.valueY + heightOf(valueFont)
      assert(bottom <= case.h, what .. " " .. case.name
        .. ": the reading overflows the panel, ends at " .. bottom)
      assert(area.valueY >= labelHeight, what .. " " .. case.name
        .. ": the reading overlaps the header")
      assert(area.pad + valueWidth <= case.w, what .. " " .. case.name
        .. ": the reading runs past the right edge")

      -- Width matters as much as height: the widest string this component can
      -- ever print has to fit the column it was given, or it clips sideways.
      -- The smallest font is the honest answer when nothing fits.
      assert(theme.textWidth(valueFont, sample) <= valueWidth
        or valueFont == SMLSIZE, what .. " " .. case.name
        .. ": the reading was fitted by height alone and clips at "
        .. theme.textWidth(valueFont, sample) .. " in " .. valueWidth)

      if area.showDetail then
        assert(bottom <= area.detailY, what .. " " .. case.name
          .. ": the reading overlaps the supporting row below it")
      end
    end

    --- A two-column supporting row: neither half may touch the other.
    local function assertColumns(what, area, leftWidth, rightX, rightWidth)
      assert(area.pad + leftWidth <= rightX, what .. " " .. case.name
        .. ": supporting columns overlap")
      assert(rightX + rightWidth <= case.w, what .. " " .. case.name
        .. ": a supporting column runs past the right edge")
    end

    local cellLayout = cellBattery.presentationFor(case.colSpan, case.rowSpan)
    cellLayout.visual = "bar"
    local cells = cellBattery.regionsFor(
      resolved, theme, rect, cellLayout, fonts, "4.44V")
    assertReading("cell-battery", cells, cells.value, cells.content, "4.44V")
    if cells.showDetail then
      assert(cells.detailY + labelHeight <= cells.barY, "cell-battery "
        .. case.name .. ": the detail row overlaps the bar")
      assertColumns("cell-battery", cells,
        cells.detailWidth, cells.packX, cells.detailWidth)
    end
    if cells.showVisual then
      assert(cells.barY + resolved.spacing.barHeight <= case.h,
        "cell-battery " .. case.name .. ": the bar overflows the panel")
    end

    local linkLayout = linkStatus.presentationFor(case.colSpan, case.rowSpan)
    linkLayout.visual = "bar"
    local link = linkStatus.regionsFor(
      resolved, theme, rect, linkLayout, fonts, "-100dBm")
    assertReading("link-status", link, link.value, link.content, "-100dBm")
    if link.showDetail then
      assert(link.detailY + labelHeight <= link.barY, "link-status "
        .. case.name .. ": the detail row overlaps the bar")
      assertColumns("link-status", link,
        link.detailWidth, link.linkX, link.linkWidth)
    end

    for _, presentation in ipairs({"distance", "bearing", "compass", "detailed"}) do
      local navLayout = navigationComponent.presentationFor(presentation)
      local nav = navigationComponent.regionsFor(
        resolved, theme, rect, navLayout, fonts, "888.88km")
      local what = "navigation/" .. presentation
      assertReading(what, nav, nav.value, nav.valueWidth, "888.88km")

      if nav.showDetail then
        assert(nav.detailY + labelHeight <= case.h,
          what .. " " .. case.name .. ": the bearing row overflows the panel")
        assertColumns(what, nav, nav.detailWidth, nav.originX, nav.originWidth)
      end
      if nav.showCoordinates then
        -- The coordinates sit below the bearing row, not on top of it.
        assert(nav.detailY + labelHeight <= nav.coordinatesY, what .. " "
          .. case.name .. ": the coordinates row overlaps the bearing row")
        assert(nav.coordinatesY + labelHeight <= case.h, what .. " "
          .. case.name .. ": the coordinates row overflows the panel")
      end
      if nav.showCompass then
        local box = primitives.arcBounds(nav.centreX, nav.centreY, nav.radius)
        assert(box.x >= 0 and box.y >= 0,
          what .. " " .. case.name .. ": the dial was placed off the panel")
        assert(box.x + box.w <= case.w and box.y + box.h <= case.h,
          what .. " " .. case.name .. ": the dial overflows the panel")
        assert(nav.pad + nav.valueWidth <= box.x,
          what .. " " .. case.name .. ": the dial overlaps the reading")
      end
    end
  end

  -- Shedding exists to protect the dominant reading, not merely to avoid an
  -- overlap. A 2 x 1 panel could fit its supporting row and a small value at
  -- the same time; the specification says to drop the row instead, so the
  -- reading a pilot glances at stays large.
  local squeezed = {x = 0, y = 0, w = 238, h = 65}
  local wideFonts = theme.typography(2, 1)

  local cellLayout = cellBattery.presentationFor(2, 1)
  cellLayout.visual = "bar"
  local shedCells = cellBattery.regionsFor(
    resolved, theme, squeezed, cellLayout, wideFonts, "4.44V")
  assertEqual(shedCells.showDetail, false,
    "cell-battery kept a supporting row a short panel could not afford")
  assert(heightOf(shedCells.value) >= heightOf(MIDSIZE),
    "cell-battery shed a row without buying its reading any size")

  local linkLayout = linkStatus.presentationFor(2, 1)
  linkLayout.visual = "bar"
  local shedLink = linkStatus.regionsFor(
    resolved, theme, squeezed, linkLayout, wideFonts, "-100dBm")
  assertEqual(shedLink.showDetail, false,
    "link-status kept a supporting row a short panel could not afford")
  assert(heightOf(shedLink.value) >= heightOf(MIDSIZE),
    "link-status shed a row without buying its reading any size")

  local shedNav = navigationComponent.regionsFor(resolved, theme, squeezed,
    navigationComponent.presentationFor("detailed"), wideFonts, "888.88km")
  assertEqual(shedNav.showCoordinates, false,
    "navigation kept a coordinates row a short panel could not afford")
  assert(heightOf(shedNav.value) >= heightOf(MIDSIZE),
    "navigation shed a row without buying its reading any size")
end

testSnapshotsAreImmutable()
testServiceScheduling()
testTelemetryFreshness()
testTelemetryLinkHeuristics()
testTelemetryPollingIsBounded()
testModelService()
testControlService()
testExtremaService()
testNavigationService()
testFontHeightsMatchTheFirmware()
testTextFitting()
testBipolarGeometry()
testMetricPresets()
testTimerSemantics()
testTxBatteryEstimate()
testVariableNormalization()
testTrimPresentation()
testIdentityPresentation()
testCellShapes()
testCellReadings()
testLinkClassification()
testTelemetryLinkView()
testCompassGeometry()
testNavigationPresentation()
testNavigationRegions()
testTelemetryContentFitsPanel()

print("AeroGrid runtime tests passed")