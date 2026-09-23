-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local yaml = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/yaml.lua"))()
local grid = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/grid.lua"))()
local layout = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/layout.lua"))()

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
    assertions.assertEqual(#errors, 0)
    assertions.assertEqual(#normalized.components, 2)
    assertions.assertEqual(normalized.components[1].config.title, "Altitude #1")
    assertions.assertEqual(normalized.components[1].config.warning, 120.5)
    assertions.assertEqual(normalized.components[1].config.enabled, true)
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
    assertions.assertEqual(#normalized.components, 1)
    assertions.assertEqual(#errors, 1)
    assert(string.match(errors[1], "overlaps first"), errors[1])
end

local function run()
    testValidation()
    testOverlapIsRejected()
end

run()
