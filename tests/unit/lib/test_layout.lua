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
panels:
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
    assertions.assertEqual(#normalized.panels, 2)
    assertions.assertEqual(normalized.panels[1].config.title, "Altitude #1")
    assertions.assertEqual(normalized.panels[1].config.warning, 120.5)
    assertions.assertEqual(normalized.panels[1].config.enabled, true)
end

local function testOverlapIsRejected()
    local document = assert(yaml.parse([[
version: 1
grid:
  columns: 4
  rows: 4
panels:
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
    assertions.assertEqual(#normalized.panels, 1)
    assertions.assertEqual(#errors, 1)
    assert(string.match(errors[1], "overlaps first"), errors[1])
end

local function testVersionOneBatteryMigration()
    local document = assert(yaml.parse([[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: monitored-pack
    type: cell-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      sourceType: cells
      source: Cels
      lowestSource: Cels-
      cells: 4
      reading: lowest
      cellFull: 4.15
      critical: 3.25
  - id: receiver-pack
    type: cell-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      sourceType: pack
      source: RxBt
      cells: 6
      reading: pack
      warning: 3.55
  - id: legacy-cells-default
    type: cell-battery
    col: 0
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      source: Cels
      cells: 4
      reading: average
]]))
    local normalized, errors = layout.validate(document, grid)
    assertions.assertEqual(#errors, 0)
    assertions.assertEqual(normalized.version, 2)
    local cells = normalized.panels[1]
    assertions.assertEqual(cells.type, "rx-battery")
    assertions.assertEqual(cells.config.reading, "cell")
    assertions.assertEqual(cells.config.lowestSource, nil)
    assertions.assertEqual(cells.config.cells, nil)
    assertions.assertEqual(cells.config.cellFull, 4.15)
    assertions.assertEqual(cells.config.cellCritical, 3.25)
    assertions.assertEqual(cells.config.cellWarning, nil, "migration materialized an omitted old default")
    assertions.assertEqual(cells.config.critical, nil)
    local pack = normalized.panels[2]
    assertions.assertEqual(pack.type, "rx-battery")
    assertions.assertEqual(pack.config.reading, "pack")
    assertions.assertEqual(pack.config.cells, 6)
    assertions.assertEqual(pack.config.cellWarning, 3.55)
    assertions.assertEqual(pack.config.warning, nil)
    local legacyCells = normalized.panels[3]
    assertions.assertEqual(legacyCells.type, "rx-battery")
    assertions.assertEqual(legacyCells.config.sourceType, nil)
    assertions.assertEqual(legacyCells.config.cells, nil)
    assertions.assertEqual(legacyCells.config.reading, "cell")
end

local function testCurrentBatteryThresholdNormalization()
    local panel = { type = "rx-battery", config = { warning = 3.55, critical = 3.25 } }
    layout.normalizePanel(panel)
    assertions.assertEqual(panel.config.cellWarning, 3.55)
    assertions.assertEqual(panel.config.cellCritical, 3.25)
    assertions.assertEqual(panel.config.warning, nil)
    assertions.assertEqual(panel.config.critical, nil)
    layout.normalizePanel(panel)
    assertions.assertEqual(panel.config.cellWarning, 3.55, "normalization must be idempotent")

    panel.config = { warning = 3.55, critical = 3.25, cellWarning = 3.6, cellCritical = 3.4 }
    layout.normalizePanel(panel)
    assertions.assertEqual(panel.config.cellWarning, 3.6, "current keys take precedence")
    assertions.assertEqual(panel.config.cellCritical, 3.4)
    assertions.assertEqual(panel.config.warning, nil)
    assertions.assertEqual(panel.config.critical, nil)

    panel.config = {}
    layout.normalizePanel(panel)
    assertions.assertEqual(panel.config.cellWarning, nil, "normalization must not materialize defaults")
    assertions.assertEqual(panel.config.cellCritical, nil)

    panel.type = "tx-battery"
    panel.config = { warning = 7.2, critical = 6.8 }
    layout.normalizePanel(panel)
    assertions.assertEqual(panel.config.warning, 7.2, "other panel settings must remain unchanged")
    assertions.assertEqual(panel.config.critical, 6.8)
    assertions.assertEqual(panel.config.cellWarning, nil)
end

local function testAdjacentMigrationSteps()
    local header = { version = 1, grid = { columns = 4, rows = 4 }, panels = {} }
    local validated, errors, sourceVersion = layout.validateHeader(header)
    assertions.assertEqual(#errors, 0)
    assertions.assertEqual(sourceVersion, 1)
    assertions.assertEqual(validated.version, 1, "header validation must not skip migration steps")
    local migrated, nextVersion = layout.migrateHeaderStep(validated)
    assert(migrated)
    assertions.assertEqual(nextVersion, 2)
    assertions.assertEqual(validated.version, 2)
    local finalized, finalizeErrors = layout.finalizeHeader(validated)
    assertions.assertEqual(#finalizeErrors, 0)
    assertions.assertEqual(finalized.version, 2)

    local panel = {
        type = "cell-battery",
        config = { sourceType = "cells", cells = 4, reading = "lowest" },
    }
    migrated, nextVersion = layout.migratePanelStep(panel, 1)
    assert(migrated)
    assertions.assertEqual(nextVersion, 2)
    assertions.assertEqual(panel.type, "rx-battery")
    assertions.assertEqual(panel.config.cells, nil)
    assertions.assertEqual(panel.config.reading, "cell")
    assertions.assertEqual(layout.supportsVersion(3), false, "future versions require registered adjacent helpers")
end

local function testUnsupportedFutureVersion()
    local document = {
        version = 3,
        grid = { columns = 4, rows = 4 },
        panels = {},
    }
    local normalized, errors = layout.validate(document, grid)
    assertions.assertEqual(normalized, nil)
    assert(string.match(errors[1], "unsupported layout version"))
end

local function run()
    testValidation()
    testOverlapIsRejected()
    testVersionOneBatteryMigration()
    testCurrentBatteryThresholdNormalization()
    testAdjacentMigrationSteps()
    testUnsupportedFutureVersion()
end

run()
