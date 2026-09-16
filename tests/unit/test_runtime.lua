-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

-- Minimal EdgeTX surface required by the theme and primitive modules.
SMLSIZE = 3
MIDSIZE = 4
DBLSIZE = 5
XXLSIZE = 6
BOLD = 1

lcd = {
  RGB = function(red, green, blue)
    if green == nil and blue == nil then return red end
    return red * 65536 + green * 256 + blue
  end,
}

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

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
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
  assertEqual(resolved.rgb.canvas, 0x101316)
  assertEqual(resolved.rgb.critical, 0xF05252)
  assertEqual(resolved.color.canvas, 0x101316)
  assertEqual(resolved.spacing.gutter, 4)

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
  -- A pale EdgeTX theme whose own text color would be unreadable for us.
  local values = {
    [1] = 0x000000, [2] = 0xF0F0F0, [3] = 0x9E9E9E,
    [4] = 0x1B3A57, [5] = 0x3F7CA8, [6] = 0xC8D8E4,
    [7] = 0x1E88E5, [8] = 0xFF8F00, [9] = 0x43A047,
    [10] = 0xF9A825, [11] = 0x757575,
  }

  local function toRgb565(rgb)
    local red = math.floor(rgb / 65536) % 256
    local green = math.floor(rgb / 256) % 256
    local blue = rgb % 256
    return math.floor(red * 31 / 255) * 2048
      + math.floor(green * 63 / 255) * 32
      + math.floor(blue * 31 / 255)
  end

  local resolved = theme.build("edgetx", nil, {
    roles = roles,
    getColor = function(role) return toRgb565(values[role]) end,
  })

  assertEqual(resolved.mode, "edgetx")
  assert(resolved.rgb.canvas ~= theme.modern().canvas, "canvas was not derived")
  assertEqual(resolved.rgb.critical, theme.modern().critical)
  assert(theme.contrast(resolved.rgb.surface, resolved.rgb.text) >= 4.5,
    "derived text is unreadable")
  assert(theme.contrast(resolved.rgb.surface, resolved.rgb.surfaceRaised) > 1,
    "surfaces were not separated")

  -- A radio without color support falls back with a warning.
  local missing = theme.build("edgetx", nil, {getColor = false})
  assertEqual(missing.rgb.canvas, theme.modern().canvas)
  assert(string.match(missing.warnings[1], "unavailable"), missing.warnings[1])

  -- Unreadable roles also fall back rather than producing an invisible theme.
  local broken = theme.build("edgetx", nil, {
    roles = roles,
    getColor = function() error("no colors", 0) end,
  })
  assertEqual(broken.rgb.canvas, theme.modern().canvas)
  assert(string.match(table.concat(broken.warnings, "\n"), "unreadable"))
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
  assertEqual(resolved.rgb.surface, 0x141414)
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
  assertEqual(theme.typography(1, 1).primary, MIDSIZE)
  assertEqual(theme.typography(2, 1).primary, DBLSIZE)
  assertEqual(theme.typography(1, 2).primary, DBLSIZE)
  assertEqual(theme.typography(2, 2).primary, XXLSIZE)
  assertEqual(theme.typography(2, 2).unit, MIDSIZE)
  assertEqual(theme.typography(1, 1).unit, SMLSIZE)
  assertEqual(theme.typography(1, 1).label, SMLSIZE)
end

--- Every state must be distinguishable by more than color alone.
local function testStates()
  local resolved = theme.build("modern")
  local modern = theme.modern()

  local normal = theme.state(resolved, "normal", "green")
  assertEqual(normal.accent, modern.green)
  assertEqual(normal.badge, nil)
  assertEqual(normal.value, modern.text)

  -- Warning and freshness states override a decorative accent.
  assertEqual(theme.state(resolved, "warning", "green").accent, modern.amber)
  assertEqual(theme.state(resolved, "critical", "green").accent, modern.critical)
  assertEqual(theme.state(resolved, "stale", "green").value, modern.textMuted)
  assertEqual(theme.state(resolved, "unavailable", "green").value, modern.textFaint)

  -- Each non-normal state carries a text badge.
  for _, name in ipairs({"stale", "warning", "critical", "unavailable", "editing"}) do
    local presentation = theme.state(resolved, name)
    assert(presentation.badge and presentation.badge ~= "",
      name .. " has no text badge")
  end

  -- Selection and editing use a heavier focus border.
  assert(theme.state(resolved, "selected").borderWidth
    > theme.state(resolved, "normal").borderWidth)

  -- An unknown accent falls back to the theme default rather than failing.
  assertEqual(theme.state(resolved, "normal", "magenta").accent, modern.cyan)
  assertEqual(theme.accentColor(resolved, "amber"), modern.amber)
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
  local surfaces = {0xFFFFFF, 0x000000, 0x69737A, 0x808080, 0xF2B84B, 0x101316}

  for _, surface in ipairs(surfaces) do
    local resolved = theme.build("custom", {surface = surface, canvas = surface})
    local tokens = resolved.rgb
    local label = string.format("surface 0x%06X", surface)

    assert(theme.contrast(tokens.surface, tokens.text) >= 4.5, label .. ": text")
    assert(theme.contrast(tokens.surface, tokens.textMuted) >= 3.0, label .. ": muted")
    assert(theme.contrast(tokens.surface, tokens.textFaint) >= 1.8, label .. ": faint")

    -- Structural separation must be visible in either direction.
    assert(theme.contrast(tokens.surface, tokens.surfaceRaised) >= 1.08,
      label .. ": elevation vanished")
    assert(theme.contrast(tokens.surface, tokens.border) >= 1.25,
      label .. ": border vanished")

    -- Every state accent must remain visible, including the fixed critical red.
    for _, key in ipairs({"cyan", "green", "amber", "orange", "critical"}) do
      assert(theme.contrast(tokens.surface, tokens[key]) >= 2.5,
        label .. ": accent " .. key .. " vanished")
    end

    -- The unavailable state must stay readable against its own panel.
    local unavailable = theme.state(resolved, "unavailable")
    assert(unavailable.badge ~= nil and unavailable.badge ~= "")
    assert(theme.contrast(tokens.surface, unavailable.value) >= 1.8,
      label .. ": unavailable text vanished")
  end
end

--- Freshness must override a component's decorative accent.
local function testStaleOverridesAccent()
  local resolved = theme.build("modern")
  local modern = theme.modern()

  local normal = theme.state(resolved, "normal", "green")
  local stale = theme.state(resolved, "stale", "green")

  assertEqual(normal.accent, modern.green)
  assert(stale.accent ~= modern.green, "stale kept the decorative accent")
  assertEqual(stale.accent, modern.textFaint)
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

--- The demo driver must actually reach every state it claims to demonstrate.
local function testDemoDriver()
  local metric = loadModule("components/metric.lua")

  local configs = {
    falling = {min = 18, max = 25.2, warning = 21.0, critical = 19.8},
    rising = {min = 0, max = 120, warning = 90, critical = 110},
    unbounded = {min = 0, max = 400},
  }

  for name, settings in pairs(configs) do
    for _, phase in ipairs({"normal", "warning", "critical"}) do
      if settings.warning or phase == "normal" then
        for step = 0, 9 do
          local value = metric.demoValue(settings, phase, step / 10)
          local state = metric.resolveState(settings, value, false)
          local expected = settings.warning and phase or "normal"
          assertEqual(state, expected,
            name .. " " .. phase .. " at step " .. step .. " gave " .. value)
          -- Synthetic readings must stay inside the configured range.
          assert(value >= settings.min - 0.001 and value <= settings.max + 0.001,
            name .. " " .. phase .. " left the range: " .. value)
        end
      end
    end
  end

  -- The driver is inert unless a layout opts in.
  local inert = {settings = {demo = false}}
  metric.refresh(inert)
  assertEqual(inert.demoTick, nil, "demo ran without being enabled")
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
testMetricDirection()
testDemoDriver()

print("AeroGrid runtime tests passed")