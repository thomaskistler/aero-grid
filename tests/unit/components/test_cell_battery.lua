-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local cellBattery = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/cell-battery.lua"))()

local function testCellShapes()
    local out = {}
    assertions.assertEqual(cellBattery.summarize(nil, out).shape, "none")
    assertions.assertEqual(cellBattery.summarize(4.09, out).shape, "number")
    assertions.assertEqual(cellBattery.summarize("4.09", out).shape, "invalid")
    assertions.assertEqual(cellBattery.summarize({}, out).shape, "empty")

    local pack = cellBattery.summarize({ 4.11, 4.13, 4.09, 4.12 }, out)
    assertions.assertEqual(pack.shape, "cells")
    assertions.assertEqual(pack.count, 4)
    assertions.assertEqual(pack.lowest, 4.09)
    assertions.assertEqual(pack.highest, 4.13)
    assert(math.abs(pack.pack - 16.45) < 0.001)

    local mixed = cellBattery.summarize({ 4.11, 0, 4.12, 99 }, out)
    assertions.assertEqual(mixed.count, 2)
    assertions.assertEqual(mixed.rejected, 2)
    assertions.assertEqual(mixed.lowest, 4.11)
    assertions.assertEqual(cellBattery.summarize({ 0, -1, 99 }, out).shape, "invalid")
end

local function testCellReadings()
    local summary = cellBattery.summarize({ 4.11, 3.25, 4.09, 4.12 }, {})
    local settings = { reading = "lowest", cellEmpty = 3.3, cellFull = 4.2, warning = 3.5, critical = 3.3 }

    assertions.assertEqual(cellBattery.primaryValue(settings, summary), 3.25)
    assertions.assertEqual(cellBattery.primaryValue(settings, summary, 3.11), 3.11)
    assertions.assertEqual(cellBattery.fraction(settings, 3.3, 4), 0)
    assertions.assertEqual(cellBattery.fraction(settings, 4.2, 4), 1)
    assert(math.abs(cellBattery.fraction(settings, 3.75, 4) - 0.5) < 0.001)
    assertions.assertEqual(cellBattery.resolveState(settings, 15.57, 3.25, false), "critical")
    assertions.assertEqual(cellBattery.resolveState(settings, 3.45, 3.45, false), "warning")
    assertions.assertEqual(cellBattery.resolveState(settings, 3.9, 3.9, false), "normal")
    assertions.assertEqual(cellBattery.resolveState(settings, 3.9, 3.9, true), "stale")
    assertions.assertEqual(cellBattery.resolveState(settings, nil, nil, false), "unavailable")

    assertions.assertEqual(cellBattery.countVariants({ shape = "empty" }, { showCount = true })[1], "NO CELLS")
    assertions.assertEqual(cellBattery.countVariants({ shape = "number" }, { showCount = true })[1], "CELLS ERR")
    assertions.assertEqual(cellBattery.countVariants({ shape = "cells", count = 4 }, { showCount = true })[1], "4S")
    assertions.assertEqual(cellBattery.packVariants({ pack = 16.4 }, { showPack = true })[1], "16.4V PACK")
end

local function run()
    testCellShapes()
    testCellReadings()
end

run()
