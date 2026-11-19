-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local definition = fixture.module("main.lua")

local function metricPanel(id, col, warning)
    return string.format(
        [[
  - id: %s
    type: metric
    col: %d
    row: 0
    colSpan: 1
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          rangeMax: 500
          warning: %d
]],
        id,
        col,
        warning
    )
end

local function testFirstPanelInLayoutOrderWins()
    fixture.reset()
    local path = fixture.makeWidget(
        "thresholds",
        "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n"
            .. metricPanel("high", 0, 300)
            .. metricPanel("low", 1, 100)
            .. [[
  - id: rx
    type: rx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      cellWarning: 3.6
      cellCritical: 3.4
]]
    )
    local context = fixture.createLoaded(nil, { Layout = "main", Theme = "modern-dark" }, path, definition)
    fixture.pump(context, 80)
    local telemetry = context.serviceRuntime.byId.telemetry
    local function altWarning()
        local spec = telemetry:thresholds("Alt")
        return spec and spec.warning
    end
    assertEqual(altWarning(), 300, "the first panel in the layout wins")
    assertEqual(telemetry:thresholds("VCel").critical, 3.4)

    -- An App-mode rebuild appends the panel to build order; layout order holds.
    local panels = context.document.panels
    context.dashboardLoader.buildPanel(context, panels[1])
    assertEqual(context.panels[#context.panels].placement.id, "high", "the rebuild must land last in build order")
    assertEqual(altWarning(), 300, "a rebuilt panel keeps its place")

    panels[1], panels[2] = panels[2], panels[1]
    assertEqual(altWarning(), 100, "moving a panel in the layout changes the winner")

    -- A draft panel the layout does not hold yet sets nothing.
    context.dashboardLoader.buildPanel(context, {
        id = "draft",
        type = "metric",
        col = 0,
        row = 2,
        colSpan = 1,
        rowSpan = 2,
        config = { metrics = { { source = "GSpd", rangeMax = 100, warning = 50 } } },
    }, nil, true)
    assertEqual(telemetry:thresholds("GSpd"), nil, "an unsaved panel registered thresholds")
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    fixture.reset()
end

testFirstPanelInLayoutOrderWins()
