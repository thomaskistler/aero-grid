-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local debrief = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/debrief_config.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

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
    assert(debrief.moveTile(section, 11, 1) == 12, "a move is allowed at the limit")
    assert(section.tiles[12].title == "Tile 11")
end

local function testSharedSize()
    local input = { size = "wide", tiles = { tile("A"), tile("B") } }
    input.tiles[1].colSpan, input.tiles[1].rowSpan = 4, 1
    local section, errors = debrief.validate(input)
    assert(#errors == 0 and section.size == "wide")
    for _, entry in ipairs(section.tiles) do
        assert(entry.colSpan == 4 and entry.rowSpan == 2, "the shared size overrides per-tile spans")
    end
    assert(input.tiles[1].rowSpan == 1, "validation does not change the input")
    assert(debrief.setSize(section, "compact"))
    for _, entry in ipairs(section.tiles) do
        assert(entry.colSpan == 2 and entry.rowSpan == 2)
    end
    assert(not debrief.setSize(section, "4x2") and section.size == "compact")
    assert(debrief.setSize(section, "wide"))
    debrief.addTile(section)
    assert(section.tiles[3].colSpan == 4 and section.tiles[3].rowSpan == 2)
    debrief.fill(section, { { type = "rx-battery", config = {} } })
    assert(section.size == "wide" and section.tiles[1].rowSpan == 2 and section.tiles[1].colSpan == 4)
    debrief.fill(section, {})
    assert(section.size == "wide" and #section.tiles == 0)
    local _, problems = debrief.validate({ size = "nope", tiles = {} })
    assert(hasMessage(problems, "debrief size"))
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
    assert(debrief.moveTile(section, 3, -1) == 2 and titles(section) == "A,C,B")
    assert(debrief.moveTile(section, 1, 1) == 2 and titles(section) == "C,A,B")
    assert(not debrief.moveTile(section, 1, -1) and not debrief.moveTile(section, 3, 1), "ends stay put")
    assert(titles(section) == "C,A,B")

    debrief.addSeries(section, 2)
    section.tiles[2].series[2].statistic = "max"
    assert(debrief.moveSeries(section, 2, 2, -1) == 1 and section.tiles[2].series[1].statistic == "max")
    assert(not debrief.moveSeries(section, 2, 2, 1) and not debrief.moveSeries(section, 9, 1, 1))

    assert(debrief.removeTile(section, 1))
    assert(not debrief.removeTile(section, 5))
    assert(titles(section) == "A,B")
end

local function panel(kind, config)
    return { type = kind, config = config or {} }
end

local function sources(tileValue)
    local list = {}
    for _, entry in ipairs(tileValue.series) do
        list[#list + 1] = entry.source .. ":" .. entry.statistic
    end
    return table.concat(list, ",")
end

local function testFromPanels()
    local sensors = {
        Capa = true,
        RQly = true,
        RSSI = true,
        GSpd = true,
        GAlt = true,
        Sats = true,
        Curr = true,
        Vspd = true,
        Fuel = true,
        Tmp1 = true,
    }
    local function present(name)
        return sensors[name] == true
    end
    local panels = {
        panel("rx-battery", { label = "Flight pack" }),
        panel("rx-battery", { label = "Second" }),
        panel("link-status", { qualitySource = "RQly" }),
        panel("navigation"),
        panel("chart", {
            label = "Power",
            metrics = {
                { source = "Curr", label = "amps", rangeMin = 0, rangeMax = 60, accent = "amber", precision = 1 },
                { source = "RQly" },
                { source = "Vspd", rangeMin = 5, rangeMax = 1, accent = "pink" },
                { source = "Fuel" },
            },
        }),
        panel("metric", { metrics = { { source = "Tmp1", label = "ESC", warning = 20, critical = 10 } } }),
        panel("metric", { metrics = { { label = "no source" } } }),
        panel("unknown"),
    }
    -- The layout's thresholds, as the telemetry registry owns them.
    local owned = {
        RQly = { sensor = "RQly", warning = 70, critical = 50, falling = true },
        Tmp1 = { sensor = "Tmp1", warning = 20, critical = 10, falling = true },
    }
    local section = debrief.fromPanels(panels, present, owned)
    local valid = debrief.validate(section)
    assert(valid and #valid.tiles == #section.tiles, "derived tiles validate")
    local expected = {
        { "Flight pack", "VCel:min,Capa:delta" },
        { "Link", "RQly:min,RSSI:min" },
        { "Speed", "GSpd:max" },
        { "Navigation", "HDst:max,FDst:delta" },
        { "Satellites", "Sats:min" },
        { "Power", "Curr:max,RQly:min,Vspd:max" },
        { "ESC", "Tmp1:min" },
    }
    assert(#section.tiles == #expected, "one tile per mapped reading, got " .. #section.tiles)
    for index, want in ipairs(expected) do
        local got = section.tiles[index]
        assert(got.title == want[1], "tile " .. index .. " title " .. tostring(got.title))
        assert(sources(got) == want[2], "tile " .. index .. " series " .. sources(got))
        assert(got.colSpan == 2 and got.rowSpan == 2, "derived tiles are Compact")
    end
    assert(section.tiles[1].series[2].label == "used" and section.tiles[4].series[2].label == "flown")
    local power = section.tiles[6].series
    assert(power[1].label == "amps" and power[1].accent == "amber" and power[1].precision == 1)
    assert(section.tiles[7].series[1].label == nil, "a lone reading's label is the tile title")
    assert(power[1].rangeMin == 0 and power[1].rangeMax == 60)
    assert(power[3].rangeMin == nil and power[3].accent == nil, "an invalid range and accent are dropped")

    -- Sources the model lacks are left out; published sensors always map.
    local bare = debrief.fromPanels({ panel("rx-battery"), panel("link-status"), panel("navigation") }, function()
        return false
    end)
    assert(#bare.tiles == 2, "only the battery and distance tiles remain")
    assert(bare.tiles[1].title == "RX battery" and sources(bare.tiles[1]) == "VCel:min")
    assert(bare.tiles[2].title == "Navigation" and sources(bare.tiles[2]) == "HDst:max,FDst:delta")

    -- A layout without mappable panels derives an empty debrief.
    assert(#debrief.fromPanels({}, present).tiles == 0)
    assert(#debrief.fromPanels(nil, present).tiles == 0)

    -- At most MAX_TILES tiles.
    local many = {}
    for index = 1, debrief.MAX_TILES + 4 do
        many[index] = panel("metric", { metrics = { { source = "M" .. index } } })
    end
    local capped = debrief.fromPanels(many, function()
        return true
    end)
    assert(#capped.tiles == debrief.MAX_TILES and capped.tiles[debrief.MAX_TILES].title == "M" .. debrief.MAX_TILES)

    many[#many + 1] = panel("link-status", { label = "Receiver link" })
    many[#many + 1] = panel("rx-battery", { label = "Receiver battery" })
    many[#many + 1] = panel("rx-battery", { label = "Second battery" })
    capped = debrief.fromPanels(many, function()
        return true
    end)
    equal(#capped.tiles, debrief.MAX_TILES)
    equal(capped.tiles[1].title, "Receiver battery", "the first battery leads even beyond the tile limit")
    equal(capped.tiles[2].title, "Receiver link", "Link follows the battery regardless of dashboard order")
    equal(capped.tiles[3].title, "M1", "the other panels retain their order")
    equal(capped.tiles[debrief.MAX_TILES].title, "M" .. (debrief.MAX_TILES - 2))

    local altitudeSettings = {
        metrics = {
            { source = "GAlt", label = "Altitude" },
            { source = "GAlt+", label = "MAX ALT" },
            { source = "VSpd+", label = "VSpeed", precision = 1 },
        },
    }
    local altitude = debrief.fromPanels({ panel("metric", altitudeSettings) }, function(name)
        return name == "GAlt" or name == "VSpd"
    end).tiles[1]
    equal(altitude.title, "Altitude")
    equal(sources(altitude), "GAlt:max,VSpd:max", "altitude and VSpeed use flight readings, not radio maxima")
    equal(altitude.series[2].label, "VSpeed")
    equal(altitude.series[2].precision, 1)
    equal(altitudeSettings.metrics[3].source, "VSpd+", "deriving does not change the dashboard")
    local paired = debrief.fromPanels({
        panel("metric", { metrics = { { source = "Alt", label = "Altitude" } } }),
    }, function(name)
        return name == "Alt" or name == "VSpd"
    end).tiles[1]
    equal(sources(paired), "Alt:max,VSpd:max", "an altitude tile includes available VSpeed")
    local minimum = debrief.fromPanels({
        panel("metric", { metrics = { { source = "GAlt-" } } }),
    }, function(name)
        return name == "GAlt"
    end).tiles[1]
    equal(sources(minimum), "GAlt:min", "a radio minimum becomes a flight minimum")
    local function altitudeSources(metrics)
        return sources(debrief.fromPanels({
            panel("metric", { metrics = metrics }),
        }, function(name)
            return name == "Alt"
        end).tiles[1])
    end
    equal(
        altitudeSources({ { source = "Alt" }, { source = "Alt-" } }),
        "Alt:max,Alt:min",
        "a minimum is distinct from the raw reading's maximum"
    )
    equal(
        altitudeSources({ { source = "Alt-" }, { source = "Alt+" } }),
        "Alt:min,Alt:max",
        "opposite extrema both survive normalization"
    )
    equal(
        altitudeSources({ { source = "Alt" }, { source = "Alt+" } }),
        "Alt:max",
        "the same base source and statistic is recorded once"
    )

    -- Fill replaces the existing tiles and keeps unknown settings.
    local filled = { tiles = { tile("Old") }, future = true }
    assert(debrief.fill(filled, { panel("rx-battery") }, present) == 1)
    assert(filled.tiles[1].title == "RX battery" and filled.future == true)
    assert(debrief.fill(filled, {}, present) == 0 and #filled.tiles == 0)

    -- Link readings are independent: either source may be unset.
    local function link(settings)
        return debrief.fromPanels({ panel("link-status", settings) }, present).tiles[1]
    end
    equal(sources(link({})), "RSSI:min", "an RSSI-only link maps")
    equal(sources(link({ qualitySource = "" })), "RSSI:min")
    equal(sources(link({ qualitySource = "RQly", rssiSource = "" })), "RQly:min")
    equal(sources(link({ qualitySource = "RSSI" })), "RSSI:min", "a source is named once")
    assert(link({ qualitySource = "", rssiSource = "" }) == nil)

    -- Chart and Metric readings the model lacks are left out before the
    -- reading limit, and a tile without readings is not added.
    local sparse = debrief.fromPanels({
        panel("chart", {
            metrics = { { source = "Nope" }, { source = "Curr" }, { source = "HDst" }, { source = "Vspd" } },
        }),
        panel("metric", { metrics = { { source = "Gone" } } }),
    }, present)
    equal(#sparse.tiles, 1, "a tile of missing readings is skipped")
    equal(sources(sparse.tiles[1]), "Curr:max,HDst:max,Vspd:max")
    equal(sparse.tiles[1].title, "Curr", "the title is the first kept reading")

    -- The statistic follows the threshold owner, not the first panel naming
    -- the source; a source without thresholds follows an explicit direction.
    local fuel = {
        panel("metric", { metrics = { { source = "Fuel", direction = "rising" } } }),
        panel("metric", { metrics = { { source = "Fuel", warning = 20, critical = 10 } } }),
    }
    local judged =
        debrief.fromPanels(fuel, present, { Fuel = { sensor = "Fuel", warning = 20, critical = 10, falling = true } })
    equal(sources(judged.tiles[1]) .. " " .. sources(judged.tiles[2]), "Fuel:min Fuel:min")
    local directed = debrief.fromPanels({
        panel("metric", { metrics = { { source = "Fuel" } } }),
        panel("metric", { metrics = { { source = "Fuel", direction = "falling" } } }),
    }, present)
    equal(sources(directed.tiles[1]), "Fuel:min")
    equal(
        sources(debrief.fromPanels({ panel("metric", { metrics = { { source = "Fuel" } } }) }, present).tiles[1]),
        "Fuel:max"
    )
end

local function run()
    testValidSection()
    testEmptyAndMalformedSections()
    testInvalidEntriesAreDropped()
    testUnknownSettingsAndRequiredSizes()
    testTileLimit()
    testSharedSize()
    testDraftOperations()
    testFromPanels()
end

run()
