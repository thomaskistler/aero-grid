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

testGridGeometry()
testValidation()
testOverlapIsRejected()
testLayoutPath()

print("AeroGrid runtime tests passed")