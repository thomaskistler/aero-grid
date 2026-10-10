-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local fixture = WidgetFixture.new()
fixture.reset()
local yaml = fixture.module("lib/yaml.lua")
local themeDocument = assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, yaml)
local function loadTheme()
    local module = fixture.module("lib/theme.lua")
    assert(module.setCatalog(themeDocument))
    return module
end
local context = fixture.createLoaded(nil, { Layout = "review-navigation", Theme = "modern-dark" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(#context.panels, 6)
fixture.assertNoOverlap(context)
for _, id in ipairs({ "detailed", "compass", "compact", "wide-distance", "bearing" }) do
    local instance = fixture.instanceOf(context, id)
    assert(instance.feed.fix, id .. " must have a GPS fix")
    assert(instance.feed.home, id .. " must have home coordinates")
    assertions.assertEqual(instance.stateName, "normal")
end
assertions.assertEqual(fixture.instanceOf(context, "unavailable").stateName, "unavailable")
local compass = fixture.instanceOf(context, "compass").compass
assert(fixture.instanceOf(context, "compass").showCompass, "review screen must show the compass")
assertions.assertEqual(#compass.rings, 1)
assertions.assertEqual(#compass.ticks, 24)
assertions.assertEqual(compass.ring.properties.bgStartAngle, 0)
assertions.assertEqual(compass.ring.properties.bgEndAngle, 360)
assertions.assertEqual(#compass.labels, 4)
assertions.assertEqual(#compass.pointers, 2)
for index, caption in ipairs({ "N", "E", "S", "W" }) do
    assertions.assertEqual(compass.labels[index].properties.text, caption)
    assert(not compass.labels[index].hidden)
end
for _, pointer in ipairs(compass.pointers) do
    assert(not pointer.hidden)
    assertions.assertEqual(
        pointer.properties.color,
        fixture.instanceOf(context, "compass").state("normal", "green").accent
    )
end
local primitives = fixture.module("lib/primitives.lua")
assert(not fixture.instanceOf(context, "compass").showCoordinates, "2x2 compass must omit coordinates")
local detailed = fixture.instanceOf(context, "detailed")
assert(detailed.showCoordinates, "detailed panel must retain its coordinate row")
local priorBearing = detailed.detail
local priorCoordinates = detailed.coordinates
fixture.radio.values[109].lat = fixture.radio.values[109].lat + 0.002
fixture.radio.values[109].lon = fixture.radio.values[109].lon + 0.005
fixture.pump(context, 40)
assert(detailed.detail ~= priorBearing, "visible bearing must follow GPS changes")
assert(detailed.coordinates ~= priorCoordinates, "visible coordinates must follow GPS changes")
assertions.assertEqual(detailed.origin, "")
assertions.assertEqual(detailed.detailLabel.properties.text, detailed.detail)
assertions.assertEqual(detailed.coordinatesLabel.properties.text, detailed.coordinates)
for bearing = 0, 359 do
    local triangles = primitives.compassPoints(compass, bearing)
    for _, label in ipairs(compass.labels) do
        local properties = label.properties
        local width, height = lcd.sizeText(properties.text, compass.font)
        local nearestX = math.max(properties.x, math.min(compass.centreX, properties.x + width))
        local nearestY = math.max(properties.y, math.min(compass.centreY, properties.y + height))
        local clearance = math.sqrt((nearestX - compass.centreX) ^ 2 + (nearestY - compass.centreY) ^ 2)
        for _, points in ipairs(triangles) do
            for _, point in ipairs(points) do
                local reach = math.sqrt((point[1] - compass.centreX) ^ 2 + (point[2] - compass.centreY) ^ 2)
                assert(reach + 2 <= clearance, "pointer must clear cardinal text at every bearing")
            end
        end
    end
end
local navigation = fixture.module("panels/navigation.lua")
local theme = loadTheme()
assertions.assertEqual(navigation.bearingText({ bearing = 29 }, theme, TINSIZE, 20, "quadrant"), "NE")
for _, rect in ipairs({ { w = 238, h = 134 }, { w = 238, h = 110 }, { w = 359, h = 134 } }) do
    local layout = navigation.presentationFor("compass")
    layout.keepCompass = true
    local area = navigation.regionsFor(
        theme.build("modern-dark"),
        theme,
        rect,
        layout,
        theme.typography(2, 2),
        { digits = navigation.DIGITS, unit = navigation.UNIT }
    )
    assert(area.showCompass, "explicit compass must survive standard two-row panels")
end
context.zone.w = 320
context.zone.h = 240
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
fixture.assertNoOverlap(context)
context.zone.w = 480
context.zone.h = 272
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
fixture.assertNoOverlap(context)
fixture.reset()

for _, showBearing in ipairs({ false, true }) do
    for _, showCoordinates in ipairs({ false, true }) do
        local navigation = fixture.module("panels/navigation.lua")
        local theme = loadTheme()
        local settings = { presentation = "compass", showBearing = showBearing, showCoordinates = showCoordinates }
        local layout = navigation.presentationFor(settings.presentation)
        layout.showDetail = settings.showBearing
        layout.showCoordinates = settings.showCoordinates
        layout.keepCompass = true
        local area = navigation.regionsFor(
            theme.build("modern-dark"),
            theme,
            { w = 238, h = 134 },
            layout,
            theme.typography(2, 2),
            { digits = navigation.DIGITS, unit = navigation.UNIT }
        )
        assertions.assertEqual(area.showDetail, showBearing)
        assertions.assertEqual(area.showCoordinates, showCoordinates)
        assert(area.showCompass, "row toggles must not remove the compass")
        if showCoordinates and not showBearing then
            assertions.assertEqual(area.coordinatesY, area.detailY, "coordinate-only footer must use its first row")
        end
        local host = fixture.module("lib/panel_host.lua")
        local resolved = host.resolveSettings(navigation, settings)
        local instance = navigation.create(
            lvgl.box({ x = 0, y = 0, w = 238, h = 134 }),
            { w = 238, h = 134 },
            resolved,
            {
                theme = theme.build("modern-dark"),
                themeBuilder = theme,
                primitives = fixture.module("lib/primitives.lua"),
                fonts = theme.typography(2, 2),
                span = { colSpan = 2, rowSpan = 2 },
                state = detailed.state,
                navigation = detailed.service,
            }
        )
        assertions.assertEqual(instance.showDetail, showBearing)
        assertions.assertEqual(instance.showCoordinates, showCoordinates)
        assertions.assertEqual(instance.detailLabel.hidden, not showBearing)
        if showCoordinates then
            assert(not instance.coordinatesLabel.hidden)
        end
        navigation.update(instance, { w = 238, h = 134 })
        assertions.assertEqual(instance.showDetail, showBearing)
        assertions.assertEqual(instance.showCoordinates, showCoordinates)
    end
end
