-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local navigation = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/navigation.lua"))()

local function testPresentation()
    assertions.assertEqual(navigation.cardinal(0), "N")
    assertions.assertEqual(navigation.cardinal(44), "NE")
    assertions.assertEqual(navigation.cardinal(350), "N")
    assertions.assertEqual(navigation.cardinal(270), "W")
    assertions.assertEqual(navigation.cardinal(nil), "")

    local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
    local settings, warnings = host.resolveSettings(navigation, {})
    assertions.assertEqual(#warnings, 0)
    assertions.assertEqual(settings.showTape, false)
    assertions.assertEqual(settings.showCoordinates, false)
    assertions.assertEqual(settings.showSatellites, true)
    local hidden, hiddenErrors = host.resolveSettings(navigation, { showSatellites = false })
    assertions.assertEqual(#hiddenErrors, 0)
    assertions.assertEqual(hidden.showSatellites, false)
    assertions.assertEqual(settings.armSwitch, "")
    assertions.assertEqual(settings.satelliteSource, "")
    assertions.assertEqual(settings.satelliteWarning, 8)
    assertions.assertEqual(settings.satelliteCritical, 4)
    for _, config in ipairs({
        { satelliteWarning = -1 },
        { satelliteCritical = 1.5 },
        { satelliteWarning = 3, satelliteCritical = 4 },
    }) do
        local _, errors = host.resolveSettings(navigation, config)
        assert(#errors > 0, "invalid satellite thresholds must be rejected")
    end
    for _, removed in ipairs({ "warning", "critical" }) do
        local _, errors = host.resolveSettings(navigation, { [removed] = 500 })
        assert(#errors > 0, "distance thresholds are no longer panel settings")
    end
    for _, arm in ipairs({ "", "SF^", "SA-", "SFv", "L01" }) do
        local _, errors = host.resolveSettings(navigation, { armSwitch = arm })
        assertions.assertEqual(#errors, 0)
    end
    for _, arm in ipairs({ "SF", "SFx", "L1", "GPS" }) do
        local _, errors = host.resolveSettings(navigation, { armSwitch = arm })
        assert(#errors > 0, "invalid armed switch must be rejected")
    end
    for _, removed in ipairs({ "presentation", "showBearing" }) do
        local _, errors = host.resolveSettings(navigation, { [removed] = true })
        assertions.assertEqual(#errors, 1)
    end
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
    assertions.assertEqual(navigation.originText(fix), "")
    for _, sample in ipairs({
        { 29, "BRG N29\194\176E" },
        { 151, "BRG S29\194\176E" },
        { 209, "BRG S29\194\176W" },
        { 331, "BRG N29\194\176W" },
        { 0, "BRG N" },
        { 90, "BRG E" },
        { 180, "BRG S" },
        { 270, "BRG W" },
        { 359.9, "BRG N" },
    }) do
        assertions.assertEqual(navigation.bearingText({ bearing = sample[1] }, nil, nil, nil, "quadrant"), sample[2])
    end
    assertions.assertEqual(navigation.coordinateText(fix), "47.37690 8.54170")
    assertions.assertEqual(navigation.resolveState({}, fix), "normal")
    assertions.assertEqual(navigation.resolveState({ warning = 500, critical = 700 }, fix), "normal")
    local settings = { satelliteSource = "Sats", showSatellites = false }
    local satellites = { available = true, value = 12 }
    for _, sample in ipairs({
        { 0, "critical" },
        { 3, "critical" },
        { 4, "warning" },
        { 7, "warning" },
        { 8, "normal" },
        { 12, "normal" },
    }) do
        satellites.value = sample[1]
        assertions.assertEqual(navigation.resolveState(settings, fix, satellites), sample[2])
    end
    satellites.value = 3
    assertions.assertEqual(
        navigation.resolveState(
            { satelliteSource = "Sats", satelliteCritical = 2, satelliteWarning = 3 },
            fix,
            satellites
        ),
        "normal"
    )
    for _, value in ipairs({ -1, 2.5, math.huge, 0 / 0, "12" }) do
        satellites.value = value
        assertions.assertEqual(navigation.resolveState(settings, fix, satellites), "unavailable")
    end
    satellites.value, satellites.stale = 12, true
    assertions.assertEqual(navigation.resolveState(settings, fix, satellites), "stale")
    satellites.available = false
    assertions.assertEqual(navigation.resolveState(settings, fix, satellites), "unavailable")
    assertions.assertEqual(navigation.resolveState(settings, fix), "unavailable")

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
    noHome.homeStatus = "waiting"
    assertions.assertEqual(navigation.originText(noHome), "WAITING FOR ARM")
    noHome.homeStatus = "missed"
    assertions.assertEqual(navigation.originText(noHome), "HOME NOT SET")
    noHome.homeStatus = "switch-unavailable"
    assertions.assertEqual(navigation.originText(noHome), "ARM SWITCH UNAVAILABLE")

    local noFix = { source = "GPS", known = true, fix = false, home = false }
    assertions.assertEqual(navigation.resolveState(settings, noFix, { available = true, value = 3 }), "critical")
    assertions.assertEqual(navigation.resolveState(settings, noHome, { available = true, value = 5 }), "warning")
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
    local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
    local _, warnings = host.resolveSettings(navigation, { distanceSource = "Dist" })
    assertions.assertEqual(#warnings, 1)
    assertions.assertEqual(warnings[1], "distanceSource is not a setting of this panel")
    assertions.assertEqual(
        navigation.distanceText({ distance = 12 }, function()
            return "12 km"
        end),
        "12 km"
    )
    assertions.assertEqual(
        navigation.distanceText({}, function()
            return "12 km"
        end),
        "--"
    )
    assertions.assertEqual(navigation.coordinateText({ latitude = 1, longitude = 2 }), "1.00000 2.00000")
end

local function run()
    testPresentation()
    testNavigationStates()
    testDistanceText()
end

run()
