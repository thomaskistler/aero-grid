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

testSnapshotsAreImmutable()
testServiceScheduling()
testTelemetryFreshness()
testTelemetryLinkHeuristics()
testTelemetryPollingIsBounded()
testModelService()
testControlService()
testExtremaService()
testNavigationService()

print("AeroGrid runtime tests passed")