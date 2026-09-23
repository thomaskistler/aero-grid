-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local navigation = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/navigation.lua"))()

local function testPresentation()
    assertions.assertEqual(navigation.cardinal(0), "N")
    assertions.assertEqual(navigation.cardinal(44), "NE")
    assertions.assertEqual(navigation.cardinal(350), "N")
    assertions.assertEqual(navigation.cardinal(270), "W")
    assertions.assertEqual(navigation.cardinal(nil), "")

    assertions.assertEqual(navigation.presentation("auto", 1, 1), "distance")
    assertions.assertEqual(navigation.presentation("auto", 2, 1), "bearing")
    assertions.assertEqual(navigation.presentation("auto", 2, 2), "compass")
    assertions.assertEqual(navigation.presentation("auto", 3, 2), "detailed")
    assertions.assertEqual(navigation.presentation("distance", 4, 4), "distance")
    assertions.assertEqual(navigation.presentationFor("detailed").showCoordinates, true)
    assertions.assertEqual(navigation.presentationFor("distance").showDetail, false)
end

local function testNavigationStates()
    local fix = {
        source = "GPS",
        known = true,
        fix = true,
        home = true,
        state = "normal",
        latitude = 47.3769,
        longitude = 8.5417,
        distance = 778,
        bearing = 9.47,
    }

    assertions.assertEqual(navigation.bearingText(fix), "BRG 009 N")
    assertions.assertEqual(navigation.originText(fix), "NORTH UP FROM HOME")
    assertions.assertEqual(navigation.coordinateText(fix), "47.37690 8.54170")
    assertions.assertEqual(navigation.resolveState({}, fix), "normal")
    assertions.assertEqual(navigation.resolveState({ warning = 500 }, fix), "warning")
    assertions.assertEqual(navigation.resolveState({ critical = 700 }, fix), "critical")

    local noHome = {
        source = "GPS",
        known = true,
        fix = true,
        home = false,
        latitude = 47.3769,
        longitude = 8.5417,
    }
    assertions.assertEqual(navigation.resolveState({}, noHome), "normal")
    assertions.assertEqual(navigation.bearingText(noHome), "BRG --")
    assertions.assertEqual(navigation.originText(noHome), "NO HOME POSITION")
    assertions.assertEqual(navigation.coordinateText(noHome), "47.37690 8.54170")

    local noFix = { source = "GPS", known = true, fix = false, home = false }
    assertions.assertEqual(navigation.resolveState({}, noFix), "unavailable")
    assertions.assertEqual(navigation.originText(noFix), "NO FIX")
    assertions.assertEqual(navigation.coordinateText(noFix), "-- , --")
    assertions.assertEqual(navigation.resolveState({}, { source = "GPS", known = false }), "unavailable")
    assertions.assertEqual(navigation.originText({ source = "GPS", known = false }), "NO GPS SOURCE")
    assertions.assertEqual(
        navigation.resolveState({}, { source = "GPS", known = true, fix = true, home = true, state = "stale" }),
        "stale"
    )
end

local function testDistanceText()
    assertions.assertEqual(navigation.distanceText({ distance = 12 }, function() return "12 km" end), "12 km")
    assertions.assertEqual(navigation.distanceText({}, function() return "12 km" end), "--")
    assertions.assertEqual(navigation.coordinateText({ latitude = 1, longitude = 2 }), "1.00000 2.00000")
end

local function run()
    testPresentation()
    testNavigationStates()
    testDistanceText()
end

run()
