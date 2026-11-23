-- SPDX-License-Identifier: GPL-2.0-only

local fixtures = {}

fixtures.singleMetric = [[
version: 2
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: RxBt
          label: Pack
          unit: V
          precision: 1
          rangeMin: 18
          rangeMax: 25.2
          warning: 21.0
          critical: 19.8
      accent: cyan
      visual: bar
]]

fixtures.overlap = [[
version: 2
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
    colSpan: 2
    rowSpan: 1
]]

fixtures.multiPanel = [[
version: 2
grid:
  columns: 4
  rows: 4
panels:
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

fixtures.REFERENCE_LAYOUT = [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: RxBt
          label: Pack
          unit: V
          precision: 1
          rangeMin: 18
          rangeMax: 25.2
          warning: 21.0
          critical: 19.8
      accent: cyan
      visual: bar
  - id: current
    type: metric
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      metrics:
        - source: Curr
          label: Current
          rangeMin: 0
          rangeMax: 120
          warning: 90
          critical: 110
      accent: orange
      visual: bar
  - id: altitude
    type: metric
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      metrics:
        - source: Alt
          label: Altitude
          rangeMin: 0
          rangeMax: 400
          warning: 250
          critical: 350
      accent: green
      visual: radial
  - id: pulse
    type: heartbeat
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      label: HEARTBEAT
      accent: amber
  - id: secondary
    type: placeholder
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      label: PHASE 1
      subtitle: DESIGN SYSTEM
      accent: green
]]

fixtures.CORE_LAYOUT = [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: countdown
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 0
      warning: 120
      critical: 30
  - id: countup
    type: flight-timer
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 1
  - id: mode
    type: flight-mode
    col: 0
    row: 1
    colSpan: 1
    rowSpan: 1
  - id: battery
    type: tx-battery
    col: 1
    row: 1
    colSpan: 1
    rowSpan: 1
    config:
      packEmpty: 6.6
      packFull: 8.4
      warning: 7.0
      critical: 6.8
  - id: gv
    type: metric
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      metrics:
        - source: gvar2
          label: GV2
          precision: 0
          rangeMin: -100
          rangeMax: 100
      visual: bar
  - id: identity
    type: model-identity
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      presentation: both
      showLabels: true
  - id: trims
    type: trim-panel
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 1
    config:
      readout: raw
  - id: dial
    type: metric
    col: 2
    row: 3
    colSpan: 1
    rowSpan: 1
    config:
      metrics:
        - source: Curr
          label: Current
          rangeMin: 0
          rangeMax: 120
      visual: radial
  - id: swing
    type: metric
    col: 3
    row: 3
    colSpan: 1
    rowSpan: 1
    config:
      metrics:
        - source: gvar1
          precision: 1
          rangeMin: -100
          rangeMax: 100
      visual: bar
]]

fixtures.TELEMETRY_LAYOUT = [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: rx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels
      label: Pack
      visual: bar
      cellWarning: 3.5
      cellCritical: 3.3
  - id: link
    type: link-status
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      rssiSource: RSSI
      qualitySource: RQly
      # Stated, not `auto`: the thresholds below are percentages, and a
      # threshold whose unit depends on which source resolved first is
      # refused at load.
      reading: quality
      qualityWarning: 50
      qualityCritical: 30
      extrema: source
      extremaSource: RQly-
  - id: elrs
    type: link-status
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      rssiSource: 1RSS
      qualitySource: RQly
      reading: rssi
      barMin: -110
      barMax: -30
      rssiWarning: -90
      rssiCritical: -100
  - id: nav
    type: navigation
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: GPS
      label: Nav
      presentation: detailed
  - id: native
    type: navigation
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: GPS2
      label: Native
      presentation: compass
]]

return fixtures
