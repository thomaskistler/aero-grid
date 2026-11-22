-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local hostIo = fixture.hostIo
local radio = fixture.radio
local resetRadio = fixture.reset
local tick = fixture.tick
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local writeFile = fixture.writeFile
local makeWidget = fixture.makeWidget
local themeModule = fixture.module("lib/theme.lua")
local layoutStoreModule = fixture.module("lib/layout_store.lua")
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local panelOf = fixture.panelOf
local settle = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
local REFERENCE_LAYOUT = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))().REFERENCE_LAYOUT
local referencePath = makeWidget("reference", REFERENCE_LAYOUT)
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local reflowDone = fixture.reflowDone

local boundsOf = fixture.boundsOf

local function testModelFilenames()
    local previous = radio.modelFilename
    for _, name in ipairs({ "model1.yml", "Kavan Sonic.yml", "FPV-7in.yml" }) do
        radio.modelFilename = name
        local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, referencePath)
        assertEqual(context.layoutPath, referencePath .. "layouts/Default.yaml", "unexpected layout for " .. name)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        assertEqual(#context.panels, 5)
    end
    radio.modelFilename = previous
end

local function probeRows(instance)
    local rows = {}
    for index = 1, #instance.keys do
        local key = instance.keys[index]
        if not key.hidden then
            local label = key.properties.text
            if label ~= "" then
                rows[label] = instance.values[index].properties.text
            end
        end
    end
    return rows
end

local function testServiceDiagnostics()
    resetRadio()
    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local widgetPath = makeWidget("service-diagnostics")

    --- Load one diagnostics page and let its services settle.
    local function page(dashboardId)
        local context = createLoaded(zone, { Layout = dashboardId, Theme = "modern-dark" }, widgetPath)
        -- A dashboard-scoped layout is found without a model-specific file.
        assertEqual(context.layoutPath, widgetPath .. "layouts/" .. dashboardId .. ".yaml")
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        for _ = 1, 80 do
            tick(20)
            definition.refresh(context)
        end
        return context
    end

    local first = page("services")
    assertEqual(#first.panels, 2)

    local telemetry = probeRows(entryById(first, "telemetry").instance)
    assertEqual(telemetry.SRC, "RxBt")
    assertEqual(telemetry.STATE, "NORMAL")
    -- Precision comes from the model's sensor table, not from the layout.
    assertEqual(telemetry.VALUE, "24.00")
    assertEqual(telemetry.UNIT, "V")
    assertEqual(telemetry.PREC, "2")
    assertEqual(telemetry.LINK, "UP")

    local navigation = probeRows(entryById(first, "navigation").instance)
    assertEqual(navigation.GPS, "GPS")
    assertEqual(navigation.FIX, "YES")
    assertEqual(navigation.HOME, "YES")
    assertEqual(navigation.LAT, "47.37690")
    assertEqual(navigation.DIST, "778m")
    assertEqual(navigation.BRG, "9 deg")

    local second = page("services2")
    assertEqual(#second.panels, 2)

    local modelRows = probeRows(entryById(second, "model").instance)
    assertEqual(modelRows.MODEL, "Test Model")
    assertEqual(modelRows.IMAGE, "plane.png")
    assertEqual(modelRows.MODE, "Sport")
    assertEqual(modelRows.TXV, "7.9V")
    assertEqual(modelRows.T0, "1:30")

    local control = probeRows(entryById(second, "control").instance)
    assertEqual(control["TRIM-AIL"], "30 23%")
    assertEqual(control.RATES, "4.5")

    assertEqual(#second.errors, 0, table.concat(second.errors, "\n"))
end

local function testDiagnosticsFitTheirPanels()
    resetRadio()
    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local widgetPath = makeWidget("diagnostics-fit")
    local context = createLoaded(zone, { Layout = "services2", Theme = "modern-dark" }, widgetPath)

    --- Drain a batched reflow.
    local function settle()
        local passes = 0
        repeat
            definition.refresh(context)
            passes = passes + 1
            assert(passes < 100, "reflow never finished")
        until reflowDone(context)
    end

    local function assertContained(what)
        for _, entry in ipairs(context.panels) do
            local bounds = boundsOf(entry)
            local instance = entry.instance
            local lineHeight = themeModule.fontHeight(instance.fonts.label)
            for index = 1, #instance.keys do
                local key = instance.keys[index]
                if not key.hidden then
                    assert(
                        key.properties.y + lineHeight <= bounds.h,
                        what .. ": " .. entry.placement.id .. " row " .. index .. " ran past its panel"
                    )
                    local value = instance.values[index].properties
                    assert(
                        value.x + value.w <= bounds.w,
                        what .. ": " .. entry.placement.id .. " row ran past the right edge"
                    )
                    assert(
                        key.properties.x + key.properties.w <= value.x,
                        what .. ": " .. entry.placement.id .. " label overlaps its value"
                    )
                end
            end
        end
    end

    assertContained("full size")
    local tallest = entryById(context, "model").instance.visibleRows
    assert(tallest > 2, "a 2 x 2 diagnostic panel showed only " .. tallest .. " rows")

    zone.w = 320
    zone.h = 140
    settle()
    assertContained("shrunk")
    assert(entryById(context, "model").instance.visibleRows < tallest, "a shrunk panel did not shed rows")

    zone.w = 480
    zone.h = 272
    settle()
    assertContained("restored")
    assertEqual(
        entryById(context, "model").instance.visibleRows,
        tallest,
        "rows were not restored when the panel grew again"
    )

    for _ = 1, 4 do
        tick(50)
        definition.refresh(context)
    end
    local rows = probeRows(entryById(context, "model").instance)
    assertEqual(rows.MODEL, "Test Model", "a restored row kept stale text")
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testMissingServiceModule()
    local widgetPath = makeWidget(
        "noservice",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: probe
    type: service-probe
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      service: navigation
      source: GPS
  - id: reading
    type: metric
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: RxBt
          label: Pack
]]
    )
    os.execute("rm -f '" .. widgetPath .. "lib/navigation_service.lua'")

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)

    assertEqual(#context.panels, 2, "a missing service disabled a panel")
    assert(string.match(table.concat(context.errors, "\n"), "navigation:"), table.concat(context.errors, "\n"))

    for _ = 1, 20 do
        tick(20)
        local ok, err = pcall(definition.refresh, context)
        assert(ok, "refresh raised without a service: " .. tostring(err))
    end

    local rows = probeRows(entryById(context, "probe").instance)
    assertEqual(rows.NAVIGATION, "UNAVAILABLE")
    -- The services that did load must keep working.
    assertEqual(entryById(context, "reading").instance.stateName, "normal")
    local ok = pcall(definition.background, context)
    assert(ok, "background raised without a service")
end

local function testHostDiagnosticsReportsTheHost()
    resetRadio()
    local source = assert(hostIo.open(sourcePath .. "layouts/Diagnostics.yaml", "r"))
    local yaml = source:read("a")
    source:close()

    local widgetPath = makeWidget("hostdiag", yaml)
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 30)

    local function linesOf(id)
        local panel = entryById(context, id).instance
        local out = {}
        for index = 1, panel.visibleLines do
            out[#out + 1] = panel.rows[index].properties.text
        end
        return table.concat(out, "\n"), panel
    end

    local identity, identityPanel = linesOf("identity")
    assert(identityPanel.visibleLines > 0, "the identity panel showed no lines")
    assert(
        string.find(identity, context.layoutPath, 1, true),
        "the panel does not show the layout the host opened: " .. identity
    )
    assertEqual(context.layoutOrigin, "default", "this widget has no model-specific layout, so the fallback answered")
    assert(
        string.find(identity, "-> " .. context.layoutOrigin, 1, true),
        "the panel does not say which candidate name answered: " .. identity
    )
    assert(string.find(identity, "main.lua ", 1, true), "the panel does not stamp the running source: " .. identity)
    -- The stamp is the answer to stale bytecode, so it has to be a reading of
    -- the file rather than a placeholder.
    assert(string.find(identity, "2026%-09%-18"), "the panel shows no modification time: " .. identity)
    -- No bytecode beside this package, so the loudest line must be absent.
    -- `make build` deletes it precisely so this stays true on a card.
    assert(
        not string.find(identity, "RUNNING main.luac", 1, true),
        "the panel reported bytecode that is not there: " .. identity
    )

    -- `Diagnostics.yaml` states no theme block, so the widget option is what decided.
    local theme = linesOf("theme")
    assert(
        string.find(theme, "mode: " .. context.theme.mode, 1, true),
        "the panel disagrees with the resolved theme: " .. theme
    )
    assertEqual(context.themeSource, "option")
    assert(
        string.find(theme, "asked by: " .. context.themeSource, 1, true),
        "the panel does not say who chose the palette: " .. theme
    )

    -- Every placement the host built, including these panels themselves.
    local panels = linesOf("panels")
    assert(string.find(panels, #context.panels .. " panels", 1, true), "the panel miscounts the dashboard: " .. panels)
    for _, entry in ipairs(context.panels) do
        assert(
            string.find(panels, entry.placement.id, 1, true),
            "the panel omits " .. entry.placement.id .. ": " .. panels
        )
    end

    local sources = linesOf("sources")
    assert(
        string.find(sources, "sources, ", 1, true) or string.find(sources, "no sources subscribed", 1, true),
        "the sources panel said nothing at all: " .. sources
    )

    -- The panel sheds lines it has no room for rather than drawing past its
    -- own bottom edge. Nothing else can see this: a label overflowing a panel
    -- is clipped by the box it sits in, so it is invisible on screen and
    -- invisible to every assertion about what is drawn. What is checkable is
    -- that the last line the panel claims to show actually fits inside it.
    local panel = entryById(context, "identity").instance
    local height = panelOf(entryById(context, "identity")).h
    local lineHeight = themeModule.fontHeight(panel.fonts.label)
    assert(panel.visibleLines > 0, "the panel shed every line")
    assert(panel.visibleLines < 12, "a two-cell panel claimed every line the panel can build")
    local last = panel.rows[panel.visibleLines].properties
    assert(
        last.y + lineHeight <= height,
        "the last line the panel shows is drawn past its own bottom edge: y "
            .. tostring(last.y)
            .. " plus "
            .. tostring(lineHeight)
            .. " in "
            .. tostring(height)
    )
    assert(panel.rows[panel.visibleLines + 1].hidden, "a line beyond what fits was left visible")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testLayoutOriginIsReported()
    resetRadio()
    local layout = [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: identity
    type: host-diagnostics
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      section: identity
]]

    -- `makeWidget` writes `layouts/Default.yaml`, which is the last candidate,
    -- so this package starts at the bottom of the search.
    local widgetPath = makeWidget("origin", layout)

    local function originOf()
        local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        settle(context, 20)
        local panel = entryById(context, "identity").instance
        local shown = {}
        for index = 1, panel.visibleLines do
            shown[#shown + 1] = panel.rows[index].properties.text
        end
        return context.layoutOrigin, table.concat(shown, "\n"), context.layoutPath
    end

    local origin, lines, path = originOf()
    assertEqual(origin, "default")
    assert(string.find(lines, "-> default", 1, true), lines)
    assert(string.find(path, "Default.yaml", 1, true), path)

    -- Shipping the named layout makes the middle branch answer. The
    -- default file is still there, which is the point: the path changes and so
    -- does the reason, and only one of those was visible before.
    writeFile(widgetPath .. "layouts/main.yaml", layout)
    origin, lines, path = originOf()
    assertEqual(origin, "shipped", "a shipped named layout did not take precedence over the default")
    assert(string.find(lines, "-> shipped", 1, true), lines)

    -- And a layout saved on the radio under that name beats both.
    local saved = layoutStoreModule.path(widgetPath, "main")
    os.execute("mkdir -p '" .. string.match(saved, "^(.*)/") .. "'")
    writeFile(saved, layout)
    origin, lines, path = originOf()
    assertEqual(origin, "user", "a saved layout did not take precedence")
    assert(string.find(lines, "-> user", 1, true), lines)
    assertEqual(path, saved)
    os.remove(saved)
end

local function testHostDiagnosticsWarnsAboutBytecode()
    resetRadio()
    local layout = [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: identity
    type: host-diagnostics
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      section: identity
]]

    local function identityLines(widgetPath)
        local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        settle(context, 20)
        local panel = entryById(context, "identity").instance
        local out = {}
        for index = 1, panel.visibleLines do
            out[#out + 1] = panel.rows[index].properties.text
        end
        return table.concat(out, "\n")
    end

    local clean = makeWidget("bytecode-clean", layout)
    assert(
        not string.find(identityLines(clean), "RUNNING main.luac", 1, true),
        "a package with no bytecode reported some"
    )

    local stale = makeWidget("bytecode-stale", layout)
    writeFile(stale .. "main.luac", "not really bytecode")
    local warned = identityLines(stale)
    assert(
        string.find(warned, "RUNNING main.luac", 1, true),
        "a package with bytecode beside its source did not say so: " .. warned
    )
end

local function testHostDiagnosticsReportsFailures()
    resetRadio()
    local widgetPath = makeWidget(
        "hostdiag-bad",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: probe
    type: metric
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 2
    config:
      metrics:
        - source: NoSuchSensor
          label: Alt
  - id: broken
    type: raiser
    col: 1
    row: 0
    colSpan: 1
    rowSpan: 2
    config:
      label: Broken
  - id: panels
    type: host-diagnostics
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      section: panels
  - id: wires
    type: host-diagnostics
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      section: sources
  - id: later
    type: latebreak
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Later
]],
        {
            ["raiser.lua"] = [==[
local raiser = {id = "raiser", supportedSpans = {"any"},
  settings = {{key = "label", type = "string", default = ""}}}
function raiser.create() error("deliberate failure") end
return raiser
]==],
            -- Builds, then raises on its first refresh, which is the other way a
            -- panel dies and the only one the host keeps an entry for.
            ["latebreak.lua"] = [==[
local latebreak = {id = "latebreak", supportedSpans = {"any"},
  settings = {{key = "label", type = "string", default = ""}}}
function latebreak.create() return {ticks = 0} end
function latebreak.refresh() error("deliberate late failure") end
return latebreak
]==],
        }
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    settle(context, 30)

    local function linesOf(id)
        local panel = entryById(context, id).instance
        local out = {}
        for index = 1, panel.visibleLines do
            out[#out + 1] = panel.rows[index].properties.text
        end
        return table.concat(out, "\n")
    end

    -- A panel that failed during create is otherwise only an error banner,
    -- which may have scrolled past before anyone looked at the screen.
    assertEqual(entryById(context, "broken"), nil, "a panel that raises in create is dropped, not kept disabled")
    assertEqual(#context.rejected, 1, "the host did not record the placement it could not build")
    local panels = linesOf("panels")
    assert(string.find(panels, "2 failed", 1, true), "the panel does not count the failure: " .. panels)
    assert(
        string.find(panels, "broken raiser 1x2 REJECTED", 1, true),
        "the panel does not report the failed panel: " .. panels
    )

    -- A source nothing can bind. The name is shown exactly as the layout
    -- spelled it, which is the half that is invisible on a panel: a typo and a
    -- missing sensor look identical there, and this at least shows the
    -- spelling that was asked for.
    local wires = linesOf("wires")
    assert(string.find(wires, "1 unbound", 1, true), "the panel does not count the unbound source: " .. wires)
    assert(
        string.find(wires, "NoSuchSensor UNBOUND", 1, true),
        "the panel does not report the unbound source: " .. wires
    )

    -- A panel that builds and then raises later is a different casualty
    -- from one that never built: the host keeps it, disabled, in `panels`,
    -- where the one that never built is only in `rejected`. Both have to
    -- appear, and until this covered it only the rejected half ever did.
    local later = entryById(context, "later")
    assert(later and later.failed, "the panel that raises on refresh was not disabled")
    panels = linesOf("panels")
    assert(
        string.find(panels, "later latebreak 2x2 FAILED", 1, true),
        "the panel does not report the panel that failed after building: " .. panels
    )
end

testModelFilenames()
testServiceDiagnostics()
testDiagnosticsFitTheirPanels()
testMissingServiceModule()
testHostDiagnosticsReportsTheHost()
testLayoutOriginIsReported()
testHostDiagnosticsWarnsAboutBytecode()
testHostDiagnosticsReportsFailures()
