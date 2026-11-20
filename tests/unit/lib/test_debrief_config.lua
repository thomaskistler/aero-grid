-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local debrief = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/debrief_config.lua"))()

local function series(source, statistic)
    return { source = source, statistic = statistic or "min" }
end

local function tile(title, entries)
    return { title = title, colSpan = 2, rowSpan = 2, series = entries or { series("VCel") } }
end

local function hasMessage(errors, text)
    for _, message in ipairs(errors) do
        if string.find(message, text, 1, true) then
            return true
        end
    end
    return false
end

local function testValidSection()
    local section, errors = debrief.validate({
        tiles = {
            {
                title = "RX battery",
                colSpan = 4,
                rowSpan = 1,
                series = {
                    {
                        source = "VCel",
                        statistic = "min",
                        label = "low",
                        rangeMin = 3,
                        rangeMax = 4.2,
                        unit = "V",
                        precision = 2,
                        accent = "cyan",
                    },
                    series("RxBt", "delta"),
                },
            },
            tile("Link"),
        },
    })
    assert(#errors == 0, table.concat(errors, "; "))
    assert(#section.tiles == 2)
    assert(section.tiles[1].colSpan == 4 and section.tiles[1].rowSpan == 1)
    assert(section.tiles[1].series[1].precision == 2)
    assert(section.tiles[2].colSpan == 2 and section.tiles[2].rowSpan == 2)
end

local function testEmptyAndMalformedSections()
    local empty, errors = debrief.validate({ tiles = {} })
    assert(empty and #empty.tiles == 0 and #errors == 0, "an empty debrief is valid")
    local missing = debrief.validate({})
    assert(missing and #missing.tiles == 0)
    local none
    none, errors = debrief.validate("tiles")
    assert(none == nil and hasMessage(errors, "mapping"))
    none, errors = debrief.validate({ tile("A") })
    assert(none == nil and hasMessage(errors, "mapping"), "a sequence is not a section")
    local unordered
    unordered, errors = debrief.validate({ tiles = { title = "A" } })
    assert(#unordered.tiles == 0 and hasMessage(errors, "sequence"))
end

local function testInvalidEntriesAreDropped()
    local section, errors = debrief.validate({
        tiles = {
            { series = { series("VCel") } },
            { title = "Size", colSpan = 3, rowSpan = 2, series = { series("VCel") } },
            tile("None", {}),
            tile("Mixed", {
                series("RQly"),
                { source = "Mrgn", statistic = "last" },
                { source = "", statistic = "min" },
                { source = "Drop", statistic = "delta", precision = 1.5 },
                { source = "Alt", statistic = "max", rangeMin = 5, rangeMax = 5 },
                { source = "Alt", statistic = "max", accent = "red" },
                series("Drop", "delta"),
                series("FDst", "delta"),
                series("HDst", "max"),
            }),
        },
    })
    assert(#section.tiles == 1 and section.tiles[1].title == "Mixed")
    local kept = section.tiles[1].series
    assert(#kept == 3 and kept[1].source == "RQly" and kept[3].source == "FDst")
    assert(hasMessage(errors, "debrief tile 1: title is required"))
    assert(hasMessage(errors, "debrief tile 2: size"))
    assert(hasMessage(errors, "debrief tile 3: has no valid series"))
    assert(hasMessage(errors, "debrief tile 4: series 2: statistic must be"))
    assert(hasMessage(errors, "series 3: source is invalid"))
    assert(hasMessage(errors, "series 4: precision is invalid"))
    assert(hasMessage(errors, "series 5: rangeMax must be greater"))
    assert(hasMessage(errors, "series 6: accent is invalid"))
    assert(hasMessage(errors, "more than 3 series"))
end

local function testUnknownSettingsAndRequiredSizes()
    local entry = tile("Future")
    entry.stripe = { style = "dashed" }
    entry.series[1].future = { mode = "new" }
    local section, errors, warnings = debrief.validate({ tiles = { entry } })
    assert(#errors == 0 and #warnings == 2)
    assert(hasMessage(warnings, "stripe is not a tile setting"))
    assert(hasMessage(warnings, "series 1: future is not a series setting"))
    assert(section.tiles[1].stripe.style == "dashed")
    assert(section.tiles[1].series[1].future.mode == "new")
    for _, size in ipairs({ {}, { colSpan = 4 }, { rowSpan = 2 } }) do
        size.title, size.series = "Missing size", { series("VCel") }
        local normalized, problems = debrief.validate({ tiles = { size } })
        assert(#normalized.tiles == 0 and hasMessage(problems, "size must be"))
    end
    local sparse = { [0] = series("VCel"), [2] = series("RQly") }
    local normalized, problems = debrief.validate({ tiles = { tile("Bad list", sparse) } })
    assert(#normalized.tiles == 0 and hasMessage(problems, "series must be a sequence"))
end

local function testTileLimit()
    local tiles = { { title = "Bad", series = {} } }
    for index = 1, 14 do
        tiles[#tiles + 1] = tile("Tile " .. index)
    end
    local section, errors = debrief.validate({ tiles = tiles })
    assert(#section.tiles == debrief.MAX_TILES and debrief.MAX_TILES == 12)
    assert(section.tiles[12].title == "Tile 12", "the limit counts valid tiles")
    assert(hasMessage(errors, "more than 12 tiles"))
    assert(not debrief.canAdd(section))
    local added, addError = debrief.addTile(section)
    assert(added == false and string.find(addError, "at most 12", 1, true))
    added, addError = debrief.pasteTile(section, 1, 2, true, true)
    assert(added == false and string.find(addError, "at most 12", 1, true))
    assert(debrief.pasteTile(section, 1, 12, true, false) == 12, "a move is allowed at the limit")
    assert(section.tiles[12].title == "Tile 1")
end

local function titles(section)
    local result = {}
    for index, entry in ipairs(section.tiles) do
        result[index] = entry.title
    end
    return table.concat(result, ",")
end

local function testDraftOperations()
    local section = { tiles = {} }
    assert(debrief.addTile(section) == 1)
    local added = section.tiles[1]
    assert(added.title == "Tile 1" and debrief.size(added) == "2x2")
    assert(#added.series == 1 and added.series[1].statistic == "min" and added.series[1].source == nil)
    local _, errors = debrief.validate(section)
    assert(hasMessage(errors, "series 1: source is required"), "a new tile needs a source before Save")

    assert(debrief.setTileValue(section, 1, "title", "A"))
    local ok, message = debrief.setTileValue(section, 1, "title", "")
    assert(not ok and message == "Title is required" and added.title == "A")
    assert(debrief.setTileValue(section, 1, "size", "4x1"))
    assert(added.colSpan == 4 and added.rowSpan == 1 and debrief.size(added) == "4x1")
    ok, message = debrief.setTileValue(section, 1, "size", "3x2")
    assert(not ok and message and debrief.size(added) == "4x1", "a rejected size leaves the tile unchanged")
    assert(not debrief.setTileValue(section, 1, "colSpan", 2))

    assert(debrief.setSeriesValue(section, 1, 1, "source", "VCel"))
    assert(debrief.setSeriesValue(section, 1, 1, "label", "low"))
    assert(debrief.setSeriesValue(section, 1, 1, "label", nil), "a cleared label falls back")
    assert(added.series[1].label == nil)
    ok, message = debrief.setSeriesValue(section, 1, 1, "source", nil)
    assert(not ok and message == "Source is required")
    assert(not debrief.setSeriesValue(section, 1, 1, "statistic", "last"))
    assert(not debrief.setSeriesValue(section, 1, 1, "precision", 1.5))
    assert(not debrief.setSeriesValue(section, 1, 1, "accent", "red"))
    assert(not debrief.setSeriesValue(section, 1, 2, "unit", "V"))

    assert(debrief.addSeries(section, 1) == 2 and debrief.addSeries(section, 1) == 3)
    assert(not debrief.addSeries(section, 1), "at most three series")
    assert(debrief.removeSeries(section, 1, 2) and debrief.removeSeries(section, 1, 2))
    assert(not debrief.removeSeries(section, 1, 1), "a tile keeps one series")

    debrief.addTile(section)
    debrief.addTile(section)
    debrief.setTileValue(section, 2, "title", "B")
    debrief.setTileValue(section, 3, "title", "C")
    assert(debrief.pasteTile(section, 3, 1, false, false) == 1 and titles(section) == "C,A,B")
    assert(debrief.pasteTile(section, 1, 3, true, false) == 3 and titles(section) == "A,B,C")
    assert(debrief.pasteTile(section, 1, 2, true, false) == 2 and titles(section) == "B,A,C")
    assert(debrief.pasteTile(section, 2, 2, false, false) == 2 and titles(section) == "B,A,C")
    assert(debrief.pasteTile(section, 2, 2, true, false) == 2 and titles(section) == "B,A,C")
    assert(
        debrief.pasteTile(section, 3, 3, true, false) == 3 and titles(section) == "B,A,C",
        "moving the last tile onto itself"
    )
    local single = { tiles = { { title = "S" } } }
    assert(debrief.pasteTile(single, 1, 1, true, false) == 1 and #single.tiles == 1 and single.tiles[1].title == "S")
    assert(debrief.pasteTile(section, 2, 3, true, true) == 4 and titles(section) == "B,A,C,A")
    section.tiles[4].series[1].source = "RQly"
    assert(section.tiles[2].series[1].source == "VCel", "a pasted copy is independent")
    assert(not debrief.pasteTile(section, 9, 1, true, true))

    assert(debrief.removeTile(section, 1))
    assert(not debrief.removeTile(section, 5))
    assert(titles(section) == "A,C,A")
end

local function run()
    testValidSection()
    testEmptyAndMalformedSections()
    testInvalidEntriesAreDropped()
    testUnknownSettingsAndRequiredSizes()
    testTileLimit()
    testDraftOperations()
end

run()
