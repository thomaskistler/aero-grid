-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
fixture.reset()
fixture.radio.rssi = 0
local context = fixture.createLoaded(nil, { Layout = "Default", Theme = "modern-dark" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(#context.panels, 9)
fixture.assertNoOverlap(context)
for id, position in pairs({
    ["flight-clock"] = { 0, 0, 2, 1 },
    ["transmitter-battery"] = { 3, 0, 1, 1 },
    identity = { 2, 2, 2, 2 },
    mode = { 2, 0, 1, 1 },
}) do
    local entry = assert(fixture.entryById(context, id))
    assertions.assertEqual(entry.placement.col, position[1])
    assertions.assertEqual(entry.placement.row, position[2])
    assertions.assertEqual(entry.placement.colSpan, position[3])
    assertions.assertEqual(entry.placement.rowSpan, position[4])
end
local timer = fixture.instanceOf(context, "flight-clock")
local previous = timer.text
fixture.radio.timers[0].value = 120
fixture.pump(context, 40)
assert(timer.text ~= previous, "timer must advance without receiver telemetry")
assertions.assertEqual(fixture.instanceOf(context, "transmitter-battery").stateName, "normal")
