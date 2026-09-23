-- SPDX-License-Identifier: GPL-2.0-only

local fixtures = {}

fixtures.singleMetric = [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Pack
      source: RxBt
      unit: V
      accent: cyan
      rangeMin: 18
      rangeMax: 25.2
      warning: 21.0
      critical: 19.8
      precision: 1
      visual: bar
]]

fixtures.overlap = [[
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
    colSpan: 2
    rowSpan: 1
]]

fixtures.multiPanel = [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: current
    type: metric
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
  - id: mode
    type: flight-mode
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
]]

return fixtures
