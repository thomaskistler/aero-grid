-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local debrief = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/debrief_config.lua"))()

local function series(source, statistic)
    return { source = source, statistic = statistic or "min" }
end

local function tile(title, entries)
    return { title = title, series = entries or { series("VCel") } }
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
    assert(section.tiles[2].colSpan == 2 and section.tiles[2].rowSpan == 2, "tiles default to Compact")
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
            { title = "Extra", stripe = true, series = { series("VCel") } },
            tile("None", {}),
            tile("Mixed", {
                series("RQly"),
                { source = "Mrgn", statistic = "last" },
                { source = "", statistic = "min" },
                { source = "Drop", statistic = "delta", precision = 1.5 },
                { source = "Alt", statistic = "max", rangeMin = 5, rangeMax = 5 },
                { source = "Alt", statistic = "max", accent = "red" },
                { source = "Alt", statistic = "max", color = "cyan" },
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
    assert(hasMessage(errors, "debrief tile 3: stripe is not a tile setting"))
    assert(hasMessage(errors, "debrief tile 4: has no valid series"))
    assert(hasMessage(errors, "debrief tile 5: series 2: statistic is invalid"))
    assert(hasMessage(errors, "series 3: source is invalid"))
    assert(hasMessage(errors, "series 4: precision is invalid"))
    assert(hasMessage(errors, "series 5: rangeMax must be greater"))
    assert(hasMessage(errors, "series 6: accent is invalid"))
    assert(hasMessage(errors, "series 7: color is not a series setting"))
    assert(hasMessage(errors, "more than 3 series"))
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
    local added, addError = debrief.addTile(section, tile("Thirteen"))
    assert(added == false and string.find(addError, "at most 12", 1, true))
end

local function testLabels()
    assert(debrief.label(series("VCel", "min")) == "min")
    assert(debrief.label({ source = "FDst", statistic = "delta", label = "" }) == "delta")
    assert(debrief.label({ source = "FDst", statistic = "delta", label = "flown" }) == "flown")
end

local function testDraftOperations()
    local section = { tiles = {} }
    assert(debrief.canAdd(section))
    assert(debrief.addTile(section, tile("A")) == 1)
    assert(debrief.addTile(section, tile("B")) == 2)
    assert(debrief.addTile(section, tile("C")) == 3)
    local added, addError = debrief.addTile(section, tile("Bad", { series("VCel", "last") }))
    assert(added == false and string.find(addError, "statistic", 1, true))
    added = debrief.addTile(section, tile("Partly", { series("VCel"), series("VCel", "last") }))
    assert(added == false, "a tile with a rejected series is not added")
    assert(#section.tiles == 3)

    assert(debrief.moveTile(section, 3, -2) == 1)
    assert(section.tiles[1].title == "C" and section.tiles[2].title == "A")
    assert(debrief.moveTile(section, 1, -1) == false)
    assert(debrief.moveTile(section, 3, 1) == false)

    assert(debrief.setTile(section, 2, { title = "Wide", colSpan = 4, rowSpan = 2, series = { series("RQly") } }))
    assert(section.tiles[2].title == "Wide" and section.tiles[2].colSpan == 4)
    assert(not debrief.setTile(section, 2, { title = "", series = { series("RQly") } }))
    assert(not debrief.setTile(section, 9, tile("Missing")))

    assert(debrief.removeTile(section, 1))
    assert(not debrief.removeTile(section, 5))
    assert(#section.tiles == 2 and section.tiles[1].title == "Wide")
end

local function run()
    testValidSection()
    testEmptyAndMalformedSections()
    testInvalidEntriesAreDropped()
    testTileLimit()
    testLabels()
    testDraftOperations()
end

run()
