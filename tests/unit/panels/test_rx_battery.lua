-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local moduleLoader = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local rxBattery = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/rx-battery.lua"))()
local primitives = moduleLoader("lib/primitives.lua")

local function testCellShapesAndReadings()
    local out = {}
    assertions.assertEqual(rxBattery.summarize(nil, out).shape, "none")
    assertions.assertEqual(rxBattery.summarize(4.09, out).shape, "number")
    assertions.assertEqual(rxBattery.summarize("4.09", out).shape, "invalid")
    assertions.assertEqual(rxBattery.summarize({}, out).shape, "empty")

    local summary = rxBattery.summarize({ 4.11, 3.25, 4.09, 4.12 }, out)
    assertions.assertEqual(summary.shape, "cells")
    assertions.assertEqual(summary.count, 4)
    assertions.assertEqual(summary.lowest, 3.25)
    assert(math.abs(summary.pack - 15.57) < 0.001)

    local settings = {
        sourceType = "cells",
        reading = "cell",
        cellEmpty = 3.2,
        cellFull = 4.2,
        warning = 3.6,
        critical = 3.4,
    }
    assertions.assertEqual(rxBattery.primaryValue(settings, summary), 3.25)
    assertions.assertEqual(rxBattery.fraction(settings, 3.2, 4, primitives), 0)
    assertions.assertEqual(rxBattery.fraction(settings, 4.2, 4, primitives), 1)
    assert(math.abs(rxBattery.fraction(settings, 3.7, 4, primitives) - 0.5) < 0.001)
    assertions.assertEqual(rxBattery.resolveState(settings, 3.25, 3.25, false), "critical")
    assertions.assertEqual(rxBattery.resolveState(settings, 3.5, 3.5, false), "warning")
    assertions.assertEqual(rxBattery.resolveState(settings, 3.9, 3.9, false), "normal")
    assertions.assertEqual(rxBattery.resolveState(settings, 3.9, 3.9, true), "stale")
    assertions.assertEqual(rxBattery.resolveState(settings, nil, nil, false), "unavailable")

    assertions.assertEqual(rxBattery.countVariants({ shape = "empty" }, { showCount = true })[1], "NO CELLS")
    assertions.assertEqual(rxBattery.countVariants({ shape = "number" }, { showCount = true })[1], "CELLS ERR")
    assertions.assertEqual(rxBattery.countVariants({ shape = "cells", count = 4 }, { showCount = true })[1], "4S")
    assertions.assertEqual(
        rxBattery.packVariants({ pack = 16.4 }, { showPack = true, reading = "cell" })[1],
        "16.4V PACK"
    )
end

local function testPackSourceAndAutomaticCount()
    local settings = {
        sourceType = "pack",
        reading = "cell",
        cells = 0,
        showPack = true,
        showCount = true,
        cellEmpty = 3.2,
        cellFull = 4.2,
        warning = 3.6,
        critical = 3.4,
    }
    assertions.assertEqual(#rxBattery.validateSettings(settings), 0)
    assertions.assertEqual(rxBattery.estimateCount(16.8, 4.2), 4)
    assertions.assertEqual(rxBattery.estimateCount(25.2, 4.2), 6)
    assertions.assertEqual(rxBattery.estimateCount(480, 4.2), nil)
    assertions.assertEqual(rxBattery.estimateCount(16.8, 0), nil)

    local context = {
        settings = settings,
        summary = {},
        feed = { available = true, raw = 16.8, stale = false },
    }
    rxBattery.gather(context)
    assertions.assertEqual(context.estimatedCells, 4)
    assertions.assertEqual(context.primary, 4.2)
    assertions.assertEqual(context.perCell, 4.2)
    assertions.assertEqual(context.summary.estimated, true)
    assertions.assertEqual(rxBattery.countVariants(context.summary, settings)[1], "4S EST")

    context.feed.raw = 15.6
    rxBattery.gather(context)
    assertions.assertEqual(context.estimatedCells, 4, "automatic count was recalculated as voltage fell")
    assertions.assertEqual(context.primary, 3.9)
    assertions.assertEqual(rxBattery.resolveState(settings, context.primary, context.perCell, context.stale), "normal")

    context.feed.stale = true
    rxBattery.gather(context)
    assertions.assertEqual(context.estimatedCells, 4, "stale reading lost its held count")
    assertions.assertEqual(rxBattery.resolveState(settings, context.primary, context.perCell, context.stale), "stale")

    context.feed.stale = false
    context.feed.raw = 12.6
    rxBattery.gather(context)
    assertions.assertEqual(context.estimatedCells, 3, "reconnected source did not start a new estimate")
    assertions.assertEqual(context.primary, 4.2)

    local pack = rxBattery.summarizePack(16.4, 4, {})
    settings.cells = 4
    settings.reading = "pack"
    assertions.assertEqual(pack.shape, "pack")
    assertions.assertEqual(pack.count, 4)
    assertions.assertEqual(rxBattery.primaryValue(settings, pack), 16.4)
    assertions.assertEqual(rxBattery.countVariants(pack, settings)[1], "4S")
    assertions.assertEqual(rxBattery.packVariants(pack, settings)[1], "4.10V AVG")
    assert(math.abs(rxBattery.fraction(settings, 15, 4, primitives) - 0.55) < 0.001)
    settings.reading = "cell"
    assertions.assertEqual(rxBattery.primaryValue(settings, pack), 4.1)
    assertions.assertEqual(rxBattery.packVariants(pack, settings)[1], "16.4V PACK")

    local empty = {}
    for _, raw in ipairs({ 0, -1, math.huge, 0 / 0, "16.4", { 4.1, 4.1 } }) do
        assertions.assertEqual(rxBattery.summarizePack(raw, 4, empty).shape, "invalid")
        assertions.assertEqual(empty.pack, nil)
    end
    assertions.assertEqual(rxBattery.summarizePack(nil, 4, empty).shape, "none")
end

local function testConfigurationValidation()
    local settings = {
        sourceType = "pack",
        reading = "cell",
        cells = 0,
        cellFull = 4.2,
        warning = 3.6,
        critical = 3.4,
        cellEmpty = 3.2,
    }
    assertions.assertEqual(#rxBattery.validateSettings(settings), 0)
    for _, count in ipairs({ -1, 1.5, 17, math.huge, 0 / 0 }) do
        settings.cells = count
        assert(#rxBattery.validateSettings(settings) > 0, "invalid pack count was accepted")
    end
    settings.cells = 4
    settings.cellFull = 3.5
    assert(#rxBattery.validateSettings(settings) > 0, "incoherent voltage levels were accepted")
    settings.cellFull = 4.2
    settings.sourceType = "cells"
    assert(#rxBattery.validateSettings(settings, nil, { cells = 4 }) > 0, "cells source accepted an override count")
    assertions.assertEqual(#rxBattery.validateSettings(settings, { rowSpan = 1 }, { showPack = true }), 1)
end

local function run()
    testCellShapesAndReadings()
    testPackSourceAndAutomaticCount()
    testConfigurationValidation()
end

run()
