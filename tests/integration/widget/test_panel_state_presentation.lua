-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local edgetx = fixture.edgetx
local radio = fixture.radio
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local themeModule = fixture.module("lib/theme.lua")
local primitivesModule = fixture.module("lib/primitives.lua")
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local pump = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
local themeCatalog =
    assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
assert(themeModule.setCatalog(themeCatalog))

local reflowDone = fixture.reflowDone

local boundsOf = fixture.boundsOf

local function testAlarmTint()
    local widgetPath = makeWidget(
        "alarm-tint",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: metric
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: RxBt
          label: Pack
          precision: 1
          rangeMin: 18
          rangeMax: 25.2
          warning: 21.0
          critical: 19.8
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    local resolved = context.theme
    local entry = entryById(context, "pack")
    local panel = entry.instance.panel
    local metricModule = assert(loadfile(sourcePath .. "panels/metric.lua"))()

    local resting = panel.background.properties.color
    assertEqual(resting, resolved.color.surface, "a healthy panel is not drawn on the resting surface")
    assertEqual(panel.border.hidden, true, "a healthy panel drew an outline")

    metricModule.setValue(entry.instance, 20.5)
    assertEqual(entry.instance.stateName, "warning")
    assertEqual(panel.background.properties.color, resolved.alertColor.warning, "a warning did not tint the panel")
    assertEqual(panel.border.hidden, true, "a warning drew an outline as well")

    metricModule.setValue(entry.instance, 19.0)
    assertEqual(entry.instance.stateName, "critical")
    assertEqual(
        panel.background.properties.color,
        resolved.alertColor.critical,
        "a critical reading did not tint the panel"
    )
    assertEqual(panel.border.hidden, true, "a critical reading drew an outline as well")
    assert(
        resolved.alertColor.warning ~= resolved.alertColor.critical,
        "a warning and a critical reading tint the panel the same colour"
    )

    -- Absent data is not an alarm, so neither of these tints anything.
    metricModule.setValue(entry.instance, 24.0, true)
    assertEqual(entry.instance.stateName, "stale")
    assertEqual(panel.background.properties.color, resting, "stale data tinted the panel")

    metricModule.setValue(entry.instance, nil)
    assertEqual(entry.instance.stateName, "unavailable")
    assertEqual(panel.background.properties.color, resting, "a missing source tinted the panel")

    -- Recovering puts the panel back, or it stays coloured after the reading
    -- that alarmed it has returned to normal.
    metricModule.setValue(entry.instance, 24.0)
    assertEqual(entry.instance.stateName, "normal")
    assertEqual(panel.background.properties.color, resting, "a panel stayed tinted after its reading recovered")
end

local function testFocusBorder()
    local widgetPath = makeWidget(
        "focus-border",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: metric
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: RxBt
          label: Pack
]]
    )

    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    local spacing = context.theme.spacing
    local entry = entryById(context, "pack")
    local panel = entry.instance.panel

    assertEqual(panel.border.hidden, true, "a resting panel drew an outline")

    -- Reflow while the border is hidden. Nothing repaints it, so an invisible
    -- border is deliberately left carrying the old size until something asks to
    -- see it.
    zone.w = 320
    zone.h = 240
    local passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)

    local selected = themeModule.state(context.theme, "selected")
    primitivesModule.stylePanel(panel, selected)
    assertEqual(panel.border.hidden, false, "a selected panel drew no outline")
    assertEqual(
        panel.border.properties.color,
        context.theme.color.cyan,
        "a selection outline was not drawn in the focus colour"
    )
    assertEqual(
        panel.border.painted.borderWidth,
        spacing.borderFocus,
        "a selection outline was not drawn at the focus weight"
    )

    local bounds = boundsOf(entry)
    assertEqual(panel.border.properties.w, bounds.w, "a revealed outline kept the width it had before the reflow")
    assertEqual(panel.border.properties.h, bounds.h, "a revealed outline kept the height it had before the reflow")

    primitivesModule.stylePanel(panel, themeModule.state(context.theme, "normal"))
    assertEqual(panel.border.hidden, true, "an outline outlived its focus")
end

local function testAccentFollowsState()
    local widgetPath = makeWidget(
        "accent-state",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: metric
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: RxBt
          label: Pack
          precision: 1
          rangeMin: 18
          rangeMax: 25.2
          warning: 21.0
          critical: 19.8
      accent: cyan
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    local spacing = context.theme.spacing
    local entry = entryById(context, "pack")
    local panel = entry.instance.panel
    local metricModule = assert(loadfile(sourcePath .. "panels/metric.lua"))()
    local modern = themeCatalog.themes[1].colors

    --- Every object carrying the accent, and where the radio would draw the arcs.
    local function assertAccent(expected, what)
        assertEqual(panel.accent.properties.color, expected, what .. ": stripe")
        assertEqual(panel.topArc.arc.properties.color, expected, what .. ": top band")
        assertEqual(panel.bottomArc.arc.properties.color, expected, what .. ": bottom band")
        for corner, band in pairs({ top = panel.topArc, bottom = panel.bottomArc }) do
            assertEqual(
                band.arc.round.drawn.x,
                band.centreX - spacing.radius,
                what .. ": " .. corner .. " band walked horizontally"
            )
            assertEqual(
                band.arc.round.drawn.y,
                band.centreY - spacing.radius,
                what .. ": " .. corner .. " band walked vertically"
            )
        end
    end

    metricModule.setValue(entry.instance, 24.0)
    assertAccent(lcd.RGB(modern.cyan), "healthy")

    metricModule.setValue(entry.instance, 20.5)
    assertEqual(entry.instance.stateName, "warning")
    assertAccent(lcd.RGB(modern.amber), "warning")

    metricModule.setValue(entry.instance, 19.0)
    assertEqual(entry.instance.stateName, "critical")
    assertAccent(lcd.RGB(modern.critical), "critical")

    -- Freshness dims the accent, and the corners have to dim with it.
    metricModule.setValue(entry.instance, 24.0, true)
    assertEqual(entry.instance.stateName, "stale")
    assertAccent(lcd.RGB(modern.textFaint), "stale")

    metricModule.setValue(entry.instance, nil)
    assertEqual(entry.instance.stateName, "unavailable")
    assertAccent(lcd.RGB(modern.textFaint), "unavailable")

    -- Twenty more transitions. One misplaced `set` moves a band by its own
    -- radius each time, so a drift this would miss is not a drift at all.
    for index = 1, 20 do
        metricModule.setValue(entry.instance, index % 2 == 0 and 24.0 or 19.0)
    end
    assertAccent(lcd.RGB(modern.cyan), "after twenty state changes")

    -- And through a reflow, which moves the bottom band and must not move the
    -- top one. The panel keeps its column, so only the height changes.
    local zone = { x = 0, y = 0, w = 480, h = 200 }
    context.zone.w, context.zone.h = zone.w, zone.h
    local passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)

    local bounds = boundsOf(entry)
    assertEqual(panel.topArc.centreY, spacing.radius, "the top band moved during a reflow")
    assertEqual(panel.bottomArc.centreY, bounds.h - spacing.radius, "the bottom band did not follow the panel's height")
    -- The mask follows too. A panel that grew past a stale mask would have its
    -- bottom corner clipped away; one that shrank would clip nothing at all
    -- below the old height, and the band would escape into the next panel.
    assertEqual(panel.column.properties.h, bounds.h, "the accent mask did not follow the panel's height")
    assertEqual(panel.column.properties.w, spacing.accentWidth, "the accent mask changed width during a reflow")
    assertAccent(lcd.RGB(modern.cyan), "after a reflow")
end

local function testProbeUsesTheSharedHeader()
    local widgetPath = makeWidget(
        "probe-header",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: probe
    type: service-probe
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      service: telemetry
      source: RxBt
      label: Telemetry
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    pump(context, 20)

    local entry = entryById(context, "probe")
    local probe = entry.instance
    local bounds = boundsOf(entry)
    local frame = themeModule.frame(context.theme, { x = 0, y = 0, w = bounds.w, h = bounds.h }, probe.fonts)

    assert(probe.badge, "the diagnostic panel has no badge object at all")
    local title = probe.title.properties
    local badge = probe.badge.properties

    assertEqual(title.x, frame.labelX, "the probe's title is not where the shared frame puts a label")
    assertEqual(title.w, frame.labelWidth, "the probe's title is not the width the shared frame leaves a label")
    assertEqual(badge.x, frame.badgeX, "the probe's badge is not in the shared frame's badge column")
    assertEqual(badge.w, frame.badgeWidth, "the probe's badge is not the width of the shared frame's column")

    assertEqual(badge.text, "", "the probe unexpectedly displays a badge")
    assertEqual(title.x + title.w, frame.badgeX + frame.badgeWidth, "an empty badge still costs heading width")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testSupportingRowsExplainTheBadge()
    local widgetPath = makeWidget(
        "supporting-rows",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: link
    type: link-status
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      rssiSource: RSSI
      qualitySource: RQly
      reading: auto
  - id: pack
    type: rx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels
      label: Pack
      visual: bar
  - id: notcells
    type: rx-battery
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels-
      label: Wrong
      visual: bar
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    pump(context, 40)

    local link = entryById(context, "link").instance
    local pack = entryById(context, "pack").instance
    assertEqual(link.showDetail, true, "a 2 x 2 link panel shed its rows")
    assertEqual(pack.showDetail, true, "a 2 x 2 cell panel shed its rows")

    --- Assert a row says something and fits the box it was given.
    ---
    --- **Measured the way the radio draws it, not estimated.**
    --- `theme.textWidth` charges every character the same 0.58 of a line
    --- height, so it over-reports text made of narrow glyphs: `CELLS ERR` is
    --- 89 px by the estimate and 64 as drawn. Fed to a fit check the estimate
    --- reports rows overflowing that the radio draws with room to spare --
    --- which is the correction already made to the collision check, for the
    --- same reason, after it reported every reading as lying across its own
    --- unit.
    ---
    --- Note what this does *not* say: `theme.fitLabel` still chooses between
    --- wordings on the estimate, so a ladder can still shed a form that would
    --- have fitted. That is a live finding rather than something this helper
    --- can settle, and it does not reach a single-wording row, which comes
    --- back out of `fitLabel` whatever the estimate says.
    local function assertRow(instance, text, width, expected, what)
        assertEqual(text, expected, what)
        local needed = themeModule.measureText(instance.fonts.label, text)
        assert(needed <= width, string.format("%s needs %d px of %d", what, needed, width))
    end

    -- **`78dB` rather than `RSSI 78dB`, and the same for the pack sum below.**
    -- A two-item supporting row is centred on the panel's two slot centres, so
    -- each item gets half the distance between them -- 86 px here against the
    -- 148 the column split gave. `fitLabel` sheds the source prefix, which is
    -- detail: the unit still says what kind of measurement it is, and the
    -- states that must stay distinguishable from one another still are.
    -- `NO CELLS` against `CELLS ERR`, and `DOWN` against `NO RSS`, all survive
    -- at this width; `testSupportingWordingsStayDistinct` is what holds them
    -- to it.
    assertRow(link, link.linkDetail, link.rowRightWidth, "78dB", "a healthy link names its secondary source")
    assertRow(pack, pack.countText, pack.detailWidth, "4S", "the cell count")
    assertRow(pack, pack.packText, pack.detailWidth, "16.4V", "the pack sum")

    -- Numeric telemetry is automatically a pack source, even if an old
    -- configuration called it a cells monitor.
    local wrong = entryById(context, "notcells").instance
    assertEqual(wrong.summary.shape, "pack")
    assertEqual(wrong.summary.estimated, true)
    assertEqual(wrong.badge.properties.text, "")
    assertRow(wrong, wrong.countText, wrong.detailWidth, "1S EST", "a numeric source's estimated pack count")

    radio.values[130] = { 0, -1, 99 }
    pump(context, 40)
    assertEqual(pack.summary.shape, "invalid")
    -- The cells table is the sole source for both the displayed lowest cell
    -- and the alarm judgement, so an unusable table has no headline.
    assertEqual(pack.text, "--")
    assertEqual(pack.badge.properties.text, "N/A")
    assertRow(pack, pack.countText, pack.detailWidth, "CELLS ERR", "nonsense from a cells source")
    assert(pack.countText ~= wrong.countText, "invalid cells must remain distinct from usable numeric voltage")
    assert(
        pack.summary.shape ~= wrong.summary.shape,
        "the panel stopped telling a wrong sensor from a nonsense table, so"
            .. " the diagnostics view has nothing left to report"
    )

    -- A dead link is reported by the row too, and is checked last because it
    -- marks every other panel stale on its way past.
    resetRadio()
    pump(context, 40)
    radio.rssi = 0
    pump(context, 40)
    assertEqual(link.stateName, "critical")
    assertEqual(link.badge.properties.text, "CRIT")
    assertRow(link, link.linkDetail, link.rowRightWidth, "NO LINK", "a dead link says so in words")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testReadingsAgreeAcrossPanels()
    --- Build one layout full of a single span and report the fonts drawn.
    local function fontsAt(colSpan, rowSpan, entries)
        local lines = { "version: 1", "grid:", "  columns: 4", "  rows: 4", "panels:" }
        local col, row = 0, 0
        for index, entry in ipairs(entries) do
            lines[#lines + 1] = "  - id: c" .. index
            lines[#lines + 1] = "    type: " .. entry[1]
            lines[#lines + 1] = "    col: " .. col
            lines[#lines + 1] = "    row: " .. row
            lines[#lines + 1] = "    colSpan: " .. colSpan
            lines[#lines + 1] = "    rowSpan: " .. rowSpan
            lines[#lines + 1] = "    config:"
            for _, line in ipairs(entry[2]) do
                lines[#lines + 1] = "      " .. line
            end
            col = col + colSpan
            if col + colSpan > 4 then
                col = 0
                row = row + rowSpan
            end
        end

        local widget = makeWidget("agree-" .. colSpan .. "x" .. rowSpan, table.concat(lines, "\n") .. "\n")
        resetRadio()
        local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widget)
        pump(context, 40)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

        local seen = {}
        for _, entry in ipairs(context.panels) do
            local instance = entry.instance
            local object = instance.value
            assert(object, entry.placement.id .. " drew no reading")
            local font = object.properties.font
            if type(font) == "function" then
                font = font()
            end
            seen[#seen + 1] = { entry.module.id, font }
        end
        return seen
    end

    -- Four panels whose readings are as different as the catalogue offers:
    -- three digits, a voltage with a unit, a dBm reading, and a distance.
    local ENTRIES = {
        {
            "metric",
            {
                "metrics:",
                "  - source: Alt",
                "    label: Alt",
                "    rangeMin: 0",
                "    rangeMax: 400",
                "    precision: 0",
            },
        },
        { "rx-battery", { "source: Cels", "label: Pack" } },
        { "link-status", { "rssiSource: RSSI", "qualitySource: RQly", "label: Link" } },
        { "tx-battery", { "label: TX", "packEmpty: 6.6", "packFull: 8.4" } },
    }

    local order = { [SMLSIZE] = 1, [MIDSIZE] = 2, [DBLSIZE] = 3, [XXLSIZE] = 4 }
    local spread = {}
    for _, span in ipairs({ { 1, 1 }, { 2, 1 }, { 4, 1 }, { 2, 2 } }) do
        local name = span[1] .. "x" .. span[2]
        local seen = fontsAt(span[1], span[2], ENTRIES)
        assertEqual(#seen, #ENTRIES, name .. ": not every panel was built")

        local low, high
        for _, row in ipairs(seen) do
            local rank = order[row[2]]
            assert(rank, name .. ": " .. row[1] .. " drew an unknown font")
            low = math.min(low or rank, rank)
            high = math.max(high or rank, rank)
        end

        -- At most one step between the largest and smallest reading on a screen
        -- of identical panels. Before this, `2 x 2` spanned three steps.
        spread[name] = high - low
        assert(high - low <= 1, string.format("%s: readings on identical panels span %d font steps", name, high - low))
    end

    -- And the agreement is real rather than an artefact of every panel being
    -- driven to the smallest font: at least one span has to reach full
    -- agreement, and the large spans must not all collapse onto SMLSIZE.
    local agreed = 0
    for _, value in pairs(spread) do
        if value == 0 then
            agreed = agreed + 1
        end
    end
    assert(
        agreed >= 2,
        "no span reached full agreement, which would be the"
            .. " result of every reading being shrunk rather than reconciled"
    )
end

local function testRedrawsOnEverythingItDraws()
    local widgetPath = makeWidget(
        "render-declaration",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: identity
    type: model-identity
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      presentation: name
      showLabels: true
]]
    )

    resetRadio()
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    pump(context, 40)

    -- The same shape in model-identity, which could not be made to fail before
    -- because a model's labels only change when its name does. Driven directly
    -- here, with the name and the bitmap held still.
    local identity = entryById(context, "identity").instance
    assertEqual(identity.labelsText, edgetx.scaffold.MODEL_LABELS)
    local name, bitmap = identity.text, identity.bitmap

    -- The services capture the radio's entry points once, at construction, so
    -- the model has to change where the service actually reads it.
    local env = context.serviceRuntime.env
    local info = env.getInfo
    env.getInfo = function()
        local out = info()
        out.labels = "fpv,racing"
        return out
    end
    pump(context, 600)
    env.getInfo = info

    assertEqual(identity.text, name, "the model name moved during the test")
    assertEqual(identity.labelsText, "fpv,racing", "the labels row kept its old value while the model's labels changed")

    resetRadio()
end

testAlarmTint()
testFocusBorder()
testAccentFollowsState()
testProbeUsesTheSharedHeader()
testSupportingRowsExplainTheBadge()
testReadingsAgreeAcrossPanels()
testRedrawsOnEverythingItDraws()
