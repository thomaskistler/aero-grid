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
  -- Kept, because a layout written for a newer component must survive an
  -- older host, and reported, because an undeclared key is far more often a
  -- misspelling or a stale name than a message from the future.
  assertEqual(settings.extra, "kept")
  assert(string.find(table.concat(warnings, "\n"),
    "extra is not a setting of this component", 1, true),
    "an undeclared key was accepted in silence")
  assertEqual(#warnings, 3, "the warning count changed; read them before editing")

  -- A `<key>Name` companion is the documented way a layout records a readable
  -- source name beside its identifier, so it is not undeclared.
  local _, named = componentHost.resolveSettings(
    {settings = {{key = "source", type = "string", default = ""}}},
    {source = "RxBt", sourceName = "Rx battery"})
  assertEqual(#named, 0, "a source-name companion was reported as unknown")

  -- A value outside a declared choice list is a typo, not a preference.
  local choiceModule = {settings = {
    {key = "shape", type = "string", default = "bar",
      choices = {"bar", "radial", "none"}},
  }}
  local chosen, choiceWarnings = componentHost.resolveSettings(
    choiceModule, {shape = "nonsense"})
  assertEqual(chosen.shape, "bar", "an unknown choice was not replaced")
  assertEqual(#choiceWarnings, 1)
  assert(string.find(choiceWarnings[1], "must be one of bar, radial, none", 1, true),
    choiceWarnings[1])

  local valid = componentHost.resolveSettings(choiceModule, {shape = "radial"})
  assertEqual(valid.shape, "radial", "a declared choice was rejected")

  local defaults = componentHost.resolveSettings(module, nil)
  assertEqual(defaults.title, "DEFAULT")
end

--- Every component's settings schema, read as one catalogue.
--- The vocabulary rules are properties of the set, not of any one component,
--- so they are checked over the set. Thirteen modules written to the same
--- contract by different sessions is exactly the situation in which each is
--- individually defensible and the collection is not.
--- Read from disk rather than listed here. A hand-kept list would leave a
--- newly added component uncovered by exactly the check that exists to keep
--- the catalogue consistent, and nothing would say so.
local function componentTypes()
  local listingPath = root .. "/build/component-types.txt"
  os.execute("ls '" .. root .. "/src/WIDGETS/AeroGrid/components' > '"
    .. listingPath .. "'")
  local listing = assert(io.open(listingPath, "r"))
  local types = {}
  for name in listing:lines() do
    local stem = string.match(name, "^(.+)%.lua$")
    if stem then types[#types + 1] = stem end
  end
  listing:close()
  os.remove(listingPath)
  assert(#types > 0, "no components were found to check")
  return types
end

--- Lua sources in one directory under the widget, by file name.
--- Read from the directory for the same reason `componentTypes` is: a list
--- written by hand stops covering the host the moment somebody adds a file.
local function sourceFiles(directory)
  local listingPath = root .. "/build/source-listing.txt"
  os.execute("ls '" .. root .. "/src/WIDGETS/AeroGrid/" .. directory
    .. "' > '" .. listingPath .. "'")
  local listing = assert(io.open(listingPath, "r"))
  local names = {}
  for name in listing:lines() do
    if string.match(name, "%.lua$") then names[#names + 1] = name end
  end
  listing:close()
  os.remove(listingPath)
  assert(#names > 0, "no sources were found in " .. directory)
  return names
end

--- Names that were retired because another key already asked their question.
--- Listed by what replaced them, so a reintroduction says where to go.
local RETIRED_KEYS = {
  display = "reading, or readout where it names a text form",
  primary = "reading",
  min = "a range named for what it bounds",
  max = "a range named for what it bounds",
  armSource = "the layout's session block",
  title = "label",
}

--- What each component's thresholds are measured in, where the answer is
--- fixed by the quantity rather than by configuration.
local FIXED_THRESHOLD_UNITS = {
  ["cell-battery"] = "volts per cell",
  ["tx-battery"] = "volts",
  ["flight-timer"] = "seconds",
  ["navigation"] = "metres",
}

local function settingsCatalog()
  local catalog = {}
  for _, kind in ipairs(componentTypes()) do
    catalog[kind] = loadModule("components/" .. kind .. ".lua").settings or {}
  end
  return catalog
end

local function testSettingsVocabulary()
  local catalog = settingsCatalog()
  local kinds = componentTypes()
  -- Twelve components ship, two of them diagnostic. `heartbeat` and
  -- `placeholder` were built to prove
  -- the host contract and are fixtures under `tests/fixtures/components`, so
  -- they are not read here: the vocabulary rules below are about what a
  -- person configures on a radio.
  assertEqual(#kinds, 12, "the catalogue changed size; the spec names twelve")

  for kind, settings in pairs(catalog) do
    local declared = {}
    for _, setting in ipairs(settings) do
      declared[setting.key] = setting

      local replacement = RETIRED_KEYS[setting.key]
      assert(not replacement, kind .. " declares the retired key "
        .. tostring(setting.key) .. "; use " .. tostring(replacement))

      -- A choice list that omits its own default rejects the value the host
      -- falls back to, so the setting has no reachable resting value.
      if setting.choices then
        local found = false
        for _, choice in ipairs(setting.choices) do
          if choice == setting.default then found = true end
        end
        assert(found, kind .. "." .. setting.key
          .. " declares choices that do not include its default "
          .. tostring(setting.default))
      end
    end

    -- A setting must have more than one answer a layout could sensibly give.
    -- `direction` was added to every component with thresholds, and on five
    -- of them the physics fixes the answer: a voltage and a link only alarm
    -- downward, a distance only upward, and a timer's direction is EdgeTX's
    -- own `countdown` flag rather than anything a layout decides. A setting
    -- with one valid value is not configuration, it is noise, and it makes a
    -- reader wonder what the other value would do.
    for key, setting in pairs(declared) do
      if type(setting.choices) == "table" then
        assert(#setting.choices > 1, kind .. "." .. key
          .. " offers one choice, so it is a fact rather than a setting;"
          .. " remove it and document the behaviour")
      end
    end

    -- A threshold's unit is not recoverable from a bare number, so the label
    -- carries it. Where the unit is fixed by what the component measures the
    -- label names it; where it follows configuration, as a metric's does and
    -- as link-status's does when `reading` resolves to RSSI rather than
    -- quality, the label says that instead of naming a unit that may be wrong.
    for _, key in ipairs({"warning", "critical"}) do
      local setting = declared[key]
      if setting and setting.type == "number" then
        local unit = FIXED_THRESHOLD_UNITS[kind]
        if unit then
          assert(string.find(setting.label, unit, 1, true),
            kind .. "." .. key .. " is measured in " .. unit
            .. " and its label does not say so: " .. tostring(setting.label))
        else
          assert(string.find(setting.label, "unit", 1, true),
            kind .. "." .. key .. " has no fixed unit and its label does not"
            .. " say which one applies: " .. tostring(setting.label))
        end
      end
    end
  end

  -- `visual` selects a drawing and `presentation` selects content. A
  -- component that confuses them reads as offering a choice it does not.
  local indicator = loadModule("components/variable-indicator.lua")
  for _, name in ipairs({"none", "bar", "bipolar-bar", "radial"}) do
    assertEqual(indicator.visual(name), name,
      "variable-indicator offers a visual it does not implement")
  end

  -- A choice list naming a value the component's own normalizer drops is
  -- worse than no list: the loader accepts it and the panel ignores it.
  local trims = loadModule("components/trim-panel.lua")
  local counts = {}
  for _, setting in ipairs(catalog["trim-panel"]) do
    if setting.key == "indicators" then
      for _, choice in ipairs(setting.choices) do
        local count = trims.indicatorCount(choice)
        assert(not counts[count], "trim-panel offers " .. choice
          .. " and " .. tostring(counts[count]) .. " as the same count")
        counts[count] = choice
      end
    end
  end
  assertEqual(counts[4], "all", "trim-panel lost its four-indicator choice")

  -- The palette reserves cyan for electrical data. Both batteries measure
  -- volts; one of them used to be green.
  for _, kind in ipairs({"cell-battery", "tx-battery"}) do
    for _, setting in ipairs(catalog[kind]) do
      if setting.key == "accent" then
        assertEqual(setting.default, "cyan",
          kind .. " defaults to an accent the colour rule does not allow")
      end
    end
  end
end

--- Every YAML example in the specification is loaded, not trusted.
---
--- The specification's layout example did not load for at least two
--- milestones. It named `showLabel`, which no component declares, and a
--- numeric source identifier, which `telemetryService` rejects, and it was
--- the single most copyable thing in the document. Nothing read it, so
--- nothing could say so.
---
--- The examples are extracted from the document at test time rather than
--- copied here. A copy would be a second source of truth and would drift
--- from the document exactly as the document drifted from the code, which is
--- the failure this exists to prevent.
local function yamlBlocksIn(path)
  local handle = io.open(path, "r")
  assert(handle, "no document at " .. path)
  local text = handle:read("a")
  handle:close()
  assert(type(text) == "string" and #text > 0,
    path .. " is empty, so every example in it would pass vacuously")

  local blocks = {}
  for body in string.gmatch(text, "\n```yaml\n(.-)\n```") do
    blocks[#blocks + 1] = body
  end
  return blocks
end

local function specificationExamples()
  return yamlBlocksIn(root .. "/plans/aerogrid-spec.md")
end

--- Check one complete layout document exactly as the host would.
---@param body string
---@param label string
local function checkLayoutExample(body, label)
  local document = yaml.parse(body)
  assert(type(document) == "table", label .. " did not parse")

  local normalized, errors = layout.validate(document, grid)
  assert(normalized, label .. " was rejected: "
    .. table.concat(errors or {}, "; "))
  assertEqual(#errors, 0, label .. ": " .. table.concat(errors, "; "))

  -- An example that declares nothing would satisfy every assertion below by
  -- having nothing to satisfy them with.
  assert(#normalized.components > 0, label .. " declares no components")

  for _, placement in ipairs(normalized.components) do
    local where = label .. ": " .. placement.id
    local chunk = loadfile(root .. "/src/WIDGETS/AeroGrid/components/"
      .. placement.type .. ".lua")
    assert(chunk, where .. ": no component file for type " .. placement.type)
    local module = chunk()

    local valid, moduleError = componentHost.validateModule(module, placement.type)
    assert(valid, where .. ": " .. tostring(moduleError))
    assert(componentHost.supportsSpan(module, placement.colSpan, placement.rowSpan),
      where .. ": " .. placement.type .. " does not support "
      .. componentHost.spanName(placement.colSpan, placement.rowSpan))

    -- Undeclared keys and values outside a declared choice list are both
    -- reported here, which is what the example used to trip over.
    local _, warnings = componentHost.resolveSettings(module, placement.config)
    assertEqual(#warnings, 0, where .. ": " .. table.concat(warnings, "; "))
  end

  return normalized
end

--- Check a theme block, which is a fragment of a layout rather than one.
---@param body string
---@param label string
local function checkThemeExample(body, label)
  local fragment = yaml.parse(body)
  assert(type(fragment) == "table" and type(fragment.theme) == "table",
    label .. " did not parse as a theme block")

  -- Validated in place, as a layout carrying it would be, then built. The
  -- validator accepts any overrides table; only the build rejects a key that
  -- is not customizable or a value that is not a colour, so a theme example
  -- checked only by the validator would prove almost nothing.
  local document = {
    version = 1,
    grid = {columns = 4, rows = 4},
    components = {},
    theme = fragment.theme,
  }
  local normalized, errors = layout.validate(document, grid)
  assert(normalized, label .. " was rejected: "
    .. table.concat(errors or {}, "; "))
  assertEqual(#errors, 0, label .. ": " .. table.concat(errors, "; "))

  local resolved = theme.build(normalized.theme.mode, normalized.theme.overrides, {})
  assertEqual(#resolved.warnings, 0,
    label .. ": " .. table.concat(resolved.warnings, "; "))
  assertEqual(resolved.mode, fragment.theme.mode,
    label .. " asked for a theme mode the host does not have")

  return resolved
end

--- Check a single component entry, which is a layout's component sequence cut
--- down to one. Spliced into the smallest document that can carry it, so the
--- same validation runs: a component example naming a setting that does not
--- exist is exactly as wrong as a whole layout doing it, and there is no
--- reason for the document to be able to carry one unchecked.
---@param body string
---@param label string
local function checkComponentExample(body, label)
  local indented = string.gsub("\n" .. body, "\n", "\n  ")
  local document = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:"
    .. indented .. "\n"
  return checkLayoutExample(document, label)
end

local function testSpecificationExamplesLoad()
  local blocks = specificationExamples()
  assert(#blocks > 0, "no YAML examples were found in the specification")

  local layouts, themes, entries = 0, 0, 0
  for index, body in ipairs(blocks) do
    local label = "specification example " .. index
    assert(#body > 0, label .. " is empty")

    if string.match(body, "^version:") then
      layouts = layouts + 1
      local normalized = checkLayoutExample(body, label)
      -- The example carries a session block, and a block that stopped
      -- reaching the host would still parse.
      if string.match(body, "\nsession:") then
        assert(normalized.session and normalized.session.armSource,
          label .. ": a session block did not survive validation")
      end
    elseif string.match(body, "^theme:") then
      themes = themes + 1
      checkThemeExample(body, label)
    elseif string.match(body, "^%- id:") then
      entries = entries + 1
      checkComponentExample(body, label)
    else
      -- An unclassified example is one nothing checks, which is the state
      -- this test exists to end. Failing is the point: add a branch here.
      -- It has already caught one: a bare component entry added to the
      -- source-settings section, which no branch covered until one did.
      error(label .. " is neither a layout nor a theme block, so nothing"
        .. " checks it. Its first line is: "
        .. tostring(string.match(body, "^([^\n]*)")))
    end
  end

  -- Both kinds have to still be present. Deleting the layout example from
  -- the document would otherwise leave this test passing over whatever
  -- remained.
  assert(layouts > 0, "the specification carries no complete layout example")
  assert(themes > 0, "the specification carries no theme example")
end

--- A threshold whose unit is decided at runtime is refused at load.
---
--- `link-status` leads with RSSI, in dBm and usually negative, or with link
--- quality, in percent and always positive. Under `reading: auto` the choice
--- is made by whichever source the protocol publishes, so `warning: 50` is a
--- perfectly plausible number in both units and means a different thing in
--- each. Nothing downstream can catch it: the panel alarms at the wrong
--- moment rather than failing.
---
--- The shipped dashboard had exactly this. Its thresholds were percentages
--- under `reading: auto`, and `auto` falls back to RSSI when no quality
--- sensor exists, where every reading is below 30, so that panel would have
--- sat permanently critical on any protocol without one.
local function testLinkThresholdsNeedAStatedReading()
  local module = loadModule("components/link-status.lua")

  local function warningsFor(config)
    local _, warnings = componentHost.resolveSettings(module, config)
    return warnings
  end

  -- The rejection, which is the behaviour being added.
  local refused = warningsFor({reading = "auto", warning = 50, critical = 30})
  assertEqual(#refused, 2,
    "both thresholds must be refused, not just the first")
  assert(string.find(refused[1], "reading: auto", 1, true), refused[1])
  assert(string.find(refused[1], "dBm or percent", 1, true), refused[1])
  assert(string.find(refused[1], "Set reading to rssi or quality", 1, true),
    "the message must say what to do about it: " .. refused[1])

  -- `auto` is only refused when a threshold depends on it. A panel that
  -- states no threshold has nothing whose unit could be ambiguous, and
  -- refusing that would make `auto` unusable rather than unambiguous.
  assertEqual(#warningsFor({reading = "auto"}), 0,
    "auto was refused on a panel that states no threshold")

  -- And a stated reading carries its thresholds, in either unit.
  assertEqual(#warningsFor({reading = "quality", warning = 50, critical = 30}), 0,
    "a percentage threshold under quality was refused")
  assertEqual(#warningsFor({reading = "rssi", warning = -90, critical = -100}), 0,
    "a dBm threshold under rssi was refused")

  -- The default is `auto`, so a layout that states thresholds and no reading
  -- is the same mistake written more quietly.
  assertEqual(#warningsFor({warning = 50}), 1,
    "a threshold with no reading stated was accepted")
end

--- Every shipped component has documentation, and its examples load.
---
--- Two failures to prevent, and the second is the one that rots quietly. An
--- example that stops loading is caught the same way the specification's are,
--- by running it rather than reading it. A component with no documentation
--- file at all is caught by reading the component directory rather than a
--- list, because a list is what lets the eleventh component be quietly
--- undocumented: nothing would be wrong, there would simply be less.
--- Components reviewed and documented so far, and the ones still owed.
---
--- The review is one component per pull request, so this starts as debt and
--- is meant to empty. It is an explicit list rather than a silent gap for one
--- reason: a component that is not on it and has no page fails immediately,
--- so a component added to the catalogue tomorrow cannot be quietly
--- undocumented. Removing the last name here should delete this table too.
local UNDOCUMENTED = {
  ["cell-battery"] = true,
  ["flight-timer"] = true,
  ["host-diagnostics"] = true,
  ["link-status"] = true,
  ["metric"] = true,
  ["model-identity"] = true,
  ["navigation"] = true,
  ["service-probe"] = true,
  ["trim-panel"] = true,
  ["variable-indicator"] = true,
}

local function testComponentDocumentationLoads()
  local kinds = componentTypes()
  assert(#kinds > 0, "no components were found to document")

  local known = {}
  for _, kind in ipairs(kinds) do known[kind] = true end
  -- A name here that is not a component is a rename nobody finished, and it
  -- would excuse a real component from ever being documented.
  for kind in pairs(UNDOCUMENTED) do
    assert(known[kind], kind .. " is listed as undocumented but is not a"
      .. " component; the list is excusing something that does not exist")
  end

  local documented = 0
  for _, kind in ipairs(kinds) do
    local path = root .. "/docs/components/" .. kind .. ".md"
    local handle = io.open(path, "r")
    if not handle then
      assert(UNDOCUMENTED[kind], kind .. " ships with no documentation at "
        .. path .. ", and is not on the list of components still owed one")
    end
    if handle then
      handle:close()
      assert(not UNDOCUMENTED[kind], kind .. " is documented but is still"
        .. " listed as owing documentation; remove it from UNDOCUMENTED")
      documented = documented + 1

    local blocks = yamlBlocksIn(path)
    assert(#blocks > 0, kind .. " is documented with no example at all, so"
      .. " nothing in its documentation can be checked by running it")

    for index, body in ipairs(blocks) do
      local label = kind .. " example " .. index
      assert(#body > 0, label .. " is empty")

      if string.match(body, "^version:") then
        checkLayoutExample(body, label)
      elseif string.match(body, "^%- id:") then
        -- Checked before the example is validated, so the failure names the
        -- real problem rather than whichever setting the other component
        -- happens not to declare. A page about one component whose example
        -- places a different one is worse than no example: it is confidently
        -- wrong, and it is exactly what copying the previous page produces.
        local declared = string.match(body, "\n%s*type:%s*([%w%-]+)")
        assertEqual(declared, kind,
          label .. " places a " .. tostring(declared)
          .. " on the page documenting " .. kind)
        checkComponentExample(body, label)
      else
        error(label .. " is neither a layout nor a component entry, so"
          .. " nothing checks it. Its first line is: "
          .. tostring(string.match(body, "^([^\n]*)")))
        end
      end
    end
  end

  -- The count is pinned so that a page disappearing is a failure rather than
  -- a quieter suite.
  local owed = 0
  for _ in pairs(UNDOCUMENTED) do owed = owed + 1 end
  assertEqual(documented + owed, #kinds,
    "every component is either documented or listed as owing a page")
  assertEqual(documented, 2,
    "the number of documented components changed; update this count as the"
      .. " review works through the catalogue")
end

--- The reading is sized from the model's own widest mode name, and fits.
---
--- `flight-mode` used to offer three forms of ten, six and four characters.
--- They were never renderings: `fitReading` chose a font from whichever form
--- fitted, and the component then drew the **whole** name at that font, so a
--- ten-character name at `2 x 2` needed about 400 pixels of a 226 pixel panel
--- and lost nearly half of itself over the edge. Nothing noticed, because
--- every test used `Sport`, which fits at every span under either behaviour.
--- That is the shape of assertion this replaces: one that was true before the
--- fix as well.
---
--- Shortening the name is not available. A truncated mode name is a different
--- name, not an abbreviation of one, so the font steps down instead.
local function testFlightModeSizing()
  local flightMode = loadModule("components/flight-mode.lua")
  local resolved = theme.build("modern")

  local function modelWith(names)
    return modelService.new(services.environment({
      getFlightMode = function(index)
        if type(index) ~= "number" or index < 0 or index >= 9 then index = 0 end
        return index, names[index] or ""
      end,
    }), services)
  end

  -- Read from every mode, not just the active one. A service that answered
  -- the active mode's name nine times would size from `Norm` and clip
  -- `LongRange7`, which is exactly what it must not do.
  assertEqual(modelWith({[0] = "Norm", [4] = "LongRange7"})
    :widestFlightModeName(), "LongRange7")
  -- An unnamed mode is drawn as FM<n>, so that is its width, not zero. Named
  -- one mode with something shorter, so the widest name in the model is an
  -- unnamed one: measuring those as empty would answer "Up" instead.
  assertEqual(modelWith({[0] = "Up"}):widestFlightModeName(), "FM1")
  assertEqual(modelWith({}):widestFlightModeName(), "FM0")
  -- Without the firmware call there is nothing to read and a sane default.
  assertEqual(modelService.new(services.environment({}), services)
    :widestFlightModeName(), "FM0")

  -- Every declared span must fit the widest name the model can show. This is
  -- the assertion the old behaviour fails: four of the eight spans clipped.
  local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
  local cellWidth = math.floor((WIDTH - GUTTER * (CELLS - 1)) / CELLS)
  local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)

  for _, widest in ipairs({"LongRange7", "Norm"}) do
    local checked = 0
    for _, span in ipairs(flightMode.supportedSpans) do
      local cols, rows = string.match(span, "(%d)x(%d)")
      cols, rows = tonumber(cols), tonumber(rows)
      local rect = {
        x = 0, y = 0,
        w = cellWidth * cols + GUTTER * (cols - 1),
        h = cellHeight * rows + GUTTER * (rows - 1),
      }
      local fonts = theme.typography(cols, rows)
      local layout = flightMode.presentationFor(cols, rows)
      local area = flightMode.regionsFor(
        resolved, theme, rect, layout, fonts, widest)

      assert(theme.textWidth(area.name, widest) <= area.content,
        widest .. " at " .. span .. " needs "
          .. theme.textWidth(area.name, widest) .. " of " .. area.content
          .. " pixels, so the name is drawn past the panel edge")
      checked = checked + 1
    end
    assertEqual(checked, 8, "not every declared span was measured")
  end

  -- And the point of reading the model rather than assuming ten characters:
  -- a model with short names keeps the larger reading.
  local function fontAt(widest)
    local rect = {x = 0, y = 0,
      w = cellWidth * 2 + GUTTER, h = cellHeight * 2 + GUTTER}
    local fonts = theme.typography(2, 2)
    return flightMode.regionsFor(resolved, theme, rect,
      flightMode.presentationFor(2, 2), fonts, widest).name
  end
  assert(theme.fontHeight(fontAt("Norm")) > theme.fontHeight(fontAt("LongRange7")),
    "a model with short mode names gained nothing from reading its names")
end

--- A mode number needs a row, and no single-row span has one.
local function testFlightModeIndexNeedsARow()
  local flightMode = loadModule("components/flight-mode.lua")

  -- The refusal, which is the behaviour being added. Accepting it and then
  -- ignoring it is the worst of the three options, because a layout author
  -- reads the setting back and believes it.
  local refused = flightMode.validateSettings({showIndex = true},
    {colSpan = 4, rowSpan = 1}, {showIndex = true})
  assertEqual(#refused, 1,
    "showIndex on a single row was accepted; no single row has space beneath"
      .. " the reading at any width")
  assert(string.find(refused[1], "two rows tall", 1, true), refused[1])
  assert(string.find(refused[1], "drop showIndex", 1, true),
    "the message must say what to do about it: " .. refused[1])

  -- Two rows is where it works, and a panel that never asked has nothing to
  -- be told about.
  assertEqual(#flightMode.validateSettings({showIndex = true},
    {colSpan = 1, rowSpan = 2}, {showIndex = true}), 0,
    "showIndex was refused on two rows")
  assertEqual(#flightMode.validateSettings({}, {colSpan = 1, rowSpan = 1}, {}),
    0, "a panel that never asked for the mode number was told off anyway")
  -- Without a span nothing can be said, and saying nothing is correct.
  assertEqual(#flightMode.validateSettings({showIndex = true}, nil,
    {showIndex = true}), 0)

  -- The host fills defaults in before this runs, so `settings` cannot say
  -- whether the layout asked. A setting that arrives only as a default is
  -- the panel shedding a row, which is normal and silent.
  assertEqual(#flightMode.validateSettings({showIndex = true},
    {colSpan = 4, rowSpan = 1}, {}), 0,
    "a default the layout never stated was reported as an ignored request")

  -- And the span has to reach it through the host, or the rule above is
  -- correct and never consulted.
  local _, warnings = componentHost.resolveSettings(
    flightMode, {showIndex = true}, {colSpan = 4, rowSpan = 1})
  assertEqual(#warnings, 1,
    "the placement's span did not reach validateSettings, so a rule that"
      .. " depends on it can never fire")
  assert(string.find(warnings[1], "two rows tall", 1, true), warnings[1])

  local _, allowed = componentHost.resolveSettings(
    flightMode, {showIndex = true}, {colSpan = 1, rowSpan = 2})
  assertEqual(#allowed, 0)
end

--- A setting that cannot apply at this span says so, and only when asked for.
---
--- No single-row span grants a supporting row: a 65 pixel panel has no space
--- beneath the reading whatever its width. Five settings across four
--- components drive such a row, and all five were accepted and silently
--- ignored there, which is worse than either refusing or working -- a layout
--- author reads the setting back and believes it.
---
--- The second half is the part that needed care. `showPack` and `showCount`
--- default to **true**, so a panel that never mentioned them arrives with
--- them set, and complaining then would report the panel's own shedding as
--- an ignored request and fail every existing layout. The host therefore
--- hands `validateSettings` the layout's own config beside the resolved
--- settings, and only a stated value is refused.
local function testInertSettingsAreRefused()
  local single = {colSpan = 4, rowSpan = 1}
  local tall = {colSpan = 1, rowSpan = 2}

  local cases = {
    {"tx-battery", "showPercent"},
    {"variable-indicator", "showName"},
    {"cell-battery", "showPack"},
    {"cell-battery", "showCount"},
    {"model-identity", "showLabels"},
    {"flight-mode", "showIndex"},
  }

  for _, case in ipairs(cases) do
    local kind, key = case[1], case[2]
    local module = loadModule("components/" .. kind .. ".lua")
    assert(type(module.validateSettings) == "function",
      kind .. " states no rule for " .. key .. " at a span that cannot"
        .. " show it")

    local stated = {[key] = true}

    -- Stated on a single row: refused, by name, with what to do about it.
    local refused = module.validateSettings(stated, single, stated)
    assertEqual(#refused, 1,
      kind .. "." .. key .. " was accepted on a single row, where no panel"
        .. " has space beneath the reading at any width")
    assert(string.find(refused[1], key, 1, true), refused[1])
    assert(string.find(refused[1], "two rows tall", 1, true), refused[1])
    assert(string.find(refused[1], "drop " .. key, 1, true),
      "the message must say what to do about it: " .. refused[1])

    -- Stated on two rows: allowed, because there it works.
    assertEqual(#module.validateSettings(stated, tall, stated), 0,
      kind .. "." .. key .. " was refused on a panel that can show it")

    -- Arrived as a default the layout never mentioned: silent, because that
    -- is the panel shedding a row rather than a request being ignored.
    assertEqual(#module.validateSettings(stated, single, {}), 0,
      kind .. "." .. key .. " reported a default the layout never stated as"
        .. " an ignored request, which would fail every existing layout")

    -- Without a span nothing can be said, and saying nothing is correct.
    assertEqual(#module.validateSettings(stated, nil, stated), 0)
  end

  -- The host is what carries the config through, so the rule above is
  -- correct and never consulted if it does not.
  local module = loadModule("components/tx-battery.lua")
  local _, warnings = componentHost.resolveSettings(
    module, {showPercent = true}, single)
  assertEqual(#warnings, 1,
    "the layout's own config did not reach validateSettings, so a rule that"
      .. " depends on what was stated can never fire")

  -- And a layout that states nothing gets the defaults without being told
  -- off for them, through the host as well as directly.
  local _, quiet = componentHost.resolveSettings(
    loadModule("components/cell-battery.lua"), {source = "Cels"}, single)
  assertEqual(#quiet, 0,
    "a layout that stated neither showPack nor showCount was reported for"
      .. " both: " .. table.concat(quiet, "; "))
end

--- Nothing in the host reaches an LVGL object by name.
---
--- An object handed back by `lvgl.*` is userdata on a radio, not a table:
--- `LvglWidgetObjectBase::getRef` calls `lua_newuserdata` for one pointer and
--- attaches `lvgl_base_mt` or `lvgl_mt`, neither of which declares
--- `__newindex`. So `label.headingText = text` raises there, and
--- `label.headingText` reads as nil. A stand-in that is a plain Lua table
--- does both silently and correctly-looking, which is how a field written
--- onto every panel's heading label passed this suite and then broke every
--- panel on the first radio that ran it.
---
--- The fixture now refuses the write, which catches any path a test walks.
--- This catches the paths no test walks, and catches reads as well, because
--- the read was the quieter half of the same defect: `placeHeader` asked the
--- label what its heading was, got nil on the radio, and therefore never
--- refitted on a reflow while looking entirely healthy here.
---
--- The rule is that the only things an object understands are its methods.
--- Every object name is collected from where it is constructed, and then any
--- use of it with a dot rather than a colon is a violation.
local function testLvglObjectsAreNeverReachedByName()
  -- Constructors whose result is an object rather than one of the small
  -- tables this host builds around several of them. `panel`, `bar`, `radial`,
  -- `compass` and `accentArc` return plain Lua tables and are deliberately
  -- absent: those are ours, and holding fields is what they are for. The
  -- object inside one, such as `band.arc`, is reached through the helper that
  -- owns it rather than by name.
  local OBJECT_MAKERS = {"label", "value", "badge", "image", "marker"}
  local LVGL_MAKERS = {"box", "rectangle", "label", "arc", "image"}

  local primitives = loadModule("lib/primitives.lua")
  for _, name in ipairs(OBJECT_MAKERS) do
    assert(type(primitives[name]) == "function",
      "primitives." .. name .. " is not a function, so this test is"
        .. " guarding a constructor that no longer exists under that name")
  end

  -- Every production source, read from the directories rather than from a
  -- list, so a file written tomorrow is held to this from the moment it
  -- exists. That is the lesson from the documentation check: a rule that
  -- names its subjects is a rule the next subject escapes.
  local sources = {"main.lua"}
  for _, name in ipairs(sourceFiles("lib")) do
    sources[#sources + 1] = "lib/" .. name
  end
  for _, kind in ipairs(componentTypes()) do
    sources[#sources + 1] = "components/" .. kind .. ".lua"
  end

  local checked, names = 0, 0
  for _, relative in ipairs(sources) do
    local handle = assert(io.open(
      root .. "/src/WIDGETS/AeroGrid/" .. relative, "r"))
    local source = handle:read("a")
    handle:close()
    checked = checked + 1

    -- Comments are stripped before anything is matched. They are where the
    -- firmware citations live, and a citation naming `lv_arc.c` reads as the
    -- object `arc` followed by a field `c` to any pattern simple enough to
    -- be worth writing. A rule that fires on a comment is a rule people
    -- learn to work around.
    source = string.gsub(source, "%-%-[^\n]*", "")

    local held = {}
    local function hold(name) if name then held[name] = true end end

    for _, maker in ipairs(OBJECT_MAKERS) do
      for name in string.gmatch(source,
          "([%w_]+%.?[%w_]*)%s*=%s*[%w_]*%.?primitives%." .. maker .. "%(") do
        hold(name)
      end
      for name in string.gmatch(source,
          "local%s+([%w_]+)%s*=%s*primitives%." .. maker .. "%(") do
        hold(name)
      end
    end
    for _, maker in ipairs(LVGL_MAKERS) do
      for name in string.gmatch(source,
          "([%w_]+%.?[%w_]*)%s*=%s*lvgl%." .. maker .. "%(") do
        hold(name)
      end
    end
    -- `header` hands back a label and a badge together.
    for first, second in string.gmatch(source,
        "([%w_]+%.?[%w_]*)%s*,%s*([%w_]+%.?[%w_]*)%s*=%s*"
          .. "[%w_]*%.?primitives%.header%(") do
      hold(first)
      hold(second)
    end

    for name in pairs(held) do
      -- `local` leaves the bare name; a field of `context` keeps its prefix.
      -- Either way the object is that name, and a dot after it is a field.
      names = names + 1
      -- A frontier, because `ring` is a suffix of `string` and the first
      -- version of this reported `primitives` for reaching `ring.upper`.
      local pattern = "%f[%w_]" .. string.gsub(name, "%.", "%%.")
        .. "%.([%w_]+)"
      for field in string.gmatch(source, pattern) do
        assert(false, relative .. " reaches " .. name .. "." .. field
          .. ", but an LVGL object is userdata on a radio and has no fields."
          .. " Writing one raises and reading one is always nil."
          .. " Keep host bookkeeping beside the object, not on it.")
      end
    end
  end

  assert(checked >= 24, "only " .. checked .. " sources were read")
  assert(names >= 20,
    "only " .. names .. " object names were found, so this test is looking"
      .. " at far less of the host than it should be")
end

--- No component writes its own heading text into the label.
---
--- This is the fourth defect of the shape "a string is drawn without being
--- measured", after a flight mode's name, the supporting rows, and a
--- navigation origin. The reading goes through the ladder and supporting rows
--- through `fitLabel`; the heading went through neither, straight into a
--- label whose long mode LVGL defaults to wrapping.
---
--- The host writes the heading, in `primitives.header`, so eleven of the
--- twelve components never touch it and cannot get it wrong. Two rewrite
--- theirs at runtime -- a timer taking its name from the model, a variable
--- indicator from the radio -- and they go through `primitives.setHeading`.
--- This is what stops a thirteenth writing it directly.
---
--- It is honestly weaker than the render declaration in #24, which made its
--- mistake unrepresentable rather than merely detectable. The difference is
--- that the host owns the redraw comparison and can derive it, but it does
--- not own paint: a component holds its own LVGL objects and calls `set` on
--- them. Making this unrepresentable would mean the host owning drawing as
--- well as deciding, which is a larger change than this defect justifies.
--- Detectable is what is available, so detectable is what this does.
local function testHeadingIsNeverWrittenDirectly()
  local kinds = componentTypes()
  local checked = 0

  for _, kind in ipairs(kinds) do
    local path = root .. "/src/WIDGETS/AeroGrid/components/" .. kind .. ".lua"
    local handle = assert(io.open(path, "r"))
    local source = handle:read("a")
    handle:close()
    checked = checked + 1

    -- `context.label` and `context.title` are the header label, whichever a
    -- component calls it. Anything else is a row the component owns.
    for _, name in ipairs({"label", "title"}) do
      -- Every write to the header label, not just the first: a component may
      -- set its colour in one place and its text in another.
      for changes in string.gmatch(source,
          "context%." .. name .. ":set%((%b{})%)") do
        -- `text` as a key, rather than anywhere in the line. The first
        -- version of this searched the whole call and matched `context`,
        -- which contains the word, and so failed on a component setting
        -- nothing but a colour.
        assert(not string.match(changes, "[{,%s]text%s*="),
          kind .. " writes its heading straight into the label: "
            .. changes .. " -- use primitives.setHeading, which fits it to"
            .. " the column the badge leaves")
      end
    end
  end

  assertEqual(checked, #kinds)
  assert(checked >= 11, "only " .. checked .. " components were read")
end

--- No component reaches for `lvgl.show` or `lvgl.hide` inside `update`.
---
--- A reflow is where visibility is decided, and every component used to
--- decide it by hand: eleven copies of the same show-or-hide pair across
--- seven components, and one component reconciling a bar's two objects
--- separately and forgetting its marker. `primitives.reconcile` and
--- `primitives.reconcileBar` are the shared versions, and this is what stops
--- a twelfth copy appearing.
---
--- Read from the component directory rather than a list, so a component
--- written tomorrow is held to it from the moment it exists.
---
--- `create` is deliberately not checked. Hiding an object at build time is a
--- statement of its initial state rather than a reconciliation, there is no
--- previous visibility to compare against, and `reconcile` there would only
--- be the same call spelled longer.
local function testReflowGoesThroughReconcile()
  local kinds = componentTypes()
  assert(#kinds > 0, "no components were found to check")

  local checked = 0
  for _, kind in ipairs(kinds) do
    local path = root .. "/src/WIDGETS/AeroGrid/components/" .. kind .. ".lua"
    local handle = assert(io.open(path, "r"))
    local source = handle:read("a")
    handle:close()

    -- The component's own `update`, which is everything from its definition
    -- to the next one at column zero.
    local body = string.match(source, "\nfunction [%w]+%.update%b()(.-)\n[%w]")
    if body then
      checked = checked + 1
      local offender = string.match(body, "(lvgl%.[sh][a-z]+)%s*%(")
      assert(not offender, kind .. " calls " .. tostring(offender)
        .. " inside update; use primitives.reconcile or reconcileBar, which"
        .. " know about the settled case and about a bar's marker")
    end
  end

  -- Every component has an `update`, so a pattern that silently matched none
  -- of them would otherwise pass this having checked nothing.
  assertEqual(checked, #kinds,
    "only " .. checked .. " of " .. #kinds .. " components' update bodies"
      .. " were found, so the rest went unchecked")
end

--- A component declares what it draws, and nothing it has shed.
---
--- The reveal work gave five components the property that a shed row is not
--- declared, so `primitives.changed` sees it reappear and nothing formats
--- text for a hidden label. The six components that work was not applied to
--- kept doing it, which is how `flight-mode` came to format a mode number
--- every frame for a panel with no room to show one.
---
--- This checks the mechanism is reached rather than the wording: a `render`
--- that writes a supporting row must consult what the panel is showing. It is
--- a weaker statement than the per-component tests elsewhere, and that is the
--- point -- it holds for a component nobody has written a test for yet.
local function testRenderConsultsWhatIsShown()
  local kinds = componentTypes()

  -- Components whose `render` declares only the dominant reading have no
  -- supporting row to gate, and are named rather than detected so that one
  -- losing its rows is a failure rather than a silent exemption.
  local NO_SUPPORTING_ROW = {
    ["host-diagnostics"] = true,
    ["service-probe"] = true,
  }

  local checked, exempt = 0, 0
  for _, kind in ipairs(kinds) do
    local path = root .. "/src/WIDGETS/AeroGrid/components/" .. kind .. ".lua"
    local handle = assert(io.open(path, "r"))
    local source = handle:read("a")
    handle:close()

    local body = string.match(source, "\nfunction [%w]+%.render%b()(.-)\n[%w]")
    if NO_SUPPORTING_ROW[kind] then
      exempt = exempt + 1
      assert(not body, kind .. " has a render function but is listed as"
        .. " having no supporting row to gate")
    else
      assert(body, kind .. " has no render function, so the redraw"
        .. " comparison cannot be derived from what it draws")
      checked = checked + 1
      assert(string.find(body, "context%.show%w+"),
        kind .. "'s render never consults what the panel is showing, so it"
          .. " formats text for rows the panel has shed")
    end
  end

  assertEqual(checked + exempt, #kinds)
  assert(checked >= 10, "only " .. checked .. " components were checked")
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
  -- Pinned as literals rather than read from theme.BADGES, because a test
  -- taking its expectations from the table it is checking would agree with any
  -- vocabulary at all, including one nobody meant to ship.
  local badges = {
    stale = "STALE", warning = "WARN", critical = "CRIT",
    unavailable = "N/A", editing = "EDIT",
  }
  for name, text in pairs(badges) do
    assertEqual(theme.state(resolved, name).badge, text,
      name .. " does not carry its own badge")
  end
  assertEqual(theme.state(resolved, "normal").badge, nil,
    "a healthy panel must not be badged")

  -- Two kinds of thing, said by two different means. The fill is a condition
  -- of the data; the outline is where the interaction is. Nothing says both.
  local focus = resolved.spacing.borderFocus
  for _, name in ipairs({"normal", "stale", "unavailable", "warning", "critical"}) do
    assertEqual(theme.state(resolved, name).borderWidth, 0,
      name .. " drew an outline, which now means focus rather than state")
  end
  for _, name in ipairs({"selected", "editing"}) do
    assertEqual(theme.state(resolved, name).borderWidth, focus,
      name .. " did not draw its outline at the focus weight")
  end

  -- An alarm tints the panel's field instead. Area is seen in peripheral
  -- vision where a line is not, which is the whole reason for the change.
  assertEqual(theme.state(resolved, "normal").surface, nil,
    "a resting panel asked for a tint")
  assertEqual(theme.state(resolved, "stale").surface, nil,
    "stale data tinted the panel; absent data is not an alarm")
  assertEqual(theme.state(resolved, "unavailable").surface, nil,
    "a missing source tinted the panel; absent data is not an alarm")
  assertEqual(theme.state(resolved, "warning").surface,
    lcd.RGB(resolved.alertRgb.warning), "a warning did not tint its panel")
  assertEqual(theme.state(resolved, "critical").surface,
    lcd.RGB(resolved.alertRgb.critical), "a critical reading did not tint its panel")
  assert(resolved.alertRgb.warning ~= resolved.alertRgb.critical,
    "warning and critical tint a panel the same colour")

  -- The whole vocabulary has to fit the column reserved for it, at every span
  -- the typography produces. This is the check the column's width is derived
  -- to satisfy, and it is driven over the table rather than a list so a badge
  -- added later is covered by it whether or not anyone remembers.
  for _, span in ipairs({{1, 1}, {2, 1}, {2, 2}, {4, 4}}) do
    local fonts = theme.typography(span[1], span[2])
    local column = theme.badgeWidth(fonts.badge)
    for name, text in pairs(theme.BADGES) do
      local needed = theme.textWidth(fonts.badge, text)
      assert(needed <= column, string.format(
        "%s does not fit the badge column at %dx%d: %s needs %d of %d",
        name, span[1], span[2], text, needed, column))
    end
  end

  -- The column is exactly what the vocabulary needs, with no slack. Asserting
  -- only that every badge fits is satisfied by any column at least that wide,
  -- including the fixed 56 this replaced, and the slack is taken out of the
  -- header label on every panel of the dashboard.
  local fonts = theme.typography(1, 1)
  local widest = 0
  for _, text in pairs(theme.BADGES) do
    local width = theme.textWidth(fonts.badge, text)
    if width > widest then widest = width end
  end
  assertEqual(theme.badgeWidth(fonts.badge), widest,
    "the badge column is not the width its vocabulary actually needs")

  -- On a panel with room, the badge gets that width whole. It used to be
  -- clamped to half the content, which protected the label by clipping the
  -- badge: CRIT and CRI are not equally alarming, while a shortened source
  -- name is merely less informative.
  local narrow = theme.frame(resolved, {x = 0, y = 0, w = 117, h = 65}, fonts)
  assertEqual(narrow.badgeWidth, widest,
    "a single-cell panel squeezed its badge instead of its label")

  -- And the label keeps what is left, which on a single cell is the whole
  -- argument for the trimmed vocabulary and the asymmetric padding. Pinned as
  -- a number: a bound like "at least four characters" is satisfied by the
  -- geometry this replaced.
  assertEqual(narrow.labelHidden, false,
    "a single-cell panel cannot show a header label beside its badge")
  assertEqual(narrow.labelWidth, 117 - resolved.spacing.paddingTight
    - resolved.spacing.paddingRight - widest - 4,
    "a single-cell panel's header label is not the width the frame leaves it")
  assert(narrow.labelWidth >= theme.textWidth(SMLSIZE, "CELLS"), string.format(
    "a single-cell panel cannot show a five-character label: %d px of a needed %d",
    narrow.labelWidth, theme.textWidth(SMLSIZE, "CELLS")))

  -- The right margin is smaller than the left padding, because the left has
  -- the accent to clear and the right has nothing. Those four pixels are a
  -- character of header on a single cell.
  assert(resolved.spacing.paddingRight < resolved.spacing.paddingTight,
    "the header pays for symmetry it does not need")
  assertEqual(narrow.content, 117 - resolved.spacing.paddingTight
    - resolved.spacing.paddingRight)

  -- A panel too narrow to carry both drops the label rather than clipping it,
  -- whether or not the menu button is the reason it ran out of room. This used
  -- to apply only to an obstructed corner, so an ordinary narrow panel clipped.
  local tiny = theme.frame(resolved, {x = 0, y = 0, w = 80, h = 65}, fonts)
  assertEqual(tiny.labelHidden, true,
    "a panel with no room for a label drew a clipped one anyway")
  assertEqual(tiny.labelWidth, 0, "a hidden label kept a width")

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

--- Every guarantee an alert tint carries must be the reason it was chosen.
---
--- The shipped palettes do not exercise all of them. Removing the elevation
--- and accent checks from the search leaves Modern's tints unchanged, because
--- another check happens to reject the same candidates first, so a test that
--- only looked at Modern would report both as covered while neither did
--- anything. That is the vacuous assertion this project has been caught by
--- before, and the answer is to test the function against palettes where each
--- check is the binding one rather than to assert harder about Modern.
---
--- Each case below is built so exactly one guarantee can reject the candidates
--- a tint would otherwise take. If that guarantee is removed, `alertSurface`
--- returns a colour violating it, and the assertion fails.
local function testAlertTintGuarantees()
  local modern = theme.modern()

  --- Tokens that are legible at rest, with one field replaced.
  local function tokensWith(overrides)
    local tokens = {}
    for key, value in pairs(modern) do tokens[key] = value end
    for key, value in pairs(overrides or {}) do tokens[key] = value end
    return tokens
  end

  --- Whatever the search returns must satisfy every guarantee, or be absent.
  local function assertCompliant(label, tokens, accent)
    local tint = theme.alertSurface(tokens, accent)
    if tint == nil then return nil end

    local checks = {
      {"separation from the resting panel", theme.contrast(tokens.surface, tint), 1.30},
      {"elevation above the screen", theme.contrast(tokens.canvas, tint), 1.30},
      {"body text", theme.contrast(tint, tokens.text), 4.5},
      {"muted text", theme.contrast(tint, tokens.textMuted), 3.0},
      {"faint text", theme.contrast(tint, tokens.textFaint), 1.8},
      {"its own accent", theme.contrast(tint, accent), 2.5},
    }
    for _, check in ipairs(checks) do
      assert(check[2] >= check[3], string.format(
        "%s: the tint leaves %s at %.2f, below %.1f",
        label, check[1], check[2], check[3]))
    end
    return tint
  end

  -- The shipped palettes, which must both produce a tint at all.
  for _, mode in ipairs({"modern", "edgetx"}) do
    local resolved = theme.build(mode)
    for _, state in ipairs({"warning", "critical"}) do
      local accent = state == "warning" and resolved.rgb.amber or resolved.rgb.critical
      assert(assertCompliant(mode .. " " .. state, resolved.rgb, accent),
        mode .. " has no " .. state .. " tint at all")
    end
  end

  -- Elevation binds: the screen sits where a tint would otherwise land, so
  -- every candidate separated from the surface is flat against the canvas
  -- until the search is pushed past it.
  assertCompliant("canvas under the tint",
    tokensWith({canvas = 0x4B4535}), modern.amber)

  -- The accent binds: an accent close to the surface it is drawn on leaves a
  -- tint mixed from it closer still, so the accent check is the only thing
  -- that can reject those candidates.
  assertCompliant("accent near the surface",
    tokensWith({amber = 0x2E3640}), 0x2E3640)
  assertCompliant("critical near the surface",
    tokensWith({critical = 0x333A44}), 0x333A44)

  -- Muted and body text are normally the easiest of the three to satisfy,
  -- because faint text is by definition the closest to the surface, so on any
  -- ordinary palette the faint check rejects a candidate before either of them
  -- is consulted and neither can be shown to do anything. A palette that
  -- inverts the ordering makes each the binding one in turn. Nothing ships
  -- looking like this; the point is that the guarantee holds when it has to.
  assertCompliant("muted text nearest the tint",
    tokensWith({textMuted = 0x555347, textFaint = 0xF0F0F0}), modern.amber)
  assertCompliant("body text nearest the tint",
    tokensWith({text = 0x4A4840, textMuted = 0xF0F0F0, textFaint = 0xE8E8E8}),
    modern.amber)

  -- Faint text binds on a light surface, which is the derived-palette case:
  -- there is no room to lighten, so the search has to darken instead.
  assertCompliant("light surface",
    tokensWith({surface = 0x364752, canvas = 0x102431, textFaint = 0x737173}),
    modern.amber)

  -- And a palette with nowhere to go returns nothing rather than something
  -- illegible, which is the branch the panel's fallback to its resting surface
  -- exists for. Body text at 4.5 against a near-white surface is what no tint
  -- can satisfy: every candidate is lighter still or too close to the surface
  -- it was mixed from.
  assertEqual(theme.alertSurface(
    tokensWith({surface = 0xF2F4F5, canvas = 0xFFFFFF}), modern.amber), nil,
    "a palette with no legible tint produced one anyway")
end

--- A hostile surface must never swallow text, accents, or state badges.
local function testDerivedThemesStayLegible()
testAlertTintGuarantees()
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
    assertEqual(unavailable.badge, "N/A", label .. ": badge text")
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
  assertEqual(metric.fraction({rangeMin = 5, rangeMax = 5}, 5), 0)
  assertEqual(metric.fraction({rangeMin = 0, rangeMax = 10}, 20), 1)
  assertEqual(metric.fraction({rangeMin = 0, rangeMax = 10}, -5), 0)
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
    -- Smaller than any span the grid can produce: a single cell is 117 by
    -- 65. Kept as a stress case, and marked so the assertions can ask it the
    -- question it can actually answer.
    {name = "tiny", w = 60, h = 40, colSpan = 1, rowSpan = 1, synthetic = true},
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
    -- The unit rides beside the reading now, so it shares the reading's rows
    -- rather than taking one below it, and the property to hold is that their
    -- baselines meet rather than that one sits under the other.
    if area.showUnit then
      assertEqual(area.unitY + heightOf(area.unitFont)
          - theme.fontBaseLine(area.unitFont),
        area.valueY + heightOf(area.primary)
          - theme.fontBaseLine(area.primary),
        case.name .. ": the unit does not sit on the reading's baseline")
      assert(area.unitY + heightOf(area.unitFont) <= case.h, case.name
        .. ": unit overflows the panel")
      assert(heightOf(area.unitFont) < heightOf(area.primary), case.name
        .. ": the unit is drawn at or above the reading's own size")
    end

    if area.showVisual then
      local unitBottom = valueBottom
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
testSettingsVocabulary()
testInertSettingsAreRefused()
testHeadingIsNeverWrittenDirectly()
testLvglObjectsAreNeverReachedByName()
testReflowGoesThroughReconcile()
testRenderConsultsWhatIsShown()
testLinkThresholdsNeedAStatedReading()
testSpecificationExamplesLoad()
testComponentDocumentationLoads()
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

--- A text sensor is a reading whose value is a string.
---
--- Crossfire and ELRS publish the aircraft's flight mode this way, as `FM`
--- with `UNIT_TEXT` (`telemetry/crossfire.cpp`), and `getValue` pushes the
--- stored string rather than a number for it: `case UNIT_TEXT:
--- lua_pushstring(L, telemetryItems[...].text)`
--- (`radio/src/lua/api_general.cpp`). The service has mapped unit 42 to a
--- `text` kind since it was written and **nothing had ever exercised it**,
--- because no fixture carried a text sensor. That is covered here whether or
--- not a component ever reads one.
---
--- The absent case is checked alongside, because it is the common one: FrSky
--- S.Port publishes no flight mode sensor at all, so a layout naming `FM` on
--- a FrSky link gets nothing and must say so rather than reading zero.
local function testTelemetryTextSensor()
  local harness = telemetryHarness()
  -- firmware: `STR_SENSOR_FLIGHT_MODE` is "FM" (`telemetry/sensor_names.h`)
  -- and `UNIT_TEXT` is 42 in `enum TelemetryUnit`
  -- (`radio/src/dataconstants.h`).
  harness.fields.FM = {id = 145, name = "FM", unit = 42}
  harness.values[145] = "ANGLE"

  local service = harness.service
  local mode = service:subscribe("FM")
  local absent = service:subscribe("Fmod")

  service:update(0)

  -- The shape, which is what nothing had checked: a string in `raw`, no
  -- numeric value, and a kind that says which to read.
  assertEqual(mode.kind, "text")
  assertEqual(mode.raw, "ANGLE")
  assertEqual(mode.value, nil,
    "a text sensor must offer no numeric value; a component reading one"
      .. " would get a number for a string and format it")
  assertEqual(mode.available, true)
  assertEqual(mode.state, "normal")

  -- A text sensor is telemetry, so it is subject to the link rules like any
  -- other reading rather than being treated as always-present.
  assertEqual(mode.telemetry, true)

  -- The common case on FrSky, which publishes no flight mode sensor at all.
  assertEqual(absent.known, false)
  assertEqual(absent.state, "unavailable")
  assertEqual(absent.raw, nil)
  assertEqual(absent.value, nil)

  -- A new string is a new reading, and the revision has to move or a panel
  -- comparing declarations would never repaint.
  local before = mode.revision
  harness.values[145] = "ACRO"
  service:update(1)
  assertEqual(mode.raw, "ACRO")
  assert(mode.revision > before,
    "a changed string did not count as a new reading")

  -- And the same string twice is not.
  local settled = mode.revision
  service:update(2)
  assertEqual(mode.revision, settled,
    "an unchanged string counted as a new reading")

  -- A dropped link keeps the last string and marks it stale, exactly as a
  -- numeric reading is kept rather than replaced with nothing.
  harness.rssi = 0
  harness.values[145] = nil
  service:update(3)
  assertEqual(mode.raw, "ACRO", "a dropped link discarded the last mode")
  assertEqual(mode.state, "stale")
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

--- Width is asked of the radio, and the estimate is only a fallback.
---
--- The two differ enough to tell apart, which is the point: `theme.textWidth`
--- charges every character 0.58 of a line height, so a decimal point costs
--- what a digit does, and against the real advances of the font EdgeTX ships
--- `7.9` comes out 68% too wide. That generosity is correct when deciding
--- whether something fits and wrong when deciding where something starts.
---
--- The mock's `lcd.sizeText` is a proportional model rather than the radio's
--- own numbers -- it cannot be more, since every font the dashboard draws
--- with is LZ4-compressed in the tree. What it reproduces faithfully is the
--- shape: a narrow `.`, a wide `m`, and a total that depends on which
--- characters a string holds rather than only how many.
local function testWidthIsMeasuredNotEstimated()
  -- The estimate is length times height times a constant, so two strings of
  -- the same length measure the same however different they look.
  assertEqual(theme.textWidth(MIDSIZE, "8.8"), theme.textWidth(MIDSIZE, "888"))

  -- Measurement does not, and that difference is what a test can see.
  assert(theme.measureText(MIDSIZE, "8.8")
      < theme.measureText(MIDSIZE, "888"),
    "a decimal point measures as wide as a digit, so this is the estimate"
      .. " wearing a different name")

  -- The estimate is generous rather than merely different, in the direction
  -- the specification asks for: it never reports less than the truth for the
  -- readings this dashboard prints.
  local checked = 0
  for _, sample in ipairs({"7.9", "10.0", "88.8", "-100", "888.88", "1:04:12"}) do
    for _, font in ipairs(theme.READING_FONTS) do
      checked = checked + 1
      assert(theme.textWidth(font, sample) >= theme.measureText(font, sample),
        "the estimate under-reports " .. sample .. " at "
          .. edgetx.fontName(font) .. ", which would clip rather than shrink")
    end
  end
  assert(checked >= 24, "only " .. checked .. " pairs were compared")

  -- The gap between them is the user's complaint, stated as a number. At the
  -- largest reading a `7.9` was placed tens of pixels further right than the
  -- radio draws it.
  local slack = theme.textWidth(XXLSIZE, "7.9") - theme.measureText(XXLSIZE, "7.9")
  assert(slack > 20, "the estimate is only " .. slack
    .. " pixels generous at XXLSIZE, so this change buys nothing and the"
    .. " gap the user reported has another cause")

  -- Empty and absent text measure zero rather than raising, because a panel
  -- with no reading yet still places its unit.
  assertEqual(theme.measureText(MIDSIZE, ""), 0)
  assertEqual(theme.measureText(MIDSIZE, nil), 0)

  -- Without `lcd.sizeText` the estimate answers, because a host that cannot
  -- measure still has to produce a number rather than nil.
  local realLcd = lcd
  lcd = {RGB = realLcd.RGB, getColor = realLcd.getColor}
  local fallback = theme.measureText(MIDSIZE, "8.8")
  lcd = realLcd
  assertEqual(fallback, theme.textWidth(MIDSIZE, "8.8"),
    "a host without lcd.sizeText did not fall back to the estimate")

  -- And a host whose `sizeText` answers something unusable is the same case.
  local broken = {RGB = realLcd.RGB, getColor = realLcd.getColor,
    sizeText = function() return nil end}
  lcd = broken
  local refused = theme.measureText(MIDSIZE, "8.8")
  lcd = realLcd
  assertEqual(refused, theme.textWidth(MIDSIZE, "8.8"),
    "a sizeText that answered nil was believed")
end

--- `fitReading`'s verdict is accurate, in both directions.
---
--- The function returns the smallest font on the ladder when nothing fits,
--- rather than failing, which is the only thing it can do -- but a caller
--- that reads only the font cannot tell that case from a comfortable fit.
--- `tx-battery` could not, and took width for a battery the reading needed.
---
--- So the verdict has to be right, and "right" is two claims: true only when
--- the returned form genuinely fits at the returned font, and false only when
--- no form fits at any font the room allows. Asserting one direction would
--- pass a function that always answered true.
local function testFitReadingReportsWhetherItFits()
  local ROOM = 200

  -- Comfortable: a short reading in a wide column.
  local font, index, fits = theme.fitReading({"88.8"}, 400, ROOM)
  assertEqual(fits, true)
  assertEqual(index, 1)
  assert(theme.textWidth(font, "88.8") <= 400,
    "the verdict was true for a form that does not fit")

  -- Impossible: the widest reading this dashboard prints, in a column
  -- narrower than it needs at the smallest font on the ladder.
  local smallest = theme.READING_FONTS[#theme.READING_FONTS]
  local tooNarrow = theme.textWidth(smallest, "888.88km") - 1
  local narrowFont, _, narrowFits =
    theme.fitReading({"888.88km"}, tooNarrow, ROOM)
  assertEqual(narrowFits, false,
    "the verdict was true for a reading nothing could fit")
  assertFont(narrowFont, smallest,
    "a reading nothing could fit was not drawn at the smallest font")

  -- Exactly on the boundary, which is where an off-by-one lives: a column of
  -- exactly the width needed fits, and one pixel less does not.
  local exact = theme.textWidth(smallest, "888.88km")
  assertEqual(select(3, theme.fitReading({"888.88km"}, exact, ROOM)), true,
    "a column of exactly the width needed was called too narrow")
  assertEqual(select(3, theme.fitReading({"888.88km"}, exact - 1, ROOM)), false,
    "a column one pixel too narrow was called wide enough")

  -- And the verdict follows the *form* that was chosen, not the longest
  -- offered: a caller whose short form fits gets true.
  local _, chosen, formFits =
    theme.fitReading({"888.88km", "88"}, exact - 1, ROOM)
  assertEqual(formFits, true,
    "a caller offering a form that fits was told nothing fits")
  assertEqual(chosen, 2)

  -- The verdict is checked across the whole ladder rather than at one size,
  -- because a rule that varies with size proves nothing at a single one.
  local checked = 0
  for _, ladderFont in ipairs(theme.READING_FONTS) do
    local room = theme.fontHeight(ladderFont)
    local need = theme.textWidth(ladderFont, "88.8")
    local got, _, verdict = theme.fitReading({"88.8"}, need, room)
    checked = checked + 1
    assertFont(got, ladderFont,
      "a column of exactly the width needed moved the font")
    assertEqual(verdict, true, edgetx.fontName(ladderFont)
      .. " was told its exact width does not fit")
  end
  assertEqual(checked, #theme.READING_FONTS)
end

--- A unit sits on its reading's baseline, not its top and not its bottom.
---
--- **EdgeTX gives Lua no way to ask for this.** `lcd.sizeText` returns a
--- width and `getFontHeight`, which is `lv_font_get_line_height`; nothing in
--- `radio/src/lua/` exposes ascent or baseline. So the alternative to knowing
--- the numbers is aligning the two labels by their tops or by their bottoms,
--- and this measures how wrong each is rather than asserting that one of them
--- looks acceptable.
---
--- For the pairs this dashboard actually produces:
---
---     reading + unit        tops wrong by   bottoms wrong by
---     XXLSIZE + MIDSIZE          31 px             9 px
---     DBLSIZE + SMLSIZE          18 px             5 px
---     MIDSIZE + SMLSIZE          10 px             2 px
---     SMLSIZE + TINSIZE           4 px             1 px
---
--- Nine pixels is most of a MIDSIZE line's descender, so bottom alignment is
--- not a near miss at the size that matters most; the unit would sit visibly
--- below the number. The numbers are knowable, so neither approximation is
--- needed, and this test is what stops one creeping back in.
local function testUnitSitsOnTheBaseline()
  local citation = edgetx.citation("FONT_BASE_LINE")

  for font, base in pairs(firmware.FONT_BASE_LINE) do
    assertEqual(theme.fontBaseLine(font), base,
      edgetx.fontName(font) .. " has a different baseline from the font the"
        .. " radio ships (" .. citation.file .. ")")
    assertEqual(theme.fontAscent(font), theme.fontHeight(font) - base,
      edgetx.fontName(font) .. "'s ascent is not its line height less its"
        .. " baseline")
  end

  local checked = 0
  for _, reading in ipairs(theme.READING_FONTS) do
    local rider = theme.unitFont(reading)
    checked = checked + 1

    -- The rider is smaller. A unit at the reading's own size is a second
    -- reading rather than a unit.
    assert(theme.fontHeight(rider) < theme.fontHeight(reading),
      edgetx.fontName(reading) .. " rides with a unit at "
        .. edgetx.fontName(rider) .. ", which is not smaller than it")

    -- Their baselines meet, at every y the caller might place the reading at.
    for _, y in ipairs({0, 7, 25, 104}) do
      local unitY = theme.unitTop(reading, rider, y)
      assertEqual(unitY + theme.fontAscent(rider), y + theme.fontAscent(reading),
        edgetx.fontName(reading) .. " and " .. edgetx.fontName(rider)
          .. " do not share a baseline when the reading's top is " .. y)
    end

    -- And the two approximations are wrong, by enough to be worth the table.
    -- Asserting they differ from the truth is what stops someone replacing
    -- `unitTop` with `y` or with `height - unitHeight` and finding the suite
    -- still green.
    local trueTop = theme.unitTop(reading, rider, 0)
    assert(trueTop > 0, edgetx.fontName(reading)
      .. ": aligning tops is exactly right, so this pair proves nothing")
    local bottoms = theme.fontHeight(reading) - theme.fontHeight(rider)
    assert(bottoms ~= trueTop, edgetx.fontName(reading)
      .. ": aligning bottoms is exactly right, so this pair proves nothing")
  end

  assertEqual(checked, #theme.READING_FONTS)

  -- The pair that matters most is the one the approximation is worst on.
  local worst = theme.fontHeight(XXLSIZE) - theme.fontHeight(MIDSIZE)
    - theme.unitTop(XXLSIZE, MIDSIZE, 0)
  assertEqual(worst, 9,
    "the error in bottom alignment at the largest reading moved, so the"
      .. " table in this comment is stale")
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

--- Supporting text picks a wording that fits rather than clipping.
local function testLabelFitting()
  local variants = {"NO HOME POSITION", "NO HOME POS", "NO HOME"}

  assertEqual(theme.fitLabel(variants, SMLSIZE, 400), "NO HOME POSITION",
    "a wide row took a shorter wording than it had room for")
  assertEqual(theme.fitLabel(variants, SMLSIZE, 120), "NO HOME POS")
  assertEqual(theme.fitLabel(variants, SMLSIZE, 80), "NO HOME")

  -- Nothing fits, so the shortest offered is the honest answer: the caller
  -- chose what its last resort would be.
  assertEqual(theme.fitLabel(variants, SMLSIZE, 4), "NO HOME")
  -- And a caller with no layout context gets the full wording.
  assertEqual(theme.fitLabel(variants, SMLSIZE, nil), "NO HOME POSITION")

  -- The chosen wording must actually fit, which is the property callers rely
  -- on; asserting which string comes back would pass on a helper that always
  -- returned the shortest one.
  for _, width in ipairs({400, 200, 120, 100, 80, 40}) do
    local text = theme.fitLabel(variants, SMLSIZE, width)
    local needed = theme.textWidth(SMLSIZE, text)
    assert(needed <= width or text == variants[#variants], string.format(
      "fitLabel returned %q needing %d px for a row of %d", text, needed, width))
  end
end

--- A cell's outline is lighter beside a smaller number, all the way down.
---
--- The integration test drives the two fonts the grid actually produces. This
--- walks the whole ladder, including the two the component cannot currently
--- reach, because `theme.fitReading` will hand back any of the five and a
--- stroke that only behaved at the two in use would be a trap for whoever
--- reaches the others.
---
--- Asserted as a shape -- never heavier beside a smaller number, and strictly
--- lighter at the ends -- rather than as five numbers. Pinning the numbers
--- would fail on any change to the ratio while saying nothing about whether
--- the ratio was still doing its job, and the numbers are pinned where they
--- matter anyway, in the documented table.
local function testBatteryStrokeScalesWithFont()
  local ladder = theme.READING_FONTS
  assert(#ladder >= 4, "the reading ladder is shorter than this test assumes")

  -- Wide enough that the width ceiling never binds, so what is measured is
  -- the font's contribution alone.
  local ROOMY = 60

  local previous, checked = nil, 0
  for index = #ladder, 1, -1 do
    local font = ladder[index]
    local stroke = primitives.batteryStroke(theme, font, ROOMY)
    checked = checked + 1

    assert(stroke >= primitives.GLYPH_STROKE_MIN, edgetx.fontName(font)
      .. " is outlined at " .. stroke
      .. ", which is a hairline rather than a drawn cell")
    if previous then
      assert(stroke >= previous, edgetx.fontName(font)
        .. " is outlined more lightly than the smaller font below it")
    end
    previous = stroke
  end

  assertEqual(checked, #ladder)

  -- The ends differ, which is what makes it a scale rather than a constant
  -- with a floor.
  local lightest = primitives.batteryStroke(theme, ladder[#ladder], ROOMY)
  local heaviest = primitives.batteryStroke(theme, ladder[1], ROOMY)
  assert(heaviest > lightest, "the largest and smallest readings are outlined"
    .. " identically, at " .. heaviest)

  -- A narrow cell is outlined more lightly than its reading asks for,
  -- because the stroke is taken out of the interior twice over. Without this
  -- the smallest cell the host will draw has a 13 pixel body outlined at 4,
  -- leaving 3 pixels of interior.
  local narrow = primitives.batteryStroke(
    theme, ladder[1], primitives.GLYPH_MIN_WIDTH)
  assert(narrow < heaviest, "the narrowest cell is outlined as heavily as the"
    .. " widest, at " .. narrow)

  -- And the interior it leaves is still a level rather than a line.
  local geometry = primitives.batteryGeometry(0, 0,
    primitives.GLYPH_MIN_WIDTH, primitives.GLYPH_MIN_HEIGHT, narrow)
  assert(geometry.interiorWidth >= 4, "the smallest cell has a "
    .. geometry.interiorWidth .. " pixel interior")
  assert(geometry.interiorHeight >= 8, "the smallest cell has a "
    .. geometry.interiorHeight .. " pixel interior height, so a level in it"
    .. " could not be read as a proportion")

  -- A level partway up that interior lands somewhere distinguishable from
  -- both ends, which is the property the interior exists for.
  local level = primitives.batteryFill(geometry, 0.5)
  assert(level > 1 and level < geometry.interiorHeight - 1,
    "half a charge in the smallest cell draws at " .. level
      .. " of " .. geometry.interiorHeight .. ", which reads as empty or full")
end

--- A battery stays visible in every state, on every palette.
---
--- The user asked for the outline, the terminal and the level to share one
--- state colour, so a critical pack is red throughout. The empty part of the
--- cell is then the panel showing through, and a red cell on a red-tinted
--- panel is the case most likely to disappear. This is that case, held to a
--- number.
---
--- A first pass at this measured 1.01 for exactly that pairing and led to a
--- backing rectangle being added to fix a problem that was not there. The
--- reading was taken on `resolved.color`, whose values are `LcdFlags` words
--- rather than colours; `theme.contrast` is arithmetic on colour channels and
--- the resolved theme carries `rgb` and `alertRgb` for this purpose. Every
--- value below is a 24-bit one.
local function testBatteryStaysVisible()
  -- 3 is roughly where two colours stop being tellable apart at a glance from
  -- arm's length. The worst pairing this palette produces is 3.07, so the
  -- cell clears it everywhere, and a change that made any state worse would
  -- be caught here rather than on a radio.
  local LEAST = 3

  --- What the cell is drawn in, which is the state's own accent.
  local function cellRgb(resolved, state, accent)
    if state == "warning" then return resolved.rgb.amber end
    if state == "critical" then return resolved.rgb.critical end
    if state == "stale" or state == "unavailable" then
      return resolved.rgb.textFaint
    end
    return resolved.rgb[accent]
  end

  local checked, worst, where = 0, 99, ""
  for _, mode in ipairs({"modern", "edgetx"}) do
    local resolved = theme.build(mode)
    for _, state in ipairs({"normal", "warning", "critical", "stale",
        "unavailable"}) do
      local backdrop = primitives.batteryBackdropRgb(resolved, state)
      for _, accent in ipairs({"cyan", "green", "amber", "orange"}) do
        local ratio = theme.contrast(cellRgb(resolved, state, accent), backdrop)
        checked = checked + 1
        if ratio < worst then
          worst, where = ratio, mode .. "/" .. state .. "/" .. accent
        end
        assert(ratio >= LEAST, mode .. "/" .. state .. "/" .. accent
          .. ": the cell is indistinguishable from the panel it stands on, at "
          .. string.format("%.2f", ratio))
      end
    end
  end

  assert(checked >= 40, "only " .. checked .. " combinations were checked")

  -- The margin is recorded rather than merely cleared, so a change that eats
  -- most of it is visible in the diff even while the test still passes.
  assert(worst < 3.5, "the worst pairing is now " .. string.format("%.2f", worst)
    .. " at " .. where .. ", so this test no longer describes the palette")

  -- And the pairing the whole question was about, named rather than left to
  -- be inferred from the loop.
  local modern = theme.build("modern")
  assert(theme.contrast(modern.rgb.critical, modern.alertRgb.critical) >= LEAST,
    "a red cell on a red panel stopped being readable")
end

--- A reading that holds no redundancy offers exactly one form.
---
--- This is the magnitude rule, checked at the only place it can be: the forms
--- a component declares. Every entry below is a reading with nothing to give
--- up, and offering it a shorter form would mean dropping a digit, a clock
--- field, or a unit that is not redundant. `flight-timer` had such a form and
--- it turned `1:04:12` into `04:12`, an hour reported as four minutes.
local function testLosslessReadingsOfferOneForm()
  local cases = {
    {"flight-timer", "FORMS",
      "a clock has no redundancy: every shorter form drops a field"},
  }

  for _, case in ipairs(cases) do
    local module = loadModule("components/" .. case[1] .. ".lua")
    local forms = module[case[2]]
    assert(type(forms) == "table", case[1] .. " declares no forms")
    if case[3] then
      assertEqual(#forms, 1, case[1] .. ": " .. case[3])
    end
  end

  -- A distance cannot shorten, and unlike a voltage it cannot drop its unit
  -- either: the unit changes with range, so `1.23km` and `1.23m` are
  -- different readings rather than one abbreviated.
  local navigation = loadModule("components/navigation.lua")
  assertEqual(navigation.DIGITS, "888.88")
  assertEqual(navigation.UNIT, "km")

  -- And a metric, whose unit is a separate label entirely.
  local metric = loadModule("components/metric.lua")
  assertEqual(#metric.widestSample({rangeMin = 0, rangeMax = 400}, 1), 1,
    "a metric offered a shorter form, which could only lose a digit")
end

--- The redraw decision covers the whole declaration, including its shape.
---
--- Comparing values alone is not enough, because a component may stop drawing
--- something: `variable-indicator` writes a zero tick only while its range
--- spans zero, and drops the key when it no longer does. A comparison that
--- walked only the new table would find every key it held unchanged and
--- report no change, leaving a tick on screen over a range that has none.
---
--- The reused scratch table is the other half of that. If it were not cleared
--- between renders, a key written once would linger for the life of the panel
--- and compare equal to itself forever, which is the same defect wearing the
--- opposite hat.
local function testRedrawDecision()
  local context = {}
  local function renderer(fields)
    return function(_, out)
      for key, value in pairs(fields) do out[key] = value end
    end
  end

  local changed, drawn = primitives.changed(context, renderer({a = 1, b = "x"}))
  assertEqual(changed, true, "the first render must paint")
  assertEqual(drawn.a, 1)

  assertEqual(primitives.changed(context, renderer({a = 1, b = "x"})), false,
    "nothing moved and the panel repainted anyway")

  assertEqual(primitives.changed(context, renderer({a = 2, b = "x"})), true,
    "a changed value did not repaint")

  -- A key that appears is a change.
  assertEqual(primitives.changed(context, renderer({a = 2, b = "x", c = true}),
    true), true, "a new field did not repaint")

  -- And a key that disappears is a change, which is the case a walk over the
  -- new table alone cannot see: every key it still holds is unchanged.
  local gone = primitives.changed(context, renderer({a = 2, b = "x"}))
  assertEqual(gone, true, "a field that stopped being drawn did not repaint")

  -- The table handed back must hold only what this render wrote. A key left
  -- over from an earlier render would be painted, and would compare equal to
  -- itself on every frame after that.
  local _, current = primitives.changed(context, renderer({a = 3}))
  assertEqual(current.a, 3)
  assertEqual(current.b, nil,
    "a field from an earlier render survived into this one")
  assertEqual(current.c, nil,
    "a field from an earlier render survived into this one")
end

--- One ladder, so two panels of the same size answer the same question.
---
--- Every component used to decide its own composition and then fit its own
--- string against the result, so identical panels disagreed twice over. The
--- assertions here are about *agreement between components*, which is the
--- thing that was broken; a bound like "no larger than the box allows" was
--- true of the old code too and would prove nothing.
local function testSharedLadder()
  local resolved = theme.build("modern")

  --- The composition a panel of this size carries.
  local function ladderFor(w, h)
    local fonts = theme.typography(w >= 200 and 2 or 1, h >= 100 and 2 or 1)
    local frame = theme.frame(resolved, {x = 0, y = 0, w = w, h = h}, fonts)
    return theme.ladder(resolved, {x = 0, y = 0, w = w, h = h}, frame)
  end

  -- A single grid row has no space for a supporting row once the reading has
  -- what it needs; two rows do. This is the decision that used to be made
  -- eight times, and it is now made once and is the same answer for everyone.
  assertEqual(ladderFor(238, 65).rows, 0,
    "a 65 px panel claimed room for a supporting row")
  assertEqual(ladderFor(238, 134).rows, 1,
    "a 134 px panel did not grant a supporting row")
  assertEqual(ladderFor(238, 65).visual, true,
    "a 65 px panel cannot carry a bar")

  -- The room left for the reading grows with the panel, and never shrinks as
  -- it grows. That is the property the four non-monotonic ladders violated.
  local previous = 0
  for _, h in ipairs({65, 134, 203, 272}) do
    local room = ladderFor(238, h).room
    assert(room >= previous, string.format(
      "a %d px panel left less room for its reading than a shorter one", h))
    previous = room
  end
end

--- A reading may give up redundancy, never magnitude.
local function testReadingForms()
  -- The box decides the font. Same box, same answer, whatever is drawn in it.
  local a = theme.fitReading({"100"}, 226, 80)
  local b = theme.fitReading({"4.44V"}, 226, 80)
  assertFont(a, b, "two readings in the same box chose different fonts")

  -- The longest form is preferred wherever it fits. Taking a shorter one
  -- anyway gives up a unit for nothing, and an assertion that only looked at
  -- narrow panels would never notice.
  local wide, wideIndex = theme.fitReading({"-100dBm", "-100"}, 400, 80)
  assertEqual(wideIndex, 1, "a reading abbreviated on a panel with room for it")

  -- And abbreviating is preferred to shrinking, which is the whole mechanism:
  -- at 226 px the full form does not fit at the target size, so the unit goes
  -- and the reading stays the size its neighbours are.
  local kept, keptIndex = theme.fitReading({"-100dBm", "-100"}, 226, 80)
  assertEqual(keptIndex, 2, "the reading shrank instead of dropping its unit")
  assertFont(kept, theme.fitReading({"100"}, 226, 80),
    "abbreviating did not keep the reading at its neighbours' size")

  -- With nothing to give up, the font steps instead. Offering one form is how
  -- a component says its reading holds no redundancy.
  local only = theme.fitReading({"-88:88:88"}, 226, 80)
  assert(theme.fontHeight(only) < theme.fontHeight(kept),
    "a reading with no shorter form kept a size it does not fit")

  -- Whatever comes back must actually fit, or the panel clips. This is the
  -- property; asserting a particular font would pass on a helper that always
  -- returned the smallest.
  for _, width in ipairs({400, 226, 160, 105, 60, 30}) do
    for _, forms in ipairs({{"100"}, {"-100dBm", "-100"}, {"888.88km"}}) do
      local chosen, at = theme.fitReading(forms, width, 80)
      local needed = theme.textWidth(chosen, forms[at])
      assert(needed <= width or chosen == SMLSIZE, string.format(
        "fitReading returned %q at %s, needing %d px of %d",
        forms[at], edgetx.fontName(chosen), needed, width))
    end
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
  assertEqual(preset.rangeMax, 400)
  assertEqual(preset.extrema, "source")
  assertEqual(preset.secondarySource, "VSpd")

  -- Anything stated in the layout wins over the preset.
  local overridden = {preset = "altitude", label = "HEIGHT", rangeMax = 1200,
    source = "GAlt", extrema = "flight"}
  metric.applyPreset(overridden)
  assertEqual(overridden.label, "HEIGHT")
  assertEqual(overridden.rangeMax, 1200)
  assertEqual(overridden.source, "GAlt")
  assertEqual(overridden.extrema, "flight")

  -- An unknown preset and an unknown extrema mode both fall back safely.
  local unknown = {preset = "nonsense", extrema = "sometimes"}
  metric.applyPreset(unknown)
  assertEqual(unknown.label, "METRIC")
  assertEqual(unknown.extrema, "none")
  assertEqual(unknown.extremaMode, "max")

  -- The forms decide the font, so they must come from the bounds rather than
  -- from whichever value happens to be showing.
  assertEqual(metric.widestSample({rangeMin = 0, rangeMax = 1200}, 1)[1], "1200.0")
  assertEqual(metric.widestSample({rangeMin = -50, rangeMax = 10}, 0)[1], "-50")

  -- A metric offers exactly one form. Its unit is drawn as a separate label,
  -- so the reading is digits alone and holds no redundancy to give up;
  -- anything shorter would drop magnitude.
  assertEqual(#metric.widestSample({rangeMin = 0, rangeMax = 1200}, 1), 1,
    "a metric offered a shorter form, which could only lose a digit")
end

--- Timer semantics belong to EdgeTX; the component only presents them.
local function testTimerSemantics()
  local timer = loadModule("components/flight-timer.lua")

  local countdown = {
    available = true, countdown = true, value = 90, start = 300,
    elapsed = 210, remaining = 90, expired = false, showElapsed = false,
  }

  assertEqual(timer.displayValue({reading = "model"}, countdown), 90)
  assertEqual(timer.displayValue({reading = "elapsed"}, countdown), 210)
  -- EdgeTX's own showElapsed preference is honoured by `model`.
  countdown.showElapsed = true
  assertEqual(timer.displayValue({reading = "model"}, countdown), 210)
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

--- The composition table in `docs/components/tx-battery.md` is true.
---
--- That page tells someone configuring a dashboard which spans show the bar
--- and which show the percentage, and which span drops the unit. Those are
--- the facts a layout is written against, and nothing checked them: the
--- existing coverage is of `hasRange`, `fraction` and `resolveState`, which
--- are the arithmetic rather than the composition.
---
--- Written as the documented table rather than as the rule that produces it,
--- because restating `cells >= 2` here would pass for any implementation that
--- happened to contain those words and would say nothing about what a person
--- sees.
local function testTxBatteryComposition()
  local battery = loadModule("components/tx-battery.lua")
  local resolved = theme.build("modern")

  -- span, reading font, unit shown, cell w x h, outline, percentage under
  --
  -- The cell stands upright, so it is half as wide as it is tall. That is
  -- what took the percentage out from under it at every span: `100%` needs 39
  -- pixels at the label font and the widest cell here is 25.
  --
  -- The outline column is the interesting one. `1x2` and `2x2` draw cells of
  -- exactly the same size and outline them differently, because the readings
  -- they stand beside are different sizes. A stroke derived from the span or
  -- from the cell would give those two rows the same number.
  local documented = {
    {"1x1", "MIDSIZE", true, nil, nil, nil, false},
    {"2x1", "MIDSIZE", true, 17, 34, 2, false},
    {"3x1", "MIDSIZE", true, 17, 34, 2, false},
    {"4x1", "MIDSIZE", true, 17, 34, 2, false},
    -- **The two-row spans read at XXLSIZE, and did not until the band stopped
    -- being cut for a row this panel does not draw.** The estimate is off by
    -- default, so with no layout asking for it there is nothing for a
    -- supporting row to hold -- and the tertiary quarter was reserved anyway,
    -- leaving a 62 px body band against XXLSIZE's 69. Told what the panel
    -- draws rather than what its height permits, the band is 93 px and the
    -- largest reading on the dashboard comes back.
    --
    -- `1 x 2` and `2 x 2` shed the `V`, which is the abbreviation rule in
    -- its documented order: an XXLSIZE `88.8` is 102 px of a 105 px box at
    -- `1 x 2` and of a 113 px half at `2 x 2`, and the unit is redundancy
    -- because the panel's own heading names what is measured. Magnitude is
    -- kept and redundancy spent, which is the trade the rule names.
    {"1x2", "XXLSIZE", false, nil, nil, nil, false},
    {"2x2", "XXLSIZE", false, 25, 50, 4, false},
    {"3x2", "XXLSIZE", true, 25, 50, 4, false},
    {"4x2", "XXLSIZE", true, 25, 50, 4, false},
  }

  local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
  local cellWidth = math.floor((WIDTH - GUTTER * (CELLS - 1)) / CELLS)
  local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)

  assertEqual(#documented, #battery.supportedSpans,
    "the documented table and the declared spans disagree in length")

  for index, row in ipairs(documented) do
    local span, font, showUnit = row[1], row[2], row[3]
    local glyphWidth, glyphHeight = row[4], row[5]
    local border, under = row[6], row[7]
    assertEqual(battery.supportedSpans[index], span,
      "the documented table is in a different order from supportedSpans")

    local cols, rows = string.match(span, "(%d)x(%d)")
    cols, rows = tonumber(cols), tonumber(rows)
    local rect = {
      x = 0, y = 0,
      w = cellWidth * cols + GUTTER * (cols - 1),
      h = cellHeight * rows + GUTTER * (rows - 1),
    }
    local fonts = theme.typography(cols, rows)
    local layout = battery.presentationFor(cols, rows)
    layout.visual = "battery"
    local area = battery.regionsFor(
      resolved, theme, primitives, rect, layout, fonts)

    assertEqual(edgetx.fontName(area.value), font,
      span .. " does not draw its reading at the documented size")
    assertEqual(area.showUnit, showUnit,
      span .. " disagrees with the documentation about showing its unit")
    assertEqual(area.glyphWidth, glyphWidth,
      span .. " draws a glyph of a different width from the documented one")
    assertEqual(area.glyphHeight, glyphHeight,
      span .. " draws a glyph of a different height from the documented one")
    assertEqual(area.glyphBorder, border,
      span .. " outlines its cell at a different weight from the documented"
        .. " one")
    assertEqual(area.detailUnderGlyph, under,
      span .. " disagrees with the documentation about where the percentage"
        .. " sits")

    -- The reading and whatever rides beside it have to fit the column they
    -- actually have, which is what is left once the glyph has taken its
    -- share -- not the panel's full width. This is the assertion that would
    -- have caught the reading being fitted as `88.8` and drawn as `88.8V`.
    local carried = theme.readingWidth(area.value, battery.DIGITS,
      area.unitFont, area.showUnit and battery.UNIT or nil)
    assert(carried <= area.valueWidth, span
      .. " draws its reading and unit past its own column: " .. carried
      .. " into " .. area.valueWidth)

    -- And the unit really is smaller than the number it rides beside, which
    -- is the whole of what makes it a rider rather than a second reading.
    if area.showUnit then
      assert(theme.fontHeight(area.unitFont) < theme.fontHeight(area.value),
        span .. " draws its unit at or above the reading's own size")
    end

    -- And a cell, where there is one, has to fit beside it and stand upright.
    if area.glyphWidth then
      assert(area.glyphX + area.glyphWidth <= area.pad + area.content,
        span .. " draws its battery past the panel edge")
      assert(area.glyphX >= area.pad + area.valueWidth,
        span .. " draws its battery over the reading")
      assert(area.glyphHeight > area.glyphWidth,
        span .. " draws a battery wider than it is tall")
      local floor = area.showDetail and area.detailY or rect.h
      assert(area.glyphY + area.glyphHeight <= floor, span
        .. " draws its battery over the row beneath it: ends at "
        .. (area.glyphY + area.glyphHeight) .. ", row at " .. floor)
    end
  end

  -- The reading is digits and nothing else. There is no longer a form to
  -- choose between, which is what stopped `88.8` being measured and `88.8V`
  -- being drawn -- 116 pixels into a 105 pixel column, invisible below 10 V
  -- because `7.9V` happens to fit where `10.0V` does not.
  assertEqual(battery.reading(7.9), "7.9")
  assertEqual(battery.reading(10.0), "10.0")
  assertEqual(battery.reading(nil), "--")

  assertEqual(battery.reading(88.8), battery.DIGITS,
    "the widest number the fitter is asked about is not the widest it prints")

  -- The cell's column ends where the percentage begins, at every height a
  -- reflow can produce rather than only at the eight the grid can.
  --
  -- This is worth sweeping rather than sampling: at the spans a 4 x 4 grid
  -- makes, the cell's own height cap binds before the room does, so the panel
  -- sizes a layout can ask for never exercise the floor at all. A zone in App
  -- mode is whatever the screen leaves, and a short two-row panel is where a
  -- cell would grow down through the row beneath it.
  local swept = 0
  for height = 70, 200, 2 do
    for _, width in ipairs({117, 238, 480}) do
      local rect = {x = 0, y = 0, w = width, h = height}
      -- `showPercent` true, because the row only exists when a layout asks
      -- for it: without that this sweep builds panels with no supporting
      -- row, finds nothing to clear, and passes while checking nothing.
      local layout = battery.presentationFor(width > 200 and 2 or 1, 2, true)
      layout.visual = "battery"
      local area = battery.regionsFor(resolved, theme, primitives, rect,
        layout, theme.typography(width > 200 and 2 or 1, 2))
      if area.glyphHeight and area.showDetail then
        swept = swept + 1
        assert(area.glyphY + area.glyphHeight <= area.detailY,
          "a " .. width .. " by " .. height .. " panel stands its battery "
            .. (area.glyphY + area.glyphHeight - area.detailY)
            .. " pixels into the row beneath it")
      end
    end
  end
  assert(swept >= 50, "only " .. swept
    .. " panels in the sweep both drew a battery and showed a percentage")
end

--- The transmitter estimate is optional and must stay off until a layout
--- states the voltage range it should be measured against.
local function testTxBatteryEstimate()
  local battery = loadModule("components/tx-battery.lua")

  assertEqual(battery.hasRange({}), false)
  assertEqual(battery.hasRange({packEmpty = 6.6}), false)
  assertEqual(battery.hasRange({packEmpty = 8.4, packFull = 6.6}), false,
    "an inverted range is not a range")
  assertEqual(battery.hasRange({packEmpty = 6.6, packFull = 8.4}), true)

  assertEqual(battery.fraction({}, 7.5), 0, "no range means no estimate")
  assertEqual(battery.fraction({packEmpty = 6.6, packFull = 8.6}, 7.6), 0.5)
  assertEqual(battery.fraction({packEmpty = 6.6, packFull = 8.6}, 9.0), 1)
  assertEqual(battery.fraction({packEmpty = 6.6, packFull = 8.6}, 6.0), 0)

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

  assertEqual(indicator.visual("radial"), "radial")
  assertEqual(indicator.visual("sparkline"), "none")
  assertEqual(indicator.visual(nil), "none")

  local range = {value = 150, min = 0, max = 100}
  assertEqual(indicator.fraction("bar", range, signed), 1,
    "the drawing is clamped")
  assertEqual(indicator.format(range.value, 0), "150",
    "the value is not clamped")

  local bipolar = {value = -25, min = -50, max = 100}
  assertEqual(indicator.fraction("bipolar-bar", bipolar, signed), -0.5)
  assertEqual(indicator.fraction("bar", {value = 25, min = 0, max = 100},
    signed), 0.25)
  assertEqual(indicator.fraction("radial", {value = nil, min = 0, max = 100},
    signed), 0)
  assertEqual(indicator.fraction("bar", {value = 5, min = 5, max = 5},
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
  assertEqual(trims.valueText({readout = "percent"}, right), "+23%")
  assertEqual(trims.valueText({readout = "raw"}, right), "+30")
  assertEqual(trims.valueText({readout = "none"}, right), "")

  local left = {available = true, raw = -240, value = -30, fraction = -0.234375,
    centered = false, threePosition = false}
  assertEqual(trims.valueText({readout = "percent"}, left), "-23%")
  assertEqual(trims.valueText({readout = "raw"}, left), "-30")

  local centred = {available = true, raw = 0, value = 0, fraction = 0,
    centered = true, threePosition = false}
  assertEqual(trims.valueText({readout = "percent"}, centred), "0%")

  -- A three-position trim reports full deflection or nothing, so naming its
  -- position is honest where a percentage would not be.
  local toggle = {available = true, raw = 1024, value = 128, fraction = 1,
    centered = false, threePosition = true}
  assertEqual(trims.valueText({readout = "percent"}, toggle), "3P HI")
  toggle.raw, toggle.centered, toggle.fraction = 0, true, 0
  assertEqual(trims.valueText({readout = "percent"}, toggle), "3P MID")
  toggle.raw, toggle.centered, toggle.fraction = -1024, false, -1
  assertEqual(trims.valueText({readout = "raw"}, toggle), "3P LO")

  assertEqual(trims.valueText({readout = "percent"}, nil), "--")
  assertEqual(trims.valueText({readout = "percent"}, {available = false}), "--")

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
  local settings = {reading = "lowest", cellEmpty = 3.3, cellFull = 4.2,
    warning = 3.5, critical = 3.3}

  assertEqual(cellBattery.primaryValue(settings, summary), 3.25)
  -- An explicitly configured lowest-cell source wins: the receiver has seen
  -- samples between our polls that this component never will.
  assertEqual(cellBattery.primaryValue(settings, summary, 3.11), 3.11)

  local pack = {reading = "pack", cellEmpty = 3.3, cellFull = 4.2}
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

  -- Three shape problems with three different fixes, said in the detail row
  -- rather than in a badge. A cells source returning a plain number is a
  -- configuration mistake, one returning nonsense is a sensor fault, and an
  -- empty table is a pack not detected yet. The badge for all three is the
  -- state, which is the same for all three.
  local function count(summary, width)
    return theme.fitLabel(
      cellBattery.countVariants(summary, {showCount = true}), SMLSIZE, width)
  end

  assertEqual(count({shape = "number"}, 400), "NOT A CELLS SENSOR")
  assertEqual(count({shape = "invalid"}, 400), "BAD CELL VALUES")
  assertEqual(count({shape = "empty"}, 400), "NO CELLS DETECTED")
  -- A source the radio has never seen is not a shape problem, and the row has
  -- nothing of its own to add to the badge.
  assertEqual(count({shape = "none"}, 400), "")
  assertEqual(count({shape = "cells", count = 4}, 400), "4S")

  -- Each wording shortens rather than clipping when the row is narrow. This
  -- is the whole reason the distinction moved out of the badge: a detail row
  -- can say it at four widths, a six-character badge cannot say it at all.
  assertEqual(count({shape = "number"}, 100), "NOT CELLS")
  assertEqual(count({shape = "number"}, 50), "NOT CELS")

  -- A count below the configured one is called out, and that too shortens.
  local short = {shape = "cells", count = 3}
  assertEqual(theme.fitLabel(cellBattery.countVariants(short,
    {showCount = true, cells = 4}), SMLSIZE, 400), "3S OF 4")
  assertEqual(theme.fitLabel(cellBattery.countVariants(short,
    {showCount = true, cells = 4}), SMLSIZE, 50), "3S/4")

  -- The pack row shortens the same way, and says nothing when switched off.
  assertEqual(theme.fitLabel(cellBattery.packVariants({pack = 16.4},
    {showPack = true}), SMLSIZE, 400), "16.4V PACK")
  assertEqual(theme.fitLabel(cellBattery.packVariants({pack = 16.4},
    {showPack = true}), SMLSIZE, 60), "16.4V")
  assertEqual(theme.fitLabel(cellBattery.packVariants({pack = 16.4},
    {showPack = false}), SMLSIZE, 400), "")
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
  assertEqual(linkStatus.primaryFor({reading = "auto"}, "live", "live"), "quality")
  assertEqual(linkStatus.primaryFor({reading = "auto"}, "live", "absent"), "rssi")
  assertEqual(linkStatus.primaryFor({reading = "auto"}, "live", "none"), "rssi")
  assertEqual(linkStatus.primaryFor({reading = "auto"}, "absent", "live"), "quality")
  -- An explicit choice is never overridden, however bad the source looks.
  assertEqual(linkStatus.primaryFor({reading = "rssi"}, "absent", "live"), "rssi")
  assertEqual(linkStatus.primaryFor({reading = "quality"}, "live", "absent"),
    "quality")

  local thresholds = {warning = 50, critical = 30}
  local function state(reading)
    return linkStatus.resolveState(thresholds, reading)
  end

  --- What the supporting row says, at whatever width it is given.
  local function link(reading, width)
    return linkStatus.linkText({
      themeBuilder = theme, fonts = {label = SMLSIZE},
      rowRightWidth = width or 400,
    }, reading)
  end

  -- A protocol with no RSSI sensor is a permanent property of the link, not a
  -- fade, and it must never be reported as a dead link. The state is the same
  -- for both; the row is what tells them apart, which is why it says this in
  -- words rather than in six badge characters.
  assertEqual(state({sourceState = "absent", linkDown = false}), "unavailable")
  assertEqual(link({sourceState = "absent", indicator = true,
    rssiState = "absent"}), "NO RSSI SENSOR")

  -- A dead link is the measurement this panel exists to report.
  assertEqual(state({sourceState = "live", linkDown = true, available = true,
    value = 96}), "critical")
  assertEqual(link({linkDown = true}), "LINK DOWN")

  -- Never powered up is not an alarm.
  assertEqual(state({sourceState = "waiting", linkDown = true,
    available = false}), "unavailable")

  -- Both shorten rather than clipping when the row is narrow.
  assertEqual(link({linkDown = true}, 70), "NO LINK")
  assertEqual(link({linkDown = true}, 45), "DOWN")
  assertEqual(link({sourceState = "absent", indicator = true,
    rssiState = "absent"}, 90), "NO RSSI")

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
  local dbm = {barMin = -110, barMax = -30}
  assertEqual(linkStatus.fraction(dbm, -110), 0)
  assertEqual(linkStatus.fraction(dbm, -30), 1)
  assert(math.abs(linkStatus.fraction(dbm, -70) - 0.5) < 0.001)
  assertEqual(linkStatus.fraction(dbm, -200), 0)
  assertEqual(linkStatus.fraction({barMin = 0, barMax = 0}, 5), 0)
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

end

--- The square an arc of a given centre and radius covers.
---
--- `radius` is the arc's *outer* edge: `lv_draw_arc.c` sets `rout = radius`
--- and `rin = radius - w`, so the stroke is drawn inside it and a thickness
--- adds nothing to the box. The widget used to carry a `primitives.arcBounds`
--- that added half the thickness, which was both wrong and called by nothing
--- but tests. It is a test's own arithmetic over a planned region, so it
--- lives here; where there is a real object, measure the object instead.
local function arcSquare(centreX, centreY, radius)
  return {
    x = centreX - radius,
    y = centreY - radius,
    w = radius * 2,
    h = radius * 2,
  }
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
  -- No badge at all: the panel is not in a failed state, and the origin
  -- caption below says which part is missing. Asked of the component
  -- directly, so this is the full wording rather than whatever a particular
  -- panel's row width leaves of it.
  assertEqual(navigation.resolveState({}, noHome), "normal")
  assertEqual(navigation.bearingText(noHome), "BRG --")
  assertEqual(navigation.originText(noHome), "NO HOME POSITION")
  assertEqual(navigation.coordinateText(noHome), "47.37690 8.54170")

  -- No fix is reported as such, never as a distance of zero.
  local noFix = {source = "GPS", known = true, fix = false, home = false,
    state = "unavailable"}
  assertEqual(navigation.resolveState({}, noFix), "unavailable")
  assertEqual(navigation.originText(noFix), "NO FIX")
  assertEqual(navigation.coordinateText(noFix), "-- , --")

  -- A source the radio does not have is a different problem again, and the
  -- caption is where that difference is stated. All three are `unavailable`.
  assertEqual(navigation.resolveState({},
    {source = "GPS", known = false, fix = false, home = false}), "unavailable")
  assertEqual(navigation.originText({source = "GPS", known = false}),
    "NO GPS SOURCE")

  -- The bearing row shortens rather than clipping. `BRG 009 N` needs 89 px and
  -- was being drawn into 38 on a 1 x 2 panel.
  assertEqual(navigation.bearingText(fix, theme, SMLSIZE, 400), "BRG 009 N")
  assertEqual(navigation.bearingText(fix, theme, SMLSIZE, 80), "BRG 009")
  assertEqual(navigation.bearingText(fix, theme, SMLSIZE, 60), "009 N")
  assertEqual(navigation.bearingText(fix, theme, SMLSIZE, 35), "009")

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
    {x = 0, y = 0, w = 238, h = 134}, layout, fonts,
    {digits = "888.88", unit = "km"})
  assertEqual(large.showCompass, true)
  assertEqual(large.showCoordinates, true)
  -- The dial sits inside its own panel, measured from its centre.
  local box = arcSquare(large.centreX, large.centreY, large.radius)
  assert(box.x >= 0 and box.y >= 0, "the dial was placed off the panel")
  assert(box.x + box.w <= 238, "the dial overflowed the panel")
  assert(box.y + box.h <= 134, "the dial overflowed the panel")
  -- And never over the reading beside it.
  assert(large.pad + large.valueWidth <= box.x, "the dial overlaps the value")

  -- A panel that cannot afford everything sheds the coordinates first and the
  -- dial next, and never the distance.
  local short = navigation.regionsFor(resolved, theme,
    {x = 0, y = 0, w = 238, h = 62}, layout, fonts,
    {digits = "888.88", unit = "km"})
  assertEqual(short.showCoordinates, false)

  local tiny = navigation.regionsFor(resolved, theme,
    {x = 0, y = 0, w = 58, h = 40}, layout, fonts,
    {digits = "888.88", unit = "km"})
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
    -- Smaller than any span the grid can produce: a single cell is 117 by
    -- 65. Kept as a stress case, and marked so the assertions can ask it the
    -- question it can actually answer.
    {name = "tiny", w = 60, h = 40, colSpan = 1, rowSpan = 1, synthetic = true},
  }

  for _, case in ipairs(cases) do
    local rect = {x = 0, y = 0, w = case.w, h = case.h}
    local fonts = theme.typography(case.colSpan, case.rowSpan)
    local labelHeight = heightOf(fonts.label)

    --- Shared assertions: the reading fits its own region in both axes, and
    --- clears the header above it and whatever row sits below it.
    --- @param reading table `digits`, and `unit` where the panel has one.
    local function assertReading(what, area, valueFont, valueWidth, reading)
      local bottom = area.valueY + heightOf(valueFont)
      assert(bottom <= case.h, what .. " " .. case.name
        .. ": the reading overflows the panel, ends at " .. bottom)
      assert(area.valueY >= labelHeight, what .. " " .. case.name
        .. ": the reading overlaps the header")
      assert(area.pad + valueWidth <= case.w, what .. " " .. case.name
        .. ": the reading runs past the right edge")

      -- Width matters as much as height, and the width that matters is the
      -- number **and whatever rides beside it**. Measuring the digits alone
      -- would pass a panel whose unit hangs over the edge, which is the whole
      -- of what an inline unit can get wrong.
      local carried = theme.readingWidth(valueFont, reading.digits,
        area.unitFont, area.showUnit and reading.unit or nil)
      if case.synthetic then
        -- Narrower than any real panel, so the widest reading genuinely does
        -- not fit and the only honest question is whether the component spent
        -- everything it had. Asserting the fit here would be asserting that a
        -- 60 pixel panel is a 117 pixel one.
        assertEqual(valueFont, theme.READING_FONTS[#theme.READING_FONTS],
          what .. " " .. case.name
            .. ": a panel too narrow for its reading kept a larger font")
      else
        assert(carried <= valueWidth, what .. " " .. case.name
          .. ": the reading and its unit clip at "
          .. carried .. " in " .. valueWidth)
      end

      -- A unit that is not smaller than its number is a second reading.
      if area.showUnit then
        assert(heightOf(area.unitFont) < heightOf(valueFont),
          what .. " " .. case.name
            .. ": the unit is drawn at or above the reading's own size")
      end

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
      resolved, theme, rect, cellLayout, fonts,
      {digits = "4.44", unit = "V"})
    assertReading("cell-battery", cells, cells.value, cells.content,
      {digits = "4.44", unit = "V"})
    if cells.showDetail then
      assert(cells.detailY + labelHeight <= cells.barY, "cell-battery "
        .. case.name .. ": the detail row overlaps the bar")
      assertColumns("cell-battery", cells,
        cells.detailWidth, cells.rowRightX, cells.detailWidth)
    end
    if cells.showVisual then
      assert(cells.barY + resolved.spacing.barHeight <= case.h,
        "cell-battery " .. case.name .. ": the bar overflows the panel")
    end

    local linkLayout = linkStatus.presentationFor(case.colSpan, case.rowSpan)
    linkLayout.visual = "bar"
    local link = linkStatus.regionsFor(
      resolved, theme, rect, linkLayout, fonts,
      {digits = "-100", unit = "dBm"})
    assertReading("link-status", link, link.value, link.content,
      {digits = "-100", unit = "dBm"})
    if link.showDetail then
      assert(link.detailY + labelHeight <= link.barY, "link-status "
        .. case.name .. ": the detail row overlaps the bar")
      assertColumns("link-status", link,
        link.detailWidth, link.rowRightX, link.rowRightWidth)
    end

    for _, presentation in ipairs({"distance", "bearing", "compass", "detailed"}) do
      local navLayout = navigationComponent.presentationFor(presentation)
      local nav = navigationComponent.regionsFor(
        resolved, theme, rect, navLayout, fonts,
        {digits = "888.88", unit = "km"})
      local what = "navigation/" .. presentation
      assertReading(what, nav, nav.value, nav.valueWidth,
        {digits = navigationComponent.DIGITS, unit = navigationComponent.UNIT})

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
        local box = arcSquare(nav.centreX, nav.centreY, nav.radius)
        assert(box.x >= 0 and box.y >= 0,
          what .. " " .. case.name .. ": the dial was placed off the panel")
        assert(box.x + box.w <= case.w and box.y + box.h <= case.h,
          what .. " " .. case.name .. ": the dial overflows the panel")
        assert(nav.pad + nav.valueWidth <= box.x,
          what .. " " .. case.name .. ": the dial overlaps the reading")

        -- **And the dial clears the rows beneath it.** This is the one the
        -- catalogue had no check for: a dial is not a label, so the
        -- integration suite's collision check sees it, but no shipped layout
        -- draws this component with two supporting rows *and* a compass, so
        -- nothing exercised the pair. The dial used to be sized against
        -- whatever vertical room was left and stand from the content top
        -- downward, which put it 44 by 2 pixels through the row below at
        -- `2 x 2` and `4 x 2`.
        if nav.showDetail then
          assert(box.y + box.h <= nav.detailY, what .. " " .. case.name
            .. ": the dial runs " .. (box.y + box.h - nav.detailY)
            .. " px into the supporting row beneath it")
        end
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
    resolved, theme, squeezed, cellLayout, wideFonts,
    {digits = "4.44", unit = "V"})
  assertEqual(shedCells.showDetail, false,
    "cell-battery kept a supporting row a short panel could not afford")
  assert(heightOf(shedCells.value) >= heightOf(MIDSIZE),
    "cell-battery shed a row without buying its reading any size")

  local linkLayout = linkStatus.presentationFor(2, 1)
  linkLayout.visual = "bar"
  local shedLink = linkStatus.regionsFor(
    resolved, theme, squeezed, linkLayout, wideFonts,
    {digits = "-100", unit = "dBm"})
  assertEqual(shedLink.showDetail, false,
    "link-status kept a supporting row a short panel could not afford")
  assert(heightOf(shedLink.value) >= heightOf(MIDSIZE),
    "link-status shed a row without buying its reading any size")

  local shedNav = navigationComponent.regionsFor(resolved, theme, squeezed,
    navigationComponent.presentationFor("detailed"), wideFonts,
    {digits = navigationComponent.DIGITS, unit = navigationComponent.UNIT})
  assertEqual(shedNav.showCoordinates, false,
    "navigation kept a coordinates row a short panel could not afford")
  assert(heightOf(shedNav.value) >= heightOf(MIDSIZE),
    "navigation shed a row without buying its reading any size")
end

testSnapshotsAreImmutable()
testServiceScheduling()
testTelemetryFreshness()
testTelemetryTextSensor()
testFlightModeSizing()
testFlightModeIndexNeedsARow()
testTelemetryLinkHeuristics()
testTelemetryPollingIsBounded()
testModelService()
testControlService()
testExtremaService()
testNavigationService()
testFontHeightsMatchTheFirmware()
testWidthIsMeasuredNotEstimated()
testFitReadingReportsWhetherItFits()
testUnitSitsOnTheBaseline()
testTextFitting()
testBatteryStrokeScalesWithFont()
testBatteryStaysVisible()
testLosslessReadingsOfferOneForm()
testRedrawDecision()
testSharedLadder()
testReadingForms()
testLabelFitting()
testBipolarGeometry()
testMetricPresets()
testTimerSemantics()
testTxBatteryEstimate()
testTxBatteryComposition()
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