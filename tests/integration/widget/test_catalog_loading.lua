-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local developmentLayoutsPath = root .. "/tests/fixtures/layouts/development/"
local hostIo = fixture.hostIo
local moduleLoader = fixture.module
local resetRadio = fixture.reset
local tick = fixture.tick
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local themeModule = fixture.module("lib/theme.lua")
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local pump = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
local REFERENCE_LAYOUT = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))().REFERENCE_LAYOUT
local SHIPPED_TYPES = {
    "metric",
    "flight-timer",
    "flight-mode",
    "tx-battery",
    "trim-panel",
    "model-identity",
    "rx-battery",
    "link-status",
    "navigation",
}
local referencePath = makeWidget("reference", REFERENCE_LAYOUT)
local galleryFile = assert(hostIo.open(root .. "/tests/fixtures/layouts/default-gallery.yaml", "r"))
local galleryPath = makeWidget("default-gallery", galleryFile:read("*a"))
galleryFile:close()
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local function testRendersInBothModes(label, zone, path, expected)
    local context = createLoaded(zone, DEFAULT_OPTIONS, path or referencePath)

    assertEqual(#context.errors, 0, label .. ": " .. table.concat(context.errors, "\n"))
    assertEqual(#context.panels, expected or 5, label .. ": panel count")

    fixture.assertContained(context, label)
    fixture.assertNoOverlap(context)

    return context
end

local function testSessionArmsTheFlight()
    local function dashboard(sessionBlock)
        return table.concat({
            "version: 1",
            "grid:",
            "  columns: 4",
            "  rows: 4",
            "panels:",
            "  - id: peak",
            "    type: link-status",
            "    col: 0",
            "    row: 0",
            "    colSpan: 2",
            "    rowSpan: 1",
            "    config:",
            "      label: Link",
            "      reading: rssi",
            "      rssiSource: RSSI",
            sessionBlock,
        }, "\n") .. "\n"
    end

    local function flightOf(yaml)
        resetRadio()
        local widget = makeWidget("session-arm", yaml)
        local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widget)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        local registry = context.serviceRuntime
        local armed = registry and registry.byId and registry.byId.armed
        assert(armed, "the dashboard built no armed service")
        return armed:state()
    end

    -- Configured is the service's own word for "an arm source was supplied",
    -- so it is the value the contract names rather than a proxy for it.
    local armed = flightOf(dashboard("session:\n  armSource: SFv"))
    assertEqual(armed.configured, true, "the layout named an arm switch and the flight session did not see it")
    assertEqual(armed.condition, "SFv", "a released session arm switch converts to the model Armed condition")

    local unarmed = flightOf(dashboard("# no session block"))
    assertEqual(unarmed.configured, false, "a dashboard that names no arm switch reported one anyway")
end

local function testRemovedFlightMinimumLoadsAsSource()
    local yaml = table.concat({
        "version: 5",
        "grid:",
        "  columns: 4",
        "  rows: 4",
        "panels:",
        "  - id: peak",
        "    type: link-status",
        "    col: 0",
        "    row: 0",
        "    colSpan: 2",
        "    rowSpan: 1",
        "    config:",
        "      label: Kept",
        "      reading: rssi",
        "      rssiSource: RSSI",
        "      extrema: flight",
    }, "\n") .. "\n"
    resetRadio()
    local widget = makeWidget("flight-minimum", yaml)
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widget)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    local link = entryById(context, "peak").instance
    assertEqual(link.settings.extrema, "source")
    assertEqual(link.settings.label, "Kept")
    assertEqual(link.minimumFeed.name, "RSSI-")
end

local function testSpanGalleryIsComplete()
    local panelHost = assert(loadfile(sourcePath .. "lib/panel_host.lua"))()

    local listingPath = root .. "/build/gallery-panels.txt"
    os.execute("ls '" .. sourcePath .. "panels' > '" .. listingPath .. "'")
    local listing = assert(hostIo.open(listingPath, "r"))
    local stems = {}
    for name in listing:lines() do
        local stem = string.match(name, "^(.+)%.lua$")
        if stem then
            stems[#stems + 1] = stem
        end
    end
    listing:close()
    os.remove(listingPath)
    assert(#stems > 0, "no panels were found to compare")

    local source = assert(hostIo.open(root .. "/tests/fixtures/layouts/span1x1.yaml", "r"))
    local gallery = source:read("a")
    source:close()

    local compared = 0
    for _, stem in ipairs(stems) do
        local module = moduleLoader("panels/" .. stem .. ".lua")
        if panelHost.supportsSpan(module, 1, 1) then
            compared = compared + 1
            assert(
                string.find(gallery, "type: " .. stem, 1, true),
                stem
                    .. " declares a 1 x 1 span but is missing from the 1 x 1 gallery,"
                    .. " so nothing is comparing it against the rest of the catalogue"
            )
        end
    end

    -- A gallery that compared one panel would satisfy every assertion above.
    -- Eleven, not thirteen: `heartbeat` and `placeholder` are fixtures now and
    -- are not in the shipped directory this reads, so they cannot be missing
    -- from a gallery they no longer belong in.
    assert(compared >= 11, "only " .. compared .. " panels were compared at 1 x 1")
end

local function testStatesCoverBothPalettes()
    local handle = assert(hostIo.open(developmentLayoutsPath .. "states.yaml", "r"))
    local layout = handle:read("a")
    handle:close()

    assert(
        not string.match(layout, "\ntheme:"),
        "states.yaml pins a theme, so both of its screens resolve the same palette"
            .. " and the light tints cannot be looked at"
    )

    local widgetPath = makeWidget("states-palettes", layout)

    --- Build the states layout under one Theme option and report what it drew.
    local function render(mode)
        resetRadio()
        local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "main", Theme = mode }, widgetPath)
        pump(context, 60)
        assertEqual(#context.errors, 0, mode .. ": " .. table.concat(context.errors, "\n"))
        return context
    end

    for _, mode in ipairs({ "modern-dark", "modern-light" }) do
        local context = render(mode)
        assertEqual(context.theme.mode, mode, "the Theme option did not decide the palette")

        -- Configured to be critical is not the same as being critical. The
        -- thresholds are rigged so the state is permanent, but that was only ever
        -- checked against Modern, and a palette is free to resolve differently.
        local critical = entryById(context, "s-critical")
        assert(critical, mode .. ": the states layout has no critical panel")
        assertEqual(critical.instance.stateName, "critical", mode .. ": the panel meant to be critical is not")

        local warning = entryById(context, "s-warning")
        assertEqual(warning.instance.stateName, "warning", mode .. ": the panel meant to be warning is not")

        -- And each is actually drawn on its tint, rather than merely resolving to
        -- a state that has one.
        assertEqual(
            critical.instance.panel.background.properties.color,
            context.theme.alertColor.critical,
            mode .. ": the critical panel is not drawn on the critical tint"
        )
        assertEqual(
            warning.instance.panel.background.properties.color,
            context.theme.alertColor.warning,
            mode .. ": the warning panel is not drawn on the warning tint"
        )
    end

    -- Both palettes must provide their own light/dark state tints.
    local modern = render("modern-dark").theme
    local light = render("modern-light").theme
    assert(
        modern.alertRgb.critical ~= light.alertRgb.critical,
        "both palettes resolve the same critical tint, so the second screen shows" .. " nothing the first does not"
    )
    assert(modern.alertRgb.warning ~= light.alertRgb.warning, "both palettes resolve the same warning tint")
end

local function testShippedLayout()
    testSessionArmsTheFlight()
    testRemovedFlightMinimumLoadsAsSource()
    testSpanGalleryIsComplete()
    testStatesCoverBothPalettes()
    resetRadio()
    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = testRendersInBothModes("gallery", zone, galleryPath, 10)
    assertEqual(context.layoutPath, galleryPath .. "layouts/Default.yaml")

    local types = {}
    for _, entry in ipairs(context.panels) do
        types[entry.module.id] = true
    end
    for _, wanted in ipairs(SHIPPED_TYPES) do
        assert(types[wanted], "the shipped dashboard does not demonstrate " .. wanted)
    end

    -- Every panel must survive real radio state, not merely construction.
    for _ = 1, 80 do
        tick(20)
        definition.refresh(context)
    end
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

    -- The altitude metric uses the explicit fixture settings.
    local altitude = entryById(context, "altitude").instance
    assertEqual(altitude.settings.label, "ALT")
    assertEqual(altitude.settings.source, "Alt")
    assertEqual(altitude.feed.name, "Alt")
    assertEqual(altitude.detailFeed.name, "Alt+", "the metric lost its maximum source")
    assertEqual(altitude.secondaryFeed.name, "VSpd")
    assertEqual(altitude.value.properties.text, "100")

    -- And the panels that read the radio rather than the link.
    assertEqual(entryById(context, "flight-clock").instance.text, "1:30")
    assertEqual(entryById(context, "mode").instance.text, "Sport")
    -- Digits alone: the `V` is its own label riding beside them.
    local radioBattery = entryById(context, "radio-battery").instance
    assertEqual(radioBattery.text, "7.9")
    assertEqual(radioBattery.unit.properties.text, "V")
    assertEqual(entryById(context, "rates").instance.text, "4.5")
    assertEqual(entryById(context, "identity").instance.text, "Test Model")
    assertEqual(entryById(context, "trims").instance.indicators[1].valueText, "+23% A")

    -- The three telemetry panels, reading what the radio really reports.
    local pack = entryById(context, "pack").instance
    -- Digits alone, with the `V` riding beside them in its own label.
    assertEqual(pack.text, "4.09", "the lowest cell is the safety reading")
    assertEqual(pack.unit.properties.text, "V")
    -- The shipped pack is 2 x 1, which is 65 px tall, and sheds its supporting
    -- row to keep the reading large. This used to assert the row's text anyway:
    -- the label was hidden and its content was still being computed, so the
    -- assertion described a string nothing drew. A row that is not shown is now
    -- not fitted either, which is what made that visible.
    assertEqual(pack.showDetail, false, "a 2 x 1 cell panel is tall enough for a supporting row after all")
    assertEqual(pack.countLabel.hidden, true)
    assertEqual(pack.packLabel.hidden, true)

    local link = entryById(context, "link").instance
    assertEqual(link.primaryName, "quality", "auto must prefer link quality")
    assertEqual(link.text, "96")
    assertEqual(link.stateName, "normal")

    local nav = entryById(context, "nav").instance
    assertEqual(nav.text, "778")
    -- Both supporting wordings share one row, and on a 2 x 2 panel neither full
    -- wording fits. The bearing needs 89 px of the 87 it is given, so it sheds
    -- its compass point and keeps the number, which is the measurement; the
    -- caption sheds its last two words. Before this the bearing simply overran
    -- its box and the caption read "NORTH UP FROM" on a radio.
    assertEqual(nav.detail, nil)
    assertEqual(nav.origin, "")
    for _, row in ipairs({ { nav.origin, nav.originWidth } }) do
        local needed = themeModule.textWidth(nav.fonts.label, row[1])
        assert(
            needed <= row[2],
            string.format("the shipped navigation panel draws %q, needing %d px of %d", row[1], needed, row[2])
        )
    end
    assert(nav.tape, "the shipped dashboard must demonstrate the tape")
end

testShippedLayout()
