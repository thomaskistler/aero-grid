-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local cellBattery = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/cell-battery.lua"))()

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

local function testPackSource()
    local settings = {
        sourceType = "pack",
        reading = "pack",
        cells = 4,
        showPack = true,
        showCount = true,
        cellEmpty = 3.3,
        cellFull = 4.2,
        warning = 3.5,
        critical = 3.3,
    }
    assertions.assertEqual(#cellBattery.validateSettings(settings), 0)
    local summary = cellBattery.summarizePack(16.4, 4, {})
    assertions.assertEqual(summary.shape, "pack")
    assertions.assertEqual(summary.count, 4)
    assertions.assertEqual(summary.lowest, nil, "pack voltage must not invent a lowest cell")
    assertions.assertEqual(cellBattery.primaryValue(settings, summary), 16.4)
    assertions.assertEqual(cellBattery.countVariants(summary, settings)[1], "4S")
    assertions.assertEqual(cellBattery.packVariants(summary, settings)[1], "4.10V AVG")
    assert(math.abs(cellBattery.fraction(settings, 15, 4) - 0.5) < 0.001)
    settings.reading = "average"
    assert(math.abs(cellBattery.primaryValue(settings, summary) - 4.1) < 0.001)
    assertions.assertEqual(cellBattery.packVariants(summary, settings)[1], "16.4V PACK")

    local context = {
        settings = settings,
        summary = {},
        feed = { available = true, raw = 13.6, stale = false },
    }
    cellBattery.gather(context)
    assertions.assertEqual(context.summary.lowest, nil)
    assertions.assertEqual(
        cellBattery.resolveState(settings, context.primary, context.perCell, context.stale),
        "warning"
    )
    context.feed.raw = 13.2
    cellBattery.gather(context)
    assertions.assertEqual(
        cellBattery.resolveState(settings, context.primary, context.perCell, context.stale),
        "critical"
    )
    context.feed.stale = true
    cellBattery.gather(context)
    assertions.assertEqual(cellBattery.resolveState(settings, context.primary, context.perCell, context.stale), "stale")
    context.feed.available = false
    cellBattery.gather(context)
    assertions.assertEqual(context.primary, nil)
    assertions.assertEqual(context.summary.pack, nil)

    for _, raw in ipairs({ 0, -1, math.huge, 0 / 0, "16.4", { 4.1, 4.1 } }) do
        assertions.assertEqual(cellBattery.summarizePack(raw, 4, summary).shape, "invalid")
        assertions.assertEqual(summary.pack, nil)
        assertions.assertEqual(cellBattery.countVariants(summary, settings)[1], "VOLT ERR")
    end
    assertions.assertEqual(cellBattery.summarizePack(nil, 4, summary).shape, "none")

    for _, count in ipairs({ 0, -1, 1.5, 17, math.huge, 0 / 0 }) do
        settings.cells = count
        assert(#cellBattery.validateSettings(settings) > 0, "invalid pack count was accepted")
    end
    settings.cells = nil
    assert(#cellBattery.validateSettings(settings) > 0, "missing pack count was accepted")
    settings.cells = 4
    settings.reading = "lowest"
    assert(#cellBattery.validateSettings(settings) > 0, "a guessed lowest cell was accepted")
    settings.reading = "average"
    settings.lowestSource = "Cels-"
    assert(#cellBattery.validateSettings(settings) > 0, "pack mode accepted a cells-monitor-only setting")
    settings.lowestSource = ""
    assertions.assertEqual(#cellBattery.validateSettings(settings, { rowSpan = 1 }, { showPack = true }), 1)
end

local function run()
    testCellShapes()
    testCellReadings()
    testPackSource()
end

run()
