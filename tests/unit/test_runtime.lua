-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

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
local function testMalformedInput()
  local cases = {
    {name = "scalar component entry", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - bare-scalar\n"},
    {name = "numeric component entry", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - 42\n"},
    {name = "components mapping", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  nope: 1\n"},
    {name = "missing grid", text = "version: 1\ncomponents: []\n"},
    {name = "future version", text = "version: 99\ngrid:\n  columns: 4\n  rows: 4\ncomponents: []\n"},
    {name = "wrong grid size", text = "version: 1\ngrid:\n  columns: 3\n  rows: 3\ncomponents: []\n"},
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
      assert(normalized, case.name .. " returned no layout")
      assert(#errors > 0, case.name .. " reported no error")
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

print("AeroGrid runtime tests passed")