-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local fixture = WidgetFixture.new()
fixture.reset()
local context = fixture.createLoaded(nil, { Layout = "review-navigation", Theme = "modern-dark" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(context.document.version, 3)
assertions.assertEqual(#context.panels, 6)
fixture.assertNoOverlap(context)
local square = fixture.instanceOf(context, "compass")
local detailed = fixture.instanceOf(context, "detailed")
assert(square.showTape, "legacy compass must become a tape")
assert(square.detailLabel.hidden, "tape and bearing text must be exclusive")
assert(not square.showCoordinates)
assert(detailed.showCoordinates, "legacy detailed must retain coordinates")
assertions.assertEqual(#square.tape.ticks, 23)
assertions.assertEqual(#square.tape.labels, 3)
assertions.assertEqual(#square.tape.shading, 4)
assertions.assertEqual(#square.tape.rims, 14)
assert(square.area.valueY + square.themeBuilder.fontAscent(square.area.value) < square.area.tapeY)
assertions.assertEqual(square.compass, nil)
assertions.assertEqual(fixture.instanceOf(context, "bearing").tape, nil)
for _, panel in ipairs(context.document.panels) do
    assertions.assertEqual(panel.config.presentation, nil)
    assertions.assertEqual(panel.config.showBearing, nil)
end

local navigation = fixture.module("panels/navigation.lua")
local theme = square.themeBuilder
local catalog = assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
assert(theme.setCatalog(catalog))
for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    local resolved = theme.build(mode)
    local light = mode == "modern-light"
    local panel = {
        theme = resolved,
        themeBuilder = theme,
        primitives = fixture.module("lib/primitives.lua"),
    }
    local tape = navigation.createTape(lvgl.box({ x = 0, y = 0, w = 200, h = 50 }), panel, {
        tapeX = 0,
        tapeY = 0,
        tapeWidth = 200,
        tapeHeight = 50,
        tapeFont = SMLSIZE,
    })
    local amounts = light and { -0.08, -0.02, 0, -0.06 } or { -0.45, -0.08, 0.04, -0.32 }
    for index, amount in ipairs(amounts) do
        assertions.assertEqual(tape.shading[index].properties.color, lcd.RGB(theme.shade(resolved.rgb.surface, amount)))
    end
    assertions.assertEqual(
        tape.rims[7].properties.color,
        lcd.RGB(theme.shade(resolved.rgb.surface, light and -0.18 or 0.48)),
        "rims must darken a light surface and lighten a dark surface"
    )
    panel.tape = tape
    panel.area = {
        showTape = true,
        tapeX = 0,
        tapeY = 0,
        tapeWidth = 200,
        tapeHeight = 50,
        tapeFont = SMLSIZE,
    }
    for _, state in ipairs({ "warning", "critical", "normal" }) do
        panel.stateName = state
        navigation.setTape(panel, 0, resolved.color.text)
        local surface = resolved.alertRgb[state] or resolved.rgb.surface
        local isLight = theme.contrast(surface, 0) > theme.contrast(surface, 0xFFFFFF)
        assertions.assertEqual(tape.surface, surface, "tape must follow the active panel surface")
        assertions.assertEqual(
            tape.shading[1].properties.color,
            lcd.RGB(theme.shade(surface, isLight and -0.08 or -0.45)),
            "recess shading must follow alert transitions and recovery"
        )
        assertions.assertEqual(tape.rims[7].properties.color, lcd.RGB(theme.shade(surface, isLight and -0.18 or 0.48)))
    end
end
local function instance(cols, rows, rect, settings)
    local host = fixture.module("lib/panel_host.lua")
    local resolved, errors = host.resolveSettings(navigation, settings or { showTape = true })
    assertions.assertEqual(#errors, 0)
    return navigation.create(lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }), rect, resolved, {
        theme = square.theme,
        themeBuilder = theme,
        primitives = fixture.module("lib/primitives.lua"),
        fonts = theme.typography(cols, rows),
        span = { colSpan = cols, rowSpan = rows },
        state = square.state,
        navigation = square.service,
        telemetry = context.serviceRuntime.byId.telemetry,
        host = context,
    })
end

for _, case in ipairs({
    { 2, 2, 238, 134 },
    { 3, 3, 359, 203 },
    { 4, 4, 480, 272 },
    { 2, 1, 238, 65 },
    { 3, 1, 359, 65 },
    { 4, 2, 480, 134 },
    { 1, 2, 117, 134 },
}) do
    local panel = instance(case[1], case[2], { w = case[3], h = case[4] })
    local area = panel.area
    assert(panel.showTape, "requested tape must fit standard span " .. case[1] .. "x" .. case[2])
    assert(not panel.showDetail)
    assert(area.tapeX + area.tapeWidth <= case[3])
    assert(area.tapeY + area.tapeHeight <= case[4])
    if case[1] <= case[2] then
        assert(area.tapeX >= math.ceil(case[3] * 0.1), "square tape must leave at least 10% on the left")
        assert(
            case[3] - area.tapeX - area.tapeWidth >= math.ceil(case[3] * 0.1),
            "square tape must leave at least 10% on the right"
        )
        assertions.assertEqual(area.tapeX * 2 + area.tapeWidth, case[3], "square tape must be centered")
        if case[1] == case[2] then
            local previous = navigation.regionsFor(
                panel.theme,
                theme,
                { w = case[3], h = case[4] },
                { showTape = true },
                panel.fonts,
                panel.sample
            )
            assertions.assertEqual(
                area.valueY,
                math.max(area.frame.top, previous.valueY - math.max(4, math.floor(case[4] * 0.03))),
                "square distance must move up without crossing the header"
            )
            assertions.assertEqual(area.value, previous.value, "moving distance must not shrink its font")
        end
    end
    if case[1] > case[2] then
        assert(
            case[3] - area.tapeX - area.tapeWidth >= math.ceil(case[3] * 0.1),
            "wide tape must leave at least 10% on the right"
        )
        assert(area.valueX + area.valueWidth < area.tapeX, "wide tape must sit beside distance")
    else
        assert(area.valueY + theme.fontAscent(area.value) < area.tapeY, "square/tall tape must sit below distance")
    end
    local pointer = panel.tape.pointer
    navigation.setTape(panel, 0, panel.state("normal", "green").accent)
    for index, caption in ipairs({ "W", "N", "E" }) do
        local label = panel.tape.labels[index]
        assert(not label.hidden, "north-centered tape must show W, N and E in full")
        assertions.assertEqual(label.properties.text, caption)
    end
    for bearing = 0, 359 do
        navigation.setTape(panel, bearing, panel.state("normal", "green").accent)
        assert(not pointer.hidden)
        local points = pointer.properties.pts
        assertions.assertEqual(points[3][1], math.floor(area.tapeWidth / 2), "pointer must stay fixed")
        for _, tick in ipairs(panel.tape.ticks) do
            if not tick.hidden then
                assert(tick.properties.pts[1][1] >= 0 and tick.properties.pts[1][1] < area.tapeWidth)
            end
        end
        local found = false
        for _, label in ipairs(panel.tape.labels) do
            if not label.hidden then
                local p = label.properties
                assert(p.x >= 0 and p.x + p.w <= area.tapeWidth)
                assert(not string.match(p.text, "^..$"), "tape must label only N, E, S, W")
                if bearing % 90 == 0 and p.text == navigation.cardinal(bearing) then
                    found = true
                    assert(math.abs(p.x + p.w / 2 - math.floor(area.tapeWidth / 2)) <= 1)
                end
            end
        end
        assert(bearing % 90 ~= 0 or found, "each cardinal must pass under pointer")
        local visibleDots = 0
        for _, dot in ipairs(panel.tape.dots) do
            if not dot.hidden then
                visibleDots = visibleDots + 1
                local p = dot.properties
                assert(p.x >= 0 and p.x + p.w <= area.tapeWidth, "dots must stay inside tape")
                local degrees = (bearing + (p.x + 1 - math.floor(area.tapeWidth / 2)) / ((area.tapeWidth - 1) / 210))
                    % 30
                assert(
                    math.min(degrees, 30 - degrees) <= 210 / (area.tapeWidth - 1),
                    "dots must align with 30 degree major ticks"
                )
            end
        end
        assert(visibleDots >= 2, "tape must show intermediate direction dots")
    end
    for _, bearing in ipairs({ -1, 359, 360, 720, 0.5 }) do
        navigation.setTape(panel, bearing, panel.state("normal", "green").accent)
        assert(not pointer.hidden)
    end
    for _, bearing in ipairs({ false, 0 / 0, math.huge }) do
        navigation.setTape(panel, bearing, panel.state("normal", "green").accent, "NO FIX")
        assert(pointer.hidden)
        assert(not panel.tape.status.hidden)
        assertions.assertEqual(panel.tape.status.properties.text, "NO FIX")
        for _, tick in ipairs(panel.tape.ticks) do
            assert(tick.hidden)
        end
        for _, label in ipairs(panel.tape.labels) do
            assert(label.hidden)
        end
        for _, dot in ipairs(panel.tape.dots) do
            assert(dot.hidden)
        end
        for _, highlight in ipairs(panel.tape.dotHighlights) do
            assert(highlight.hidden)
        end
    end
end

local bearingOnly = instance(2, 2, { w = 238, h = 134 }, { bearingFormat = "quadrant" })
assert(bearingOnly.showDetail)
assertions.assertEqual(bearingOnly.tape, nil)
assert(string.match(bearingOnly.detail, "^BRG N"))
local priorCoordinates, priorBearing = detailed.coordinates, detailed.bearing
fixture.radio.values[109].lat = fixture.radio.values[109].lat + 0.002
fixture.radio.values[109].lon = fixture.radio.values[109].lon + 0.005
fixture.pump(context, 40)
assert(detailed.bearing ~= priorBearing, "tape bearing must follow GPS changes")
assert(detailed.coordinates ~= priorCoordinates, "coordinate row must follow GPS changes")
assertions.assertEqual(detailed.coordinatesLabel.properties.text, detailed.coordinates)

fixture.radio.values[109]["pilot-lat"] = 0
fixture.radio.values[109]["pilot-lon"] = 0
fixture.pump(context, 40)
assert(detailed.tape.pointer.hidden)
assert(string.match(detailed.tape.status.properties.text, "^NO HOME"))
assertions.assertEqual(detailed.text, "--")
assertions.assertEqual(detailed.stateName, "normal")
assert(detailed.coordinates ~= "-- , --", "missing home must not hide a valid position")
fixture.radio.values[109].lat = 0
fixture.radio.values[109].lon = 0
fixture.pump(context, 40)
assertions.assertEqual(detailed.tape.status.properties.text, "NO FIX")

fixture.radio.values[109] = { lat = 47, lon = 8, delay = 0 }
fixture.radio.values[305] = -1024
local custom = instance(2, 2, { w = 238, h = 134 }, { armSwitch = "SFv", showTape = true })
fixture.pump(context, 20)
navigation.refresh(custom)
assertions.assertEqual(custom.feed.homeStatus, "waiting")
assertions.assertEqual(custom.text, "--")
fixture.radio.values[305] = 1024
local definition = fixture.module("main.lua")
for _ = 1, 20 do
    fixture.tick(20)
    definition.background(context)
end
navigation.refresh(custom)
assertions.assertEqual(custom.feed.homeStatus, "captured", "background updates must capture home")
assertions.assertEqual(custom.text, "0")
fixture.radio.values[109].lat = 47.001
fixture.radio.values[305] = -1024
fixture.pump(context, 20)
fixture.radio.values[305] = 1024
fixture.pump(context, 20)
navigation.refresh(custom)
assertions.assertEqual(custom.feed.pilotLatitude, 47)
assert(custom.feed.distance > 100 and custom.feed.distance < 120)

local homes = context.navigationHomes
definition.update(context, { Layout = "review-navigation", Theme = "modern-light" })
fixture.pump(context, 120)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assert(context.navigationHomes == homes, "layout/theme reload must preserve capture state")
square = fixture.instanceOf(context, "compass")
custom = instance(2, 2, { w = 238, h = 134 }, { armSwitch = "SFv" })
fixture.pump(context, 20)
navigation.refresh(custom)
assertions.assertEqual(custom.feed.pilotLatitude, 47, "panel recreation must not reset home")
assert(custom.feed.distance > 100 and custom.feed.distance < 120)

fixture.radio.modelFilename = "another-model.yml"
definition.update(context, { Layout = "review-navigation", Theme = "modern-dark" })
fixture.pump(context, 120)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assert(context.navigationHomes ~= homes, "a different model must not inherit home")
square = fixture.instanceOf(context, "compass")
custom = instance(2, 2, { w = 238, h = 134 }, { armSwitch = "SFv" })
fixture.pump(context, 20)
assertions.assertEqual(custom.feed.home, false, "starting armed in a new model must not capture")
assertions.assertEqual(custom.feed.homeStatus, "waiting")

fixture.radio.fields.Sats = { id = 122, name = "Sats", desc = "Satellites", unit = 0 }
fixture.radio.values[122] = 12
fixture.radio.values[109] = { lat = 47.002, lon = 8.003, ["pilot-lat"] = 47, ["pilot-lon"] = 8, delay = 0 }
for _, shape in ipairs({ { 1, 2, 117, 134 }, { 2, 1, 238, 65 }, { 2, 2, 238, 134 } }) do
    local satellitePanel = instance(
        shape[1],
        shape[2],
        { w = shape[3], h = shape[4] },
        { satelliteSource = "Sats", showTape = true }
    )
    fixture.pump(context, 20)
    navigation.refresh(satellitePanel)
    assertions.assertEqual(satellitePanel.stateName, "normal")
    assert(satellitePanel.showSatellites, "satellite count must fit standard span " .. shape[1] .. "x" .. shape[2])
    assertions.assertEqual(satellitePanel.satelliteLabel.properties.text, "12")
    local header = satellitePanel.satelliteHeader.properties
    assert(header.x + header.w <= shape[3])
    for _, sample in ipairs({
        { 3, "critical" },
        { 4, "warning" },
        { 7, "warning" },
        { 8, "normal" },
        { 0, "critical" },
        { 12, "normal" },
    }) do
        fixture.radio.values[122] = sample[1]
        fixture.pump(context, 20)
        navigation.refresh(satellitePanel)
        assertions.assertEqual(satellitePanel.stateName, sample[2])
        if satellitePanel.showSatellites then
            assertions.assertEqual(satellitePanel.satelliteLabel.properties.text, tostring(sample[1]))
        end
        if satellitePanel.showSatellites and satellitePanel.badgeText ~= "" then
            assert(
                satellitePanel.satelliteHeader.properties.x + satellitePanel.satelliteHeader.properties.w
                    < satellitePanel.badge.properties.x,
                "satellites must not overlap the state badge"
            )
        end
    end
    navigation.update(satellitePanel, { w = 60, h = 40 })
    assert(not satellitePanel.showSatellites, "drop satellite count rather than clip narrow headers")
    navigation.update(satellitePanel, { w = shape[3], h = shape[4] })
    assert(satellitePanel.showSatellites, "restore satellite count after reflow")
end
local hidden = instance(2, 2, { w = 238, h = 134 }, { satelliteSource = "Sats", showSatellites = false })
assert(hidden.satellites, "hiding the indicator must retain the satellite subscription")
assertions.assertEqual(hidden.satelliteHeader, nil)
assertions.assertEqual(hidden.satelliteIcon, nil)
assertions.assertEqual(hidden.satelliteLabel, nil)
for _, sample in ipairs({
    { 3, "critical" },
    { 4, "warning" },
    { 8, "normal" },
    { -1, "unavailable" },
}) do
    fixture.radio.values[122] = sample[1]
    fixture.pump(context, 20)
    navigation.refresh(hidden)
    assertions.assertEqual(hidden.stateName, sample[2], "satellite alerts must remain active with the indicator off")
    navigation.update(hidden, { w = 60, h = 40 })
    navigation.update(hidden, { w = 238, h = 134 })
    assert(not hidden.showSatellites, "reflow must not reveal a disabled indicator")
end
fixture.radio.values[122] = 12
fixture.pump(context, 20)
local noSatelliteSource = instance(2, 2, { w = 238, h = 134 }, { showSatellites = true })
assertions.assertEqual(noSatelliteSource.satelliteHeader, nil)
assertions.assertEqual(noSatelliteSource.satellites, nil)
local missing = instance(2, 2, { w = 238, h = 134 }, { satelliteSource = "MissingSats" })
fixture.pump(context, 20)
navigation.refresh(missing)
assertions.assertEqual(missing.stateName, "unavailable")
assertions.assertEqual(missing.satelliteLabel.properties.text, "--")
fixture.radio.values[109], fixture.radio.values[122], fixture.radio.rssi = 0, 0, 0
fixture.pump(context, 20)
local stale = instance(2, 2, { w = 238, h = 134 }, { satelliteSource = "Sats" })
navigation.refresh(stale)
assertions.assertEqual(stale.stateName, "stale")
assertions.assertEqual(stale.satelliteLabel.properties.text, "12")
navigation.refresh(hidden)
assertions.assertEqual(hidden.stateName, "stale", "hidden satellite telemetry must still report staleness")
fixture.radio.values[109] = {}
fixture.reset()
