-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local indicator = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/variable-indicator.lua"))()
local primitives = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/primitives.lua"))()

local function testNormalization()
    assertions.assertEqual(indicator.visual("radial"), "radial")
    assertions.assertEqual(indicator.visual("sparkline"), "none")
    assertions.assertEqual(indicator.visual(nil), "none")

    local range = { value = 150, min = 0, max = 100 }
    assertions.assertEqual(indicator.fraction("bar", range, primitives.signedFraction), 1)
    assertions.assertEqual(indicator.format(range.value, 0), "150")

    local bipolar = { value = -25, min = -50, max = 100 }
    assertions.assertEqual(indicator.fraction("bipolar-bar", bipolar, primitives.signedFraction), -0.5)
    assertions.assertEqual(
        indicator.fraction("bar", { value = 25, min = 0, max = 100 }, primitives.signedFraction),
        0.25
    )
    assertions.assertEqual(indicator.fraction("radial", { value = nil, min = 0, max = 100 }, primitives.signedFraction), 0)
    assertions.assertEqual(indicator.fraction("bar", { value = 5, min = 5, max = 5 }, primitives.signedFraction), 0)
end

local function testFormattingAndRange()
    assertions.assertEqual(indicator.crossesZero({ min = -100, max = 100 }), true)
    assertions.assertEqual(indicator.crossesZero({ min = 0, max = 100 }), false)
    assertions.assertEqual(indicator.crossesZero({ min = -100, max = 0 }), false)
    assertions.assertEqual(indicator.format(4.5, 1), "4.5")
    assertions.assertEqual(indicator.format(4.5678, 9), "4.568")
    assertions.assertEqual(indicator.format(nil, 1), "--")
    assertions.assertEqual(indicator.format(0 / 0, 1), "--")
end

local function run()
    testNormalization()
    testFormattingAndRange()
end

run()
