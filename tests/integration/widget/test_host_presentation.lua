-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local lvglMock = fixture.lvglMock
local settleLvgl = fixture.lvglMock.settle
local appZone = fixture.lvglMock.appZone
local fullScreenZone = fixture.lvglMock.fullScreenZone
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local themeModule = fixture.module("lib/theme.lua")
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local panelOf = fixture.panelOf
local pump = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
local REFERENCE_LAYOUT = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))().REFERENCE_LAYOUT
local referencePath = makeWidget("reference", REFERENCE_LAYOUT)
local themeCatalog =
    assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
assert(themeModule.setCatalog(themeCatalog))
local appContext

local assertFont = fixture.assertFont

local boundsOf = fixture.boundsOf

local function testRendersInBothModes(label, zone, path, expected)
    local context = createLoaded(zone, DEFAULT_OPTIONS, path or referencePath)

    assertEqual(#context.errors, 0, label .. ": " .. table.concat(context.errors, "\n"))
    assertEqual(#context.panels, expected or 5, label .. ": panel count")

    fixture.assertContained(context, label)
    fixture.assertNoOverlap(context)

    return context
end

local function testThemeReachesPanels()
    local modern = themeCatalog.themes[1].colors
    assertEqual(appContext.theme.mode, "modern-dark")
    assertEqual(
        appContext.canvas.properties.color,
        lcd.RGB(modern.canvas),
        "the canvas was not painted in the resolved canvas colour"
    )

    for _, entry in ipairs(appContext.panels) do
        assertEqual(
            entry.instance.panel.background.properties.color,
            lcd.RGB(modern.surface),
            entry.placement.id .. " did not use the theme surface"
        )
    end

    -- Panels receive span-appropriate typography from the host.
    local pack = entryById(appContext, "pack")
    local current = entryById(appContext, "current")
    assertFont(pack.instance.fonts.primary, XXLSIZE)
    assertFont(current.instance.fonts.primary, DBLSIZE)
end

local function testBackgroundsArePainted()
    local function assertPainted(object, what)
        assertEqual(object.kind, "rectangle", what .. " must be a rectangle")
        assertEqual(object.properties.filled, true, what .. " must be filled")
        -- Not merely "has a colour": a surface has to be painted in a value the
        -- host resolved and lcd.RGB encoded. A 24-bit token is not nil either,
        -- and on a radio it paints a colour belonging to no theme.
        local color = object.properties.color
        assert(
            type(color) == "number" and color % 65536 == 0x8000,
            what .. " was not painted in a resolved colour: " .. tostring(color)
        )
    end

    assertPainted(appContext.canvas, "dashboard canvas")

    for _, entry in ipairs(appContext.panels) do
        local panel = entry.instance.panel
        assertPainted(panel.background, entry.placement.id .. " panel background")
        -- Containers and panel roots are boxes, so they must never carry a color.
        assertEqual(entry.container.kind, "box")
        assertEqual(
            entry.container.properties.color,
            nil,
            entry.placement.id .. " container relies on an unpainted box color"
        )
        assertEqual(
            panel.root.properties.color,
            nil,
            entry.placement.id .. " panel root relies on an unpainted box color"
        )
    end
end

local function testPanelPresentation()
    local spacing = appContext.theme.spacing
    local modern = themeCatalog.themes[1].colors

    -- Panels are told apart from the screen by their fill, so the fill has to
    -- be separable by eye. Measured on the tokens, because contrast arithmetic
    -- is defined on 24-bit values and means nothing applied to a flag word.
    assert(
        themeModule.contrast(modern.canvas, modern.surface) >= 1.30,
        "panels are not elevated above the screen they sit on"
    )

    for _, entry in ipairs(appContext.panels) do
        local id = entry.placement.id
        local panel = entry.instance.panel
        local bounds = boundsOf(entry)

        -- No outline at rest. The fill already says where the panel is, and a
        -- border on every panel is a border that says nothing when one of them
        -- needs to shout.
        assertEqual(panel.border.hidden, true, id .. " drew an outline at rest")

        -- Corners: what the radio was given, not what was last passed to `set`.
        assertEqual(
            panel.background.painted.radius,
            spacing.radius,
            id .. " was not rounded to the theme's corner radius"
        )

        -- Everything carrying the accent is a child of a column exactly one
        -- accent width across, and LVGL clips a child to its parent's coordinates
        -- unless the parent carries LV_OBJ_FLAG_OVERFLOW_VISIBLE, which EdgeTX
        -- never sets (`lv_refr.c`, `refr_obj`). The column is therefore a
        -- rectangular mask, and it is what keeps the corner bands inside the
        -- accent's own width instead of bulging into the panel.
        local column = panel.column.properties
        assertEqual(panel.column.kind, "box", id .. " accent mask is not a box")
        assertEqual(column.x, 0, id .. " accent mask left the panel's left edge")
        assertEqual(column.y, 0, id .. " accent mask left the panel's top edge")
        assertEqual(column.w, spacing.accentWidth, id .. " accent mask is not one accent width across")
        assertEqual(column.h, bounds.h, id .. " accent mask does not cover the panel's height")
        -- A box accepts `color` and silently ignores it (constraint 2), so a mask
        -- that asked for one would be relying on that. It asks for none.
        assertEqual(column.color, nil, id .. " accent mask asked for a colour")

        -- The mask only masks what is inside it. An accent object parented to the
        -- panel root would be clipped by the root instead, which is the whole
        -- panel, so it would not be clipped at all.
        --- Name an object's parent, so a mismatch does not read as two addresses.
        local function parentName(object)
            if object.parent == panel.column then
                return "the accent mask"
            end
            if object.parent == panel.root then
                return "the panel root"
            end
            return "something else"
        end
        for what, object in pairs({
            ["accent stripe"] = panel.accent,
            ["top band"] = panel.topArc.arc,
            ["bottom band"] = panel.bottomArc.arc,
        }) do
            assert(
                object.parent == panel.column,
                id
                    .. ": the "
                    .. what
                    .. " is parented to "
                    .. parentName(object)
                    .. " rather than to the"
                    .. " accent mask, so nothing clips it"
            )
        end

        -- The mask has to be load bearing, or asserting its width asserts
        -- nothing. An arc occupies a box of `2 * radius` about its centre, so a
        -- corner band reaches `2 * radius` across where the column allows
        -- `accentWidth`. Without the clip that difference is drawn, which is the
        -- accent bulging out of its own column.
        assert(
            spacing.radius * 2 > spacing.accentWidth,
            id
                .. " the corner bands fit inside the accent width unclipped, so the"
                .. " mask is decorative and proves nothing"
        )

        -- The accent is a plain stripe: constant width, square ends, stopping
        -- where the panel's corner curves away rather than following it round.
        local accent = panel.accent.properties
        assertEqual(accent.x, 0, id .. " moved its accent off the left edge")
        assertEqual(accent.w, spacing.accentWidth, id .. " accent changed width")

        -- Square ends. A radius on a stripe this narrow rounds its caps, which
        -- tapers the band at both ends and is the thing that was rejected.
        assertEqual(panel.accent.painted.radius, 0, id .. " accent was drawn with rounded ends")

        -- The straight run spans exactly the part of the left edge that is
        -- straight: it starts where the top corner's arc ends and stops where the
        -- bottom corner's begins, so stripe and arcs abut at the two tangents.
        assertEqual(accent.y, spacing.radius, id .. " accent does not start at the top corner's tangent")
        assertEqual(
            accent.y + accent.h,
            bounds.h - spacing.radius,
            id .. " accent does not end at the bottom corner's tangent"
        )

        -- A quarter band per corner, carrying the accent round rather than
        -- stopping at it. Centred on the panel's own corner centres and given the
        -- panel's own corner radius, which is what makes the band's outer edge
        -- and the panel's edge the same circle: LVGL draws an arc between
        -- `radius` and `radius - width` from the centre (lv_draw_arc.c, rout and
        -- rin), and the object's box is 2 * radius square about that centre
        -- (LvglWidgetArc::build via setRadius, and get_center in lv_arc.c).
        for corner, band in pairs({ top = panel.topArc, bottom = panel.bottomArc }) do
            local arc = band.arc.properties
            assertEqual(
                arc.radius,
                spacing.radius,
                id .. " " .. corner .. " band does not share the panel's corner radius"
            )
            assertEqual(
                arc.thickness,
                spacing.accentWidth,
                id .. " " .. corner .. " band is not the accent's thickness"
            )
            assertEqual(band.centreX, spacing.radius, id .. " " .. corner .. " band is not on the corner centre")
            -- An arc stores a corner, so what the firmware would draw is checked
            -- through the mock's own reproduction of that arithmetic rather than
            -- through the coordinates it was handed.
            assertEqual(
                band.arc.round.drawn.x,
                band.centreX - spacing.radius,
                id .. " " .. corner .. " band drifted horizontally"
            )
            assertEqual(
                band.arc.round.drawn.y,
                band.centreY - spacing.radius,
                id .. " " .. corner .. " band drifted vertically"
            )
        end

        assertEqual(panel.topArc.centreY, spacing.radius, id .. " top band is not on the top corner centre")
        assertEqual(
            panel.bottomArc.centreY,
            bounds.h - spacing.radius,
            id .. " bottom band is not on the bottom corner centre"
        )

        -- The quarters face the left edge, or the accent would appear on the
        -- right. LVGL measures zero at three o'clock, clockwise.
        assertEqual(panel.topArc.arc.properties.startAngle, 180, id .. " top band does not start at nine o'clock")
        assertEqual(panel.topArc.arc.properties.endAngle, 270, id .. " top band does not end at twelve o'clock")
        assertEqual(panel.bottomArc.arc.properties.startAngle, 90, id .. " bottom band does not start at six o'clock")
        assertEqual(panel.bottomArc.arc.properties.endAngle, 180, id .. " bottom band does not end at nine o'clock")

        -- The surface is the whole panel. The accent is drawn on it, not under it.
        local surface = panel.background.properties
        assertEqual(surface.x, 0, id .. " surface left the panel origin")
        assertEqual(surface.y, 0, id .. " surface left the panel origin")
        assertEqual(surface.w, bounds.w, id .. " surface is not the panel's width")
        assertEqual(surface.h, bounds.h, id .. " surface is not the panel's height")

        -- Content has to clear the band. Every panel under 80 px tall used to
        -- start its text at the accent's own right edge. Checked over whatever
        -- labels the panel actually built, because the catalogue does not
        -- agree on what to call them and the rule is about pixels, not names.
        local labels = 0
        for _, object in ipairs(lvglMock.objects) do
            if object.parent == panel.root and object.kind == "label" and not object.hidden then
                labels = labels + 1
                assert(
                    object.properties.x >= spacing.accentWidth + spacing.accentGap,
                    id .. " drew text against the accent, at x " .. tostring(object.properties.x)
                )
            end
        end
        assert(labels > 0, id .. " drew no text at all")
    end
end

local function testResponsiveSpans()
    local metricModule = assert(loadfile(sourcePath .. "panels/metric.lua"))()

    local small = metricModule.presentationFor(1, 1)
    local wide = metricModule.presentationFor(2, 1)
    local large = metricModule.presentationFor(2, 2)

    assertEqual(small.showUnit, false, "1 x 1 must stay minimal")
    assertEqual(small.showVisual, false)
    assertEqual(wide.showUnit, true, "2 x 1 adds units")
    assertEqual(wide.showRange, false)
    assertEqual(large.showRange, true, "2 x 2 adds the range")

    -- A metric with no supporting entries creates no supporting labels.
    assertEqual(entryById(appContext, "pack").instance.range, nil)
    assertEqual(entryById(appContext, "current").instance.range, nil)
    -- The altitude metric disables its visualization through configuration.
    assertEqual(entryById(appContext, "altitude").instance.bar, nil)
end

local function testReflowAndLifecycle()
    local zone = appContext.zone
    zone.w = 320
    zone.h = 240

    -- Reflow is batched across callbacks, so drain it before asserting.
    local passes = 0
    repeat
        definition.refresh(appContext)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until appContext.width == zone.w
        and appContext.height == zone.h
        and not appContext.reflowIndex
        and appContext.aerogridMenu
        and appContext.aeroMenuWidth == zone.w
        and appContext.aeroMenuZoneHeight == zone.h

    assertEqual(appContext.root.properties.w, 320)
    assertEqual(appContext.root.properties.h, 240)
    assertEqual(appContext.canvas.properties.w, 320)
    assertEqual(panelOf(entryById(appContext, "pack")).w, 158)

    local pulse = entryById(appContext, "pulse")
    assert(
        fixture.pumpUntil(appContext, function()
            return appContext.flightBroker.document.flightCount ~= nil and not appContext.flightBroker.pendingCount
        end),
        "initial count persistence must settle before steady-state lifecycle assertions"
    )
    local ticksBefore = pulse.instance.ticks
    pump(appContext, 2)
    assertEqual(pulse.instance.ticks, ticksBefore + 2, "refresh was not dispatched")

    definition.background(appContext)
    assertEqual(pulse.instance.backgroundTicks, 1, "background was not dispatched")

    -- EdgeTX supplies widget input only in fullscreen.
    assertEqual(definition.event(appContext, 32), false)
    assertEqual(pulse.instance.events, 0, "App-mode input cannot reach panels")
end

local hostTurn = fixture.hostTurn

local function testOptionReload()
    definition.update(appContext, { Layout = "alternate", Theme = "modern-dark" })

    -- A reload discards the whole page and builds the next generation as a
    -- fresh child of the root, which is never cleared. The clearing callback
    -- must create nothing, because EdgeTX may collect the clear much later.
    local discarded = appContext.page
    hostTurn(appContext)
    assertEqual(discarded.cleared, true, "retirement turn did not discard the page")
    assertEqual(appContext.root.cleared, false, "the root must never be cleared")
    assertEqual(appContext.reloadState, "rebuild", "reload did not defer its rebuild")
    assertEqual(appContext.page, nil, "page was recreated in the clearing callback")
    assertEqual(appContext.canvas, nil, "canvas was recreated in the clearing callback")
    assertEqual(appContext.stage, nil, "loading started before the rebuild")

    hostTurn(appContext)
    assert(appContext.page, "rebuild did not create a new page")
    assert(appContext.page ~= discarded, "rebuild reused the discarded page")
    assert(appContext.canvas, "rebuild did not recreate the canvas")
    assert(appContext.stage, "reload did not restage a load")

    local guard = 0
    while appContext.stage do
        definition.refresh(appContext)
        guard = guard + 1
        assert(guard < 200, "reload never finished")
    end
    assertEqual(#appContext.panels, 5)

    -- The rebuilt dashboard must still be usable, which is what the deferred
    -- cleanup broke: the canvas survived creation and then died silently.
    definition.refresh(appContext)
    definition.refresh(appContext)
    assertEqual(#appContext.errors, 0, table.concat(appContext.errors, "\n"))
    appContext.canvas:set({ color = appContext.theme.color.canvas })

    -- Reloading a second time must behave identically.
    definition.update(appContext, { Layout = "main", Theme = "modern-dark" })
    local rounds = 0
    repeat
        definition.refresh(appContext)
        rounds = rounds + 1
        assert(rounds < 200, "second reload never finished")
    until not appContext.optionsRequest and not appContext.stage and not appContext.reloadState
    assertEqual(#appContext.panels, 5)
    assertEqual(#appContext.errors, 0, table.concat(appContext.errors, "\n"))

    -- Switching only the theme must also trigger a rebuild.
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, referencePath)
    definition.update(context, { Layout = "main", Theme = "custom" })
    assertEqual(context.optionsRequest.themeMode, "custom")
    assertEqual(context.reloadState, nil, "native options must wait for a scheduler grant")

    -- Preserve the stored dark/light positions and offer Glass as the next choice.
    local options = definition.options[2]
    assertEqual(options[1], "Theme")
    assertEqual(table.concat(options[4], ","), "Dark,Light,Glass")
    for position, mode in pairs({ [1] = "modern-dark", [2] = "modern-light", [3] = "@glass", [9] = "modern-dark" }) do
        local selected = createLoaded(
            { x = 0, y = 0, w = 480, h = 272 },
            { Layout = "main", Theme = position },
            referencePath
        )
        assertEqual(selected.themeMode, mode, "Theme position " .. position)
    end
end

local function testReloadSurvivesLateCleanup()
    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, referencePath)
    local firstPage = context.page

    definition.update(context, { Layout = "alternate", Theme = "modern-dark" })

    -- Withhold cleanup across the entire reload, the worst case.
    lvglMock.setDeferCleanup(true)
    local guard = 0
    repeat
        definition.refresh(context)
        guard = guard + 1
        assert(guard < 300, "reload never finished while cleanup was withheld")
    until not context.optionsRequest and not context.stage and not context.reloadState

    assert(context.page ~= firstPage, "reload reused the discarded page")
    assertEqual(#context.panels, 5)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

    -- Now let the withheld cleanup land, all at once and late.
    lvglMock.setDeferCleanup(false)
    settleLvgl()

    -- The rebuilt dashboard must still be alive and usable.
    assertEqual(context.canvas.invalid, false, "canvas was swept by late cleanup")
    assertEqual(context.page.invalid, false, "page was swept by late cleanup")
    for _, entry in ipairs(context.panels) do
        assertEqual(entry.container.invalid, false, entry.placement.id .. " was swept by late cleanup")
    end

    context.canvas:set({ color = context.theme.color.canvas })
    definition.refresh(context)
    definition.refresh(context)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testBadgeGeometry()
    local entry = entryById(appContext, "pack")
    local instance = entry.instance
    local label = instance.label.properties
    local badge = instance.badge.properties
    local bounds = boundsOf(entry)

    assert(
        badge.text == "" or label.x + label.w <= badge.x,
        "badge overlaps the label: label ends at " .. (label.x + label.w) .. ", badge starts at " .. badge.x
    )
    assert(badge.x + badge.w <= bounds.w, "badge extends past the panel")
    assert(label.w > 0 and badge.w > 0, "label or badge collapsed")
end

appContext = testRendersInBothModes("app mode", appZone())
testRendersInBothModes("1 x 1", fullScreenZone())
lvglMock.setAppMode(false)
testThemeReachesPanels()
testBackgroundsArePainted()
testPanelPresentation()
testResponsiveSpans()
testBadgeGeometry()
testReflowAndLifecycle()
testOptionReload()
testReloadSurvivesLateCleanup()
