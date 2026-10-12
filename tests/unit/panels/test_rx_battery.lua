-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local moduleLoader = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local rxBattery = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/rx-battery.lua"))()
local primitives = moduleLoader("lib/primitives.lua")
-- radio/src/translations/untranslated.h, CHAR_DELTA (U+0088).
CHAR_DELTA = "\194\136"

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
        cellWarning = 3.6,
        cellCritical = 3.4,
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
        cellWarning = 3.6,
        cellCritical = 3.4,
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
        cellWarning = 3.6,
        cellCritical = 3.4,
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
    assert(
        #rxBattery.validateSettings(settings, nil, { cells = 4 }) == 0,
        "stored numeric count must be allowed for tables"
    )
    -- Supporting details are preferences the panel sheds where they do not
    -- fit; no span or visualization makes stating them an error.
    local stated = { showPack = true, showCount = true }
    for _, visual in ipairs({ "battery", "bar", "none" }) do
        settings.visual = visual
        for _, span in ipairs({
            { colSpan = 1, rowSpan = 1 },
            { colSpan = 2, rowSpan = 1 },
            { colSpan = 4, rowSpan = 1 },
            { colSpan = 1, rowSpan = 2 },
        }) do
            local messages = rxBattery.validateSettings(settings, span, stated)
            assertions.assertEqual(#messages, 0, table.concat(messages, "; "))
        end
    end
end

local function testSupportingWordings()
    assertions.assertEqual(rxBattery.measureForm({ "4S EST", "4S~", "4S" }), "8S")
    assertions.assertEqual(rxBattery.measureForm({ "16.4V PACK", "16.4V" }), "88.8V")
    assertions.assertEqual(rxBattery.measureForm({ "9.8V PACK", "9.8V" }), "8.8V")
    assertions.assertEqual(rxBattery.measureForm({ "CELLS ERR" }), "CELLS ERR")
    assertions.assertEqual(rxBattery.measureForm({ "" }), "")
    local pack = rxBattery.summarizePack(16.4, 4, {})
    local variants = rxBattery.packVariants(pack, { showPack = true, reading = "pack" })
    assertions.assertEqual(variants[1], "4.10V AVG")
    assertions.assertEqual(variants[2], "4.10V", "the average must have a short form to shed its suffix")
    assertions.assertEqual(rxBattery.packVariants(pack, { showPack = false, reading = "pack" })[1], "")
    assertions.assertEqual(rxBattery.countVariants(pack, { showCount = false })[1], "")
    -- A broken source is named in the count's place whatever the toggle says.
    assertions.assertEqual(rxBattery.countVariants({ shape = "empty" }, { showCount = false })[1], "NO CELLS")
end

local function testVisualizationMetadata()
    local byKey = {}
    for _, setting in ipairs(rxBattery.settings) do
        byKey[setting.key] = setting
    end
    local visual = byKey.visual
    assertions.assertEqual(table.concat(visual.choices, ","), "battery,bar,none", "stored values must stay compatible")
    assertions.assertEqual(table.concat(visual.choiceLabels, ","), "battery,bar,details")
    assert(byKey.sourceType == nil and rxBattery.drawerGroups == nil)
    assertions.assertEqual(byKey.showDelta.default, false)
    assertions.assertEqual(byKey.showPack.label, "Show alt reading")
    for _, key in ipairs({ "showPack", "showCount", "showDelta" }) do
        local condition = byKey[key].visibleWhen
        assert(
            condition and condition.key == "visual" and condition.value == "battery" and condition.invert,
            key .. " must be hidden only for the battery visualization"
        )
    end
    for _, key in ipairs({ "cellFull", "cellEmpty" }) do
        local condition = byKey[key].visibleWhen
        assert(condition.value == "none" and condition.invert, key .. " must be hidden only without a visual")
    end
end

local function testAutomaticShapesAndDelta()
    local settings = { cells = 6, reading = "cell", cellFull = 4.2, showDelta = true, showCount = true }
    local context = { settings = settings, summary = {}, feed = { available = true, raw = { 4.10, 4.11 } } }
    rxBattery.gather(context)
    assertions.assertEqual(context.primary, 4.10)
    assertions.assertEqual(context.summary.count, 2, "table must ignore configured numeric count")
    assertions.assertEqual(rxBattery.countVariants(context.summary, settings)[1], "2S")
    assertions.assertEqual(rxBattery.deltaVariants(context.summary, settings)[1], CHAR_DELTA .. " 0.01v")
    context.feed.stale = true
    rxBattery.gather(context)
    assertions.assertEqual(rxBattery.deltaVariants(context.summary, settings)[1], CHAR_DELTA .. " 0.01v")
    context.feed.stale = false
    context.feed.raw = { 4.10 }
    rxBattery.gather(context)
    assertions.assertEqual(rxBattery.deltaVariants(context.summary, settings)[1], CHAR_DELTA .. " 0.00v")
    for _, raw in ipairs({ {}, { 0, -1 }, { 4.1, "bad" }, 25.2, -1, "bad", math.huge, 0 / 0 }) do
        context.feed.raw = raw
        rxBattery.gather(context)
        assertions.assertEqual(rxBattery.deltaVariants(context.summary, settings)[1], "")
    end
    context.feed.available = false
    rxBattery.gather(context)
    assertions.assertEqual(context.primary, nil)
    assertions.assertEqual(rxBattery.deltaVariants(context.summary, settings)[1], "")
    context.feed.available = true
    context.feed.raw = 25.2
    rxBattery.gather(context)
    assertions.assertEqual(context.summary.shape, "pack")
    assertions.assertEqual(context.primary, 4.2, "numeric sources are pack voltage regardless of previous shape")
    settings.cells = 0
    context.feed.raw = 4.2
    rxBattery.gather(context)
    assertions.assertEqual(context.summary.count, 1, "small numeric voltages remain pack voltage")
    settings.showDelta = false
    context.feed.raw = { 4.1, 4.11 }
    rxBattery.gather(context)
    assertions.assertEqual(rxBattery.deltaVariants(context.summary, settings)[1], "")
    settings.showDelta = true
    settings.cells = 0
    context.feed.raw = 16.8
    context.feed.stale = true
    rxBattery.gather(context)
    assertions.assertEqual(context.estimatedCells, nil, "first stale reading must not estimate")
    context.feed.stale = false
    rxBattery.gather(context)
    assertions.assertEqual(context.estimatedCells, 4)
    context.feed.available = false
    rxBattery.gather(context)
    context.feed.available = true
    context.feed.raw = 12.6
    rxBattery.gather(context)
    assertions.assertEqual(context.estimatedCells, 3, "unavailable then fresh starts a new estimate")
end

local function run()
    testCellShapesAndReadings()
    testPackSourceAndAutomaticCount()
    testConfigurationValidation()
    testSupportingWordings()
    testVisualizationMetadata()
    testAutomaticShapesAndDelta()
end

run()
