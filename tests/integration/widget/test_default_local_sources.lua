-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
fixture.reset()
function getOutputValue(index)
    return index == 2 and -1024 or 0
end
fixture.radio.rssi = 0
local context = fixture.createLoaded(nil, { Layout = "Default", Theme = "modern-dark" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
local timer = fixture.instanceOf(context, "flight-clock")
local previous = timer.text
fixture.radio.timers[0].value = 120
fixture.pump(context, 40)
assert(timer.text ~= previous, "timer must advance without receiver telemetry")
assertions.assertEqual(fixture.instanceOf(context, "transmitter-battery").stateName, "normal")
local outputs = fixture.instanceOf(context, "outputs")
assert(outputs.area.count >= 4)
assertions.assertEqual(#outputs.rows, outputs.area.count)
for _, row in ipairs(outputs.rows) do
    assert(row.feed.available, "channel outputs must work without receiver telemetry")
end
assertions.assertEqual(outputs.rows[3].feed.raw, -1024)
