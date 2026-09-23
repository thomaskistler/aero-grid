-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local trims = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/trim-panel.lua"))()

local function testIndicatorSelection()
    assertions.assertEqual(trims.indicatorCount("single"), 1)
    assertions.assertEqual(trims.indicatorCount("pair"), 2)
    assertions.assertEqual(trims.indicatorCount("all"), 4)
    assertions.assertEqual(trims.indicatorCount("unknown"), 1)

    local wide = { x = 0, y = 0, w = 200, h = 60 }
    local tall = { x = 0, y = 0, w = 60, h = 200 }
    assertions.assertEqual(trims.isVertical({ orientation = "auto" }, 1, wide), false)
    assertions.assertEqual(trims.isVertical({ orientation = "auto" }, 1, tall), true)
    assertions.assertEqual(trims.isVertical({ orientation = "vertical" }, 1, wide), true)
    assertions.assertEqual(
        trims.isVertical({ orientation = "vertical", orientation2 = "horizontal" }, 2, wide),
        false
    )
end

local function testCaptionsAndValues()
    assertions.assertEqual(trims.captionFor("trim-ail"), "AIL")
    assertions.assertEqual(trims.captionFor("trim-t5"), "T5")
    assertions.assertEqual(trims.captionFor("sa"), "SA")
    assertions.assertEqual(trims.captionFor(nil), "--")

    local right = {
        available = true,
        raw = 240,
        value = 30,
        fraction = 0.234375,
        centered = false,
        threePosition = false,
    }
    assertions.assertEqual(trims.valueText({ readout = "percent" }, right), "+23%")
    assertions.assertEqual(trims.valueText({ readout = "raw" }, right), "+30")
    assertions.assertEqual(trims.valueText({ readout = "none" }, right), "")

    local centered = { available = true, raw = 0, value = 0, fraction = 0, centered = true, threePosition = false }
    assertions.assertEqual(trims.valueText({ readout = "percent" }, centered), "0%")
    assertions.assertEqual(trims.valueText({ readout = "raw" }, centered), "0")
    assertions.assertEqual(trims.valueText({ readout = "percent" }, nil), "--")

    local toggle = {
        available = true,
        raw = 1024,
        value = 128,
        fraction = 1,
        centered = false,
        threePosition = true,
    }
    assertions.assertEqual(trims.valueText({ readout = "percent" }, toggle), "3P HI")
    toggle.raw, toggle.centered, toggle.fraction = 0, true, 0
    assertions.assertEqual(trims.valueText({ readout = "percent" }, toggle), "3P MID")
    toggle.raw, toggle.centered, toggle.fraction = -1024, false, -1
    assertions.assertEqual(trims.valueText({ readout = "raw" }, toggle), "3P LO")
end

local function run()
    testIndicatorSelection()
    testCaptionsAndValues()
end

run()
