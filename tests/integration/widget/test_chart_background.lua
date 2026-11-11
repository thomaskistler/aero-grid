-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
fixture.reset()
for index = 1, 3 do
    fixture.radio.fields["B" .. index] = { id = 5100 + index, name = "B" .. index, unit = 1 }
    fixture.radio.values[5100 + index] = index
end
fixture.radioMock.indexFields()
local file = assert(hostIo.open(root .. "/build/test-widget-fixture/layouts/chart-background.yaml", "w"))
file:write([[
version: 5
grid:
  columns: 4
  rows: 4
panels:
  - id: chart
    type: chart
    col: 0
    row: 0
    colSpan: 4
    rowSpan: 2
    config:
      armSwitch: SAv
      metrics:
        - source: B1
        - source: B2
        - source: B3
]])
file:close()
local context = definition.create(
    { x = 0, y = 0, w = 480, h = 272 },
    { Layout = "chart-background", Theme = "modern-dark" },
    root .. "/build/test-widget-fixture/"
)
local worst = 0
local function pump(count, hidden)
    for _ = 1, count do
        fixture.tick(5)
        for index = 1, 3 do
            fixture.radio.values[5100 + index] = (getTime() * index * 7) % 997 - 400
        end
        local counted = 0
        debug.sethook(function()
            counted = counted + 1
        end, "", 1)
        if hidden then
            definition.background(context)
        else
            definition.refresh(context)
        end
        debug.sethook()
        worst = math.max(worst, counted)
        fixture.lvglMock.settle()
    end
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
end
fixture.radio.values[300] = 0
pump(200)
fixture.radio.values[300] = 1024
pump(200)
local panel = context.panels[1].instance
assert(panel.columnRenderer and panel.columnConsumers, "the chart must be drawing before it is hidden")
-- Twenty seconds behind another radio screen.
pump(400, true)
for _, owner in ipairs(panel.columnConsumers) do
    assert(#owner.pending <= 3, "hidden charts must keep consuming telemetry")
    assert(#owner.map.dirtyList <= 3, "hidden charts must keep their columns current")
end
worst = 0
pump(40)
assert(worst < 16000, string.format("returning to a hidden chart cost %d Lua instructions in one callback", worst))
print(string.format("Hidden charts stay current; first visible callbacks peak at %d Lua instructions", worst))
