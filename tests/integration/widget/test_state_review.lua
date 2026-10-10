-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
fixture.reset()
local context = fixture.createLoaded(nil, { Layout = "review-state", Theme = "modern-dark" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(#context.panels, 6)
fixture.assertNoOverlap(context)

for _, id in ipairs({ "compact", "tall", "wide", "three-readings", "three-wide", "unmapped" }) do
    assert(fixture.instanceOf(context, id), "missing review panel " .. id)
end

local three = fixture.instanceOf(context, "three-readings")
local compact = fixture.instanceOf(context, "compact")
local unmapped = fixture.instanceOf(context, "unmapped")
fixture.radio.values[305] = -1024
fixture.radio.values[300] = 0
fixture.radio.values[301] = -1024
fixture.pump(context, 40)
assertions.assertEqual(compact.text, "DISARMED")
assertions.assertEqual(three.supporting[2].properties.text, "RATE MID")
assertions.assertEqual(three.supporting[3].properties.text, "FLAP UP")
assertions.assertEqual(unmapped.stateName, "unavailable")

fixture.radio.values[305] = 1024
fixture.radio.values[300] = 1024
fixture.radio.values[301] = 1024
fixture.pump(context, 40)
assertions.assertEqual(compact.text, "ARMED")
assertions.assertEqual(three.supporting[2].properties.text, "RATE HIGH")
assertions.assertEqual(three.supporting[3].properties.text, "FLAP DOWN")
assertions.assertEqual(unmapped.stateName, "normal")

fixture.radio.values[305] = nil
fixture.pump(context, 40)
assertions.assertEqual(compact.text, "--")
assertions.assertEqual(compact.stateName, "unavailable")
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
