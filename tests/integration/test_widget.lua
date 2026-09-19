-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local hostIo = io

--- The EdgeTX surface this suite runs against.
---
--- Every value that is a claim about the radio lives in `tests/support/edgetx.lua`,
--- carries the firmware file and symbol it was read from, and cannot be added
--- without one. Everything below is this suite's own scaffolding.
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
local firmware = edgetx.firmware

edgetx.constants()
local lcdMock = edgetx.lcd()
local lvglMock = edgetx.lvgl()
local radioMock = edgetx.radio(hostIo)

local toRgb565 = lcdMock.toRgb565
local edgeTxRoles = lcdMock.roles

local settleLvgl = lvglMock.settle
local setPropertyValidation = lvglMock.setPropertyValidation
local setCallCounting = lvglMock.setCallCounting
local appZone = lvglMock.appZone
local fullScreenZone = lvglMock.fullScreenZone

local radio = radioMock.state
local resetRadio = radioMock.reset
local tick = radioMock.tick

local MENU_BUTTON_HEIGHT = firmware.MENU_HEADER_HEIGHT_PX
local MENU_BUTTON_WIDTH = firmware.MENU_HEADER_BUTTONS_LEFT

io = {
  open = hostIo.open,
  read = function(handle, size) return handle:read(size) end,
  close = function(handle) return handle:close() end,
}

--- The square an arc covers, read from where the mock drew it.
---
--- `round.drawn` is what `LvglWidgetRoundObject::setPos` stored, so this
--- measures the object rather than repeating the firmware's arithmetic over
--- the arguments Lua passed. `radius` is the outer edge: `lv_draw_arc.c`
--- draws the stroke inward from it, so a thickness does not widen the box.
local function arcSquareOf(arc)
  local radius = arc.round.radius()
  return {
    x = arc.round.drawn.x,
    y = arc.round.drawn.y,
    w = radius * 2,
    h = radius * 2,
  }
end

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
  end
end

--- Compare font constants by name.
---
--- The real constants are LcdFlags, so a mismatch otherwise reads "expected
--- 1536, got 1280", which tells a reader nothing. Correcting the fixture to
--- the radio's values is only worth doing if a failure stays legible.
local function assertFont(actual, expected, message)
  if actual ~= expected then
    error((message or "wrong font") .. ": expected "
      .. edgetx.fontName(expected) .. ", got " .. edgetx.fontName(actual), 2)
  end
end

--- Write a complete file through the host's real io implementation.
local function writeFile(path, text)
  local handle = assert(hostIo.open(path, "w"))
  handle:write(text)
  handle:close()
end

--- Build an isolated copy of the widget package so a test can supply its own
--- layout and component files without touching the shipped sources.
---@param name string Unique scratch directory name under build/.
---@param layoutYaml? string Replacement layouts/default.yaml content.
---@param extraComponents? table<string, string> Component filename to Lua source.
---@return string widgetPath
local function makeWidget(name, layoutYaml, extraComponents)
  local directory = root .. "/build/test-widgets/" .. name
  os.execute("rm -rf '" .. directory .. "'")
  os.execute("mkdir -p '" .. directory .. "'")
  os.execute("cp -R '" .. sourcePath .. ".' '" .. directory .. "'")

  if layoutYaml then
    writeFile(directory .. "/layouts/default.yaml", layoutYaml)
  end
  for filename, source in pairs(extraComponents or {}) do
    writeFile(directory .. "/components/" .. filename, source)
  end

  return directory .. "/"
end

local widgetChunk = assert(loadfile(sourcePath .. "main.lua"))
local definition = widgetChunk()

-- Wrap every host callback so the deferred cleanup runs exactly where the
-- firmware runs it: after the callback returns, not during it.
for _, name in ipairs({"create", "update", "refresh", "background", "event"}) do
  local original = definition[name]
  definition[name] = function(...)
    local first, second = original(...)
    settleLvgl()
    return first, second
  end
end
local themeModule = assert(loadfile(sourcePath .. "lib/theme.lua"))()
local primitivesModule = assert(loadfile(sourcePath .. "lib/primitives.lua"))()

assertEqual(definition.name, "AeroGrid")
assertEqual(definition.useLvgl, true)
assert(type(definition.background) == "function", "host must expose background")
assert(type(definition.event) == "function", "host must expose event")
assertEqual(definition.translate("Theme"), "Theme")

local DEFAULT_OPTIONS = {DashID = "main", Theme = "modern"}

--- Advance the clock and refresh, so rate-limited components fall due.
local function pump(context, count, step)
  for _ = 1, count do
    tick(step or 20)
    definition.refresh(context)
  end
end

--- Create a host and pump refresh until the staged loader finishes.
--- EdgeTX budgets instructions per callback, so loading is spread over
--- consecutive refreshes rather than completed inside create().
local function createLoaded(zone, options, path)
  local context = definition.create(zone, options or DEFAULT_OPTIONS, path)
  local guard = 0
  while context.stage do
    definition.refresh(context)
    guard = guard + 1
    assert(guard < 200, "staged load never finished")
  end
  return context
end

--- Find a loaded component entry by its layout id.
local function entryById(context, id)
  for _, entry in ipairs(context.components) do
    if entry.placement.id == id then return entry end
  end
  return nil
end

--- Every shipped component exposes its panel through the shared primitive.
local function panelOf(entry)
  return entry.instance.panel.root.properties
end

--- The host owns placement, so bounds come from the component's container.
local function boundsOf(entry)
  return entry.container.properties
end

--- Report whether two rendered panels share any pixel.
local function panelsOverlap(first, second)
  return first.x < second.x + second.w and second.x < first.x + first.w
    and first.y < second.y + second.h and second.y < first.y + first.h
end

--- The design-system tests need an arrangement they control: the shipped
--- dashboard is free to change as the catalog grows, and a test that asserted
--- its exact contents would break every time it did. This layout pins the
--- spans and configurations those tests measure.
local REFERENCE_LAYOUT = [[
version: 1
theme:
  mode: modern
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Pack
      source: RxBt
      unit: V
      accent: cyan
      rangeMin: 18
      rangeMax: 25.2
      warning: 21.0
      critical: 19.8
      precision: 1
      visual: bar
  - id: current
    type: metric
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      label: Current
      source: Curr
      accent: orange
      rangeMin: 0
      rangeMax: 120
      warning: 90
      critical: 110
      visual: bar
  - id: altitude
    type: metric
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      label: Altitude
      source: Alt
      accent: green
      rangeMin: 0
      rangeMax: 400
      warning: 250
      critical: 350
      visual: radial
  - id: pulse
    type: heartbeat
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      label: HEARTBEAT
      accent: amber
  - id: secondary
    type: placeholder
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      label: PHASE 1
      subtitle: DESIGN SYSTEM
      accent: green
]]

local referencePath = makeWidget("reference", REFERENCE_LAYOUT)

--- Architecture checkpoint: a layout must load separately authored component
--- modules and render them correctly in App mode and ordinary 1 x 1.
local function testRendersInBothModes(label, zone, path, expected)
  local context = createLoaded(zone, DEFAULT_OPTIONS, path or referencePath)

  assertEqual(#context.errors, 0, label .. ": " .. table.concat(context.errors, "\n"))
  assertEqual(#context.components, expected or 5, label .. ": component count")

  for _, entry in ipairs(context.components) do
    local bounds = boundsOf(entry)
    assert(bounds.x >= 0 and bounds.y >= 0, label .. ": container outside zone origin")
    assert(bounds.x + bounds.w <= zone.w, label .. ": container exceeds zone width")
    assert(bounds.y + bounds.h <= zone.h, label .. ": container exceeds zone height")
    assert(bounds.w > 0 and bounds.h > 0, label .. ": container collapsed")

    -- Components are handed container-local coordinates, so their panel must
    -- start at the origin and never exceed the container it was given.
    local panel = panelOf(entry)
    assertEqual(panel.x, 0, label .. ": " .. entry.placement.id .. " left its container")
    assertEqual(panel.y, 0, label .. ": " .. entry.placement.id .. " left its container")
    assert(panel.w <= bounds.w and panel.h <= bounds.h,
      label .. ": " .. entry.placement.id .. " overflowed its container")
  end

  for first = 1, #context.components do
    for second = first + 1, #context.components do
      assert(not panelsOverlap(boundsOf(context.components[first]),
        boundsOf(context.components[second])),
        label .. ": rendered panels overlap")
    end
  end

  return context
end

-- App mode occupies the full TX16S-class display; ordinary Full screen sits
-- below EdgeTX's own top bar and is 227 tall rather than 272.
local appContext = testRendersInBothModes("app mode", appZone())
testRendersInBothModes("1 x 1", fullScreenZone())
lvglMock.setAppMode(false)
--- Milestone 7's deliverable: the shipped dashboard must demonstrate the
--- complete ten-component catalogue, loading each from its own module without
--- error and keeping each one inside the container the host gave it.
local SHIPPED_TYPES = {
  "metric", "flight-timer", "flight-mode", "tx-battery",
  "variable-indicator", "trim-panel", "model-identity",
  "cell-battery", "link-status", "navigation",
}

--- Every layout that ships must load, whatever it is for.
---
--- The shipped default is covered above, but the simulator layouts are only
--- ever exercised by running the simulator, so a component type that does not
--- exist, a span a component refuses, or a grid that overflows would not
--- surface until a radio drew it. They are read from disk rather than listed
--- here, so a new layout is covered the moment it is added.
local function testShippedLayoutsLoad()
  local listingPath = root .. "/build/shipped-layouts.txt"
  os.execute("ls '" .. sourcePath .. "layouts' > '" .. listingPath .. "'")
  local listing = assert(hostIo.open(listingPath, "r"))
  local names = {}
  for name in listing:lines() do
    local stem = string.match(name, "^(.+)%.yaml$")
    if stem and stem ~= "default" then names[#names + 1] = stem end
  end
  listing:close()
  os.remove(listingPath)
  assert(#names > 0, "no shipped layouts were found to check")

  for _, stem in ipairs(names) do
    resetRadio()

    -- The host loads layouts/default.yaml unless a dashboard is named, so each
    -- candidate takes that name inside its own copy of the package.
    local source = assert(hostIo.open(sourcePath .. "layouts/" .. stem .. ".yaml", "r"))
    local yaml = source:read("a")
    source:close()

    local widget = makeWidget("layout-" .. stem, yaml)
    local declared = 0
    for _ in string.gmatch(yaml, "\n  %- id:") do declared = declared + 1 end
    assert(declared > 0, stem .. ": no components were declared")

    local zone = {x = 0, y = 0, w = 480, h = 272}
    local context = testRendersInBothModes("layout " .. stem, zone, widget, declared)

    -- Construction is not the bar: a component that fails on its first real
    -- reading is still a broken layout.
    for _ = 1, 60 do
      tick(20)
      definition.refresh(context)
    end
    assertEqual(#context.errors, 0, stem .. ": " .. table.concat(context.errors, "\n"))
    for _, entry in ipairs(context.components) do
      assert(not entry.failed, stem .. ": " .. entry.placement.id .. " failed")
    end
  end
end

--- The flight session is configured by the layout, not by a panel.
---
--- `armSource` used to be a setting on `metric` and on `link-status`, so a
--- dashboard with both could name two switches. `extremaService:flight`
--- documents that the first caller establishes the source, which meant the
--- second component's switch was read from the layout, accepted by the host,
--- and then silently discarded. Moving it to the layout's `session` block
--- makes that contradiction unstatable. This checks the block is what does
--- the arming, by building the same dashboard with and without it.
local function testSessionArmsTheFlight()
  local function dashboard(sessionBlock)
    return table.concat({
      "version: 1",
      "grid:",
      "  columns: 4",
      "  rows: 4",
      "components:",
      "  - id: peak",
      "    type: metric",
      "    col: 0",
      "    row: 0",
      "    colSpan: 2",
      "    rowSpan: 1",
      "    config:",
      "      label: Alt",
      "      source: Alt",
      "      extrema: flight",
      "      precision: 0",
      sessionBlock,
    }, "\n") .. "\n"
  end

  local function flightOf(yaml)
    resetRadio()
    local widget = makeWidget("session-arm", yaml)
    local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
      DEFAULT_OPTIONS, widget)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    local registry = context.serviceRuntime
    local extrema = registry and registry.byId and registry.byId.extrema
    assert(extrema, "the dashboard built no extrema service")
    return extrema:flight()
  end

  -- Configured is the service's own word for "an arm source was supplied",
  -- so it is the value the contract names rather than a proxy for it.
  local armed = flightOf(dashboard("session:\n  armSource: sf"))
  assertEqual(armed.configured, true,
    "the layout named an arm switch and the flight session did not see it")

  local unarmed = flightOf(dashboard("# no session block"))
  assertEqual(unarmed.configured, false,
    "a dashboard that names no arm switch reported one anyway")
end

--- The single-cell gallery has to contain the catalogue, or it is not a
--- comparison.
---
--- `span1x1.yaml` exists so a person can see thirteen components at the same
--- span at once and judge whether they belong to the same dashboard. A
--- component missing from it is a component nobody is comparing, and the most
--- likely way for one to go missing is for it to be written after the gallery.
--- The component directory is therefore read from disk rather than listed
--- here, exactly as the layout sweep above reads the layout directory.
local function testSpanGalleryIsComplete()
  local componentHost = assert(loadfile(sourcePath .. "lib/component_host.lua"))()

  local listingPath = root .. "/build/gallery-components.txt"
  os.execute("ls '" .. sourcePath .. "components' > '" .. listingPath .. "'")
  local listing = assert(hostIo.open(listingPath, "r"))
  local stems = {}
  for name in listing:lines() do
    local stem = string.match(name, "^(.+)%.lua$")
    if stem then stems[#stems + 1] = stem end
  end
  listing:close()
  os.remove(listingPath)
  assert(#stems > 0, "no components were found to compare")

  local source = assert(hostIo.open(sourcePath .. "layouts/span1x1.yaml", "r"))
  local gallery = source:read("a")
  source:close()

  local compared = 0
  for _, stem in ipairs(stems) do
    local module = assert(loadfile(sourcePath .. "components/" .. stem .. ".lua"))()
    if componentHost.supportsSpan(module, 1, 1) then
      compared = compared + 1
      assert(string.find(gallery, "type: " .. stem, 1, true),
        stem .. " declares a 1 x 1 span but is missing from the 1 x 1 gallery,"
          .. " so nothing is comparing it against the rest of the catalogue")
    end
  end

  -- A gallery that compared one component would satisfy every assertion above.
  assert(compared >= 13,
    "only " .. compared .. " components were compared at 1 x 1")
end

--- The span galleries have to be reachable by paging, not by editing settings.
---
--- A gallery only ships as a layout, and selecting a layout means setting the
--- widget's Dashboard ID. In App mode that is not reachable from the main
--- view at all: `Widget::openMenu` returns immediately after
--- `setFullscreen(true)` when the widget is not in the top bar and the view is
--- App mode (radio/src/gui/colorlcd/mainview/widget.cpp), so there is no
--- widget menu to open. Reaching a gallery would mean going through Model
--- Setup and Screens once per gallery, which is enough friction that nobody
--- would look at them, which is the whole point of them existing.
---
--- The tracked simulator model therefore carries a screen per gallery. This
--- holds that arrangement together: a gallery added later without a screen is
--- a gallery nobody pages to.
--- The states layout has to be judgeable on both palettes, from a screen.
---
--- Every guarantee an alert tint carries is a contrast ratio, and a ratio can
--- only say a tint is legible. It cannot say whether the colour the search
--- landed on is the right one to look at, and the derived palette is where
--- that is least likely to be right by luck: its tints are mixed from
--- whatever surface the radio supplied, in the opposite lightness direction to
--- Modern's. Modern's critical has been seen and approved; the derived one had
--- only ever been a number.
---
--- So the tracked model carries the same layout twice under different Theme
--- options. That works because `states.yaml` states no theme of its own and
--- the host falls back to the native option, which this pins: a `theme` block
--- creeping back into the layout would silently collapse both screens onto one
--- palette while every assertion about reachability still passed.
local function testStatesCoverBothPalettes()
  local handle = assert(hostIo.open(
    sourcePath .. "layouts/states.yaml", "r"))
  local layout = handle:read("a")
  handle:close()

  assert(not string.match(layout, "\ntheme:"),
    "states.yaml pins a theme, so both of its screens resolve the same palette"
      .. " and the derived tints cannot be looked at")

  local widgetPath = makeWidget("states-palettes", layout)

  --- Build the states layout under one Theme option and report what it drew.
  local function render(mode)
    resetRadio()
    local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
      {DashID = "main", Theme = mode}, widgetPath)
    pump(context, 60)
    assertEqual(#context.errors, 0,
      mode .. ": " .. table.concat(context.errors, "\n"))
    return context
  end

  for _, mode in ipairs({"modern", "edgetx"}) do
    local context = render(mode)
    assertEqual(context.theme.mode, mode,
      "the Theme option did not decide the palette")

    -- Configured to be critical is not the same as being critical. The
    -- thresholds are rigged so the state is permanent, but that was only ever
    -- checked against Modern, and a palette is free to resolve differently.
    local critical = entryById(context, "s-critical")
    assert(critical, mode .. ": the states layout has no critical panel")
    assertEqual(critical.instance.stateName, "critical",
      mode .. ": the panel meant to be critical is not")

    local warning = entryById(context, "s-warning")
    assertEqual(warning.instance.stateName, "warning",
      mode .. ": the panel meant to be warning is not")

    -- And each is actually drawn on its tint, rather than merely resolving to
    -- a state that has one.
    assertEqual(critical.instance.panel.background.properties.color,
      context.theme.alertColor.critical,
      mode .. ": the critical panel is not drawn on the critical tint")
    assertEqual(warning.instance.panel.background.properties.color,
      context.theme.alertColor.warning,
      mode .. ": the warning panel is not drawn on the warning tint")
  end

  -- The two screens are only worth having if they differ. Derived tints that
  -- landed on Modern's would mean the search is ignoring the radio's surface.
  local modern = render("modern").theme
  local derived = render("edgetx").theme
  assert(modern.alertRgb.critical ~= derived.alertRgb.critical,
    "both palettes resolve the same critical tint, so the second screen shows"
      .. " nothing the first does not")
  assert(modern.alertRgb.warning ~= derived.alertRgb.warning,
    "both palettes resolve the same warning tint")
end

local function testGalleriesAreReachable()
testStatesCoverBothPalettes()
  local handle = assert(hostIo.open(
    root .. "/tests/fixtures/sdcard/MODELS/model1.yml", "r"))
  local model = handle:read("a")
  handle:close()

  local listingPath = root .. "/build/gallery-layouts.txt"
  os.execute("ls '" .. sourcePath .. "layouts' > '" .. listingPath .. "'")
  local listing = assert(hostIo.open(listingPath, "r"))
  local galleries = {}
  for name in listing:lines() do
    local stem = string.match(name, "^(span%w+)%.yaml$")
      or string.match(name, "^(states)%.yaml$")
    if stem then galleries[#galleries + 1] = stem end
  end
  listing:close()
  os.remove(listingPath)
  assert(#galleries > 0, "no span galleries were found")

  for _, stem in ipairs(galleries) do
    -- The file is written by the simulator and uses CRLF, so the value is
    -- matched up to the line ending rather than to the end of the line.
    assert(string.find(model, "stringValue: " .. stem, 1, true),
      stem .. " ships as a layout but no screen of the tracked model selects"
        .. " it, so nothing pages to it")
  end

  -- Anything under review has to be reachable in a page or two. The galleries
  -- are reference material for this audit and can sit behind the dashboards
  -- and the states pages; when `states` was last it took six pages to reach
  -- and in practice went unseen, which is the whole failure mode a screen
  -- exists to prevent.
  local order = {}
  for value in string.gmatch(model, "stringValue: ([%w]+)") do
    order[#order + 1] = value
  end
  local position = {}
  for index, name in ipairs(order) do
    if not position[name] then position[name] = index end
  end
  for _, stem in ipairs(galleries) do
    if string.match(stem, "^span") then
      assert(position.states < position[stem], "the " .. stem
        .. " gallery is paged before the states screens, which are what is"
        .. " actually being looked at")
    end
  end
  assert(position.sim == 1 and position.sim2 == 2,
    "the two dashboards are not the first two screens")

  -- The states layout is carried twice, and the two screens are only worth
  -- the space if they resolve different palettes. Each screen stores DashID
  -- then Theme, so the value after a `states` entry is that screen's theme.
  local themes = {}
  for index, name in ipairs(order) do
    if name == "states" then themes[#themes + 1] = order[index + 1] end
  end
  assertEqual(#themes, 2,
    "the states layout is not carried on two screens")
  assert(themes[1] ~= themes[2],
    "both states screens are set to the " .. tostring(themes[1])
      .. " palette, so the derived tints are on no screen at all")
  for _, mode in ipairs(themes) do
    assert(mode == "modern" or mode == "edgetx",
      "a states screen asks for an unknown palette: " .. tostring(mode))
  end

  -- EdgeTX stops at MAX_CUSTOM_SCREENS, which is 10 on colour targets
  -- (radio/src/dataconstants.h). A model carrying more is one the radio will
  -- not load as written.
  local screens = 0
  for _ in string.gmatch(model, "\n      LayoutId:") do screens = screens + 1 end
  assert(screens >= #galleries + 2,
    "the tracked model has " .. screens .. " screens, too few for the"
      .. " galleries plus the two dashboards")
  assert(screens <= 10,
    "the tracked model has " .. screens .. " screens, more than EdgeTX's"
      .. " MAX_CUSTOM_SCREENS of 10")
end

local function testShippedLayout()
testShippedLayoutsLoad()
testSessionArmsTheFlight()
testSpanGalleryIsComplete()
testGalleriesAreReachable()
  resetRadio()
  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = testRendersInBothModes("shipped", zone, sourcePath, 10)
  assertEqual(context.layoutPath, sourcePath .. "layouts/default.yaml")

  local types = {}
  for _, entry in ipairs(context.components) do types[entry.module.id] = true end
  for _, wanted in ipairs(SHIPPED_TYPES) do
    assert(types[wanted],
      "the shipped dashboard does not demonstrate " .. wanted)
  end

  -- Every component must survive real radio state, not merely construction.
  for _ = 1, 80 do
    tick(20)
    definition.refresh(context)
  end
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

  -- The preset metric takes its label, bounds, and sources from the preset.
  local altitude = entryById(context, "altitude").instance
  assertEqual(altitude.settings.label, "ALT")
  assertEqual(altitude.settings.source, "Alt")
  assertEqual(altitude.feed.name, "Alt")
  assertEqual(altitude.extremeFeed.name, "Alt+", "the preset lost its extrema")
  assertEqual(altitude.secondaryFeed.name, "VSpd")
  assertEqual(altitude.value.properties.text, "100")

  -- And the components that read the radio rather than the link.
  assertEqual(entryById(context, "flight-clock").instance.text, "1:30")
  assertEqual(entryById(context, "mode").instance.text, "Sport")
  assertEqual(entryById(context, "radio-battery").instance.text, "7.9V")
  assertEqual(entryById(context, "rates").instance.text, "4.5")
  assertEqual(entryById(context, "identity").instance.text, "Test Model")
  assertEqual(entryById(context, "trims").instance.indicators[1].valueText, "+23%")

  -- The three telemetry components, reading what the radio really reports.
  local pack = entryById(context, "pack").instance
  assertEqual(pack.text, "4.09V", "the lowest cell is the safety reading")
  -- The shipped pack is 2 x 1, which is 65 px tall, and sheds its supporting
  -- row to keep the reading large. This used to assert the row's text anyway:
  -- the label was hidden and its content was still being computed, so the
  -- assertion described a string nothing drew. A row that is not shown is now
  -- not fitted either, which is what made that visible.
  assertEqual(pack.showDetail, false,
    "a 2 x 1 cell panel is tall enough for a supporting row after all")
  assertEqual(pack.countLabel.hidden, true)
  assertEqual(pack.packLabel.hidden, true)

  local link = entryById(context, "link").instance
  assertEqual(link.primaryName, "quality", "auto must prefer link quality")
  assertEqual(link.text, "96%")
  assertEqual(link.stateName, "normal")

  local nav = entryById(context, "nav").instance
  assertEqual(nav.text, "778m")
  -- Both supporting wordings share one row, and on a 2 x 2 panel neither full
  -- wording fits. The bearing needs 89 px of the 87 it is given, so it sheds
  -- its compass point and keeps the number, which is the measurement; the
  -- caption sheds its last two words. Before this the bearing simply overran
  -- its box and the caption read "NORTH UP FROM" on a radio.
  assertEqual(nav.detail, "BRG 009")
  assertEqual(nav.origin, "NORTH UP")
  for _, row in ipairs({{nav.detail, nav.detailWidth}, {nav.origin, nav.originWidth}}) do
    local needed = themeModule.textWidth(nav.fonts.label, row[1])
    assert(needed <= row[2], string.format(
      "the shipped navigation panel draws %q, needing %d px of %d",
      row[1], needed, row[2]))
  end
  assert(nav.compass, "the shipped dashboard must demonstrate the dial")
end

--- The host owns the palette: every panel uses the resolved surface token.
---
--- A rendered colour is compared against `lcd.RGB(token)`, never against the
--- token itself. The dashboard keeps its palette twice: 24-bit `theme.rgb`
--- for arithmetic, `theme.color` display values for drawing. While the
--- mock returned its input unchanged the two were the same number, so this
--- test passed whichever one the host reached for.
local function testThemeReachesComponents()
  local modern = themeModule.modern()
  assertEqual(appContext.theme.mode, "modern")
  assertEqual(appContext.canvas.properties.color, lcd.RGB(modern.canvas),
    "the canvas was not painted in the resolved canvas colour")

  for _, entry in ipairs(appContext.components) do
    assertEqual(entry.instance.panel.background.properties.color,
      lcd.RGB(modern.surface),
      entry.placement.id .. " did not use the theme surface")
  end

  -- Components receive span-appropriate typography from the host.
  local pack = entryById(appContext, "pack")
  local current = entryById(appContext, "current")
  assertFont(pack.instance.fonts.primary, XXLSIZE)
  assertFont(current.instance.fonts.primary, DBLSIZE)
end

--- EdgeTX's lvgl.box parses `color` but never paints it, so any background
--- drawn with a box silently inherits the radio's own theme instead of ours.
--- Every visible surface must therefore be a filled rectangle.
local function testBackgroundsArePainted()
  local function assertPainted(object, what)
    assertEqual(object.kind, "rectangle", what .. " must be a rectangle")
    assertEqual(object.properties.filled, true, what .. " must be filled")
    -- Not merely "has a colour": a surface has to be painted in a value the
    -- host resolved and lcd.RGB encoded. A 24-bit token is not nil either,
    -- and on a radio it paints a colour belonging to no theme.
    local color = object.properties.color
    assert(type(color) == "number" and color % 65536 == 0x8000,
      what .. " was not painted in a resolved colour: " .. tostring(color))
  end

  assertPainted(appContext.canvas, "dashboard canvas")

  for _, entry in ipairs(appContext.components) do
    local panel = entry.instance.panel
    assertPainted(panel.background, entry.placement.id .. " panel background")
    -- Containers and panel roots are boxes, so they must never carry a color.
    assertEqual(entry.container.kind, "box")
    assertEqual(entry.container.properties.color, nil,
      entry.placement.id .. " container relies on an unpainted box color")
    assertEqual(panel.root.properties.color, nil,
      entry.placement.id .. " panel root relies on an unpainted box color")
  end
end

--- A panel is a card: an elevated fill, softly rounded, with a pill accent and
--- no outline at rest.
---
--- Every number here is a claim about what the radio paints rather than about
--- what the host asked for. A rectangle's corner radius and border width reach
--- LVGL in `build`, and for the border only again when its opacity moves, so
--- the fixture keeps what was actually applied apart from what was last
--- passed. Asserting the latter would let a panel claim a heavier critical
--- outline while drawing the resting one.
local function testPanelPresentation()
  local spacing = appContext.theme.spacing
  local modern = themeModule.modern()

  -- Panels are told apart from the screen by their fill, so the fill has to
  -- be separable by eye. Measured on the tokens, because contrast arithmetic
  -- is defined on 24-bit values and means nothing applied to a flag word.
  assert(themeModule.contrast(modern.canvas, modern.surface) >= 1.30,
    "panels are not elevated above the screen they sit on")

  for _, entry in ipairs(appContext.components) do
    local id = entry.placement.id
    local panel = entry.instance.panel
    local bounds = boundsOf(entry)

    -- No outline at rest. The fill already says where the panel is, and a
    -- border on every panel is a border that says nothing when one of them
    -- needs to shout.
    assertEqual(panel.border.hidden, true, id .. " drew an outline at rest")

    -- Corners: what the radio was given, not what was last passed to `set`.
    assertEqual(panel.background.painted.radius, spacing.radius,
      id .. " was not rounded to the theme's corner radius")

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
    assertEqual(column.w, spacing.accentWidth,
      id .. " accent mask is not one accent width across")
    assertEqual(column.h, bounds.h,
      id .. " accent mask does not cover the panel's height")
    -- A box accepts `color` and silently ignores it (constraint 2), so a mask
    -- that asked for one would be relying on that. It asks for none.
    assertEqual(column.color, nil, id .. " accent mask asked for a colour")

    -- The mask only masks what is inside it. An accent object parented to the
    -- panel root would be clipped by the root instead, which is the whole
    -- panel, so it would not be clipped at all.
    --- Name an object's parent, so a mismatch does not read as two addresses.
    local function parentName(object)
      if object.parent == panel.column then return "the accent mask" end
      if object.parent == panel.root then return "the panel root" end
      return "something else"
    end
    for what, object in pairs({["accent stripe"] = panel.accent,
        ["top band"] = panel.topArc.arc,
        ["bottom band"] = panel.bottomArc.arc}) do
      assert(object.parent == panel.column, id .. ": the " .. what
        .. " is parented to " .. parentName(object) .. " rather than to the"
        .. " accent mask, so nothing clips it")
    end

    -- The mask has to be load bearing, or asserting its width asserts
    -- nothing. An arc occupies a box of `2 * radius` about its centre, so a
    -- corner band reaches `2 * radius` across where the column allows
    -- `accentWidth`. Without the clip that difference is drawn, which is the
    -- accent bulging out of its own column.
    assert(spacing.radius * 2 > spacing.accentWidth,
      id .. " the corner bands fit inside the accent width unclipped, so the"
        .. " mask is decorative and proves nothing")

    -- The accent is a plain stripe: constant width, square ends, stopping
    -- where the panel's corner curves away rather than following it round.
    local accent = panel.accent.properties
    assertEqual(accent.x, 0, id .. " moved its accent off the left edge")
    assertEqual(accent.w, spacing.accentWidth, id .. " accent changed width")

    -- Square ends. A radius on a stripe this narrow rounds its caps, which
    -- tapers the band at both ends and is the thing that was rejected.
    assertEqual(panel.accent.painted.radius, 0,
      id .. " accent was drawn with rounded ends")

    -- The straight run spans exactly the part of the left edge that is
    -- straight: it starts where the top corner's arc ends and stops where the
    -- bottom corner's begins, so stripe and arcs abut at the two tangents.
    assertEqual(accent.y, spacing.radius,
      id .. " accent does not start at the top corner's tangent")
    assertEqual(accent.y + accent.h, bounds.h - spacing.radius,
      id .. " accent does not end at the bottom corner's tangent")

    -- A quarter band per corner, carrying the accent round rather than
    -- stopping at it. Centred on the panel's own corner centres and given the
    -- panel's own corner radius, which is what makes the band's outer edge
    -- and the panel's edge the same circle: LVGL draws an arc between
    -- `radius` and `radius - width` from the centre (lv_draw_arc.c, rout and
    -- rin), and the object's box is 2 * radius square about that centre
    -- (LvglWidgetArc::build via setRadius, and get_center in lv_arc.c).
    for corner, band in pairs({top = panel.topArc, bottom = panel.bottomArc}) do
      local arc = band.arc.properties
      assertEqual(arc.radius, spacing.radius,
        id .. " " .. corner .. " band does not share the panel's corner radius")
      assertEqual(arc.thickness, spacing.accentWidth,
        id .. " " .. corner .. " band is not the accent's thickness")
      assertEqual(band.centreX, spacing.radius,
        id .. " " .. corner .. " band is not on the corner centre")
      -- An arc stores a corner, so what the firmware would draw is checked
      -- through the mock's own reproduction of that arithmetic rather than
      -- through the coordinates it was handed.
      assertEqual(band.arc.round.drawn.x, band.centreX - spacing.radius,
        id .. " " .. corner .. " band drifted horizontally")
      assertEqual(band.arc.round.drawn.y, band.centreY - spacing.radius,
        id .. " " .. corner .. " band drifted vertically")
    end

    assertEqual(panel.topArc.centreY, spacing.radius,
      id .. " top band is not on the top corner centre")
    assertEqual(panel.bottomArc.centreY, bounds.h - spacing.radius,
      id .. " bottom band is not on the bottom corner centre")

    -- The quarters face the left edge, or the accent would appear on the
    -- right. LVGL measures zero at three o'clock, clockwise.
    assertEqual(panel.topArc.arc.properties.startAngle, 180,
      id .. " top band does not start at nine o'clock")
    assertEqual(panel.topArc.arc.properties.endAngle, 270,
      id .. " top band does not end at twelve o'clock")
    assertEqual(panel.bottomArc.arc.properties.startAngle, 90,
      id .. " bottom band does not start at six o'clock")
    assertEqual(panel.bottomArc.arc.properties.endAngle, 180,
      id .. " bottom band does not end at nine o'clock")

    -- The surface is the whole panel. The accent is drawn on it, not under it.
    local surface = panel.background.properties
    assertEqual(surface.x, 0, id .. " surface left the panel origin")
    assertEqual(surface.y, 0, id .. " surface left the panel origin")
    assertEqual(surface.w, bounds.w, id .. " surface is not the panel's width")
    assertEqual(surface.h, bounds.h, id .. " surface is not the panel's height")

    -- Content has to clear the band. Every panel under 80 px tall used to
    -- start its text at the accent's own right edge. Checked over whatever
    -- labels the component actually built, because the catalogue does not
    -- agree on what to call them and the rule is about pixels, not names.
    local labels = 0
    for _, object in ipairs(lvglMock.objects) do
      if object.parent == panel.root and object.kind == "label"
          and not object.hidden then
        labels = labels + 1
        assert(object.properties.x >= spacing.accentWidth + spacing.accentGap,
          id .. " drew text against the accent, at x "
            .. tostring(object.properties.x))
      end
    end
    assert(labels > 0, id .. " drew no text at all")
  end
end

--- An alarm tints the panel's field, and recovering puts it back.
---
--- The outline used to carry this and no longer does. Area is seen in
--- peripheral vision where a line is not, which is what a panel on a moving
--- aircraft has to manage, and the border is now free to mean one thing.
---
--- The tint has to hold every guarantee the resting surface holds, because
--- none of them transfer: there was only ever one surface to check before, and
--- `enforceLegibility` checked it once at build. A tint that swallowed the
--- muted text drawn on it would be a legible panel turning illegible at
--- exactly the moment a pilot needs to read it.
local function testAlarmTint()
  local widgetPath = makeWidget("alarm-tint", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: metric
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      label: Pack
      source: RxBt
      rangeMin: 18
      rangeMax: 25.2
      warning: 21.0
      critical: 19.8
      precision: 1
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  local resolved = context.theme
  local entry = entryById(context, "pack")
  local panel = entry.instance.panel
  local metricModule = assert(loadfile(sourcePath .. "components/metric.lua"))()

  local resting = panel.background.properties.color
  assertEqual(resting, resolved.color.surface,
    "a healthy panel is not drawn on the resting surface")
  assertEqual(panel.border.hidden, true, "a healthy panel drew an outline")

  --- Every guarantee the resting surface carries, against a tint.
  ---
  --- Measured on the 24-bit tokens, because contrast arithmetic is defined on
  --- those; the panel is painted with the display value and the two are
  --- deliberately different numbers.
  local function assertLegible(name, tint)
    assert(tint, "there is no " .. name .. " tint at all")
    local checks = {
      {"body text", resolved.rgb.text, 4.5},
      {"muted text", resolved.rgb.textMuted, 3.0},
      {"faint text", resolved.rgb.textFaint, 1.8},
    }
    for _, check in ipairs(checks) do
      local ratio = themeModule.contrast(tint, check[2])
      assert(ratio >= check[3], string.format(
        "the %s tint leaves %s at %.2f, below %.1f", name, check[1], ratio, check[3]))
    end
    -- A card has to still read as a card once it is coloured.
    local elevation = themeModule.contrast(resolved.rgb.canvas, tint)
    assert(elevation >= 1.30, string.format(
      "the %s tint leaves the panel flat against the screen at %.2f", name, elevation))
    -- And it has to be noticed beside an untinted panel, or it says nothing.
    local separation = themeModule.contrast(resolved.rgb.surface, tint)
    assert(separation >= 1.30, string.format(
      "the %s tint is indistinguishable from a resting panel at %.2f",
      name, separation))
  end

  assertLegible("warning", resolved.alertRgb.warning)
  assertLegible("critical", resolved.alertRgb.critical)

  -- The accent and the badge are drawn on the tint, and for critical both are
  -- red on what is now a red field. That is the pairing most likely to turn to
  -- mush, and it is the reason the tint is taken darker rather than toward the
  -- accent's own lightness.
  local accents = {warning = resolved.rgb.amber, critical = resolved.rgb.critical}
  for name, accent in pairs(accents) do
    local ratio = themeModule.contrast(resolved.alertRgb[name], accent)
    assert(ratio >= 2.5, string.format(
      "the %s accent is lost on its own tint at %.2f", name, ratio))
  end

  metricModule.setValue(entry.instance, 20.5)
  assertEqual(entry.instance.stateName, "warning")
  assertEqual(panel.background.properties.color, resolved.alertColor.warning,
    "a warning did not tint the panel")
  assertEqual(panel.border.hidden, true, "a warning drew an outline as well")

  metricModule.setValue(entry.instance, 19.0)
  assertEqual(entry.instance.stateName, "critical")
  assertEqual(panel.background.properties.color, resolved.alertColor.critical,
    "a critical reading did not tint the panel")
  assertEqual(panel.border.hidden, true, "a critical reading drew an outline as well")
  assert(resolved.alertColor.warning ~= resolved.alertColor.critical,
    "a warning and a critical reading tint the panel the same colour")

  -- Absent data is not an alarm, so neither of these tints anything.
  metricModule.setValue(entry.instance, 24.0, true)
  assertEqual(entry.instance.stateName, "stale")
  assertEqual(panel.background.properties.color, resting,
    "stale data tinted the panel")

  metricModule.setValue(entry.instance, nil)
  assertEqual(entry.instance.stateName, "unavailable")
  assertEqual(panel.background.properties.color, resting,
    "a missing source tinted the panel")

  -- Recovering puts the panel back, or it stays coloured after the reading
  -- that alarmed it has returned to normal.
  metricModule.setValue(entry.instance, 24.0)
  assertEqual(entry.instance.stateName, "normal")
  assertEqual(panel.background.properties.color, resting,
    "a panel stayed tinted after its reading recovered")
end

--- A revealed outline still carries the weight and size it should.
---
--- Nothing a component produces draws an outline any more, so this drives the
--- presentation directly. It is kept because constraint 13 has not gone away:
--- a border's thickness reaches LVGL when the object is built and never again,
--- which is why the panel builds one at the focus weight and shows or hides
--- it. The editor in phase 2 is what will exercise this for real.
local function testFocusBorder()
  local widgetPath = makeWidget("focus-border", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: metric
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      label: Pack
      source: RxBt
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
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
  until not context.reflowIndex

  local selected = themeModule.state(context.theme, "selected")
  primitivesModule.stylePanel(panel, selected)
  assertEqual(panel.border.hidden, false, "a selected panel drew no outline")
  assertEqual(panel.border.properties.color, context.theme.color.cyan,
    "a selection outline was not drawn in the focus colour")
  assertEqual(panel.border.painted.borderWidth, spacing.borderFocus,
    "a selection outline was not drawn at the focus weight")

  local bounds = boundsOf(entry)
  assertEqual(panel.border.properties.w, bounds.w,
    "a revealed outline kept the width it had before the reflow")
  assertEqual(panel.border.properties.h, bounds.h,
    "a revealed outline kept the height it had before the reflow")

  primitivesModule.stylePanel(panel, themeModule.state(context.theme, "normal"))
  assertEqual(panel.border.hidden, true, "an outline outlived its focus")
end

--- The accent is three objects, and a state has to move all of them.
---
--- The stripe and the two corner bands are one visual element, so a state that
--- dims the accent must dim the corners too. With the accent carried by a
--- single rectangle this could not go wrong; with three it can, and a panel
--- whose corners stayed bright while its stripe went grey would read as a
--- rendering fault rather than as stale data.
---
--- The bands are also arcs, which means constraint 11 applies: every `set` on
--- a round object walks it up and left by its own radius unless the centre is
--- restated. Colour changes are `set` calls, so a panel that changes state
--- repeatedly would march its own corners off the screen. The mock reproduces
--- that arithmetic rather than storing coordinates, so the assertion is
--- against where the firmware would actually draw.
local function testAccentFollowsState()
  local widgetPath = makeWidget("accent-state", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: metric
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      label: Pack
      source: RxBt
      rangeMin: 18
      rangeMax: 25.2
      warning: 21.0
      critical: 19.8
      precision: 1
      accent: cyan
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  local spacing = context.theme.spacing
  local entry = entryById(context, "pack")
  local panel = entry.instance.panel
  local metricModule = assert(loadfile(sourcePath .. "components/metric.lua"))()
  local modern = themeModule.modern()

  --- Every object carrying the accent, and where the radio would draw the arcs.
  local function assertAccent(expected, what)
    assertEqual(panel.accent.properties.color, expected, what .. ": stripe")
    assertEqual(panel.topArc.arc.properties.color, expected, what .. ": top band")
    assertEqual(panel.bottomArc.arc.properties.color, expected,
      what .. ": bottom band")
    for corner, band in pairs({top = panel.topArc, bottom = panel.bottomArc}) do
      assertEqual(band.arc.round.drawn.x, band.centreX - spacing.radius,
        what .. ": " .. corner .. " band walked horizontally")
      assertEqual(band.arc.round.drawn.y, band.centreY - spacing.radius,
        what .. ": " .. corner .. " band walked vertically")
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
  local zone = {x = 0, y = 0, w = 480, h = 200}
  context.zone.w, context.zone.h = zone.w, zone.h
  local passes = 0
  repeat
    definition.refresh(context)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not context.reflowIndex

  local bounds = boundsOf(entry)
  assertEqual(panel.topArc.centreY, spacing.radius,
    "the top band moved during a reflow")
  assertEqual(panel.bottomArc.centreY, bounds.h - spacing.radius,
    "the bottom band did not follow the panel's height")
  -- The mask follows too. A panel that grew past a stale mask would have its
  -- bottom corner clipped away; one that shrank would clip nothing at all
  -- below the old height, and the band would escape into the next panel.
  assertEqual(panel.column.properties.h, bounds.h,
    "the accent mask did not follow the panel's height")
  assertEqual(panel.column.properties.w, spacing.accentWidth,
    "the accent mask changed width during a reflow")
  assertAccent(lcd.RGB(modern.cyan), "after a reflow")
end

--- Supporting rows say what a badge cannot, at a span that has room for them.
---
--- The badge vocabulary was cut to the theme's own states, because a column
--- wide enough for `NOT CELLS` is a column that leaves a single-cell header
--- about four characters. Everything that vocabulary used to carry moved to
--- the supporting row, so this is where the distinctions the catalogue depends
--- on have to be checked: a dead link against a protocol with no RSSI sensor,
--- and a cells sensor returning a number against one returning nonsense.
---
--- Every row here is also checked to fit the box it was given. That is the
--- other half: a row that says the right thing and overruns its width is the
--- defect this replaced, where `16.4V PACK` was drawn into 48 px of a panel
--- that needed 99.
--- The diagnostic panel uses the shared header, not a private copy of it.
---
--- `service-probe` computed its own title width, spanning the panel's whole
--- content, so it reserved no badge column at all: the one shipped diagnostic
--- view was the only thing on the dashboard that could not show a state. It
--- had already drifted once before for the same reason, drawing its title into
--- the corner EdgeTX paints its menu button over, because only the shared
--- helper knows that corner exists.
---
--- The geometry is compared against `theme.frame`'s own answer rather than
--- against numbers copied out of it, so a probe that starts computing its own
--- again fails here however plausible its arithmetic looks.
local function testProbeUsesTheSharedHeader()
  local widgetPath = makeWidget("probe-header", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
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
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  pump(context, 20)

  local entry = entryById(context, "probe")
  local probe = entry.instance
  local bounds = boundsOf(entry)
  local frame = themeModule.frame(context.theme,
    {x = 0, y = 0, w = bounds.w, h = bounds.h}, probe.fonts)

  assert(probe.badge, "the diagnostic panel has no badge object at all")
  local title = probe.title.properties
  local badge = probe.badge.properties

  assertEqual(title.x, frame.labelX,
    "the probe's title is not where the shared frame puts a label")
  assertEqual(title.w, frame.labelWidth,
    "the probe's title is not the width the shared frame leaves a label")
  assertEqual(badge.x, frame.badgeX,
    "the probe's badge is not in the shared frame's badge column")
  assertEqual(badge.w, frame.badgeWidth,
    "the probe's badge is not the width of the shared frame's column")

  -- The title must actually leave the badge column alone, which is the thing
  -- that was wrong: a title spanning the content reaches into it.
  assert(title.x + title.w <= badge.x,
    "the probe's title runs into its own badge column")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testSupportingRowsExplainTheBadge()
  local widgetPath = makeWidget("supporting-rows", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
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
    type: cell-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels
      lowestSource: Cels-
      label: Pack
  - id: notcells
    type: cell-battery
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels-
      label: Wrong
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  pump(context, 40)

  local link = entryById(context, "link").instance
  local pack = entryById(context, "pack").instance
  assertEqual(link.showDetail, true, "a 2 x 2 link panel shed its rows")
  assertEqual(pack.showDetail, true, "a 2 x 2 cell panel shed its rows")

  --- Assert a row says something and fits the box it was given.
  local function assertRow(instance, text, width, expected, what)
    assertEqual(text, expected, what)
    local needed = themeModule.textWidth(instance.fonts.label, text)
    assert(needed <= width, string.format(
      "%s needs %d px of %d", what, needed, width))
  end

  assertRow(link, link.linkDetail, link.linkWidth, "RSSI 78dB",
    "a healthy link names its secondary source")
  assertRow(pack, pack.countText, pack.detailWidth, "4S",
    "the cell count")
  assertRow(pack, pack.packText, pack.detailWidth, "16.4V PACK",
    "the pack sum")

  -- A cells source answering with a plain number is a configuration mistake,
  -- and one answering with nonsense is a sensor fault. Both resolve to `N/A`,
  -- and the supporting row is the only thing that separates them.
  --
  -- The number case is configured rather than mutated into: the telemetry
  -- service keeps the last good reading, so a source that has already produced
  -- a cells table and then produces a number reads as stale data, which is a
  -- third situation again and not the one being tested here.
  local wrong = entryById(context, "notcells").instance
  assertEqual(wrong.summary.shape, "number")
  assertEqual(wrong.badge.properties.text, "N/A")
  assertRow(wrong, wrong.countText, wrong.detailWidth, "NOT CELLS",
    "a plain number from a cells source")

  radio.values[130] = {0, -1, 99}
  pump(context, 40)
  assertEqual(pack.summary.shape, "invalid")
  -- The explicit lowest-cell source keeps a reading alive, so the panel is not
  -- unavailable; the row is what reports that the table itself is gone.
  assertEqual(pack.text, "4.09V")
  assertRow(pack, pack.countText, pack.detailWidth, "BAD CELLS",
    "nonsense from a cells source")
  assert(pack.countText ~= wrong.countText,
    "a sensor fault and a configuration mistake read the same")

  -- A dead link is reported by the row too, and is checked last because it
  -- marks every other panel stale on its way past.
  resetRadio()
  pump(context, 40)
  radio.rssi = 0
  pump(context, 40)
  assertEqual(link.stateName, "critical")
  assertEqual(link.badge.properties.text, "CRIT")
  assertRow(link, link.linkDetail, link.linkWidth, "LINK DOWN",
    "a dead link says so in words")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- Panels of one size agree about how large a reading is.
---
--- This is the thing the shared ladder exists for, and it is measured through
--- the real host rather than through the geometry helpers, because the defect
--- was never in the arithmetic: each component's own ladder was correct and
--- they disagreed with each other. At `2 x 2` the four panels of the span
--- gallery landed on XXLSIZE, DBLSIZE, MIDSIZE and SMLSIZE, a range of four to
--- one on panels identical to the pixel.
---
--- The bound the old code also satisfied is "no reading is larger than its box
--- allows". That is true of every version of this component and proves
--- nothing, so what is asserted here is the spread between components and the
--- direction of the ladder.
local function testReadingsAgreeAcrossComponents()
  --- Build one layout full of a single span and report the fonts drawn.
  local function fontsAt(colSpan, rowSpan, entries)
    local lines = {"version: 1", "grid:", "  columns: 4", "  rows: 4", "components:"}
    local col, row = 0, 0
    for index, entry in ipairs(entries) do
      lines[#lines + 1] = "  - id: c" .. index
      lines[#lines + 1] = "    type: " .. entry[1]
      lines[#lines + 1] = "    col: " .. col
      lines[#lines + 1] = "    row: " .. row
      lines[#lines + 1] = "    colSpan: " .. colSpan
      lines[#lines + 1] = "    rowSpan: " .. rowSpan
      lines[#lines + 1] = "    config:"
      for _, line in ipairs(entry[2]) do lines[#lines + 1] = "      " .. line end
      col = col + colSpan
      if col + colSpan > 4 then col = 0; row = row + rowSpan end
    end

    local widget = makeWidget("agree-" .. colSpan .. "x" .. rowSpan,
      table.concat(lines, "\n") .. "\n")
    resetRadio()
    local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
      DEFAULT_OPTIONS, widget)
    pump(context, 40)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

    local seen = {}
    for _, entry in ipairs(context.components) do
      local instance = entry.instance
      local object = instance.value
      assert(object, entry.placement.id .. " drew no reading")
      local font = object.properties.font
      if type(font) == "function" then font = font() end
      seen[#seen + 1] = {entry.module.id, font}
    end
    return seen
  end

  -- Four components whose readings are as different as the catalogue offers:
  -- three digits, a voltage with a unit, a dBm reading, and a distance.
  local ENTRIES = {
    {"metric", {"label: Alt", "source: Alt", "rangeMin: 0", "rangeMax: 400",
      "precision: 0"}},
    {"cell-battery", {"source: Cels", "label: Pack"}},
    {"link-status", {"rssiSource: RSSI", "qualitySource: RQly", "label: Link"}},
    {"tx-battery", {"label: TX", "packEmpty: 6.6", "packFull: 8.4"}},
  }

  local order = {[SMLSIZE] = 1, [MIDSIZE] = 2, [DBLSIZE] = 3, [XXLSIZE] = 4}
  local spread = {}
  for _, span in ipairs({{1, 1}, {2, 1}, {4, 1}, {2, 2}}) do
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
    assert(high - low <= 1, string.format(
      "%s: readings on identical panels span %d font steps", name, high - low))
  end

  -- And the agreement is real rather than an artefact of every panel being
  -- driven to the smallest font: at least one span has to reach full
  -- agreement, and the large spans must not all collapse onto SMLSIZE.
  local agreed = 0
  for _, value in pairs(spread) do if value == 0 then agreed = agreed + 1 end end
  assert(agreed >= 2, "no span reached full agreement, which would be the"
    .. " result of every reading being shrunk rather than reconciled")
end

--- A panel redraws when anything it draws changes, not when a chosen subset does.
---
--- Four instances of one defect have been found in this catalogue, each fixed
--- by adding the missed field to a hand-written list, which is why there was a
--- fourth. The two driven here are the live one and the latent one.
---
--- Both need the same care to reproduce: a change that also moves a compared
--- value proves nothing, because the short-circuit would have broken anyway
--- and the assertion passes for the wrong reason. The global variable's
--- precision is therefore pinned so that only its name arrives, and the
--- model's labels are changed while its name and bitmap are held still.
local function testRedrawsOnEverythingItDraws()
  local widgetPath = makeWidget("render-declaration", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: gv
    type: variable-indicator
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      binding: global
      index: 0
      showName: true
  - id: identity
    type: model-identity
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      presentation: name
      showLabels: true
]])

  resetRadio()
  -- The radio has not yet answered for this variable's details, which is the
  -- cold start every dashboard goes through.
  local details = radio.globalDetails[0]
  radio.globalDetails[0] = nil

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  pump(context, 40)

  local gv = entryById(context, "gv").instance
  assertEqual(gv.detail, "GV1 FM1",
    "the supporting row does not name the variable before its details arrive")
  local before = gv.text

  -- EdgeTX answers, with a name and with the same precision it was already
  -- being read at, so the value on screen does not move. Anything that moved
  -- the value would break the short-circuit by itself and prove nothing.
  radio.globalDetails[0] = {
    name = "Rates", min = -100, max = 100, prec = 0, unit = 0,
  }
  pump(context, 60)

  assertEqual(gv.text, before,
    "the value moved, so this no longer tests what it was written for")
  assertEqual(gv.labelValue, "RATES", "the header did not take the new name")
  assertEqual(gv.detail, "Rates FM1",
    "the header took the variable's name and the supporting row kept the old"
      .. " one, which is the defect this exists to catch")

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
  assertEqual(identity.labelsText, "fpv,racing",
    "the labels row kept its old value while the model's labels changed")

  radio.globalDetails[0] = details
  resetRadio()
end

--- Responsive presentation must differ across the baseline spans.
local function testResponsiveSpans()
  local metricModule = assert(loadfile(sourcePath .. "components/metric.lua"))()

  local small = metricModule.presentationFor(1, 1)
  local wide = metricModule.presentationFor(2, 1)
  local large = metricModule.presentationFor(2, 2)

  assertEqual(small.showUnit, false, "1 x 1 must stay minimal")
  assertEqual(small.showVisual, false)
  assertEqual(wide.showUnit, true, "2 x 1 adds units")
  assertEqual(wide.showRange, false)
  assertEqual(large.showRange, true, "2 x 2 adds the range")

  -- A 2 x 2 metric renders its range and bar; a 2 x 1 renders neither range.
  assert(entryById(appContext, "pack").instance.range, "2 x 2 metric lost its range")
  assertEqual(entryById(appContext, "current").instance.range, nil)
  -- The altitude metric disables its visualization through configuration.
  assertEqual(entryById(appContext, "altitude").instance.bar, nil)
end

--- Every state must restyle the panel and publish a text badge where required.
local function testMetricStates()
  local pack = entryById(appContext, "pack").instance
  local metricModule = assert(loadfile(sourcePath .. "components/metric.lua"))()
  local modern = themeModule.modern()

  metricModule.setValue(pack, 24.0)
  assertEqual(pack.stateName, "normal")
  assertEqual(pack.value.properties.text, "24.0")
  assertEqual(pack.badge.properties.text, "")
  assertEqual(pack.panel.accent.properties.color, lcd.RGB(modern.cyan),
    "the accent bar did not follow the normal state")

  -- Falling thresholds: warning at 21.0, critical at 19.8.
  metricModule.setValue(pack, 20.5)
  assertEqual(pack.stateName, "warning")
  assertEqual(pack.badge.properties.text, "WARN")
  assertEqual(pack.panel.accent.properties.color, lcd.RGB(modern.amber),
    "the accent bar did not follow the amber state")

  metricModule.setValue(pack, 19.0)
  assertEqual(pack.stateName, "critical")
  assertEqual(pack.badge.properties.text, "CRIT")
  assertEqual(pack.panel.accent.properties.color, lcd.RGB(modern.critical),
    "the accent bar did not follow the critical state")

  metricModule.setValue(pack, 24.0, true)
  assertEqual(pack.stateName, "stale")
  assertEqual(pack.badge.properties.text, "STALE")

  metricModule.setValue(pack, nil)
  assertEqual(pack.stateName, "unavailable")
  assertEqual(pack.badge.properties.text, "N/A")
  assertEqual(pack.value.properties.text, "--")

  -- Rising thresholds must be inferred in the opposite direction.
  local current = entryById(appContext, "current").instance
  metricModule.setValue(current, 10)
  assertEqual(current.stateName, "normal")
  metricModule.setValue(current, 95)
  assertEqual(current.stateName, "warning")
  metricModule.setValue(current, 115)
  assertEqual(current.stateName, "critical")

  -- Geometry must stay stable as values and states change.
  local before = pack.value.properties.w
  metricModule.setValue(pack, 22.5)
  assertEqual(pack.value.properties.w, before, "value width shifted")
end

--- Zone changes reflow every component through the renamed update callback.
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
  until not appContext.reflowIndex

  assertEqual(appContext.root.properties.w, 320)
  assertEqual(appContext.root.properties.h, 240)
  assertEqual(appContext.canvas.properties.w, 320)
  assertEqual(panelOf(entryById(appContext, "pack")).w, 158)

  local pulse = entryById(appContext, "pulse")
  local ticksBefore = pulse.instance.ticks
  pump(appContext, 2)
  assertEqual(pulse.instance.ticks, ticksBefore + 2, "refresh was not dispatched")

  definition.background(appContext)
  assertEqual(pulse.instance.backgroundTicks, 1, "background was not dispatched")

  -- Events reach components; an unconsumed event is reported as unconsumed.
  assertEqual(definition.event(appContext, 32), false)
  assertEqual(pulse.instance.events, 1, "event was not dispatched")
end

--- Changing Dashboard ID or Theme tears down and restages without leaking.
local function testOptionReload()
  definition.update(appContext, {DashID = "alternate", Theme = "modern"})

  -- A reload discards the whole page and builds the next generation as a
  -- fresh child of the root, which is never cleared. The clearing callback
  -- must create nothing, because EdgeTX may collect the clear much later.
  local discarded = appContext.page
  definition.refresh(appContext)
  assertEqual(discarded.cleared, true, "first callback did not discard the page")
  assertEqual(appContext.root.cleared, false, "the root must never be cleared")
  assertEqual(appContext.reloadState, "rebuild", "reload did not defer its rebuild")
  assertEqual(appContext.page, nil, "page was recreated in the clearing callback")
  assertEqual(appContext.canvas, nil, "canvas was recreated in the clearing callback")
  assertEqual(appContext.stage, nil, "loading started before the rebuild")

  definition.refresh(appContext)
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
  assertEqual(#appContext.components, 5)

  -- The rebuilt dashboard must still be usable, which is what the deferred
  -- cleanup broke: the canvas survived creation and then died silently.
  definition.refresh(appContext)
  definition.refresh(appContext)
  assertEqual(#appContext.errors, 0, table.concat(appContext.errors, "\n"))
  appContext.canvas:set({color = appContext.theme.color.canvas})

  -- Reloading a second time must behave identically.
  definition.update(appContext, {DashID = "main", Theme = "modern"})
  local rounds = 0
  repeat
    definition.refresh(appContext)
    rounds = rounds + 1
    assert(rounds < 200, "second reload never finished")
  until not appContext.stage and not appContext.reloadState
  assertEqual(#appContext.components, 5)
  assertEqual(#appContext.errors, 0, table.concat(appContext.errors, "\n"))

  -- Switching only the theme must also trigger a rebuild.
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, referencePath)
  definition.update(context, {DashID = "main", Theme = "custom"})
  assertEqual(context.reloadState, "clear")
end

--- A reload must not depend on when EdgeTX collects a pending clear.
--- callRefs is skipped while the widget is off screen, such as behind the
--- settings dialog, and once an error has been reported, so the cleanup that
--- follows clear() can land several callbacks later. Rebuilding into a fresh
--- page keeps the new generation out of its reach.
local function testReloadSurvivesLateCleanup()
  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, referencePath)
  local firstPage = context.page

  definition.update(context, {DashID = "alternate", Theme = "modern"})

  -- Withhold cleanup across the entire reload, the worst case.
  lvglMock.setDeferCleanup(true)
  local guard = 0
  repeat
    definition.refresh(context)
    guard = guard + 1
    assert(guard < 300, "reload never finished while cleanup was withheld")
  until not context.stage and not context.reloadState

  assert(context.page ~= firstPage, "reload reused the discarded page")
  assertEqual(#context.components, 5)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

  -- Now let the withheld cleanup land, all at once and late.
  lvglMock.setDeferCleanup(false)
  settleLvgl()

  -- The rebuilt dashboard must still be alive and usable.
  assertEqual(context.canvas.invalid, false, "canvas was swept by late cleanup")
  assertEqual(context.page.invalid, false, "page was swept by late cleanup")
  for _, entry in ipairs(context.components) do
    assertEqual(entry.container.invalid, false,
      entry.placement.id .. " was swept by late cleanup")
  end

  context.canvas:set({color = context.theme.color.canvas})
  definition.refresh(context)
  definition.refresh(context)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

--- The state badge must never be drawn on top of the label it accompanies.
local function testBadgeGeometry()
  local entry = entryById(appContext, "pack")
  local instance = entry.instance
  local label = instance.label.properties
  local badge = instance.badge.properties
  local bounds = boundsOf(entry)

  assert(label.x + label.w <= badge.x,
    "badge overlaps the label: label ends at " .. (label.x + label.w)
      .. ", badge starts at " .. badge.x)
  assert(badge.x + badge.w <= bounds.w, "badge extends past the panel")
  assert(label.w > 0 and badge.w > 0, "label or badge collapsed")
end

--- A radial visualization must be repositioned and resized on reflow.
local function testRadialReflow()
  local widgetPath = makeWidget("radial", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: dial
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Dial
      visual: radial
      rangeMin: 0
      rangeMax: 100
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  local dial = entryById(context, "dial")
  assert(dial.instance.radial, "radial visualization was not created")

  -- EdgeTX positions an arc by its centre: LvglWidgetArc::build calls setPos,
  -- and LvglWidgetRoundObject::setPos stores x - radius. A test that read x
  -- as a corner would pass while the arc was drawn a radius off the panel.
  --
  -- Measured from the object the mock actually drew rather than recomputed
  -- from what Lua passed. Recomputing is how the widget came to carry an
  -- `arcBounds` helper that no component called and that put the outer edge
  -- half a stroke too far out: the only thing checking it was a test that
  -- used the same arithmetic.
  local arc = dial.instance.radial.arc
  local bounds = boundsOf(dial)
  local firstRadius = arc.properties.radius
  local box = arcSquareOf(arc)
  assert(box.x >= 0 and box.y >= 0, "radial was drawn off its own panel")
  assert(box.x + box.w <= bounds.w, "radial overflows its panel")
  assert(box.y + box.h <= bounds.h, "radial overflows its panel")

  -- The value must not sit underneath the arc.
  local value = dial.instance.value.properties
  assert(value.x + value.w <= box.x, "value overlaps the radial")

  zone.w = 240
  zone.h = 160
  definition.refresh(context)

  local resized = dial.instance.radial.arc
  local newBounds = boundsOf(dial)
  local newBox = arcSquareOf(resized)
  assert(resized.properties.radius < firstRadius,
    "radial did not shrink with the panel")
  assert(newBox.x >= 0 and newBox.y >= 0, "radial left its panel after reflow")
  assert(newBox.x + newBox.w <= newBounds.w, "radial overflowed after reflow")
  assert(newBox.y + newBox.h <= newBounds.h, "radial overflowed after reflow")
end

--- A component that fails during create must leave no partial drawing behind.
local function testCreateFailureIsCleaned()
  local widgetPath = makeWidget("halfbuilt", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: broken
    type: halfbuilt
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: safe
    type: placeholder
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]], {
    ["halfbuilt.lua"] = [==[
local halfbuilt = {id = "halfbuilt", apiVersion = 1, supportedSpans = {"any"}}
function halfbuilt.create(parent, rect, settings, services)
  services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))
  error("failed after drawing", 0)
end
return halfbuilt
]==],
  })

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)

  assertEqual(#context.components, 1, "failed component must not be kept")
  assertEqual(context.components[1].placement.id, "safe")
  assert(string.match(table.concat(context.errors, "\n"), "failed after drawing"))
end

--- Real telemetry must drive the shipped dashboard end to end: the host polls
--- through its services, the metric renders what the service normalized, and
--- every state the design system defines is reachable from radio state alone.
local function testTelemetryDrivesComponents()
  resetRadio()
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, referencePath)
  local pack = entryById(context, "pack").instance
  local current = entryById(context, "current").instance

  assert(pack.feed, "the metric never subscribed to a source")
  assertEqual(pack.feed.name, "RxBt")

  --- Advance far enough for the services and the component to both fall due.
  local function settle()
    for _ = 1, 8 do
      tick(20)
      definition.refresh(context)
    end
  end

  settle()
  assertEqual(pack.stateName, "normal")
  assertEqual(pack.value.properties.text, "24.0")
  assertEqual(pack.badge.properties.text, "")

  -- This panel is one row tall and sheds its unit row, so the unit is not on
  -- screen here and asserting its text would assert nothing anyone can see.
  -- What is true here is that the row is shed; the sensor's unit is checked
  -- at a span that keeps it, in testMetricTakesTheSensorUnit.
  assertEqual(current.showUnit, false,
    "a one-row metric found space for a unit row")
  assert(current.unit.hidden, "a shed unit row was left on screen")
  -- Without a configured precision, the sensor's precision. This is the
  -- dominant reading, which every span draws.
  assertEqual(current.text, "10.0", "the sensor precision was ignored")

  radio.values[100] = 20.5
  settle()
  assertEqual(pack.stateName, "warning")
  assertEqual(pack.badge.properties.text, "WARN")

  radio.values[100] = 19.0
  settle()
  assertEqual(pack.stateName, "critical")
  assertEqual(pack.badge.properties.text, "CRIT")

  -- Losing the link must keep the last reading and mark it stale, never
  -- replace it with the zero EdgeTX reports for a dead telemetry source.
  radio.values[100] = 24.0
  settle()
  assertEqual(pack.stateName, "normal")
  radio.rssi = 0
  settle()
  assertEqual(pack.stateName, "stale")
  assertEqual(pack.badge.properties.text, "STALE")
  assertEqual(pack.value.properties.text, "24.0", "a stale poll overwrote the value")

  -- With the link back, a zero really is a reading and must be shown as one.
  radio.rssi = 80
  radio.values[100] = 0
  settle()
  assertEqual(pack.value.properties.text, "0.0", "a valid zero was not shown")
  assertEqual(pack.stateName, "critical")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A source no component references must never be read, because every poll is
--- charged to the same instruction budget as the rest of the dashboard.
local function testOnlyReferencedSourcesArePolled()
  resetRadio()
  local read = {}
  local realGetValue = getValue
  getValue = function(source)
    read[tostring(source)] = true
    return realGetValue(source)
  end

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, referencePath)
  for _ = 1, 40 do
    tick(20)
    definition.refresh(context)
  end
  getValue = realGetValue

  assert(read["100"], "a referenced source was never polled")
  assert(not read["109"], "an unreferenced GPS source was polled")
  assert(not read["310"], "an unreferenced trim source was polled")
  assert(not read["tx-voltage"], "an unreferenced radio source was polled")

  -- Services nothing subscribed to must stay idle rather than being scheduled.
  local byId = context.serviceRuntime.byId
  assert(byId.telemetry.revision > 0, "the telemetry service never ran")
  assertEqual(byId.navigation.revision, 0, "an idle service was scheduled")
  assertEqual(byId.control.revision, 0, "an idle service was scheduled")
  assertEqual(byId.model.revision, 0, "an idle service was scheduled")
end

testShippedLayout()
testThemeReachesComponents()
testBackgroundsArePainted()
testPanelPresentation()
testAlarmTint()
testFocusBorder()
testAccentFollowsState()
testProbeUsesTheSharedHeader()
testSupportingRowsExplainTheBadge()
testReadingsAgreeAcrossComponents()
testRedrawsOnEverythingItDraws()
testResponsiveSpans()
testBadgeGeometry()
testMetricStates()
testTelemetryDrivesComponents()
testOnlyReferencedSourcesArePolled()
testReflowAndLifecycle()
testOptionReload()
testReloadSurvivesLateCleanup()

--- A layout may select the EdgeTX-derived theme, which must stay readable.
local function testEdgeTxTheme()
  local widgetPath = makeWidget("edgetx-theme", [[
version: 1
theme:
  mode: edgetx
grid:
  columns: 4
  rows: 4
components:
  - id: only
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Derived
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)

  assertEqual(context.theme.mode, "edgetx")
  assertEqual(#context.components, 1)

  local modern = themeModule.modern()
  local tokens = context.theme.rgb

  -- The canvas must be the radio's own COLOR_THEME_SECONDARY1, widened from
  -- the RGB565 half of the flag word `lcd.getColor` returns.
  --
  -- This previously asserted only that the canvas differed from Modern's,
  -- which is satisfied by every colour being wrong in the same way. That is
  -- how a palette in which every role of every theme resolved to 0x840000
  -- passed this suite while drawing every panel on the radio dark red.
  assertEqual(tokens.canvas,
    themeModule.fromRgb565(toRgb565(edgeTxRoles[COLOR_THEME_SECONDARY1])),
    "the canvas is not the radio's own COLOR_THEME_SECONDARY1")
  assertEqual(tokens.text,
    themeModule.fromRgb565(toRgb565(edgeTxRoles[COLOR_THEME_PRIMARY2])),
    "body text is not the radio's own COLOR_THEME_PRIMARY2")

  -- Critical red stays dashboard-owned so alarms remain recognizable.
  assertEqual(tokens.critical, modern.critical)
  -- Contrast correction must keep body text readable on the derived surface.
  assert(themeModule.contrast(tokens.surface, tokens.text) >= 4.5,
    "derived text failed contrast correction")

  -- A panel has to be visible against the dashboard behind it. Canvas and
  -- surface derive from the same EdgeTX role, so without the legibility pass
  -- separating them they are the same colour and a panel has no edge at all.
  --
  -- The old assertion here was `contrast(surface, canvas) >= 1.0`, which is
  -- a tautology: theme.contrast orders its arguments and returns
  -- (lighter + 0.05) / (darker + 0.05), so it is at least 1 for any two
  -- colours, including two identical ones. It could not fail for any
  -- implementation of anything.
  assert(themeModule.contrast(tokens.surface, tokens.canvas) >= 1.08,
    "a panel cannot be told apart from the dashboard behind it")
end

--- Custom mode accepts a small override set and rejects the rest.
local function testCustomTheme()
  local widgetPath = makeWidget("custom-theme", [[
version: 1
theme:
  mode: custom
  overrides:
    canvas: 0x000000
    surface: 0x101010
    accent: green
    border: 0xFF00FF
grid:
  columns: 4
  rows: 4
components:
  - id: only
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Custom
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)

  assertEqual(context.theme.mode, "custom")
  assertEqual(context.theme.rgb.canvas, 0x000000)
  -- 0x101010 on a black canvas measures 1.11, and with no resting outline the
  -- fill is the only thing that makes a panel a panel, so the legibility pass
  -- lifts it exactly as it lifts a surface that would swallow text.
  assert(themeModule.contrast(context.theme.rgb.canvas,
    context.theme.rgb.surface) >= 1.30,
    "a custom surface was left flat against its own canvas")
  assertEqual(context.theme.accent, "green")
  -- border is outside the customizable set and must be reported, not applied.
  assert(context.theme.rgb.border ~= 0xFF00FF,
    "an override outside the customizable set was applied anyway")
  assert(themeModule.contrast(context.theme.rgb.surface,
    context.theme.rgb.border) >= 1.25, "the border vanished into the surface")

  local joined = table.concat(context.errors, "\n")
  assert(string.match(joined, "border is not customizable"), joined)
end

--- A component that raises must be disabled without affecting its neighbours.
local function testFailureIsolation()
  local widgetPath = makeWidget("exploder", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: boom
    type: exploder
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: safe
    type: placeholder
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]], {
    ["exploder.lua"] = [==[
local exploder = {id = "exploder", apiVersion = 1, supportedSpans = {"any"}}
function exploder.create(parent, rect, settings, services)
  return {panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))}
end
function exploder.refresh()
  error("exploder failed", 0)
end
return exploder
]==],
  })

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  assertEqual(#context.components, 2)

  pump(context, 1)

  local boom = entryById(context, "boom")
  local safe = entryById(context, "safe")
  assertEqual(boom.failed, true, "failing component was not disabled")
  assert(string.match(boom.error, "exploder failed"), boom.error)
  assertEqual(safe.failed, nil, "healthy component was disabled")
  assertEqual(#context.errors, 1, "failure was not reported exactly once")
  assert(context.errorLabel, "failure was not shown")

  -- Further refreshes must stay quiet and keep the healthy component running.
  pump(context, 2)
  assertEqual(#context.errors, 1, "failure was reported repeatedly")
  assertEqual(#context.components, 2)
end

--- A reported failure must be readable on the radio it happened on.
---
--- In App mode EdgeTX draws its menu button over the top-left corner of the
--- screen, above everything the widget draws, so an overlay placed at the
--- zone's own origin is invisible exactly when it matters most: a component
--- could fail and the radio would show nothing at all. The overlay therefore
--- has to clear the button, and a reserved corner has to be recognized in the
--- first place, which means reading a firmware constant the firmware shifts.
local function testErrorsClearTheMenuButton()
  local widgetPath = makeWidget("overlay", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: boom
    type: exploder
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
]], {
    ["exploder.lua"] = [==[
local exploder = {id = "exploder", apiVersion = 1, supportedSpans = {"any"}}
function exploder.create(parent, rect, settings, services)
  return {panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))}
end
function exploder.refresh()
  error("exploder failed", 0)
end
return exploder
]==],
  })

  --- Report whether a box intersects the corner the button covers.
  local function underButton(properties, text)
    local width = themeModule.textWidth(SMLSIZE, text)
    local height = themeModule.fontHeight(SMLSIZE)
    return properties.x < MENU_BUTTON_WIDTH
      and properties.y < MENU_BUTTON_HEIGHT
      and properties.x + width > 0
      and properties.y + height > 0
  end

  local context = createLoaded(appZone(), DEFAULT_OPTIONS, widgetPath)
  pump(context, 1)

  assert(context.reserved, "App mode did not reserve the menu button corner")
  assertEqual(context.reserved.w, MENU_BUTTON_WIDTH, "reserved width")
  assertEqual(context.reserved.h, MENU_BUTTON_HEIGHT, "reserved height")

  local label = assert(context.errorLabel, "failure was not shown at all")
  local text = table.concat(context.errors, "\n")
  assert(not underButton(label.properties, text),
    "the error overlay is drawn under the EdgeTX menu button, at ("
      .. label.properties.x .. "," .. label.properties.y .. ")")
  -- Clearing the button must not push it off the screen either.
  assert(label.properties.y + themeModule.fontHeight(SMLSIZE) <= 272,
    "the error overlay was pushed off the bottom of the display")

  -- Outside App mode the button is either hidden or drawn above the widget, so
  -- nothing is reserved and the overlay keeps the whole zone.
  local plain = createLoaded(fullScreenZone(), DEFAULT_OPTIONS, widgetPath)
  pump(plain, 1)
  assertEqual(plain.reserved, nil, "a Full screen zone reserved a corner")
  assertEqual(assert(plain.errorLabel).properties.y, 8,
    "the overlay gave up room it did not have to")

  -- A radio whose button is not 45 px must still be measured rather than
  -- assumed. EdgeTX scales MENU_HEADER_HEIGHT per display class, so a host
  -- that never unshifts the constant falls back to this file's 480 x 272
  -- guess and is wrong everywhere else; only a different height can catch it.
  local wideButton = 62
  MENU_HEADER_HEIGHT = wideButton * 65536
  local wide = createLoaded(appZone(), DEFAULT_OPTIONS, widgetPath)
  assertEqual(assert(wide.reserved, "no corner reserved on a wider display").h,
    wideButton, "the button height was assumed rather than read")
  assertEqual(wide.reserved.w, 65,
    "the width kept clear does not match MENU_HEADER_BUTTONS_LEFT")
  MENU_HEADER_HEIGHT = MENU_BUTTON_HEIGHT * 65536

  -- A zone that moves out from under the button releases the reservation, and
  -- the overlay it already created follows.
  lvglMock.setAppMode(true)
  local moving = createLoaded(appZone(), DEFAULT_OPTIONS, widgetPath)
  pump(moving, 1)
  local moved = assert(moving.errorLabel).properties.y
  assert(moved > 8, "App mode overlay was not moved clear")
  moving.zone.yabs = MENU_BUTTON_HEIGHT
  moving.zone.h = 272 - MENU_BUTTON_HEIGHT
  pump(moving, 4)
  assertEqual(moving.reserved, nil, "reservation survived the zone moving")
  assertEqual(moving.errorLabel.properties.y, 8,
    "the overlay did not follow the zone out from under the button")
  lvglMock.setAppMode(false)
end

--- Nothing a pilot has to read may sit under the EdgeTX menu button.
---
--- This is the defect that hid the shipped dashboard's distance reading: the
--- compass dial squeezed navigation's value down to SMLSIZE, which left it
--- 39 x 17 at (8, 25), entirely inside the 47 x 45 corner the button covers.
--- Nothing failed and nothing was reported; the number was simply painted over.
--- A layout author cannot predict that, because it depends on which font
--- fitText chose, so it has to be a checked invariant rather than advice.
local function testNothingReadableUnderTheMenuButton()
  --- Every label a component actually draws, with its rendered box.
  local function readableLabels(entry)
    local found = {}

    local function walk(object, offsetX, offsetY)
      for _, child in ipairs(object.children) do
        local x = offsetX + (child.properties.x or 0)
        local y = offsetY + (child.properties.y or 0)
        local text = tostring(child.properties.text or "")
        if child.kind == "label" and not child.hidden and text ~= "" then
          local font = child.properties.font
          local size = type(font) == "function" and font() or font
          found[#found + 1] = {
            text = text,
            x = x,
            y = y,
            w = themeModule.textWidth(size, text),
            h = themeModule.fontHeight(size),
          }
        end
        walk(child, x, y)
      end
    end

    local bounds = boundsOf(entry)
    walk(entry.container, bounds.x, bounds.y)
    return found
  end

  local function check(label, context)
    local reserved = assert(context.reserved, label .. ": nothing was reserved")
    for _, entry in ipairs(context.components) do
      for _, drawn in ipairs(readableLabels(entry)) do
        assert(drawn.x >= reserved.w or drawn.y >= reserved.h
            or drawn.x + drawn.w <= 0 or drawn.y + drawn.h <= 0,
          label .. ": " .. entry.placement.id .. ' draws "' .. drawn.text
            .. '" at (' .. drawn.x .. "," .. drawn.y
            .. "), under the EdgeTX menu button")
      end
    end
  end

  -- Every shipped layout, because the directory is the list. A new layout is
  -- covered the moment it is added, exactly like the load coverage.
  local listingPath = root .. "/build/appmode-layouts.txt"
  os.execute("ls '" .. sourcePath .. "layouts' > '" .. listingPath .. "'")
  local listing = assert(hostIo.open(listingPath, "r"))
  local names = {}
  for name in listing:lines() do
    local stem = string.match(name, "^(.+)%.yaml$")
    if stem then names[#names + 1] = stem end
  end
  listing:close()
  os.remove(listingPath)
  assert(#names > 1, "no shipped layouts were found to check")

  for _, stem in ipairs(names) do
    resetRadio()
    local source = assert(hostIo.open(sourcePath .. "layouts/" .. stem .. ".yaml", "r"))
    local yaml = source:read("a")
    source:close()

    local widget = makeWidget("appmode-" .. stem, yaml)
    local context = createLoaded(appZone(), DEFAULT_OPTIONS, widget)
    pump(context, 60)
    assertEqual(#context.errors, 0, stem .. ": " .. table.concat(context.errors, "\n"))
    check("layout " .. stem, context)
  end

  -- The worst case the grid permits: a single cell in the corner, where the
  -- button covers 40% of the width and 69% of the height. The reading has to
  -- survive even though the label cannot.
  local cramped = makeWidget("appmode-cramped", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: tight
    type: metric
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      label: Pack
      source: RxBt
      precision: 1
]])
  resetRadio()
  local context = createLoaded(appZone(), DEFAULT_OPTIONS, cramped)
  pump(context, 60)
  check("1 x 1 corner", context)

  local tight = entryById(context, "tight").instance
  assertEqual(tight.value.properties.text, "24.0",
    "the reading was lost rather than moved")
  assert(tight.label.hidden,
    "a label with no room left beside the button was drawn anyway")

  -- Every catalogue component, at every span the grid allows, in the corner.
  -- Eight of the ten pull their reading back up when a panel is too short to
  -- hold it below the header, which could slide it under the button again.
  -- The cell heights that would do that are one pixel away from the ones the
  -- grid actually produces, so this is measured rather than reasoned about.
  local sweepPath = makeWidget("appmode-sweep")
  --- What each component needs to draw something real during the sweep.
  local SWEEP_CONFIG = {
    ["metric"] = {"      label: Probe", "      source: RxBt"},
    ["flight-timer"] = {"      label: Probe", "      timer: 0"},
    ["flight-mode"] = {"      label: Probe"},
    ["tx-battery"] = {"      label: Probe"},
    ["variable-indicator"] = {"      label: Probe", "      index: 0"},
    ["trim-panel"] = {"      label: Probe", "      trim1: trim-ail"},
    ["model-identity"] = {"      label: Probe"},
    ["cell-battery"] = {"      label: Probe", "      source: Cels"},
    ["link-status"] = {"      label: Probe", "      rssiSource: RSSI",
      "      qualitySource: RQly"},
    ["navigation"] = {"      label: Probe", "      source: GPS"},
    ["heartbeat"] = {"      label: Probe"},
    ["placeholder"] = {"      label: Probe"},
  }

  local sweepTypes = {
    "metric", "flight-timer", "flight-mode", "tx-battery",
    "variable-indicator", "trim-panel", "model-identity",
    "cell-battery", "link-status", "navigation",
    -- The two development components ship in the package too, so a layout
    -- may place them. Both drew at a raw (8, 6) until they were routed
    -- through the shared frame like everything else.
    "heartbeat", "placeholder",
  }
  local checked = {}

  for _, kind in ipairs(sweepTypes) do
    checked[kind] = 0
    for colSpan = 1, 4 do
      for rowSpan = 1, 4 do
        resetRadio()
        writeFile(sweepPath .. "layouts/default.yaml", table.concat({
          "version: 1",
          "grid:",
          "  columns: 4",
          "  rows: 4",
          "components:",
          "  - id: probe",
          "    type: " .. kind,
          "    col: 0",
          "    row: 0",
          "    colSpan: " .. colSpan,
          "    rowSpan: " .. rowSpan,
          "    config:",
          -- Each kind gets only the keys it declares. Handing every key to
          -- every component was a shortcut, and it stopped being a harmless
          -- one when an undeclared key became something the host reports.
          table.concat(SWEEP_CONFIG[kind] or {"      label: Probe"}, "\n"),
          "", }, "\n"))

        local swept = createLoaded(appZone(), DEFAULT_OPTIONS, sweepPath)
        pump(swept, 20)

        -- A span the component refuses is a refusal, not a defect.
        local refused = #swept.components == 0
        if not refused then
          assertEqual(#swept.errors, 0, kind .. " " .. colSpan .. "x" .. rowSpan
            .. ": " .. table.concat(swept.errors, "\n"))
          check(kind .. " " .. colSpan .. "x" .. rowSpan, swept)
          checked[kind] = checked[kind] + 1
        end
      end
    end
  end

  -- Per type, so a name the loader rejects cannot quietly drop one from the
  -- sweep and leave it looking as though it passed.
  for _, kind in ipairs(sweepTypes) do
    assert(checked[kind] > 0, kind .. " was never built at any span")
  end

  -- Outside App mode nothing is taken away, so the same layout keeps the
  -- geometry it has always had.
  local plain = createLoaded(fullScreenZone(), DEFAULT_OPTIONS, cramped)
  pump(plain, 60)
  local plainLabel = entryById(plain, "tight").instance.label
  local plainSpacing = themeModule.build("modern").spacing
  assertEqual(plainLabel.hidden, false, "a Full screen panel lost its label")
  -- An unobstructed label starts where the content does, which is clear of
  -- the accent stripe rather than hard against it.
  assertEqual(plainLabel.properties.x,
    plainSpacing.accentWidth + plainSpacing.accentGap,
    "a Full screen panel moved its label")
  lvglMock.setAppMode(false)
end

--- The host adapting as designed must not be reported as a failure.
---
--- The legibility pass corrects derived palettes by design, and every
--- correction used to be promoted to an error. Now that the overlay is
--- actually visible, that would leave a permanent banner on the screen of
--- every radio running the EdgeTX or Custom theme, announcing that the
--- dashboard had done its job.
local function testNoticesAreNotErrors()
  local derived = makeWidget("derived-theme", [[
version: 1
theme:
  mode: edgetx
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Pack
      source: RxBt
  - id: boom
    type: exploder
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]], {
    ["exploder.lua"] = [==[
local exploder = {id = "exploder", apiVersion = 1, supportedSpans = {"any"}}
function exploder.create(parent, rect, settings, services)
  return {panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))}
end
function exploder.refresh()
  error("exploder failed", 0)
end
return exploder
]==],
  })

  resetRadio()
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, derived)
  assertEqual(context.theme.mode, "edgetx")

  -- The deliberately light mock roles guarantee the legibility pass engages,
  -- so a test that saw no notices would not be testing anything.
  assert(#context.notices > 0, "the legibility pass recorded nothing")
  local corrected = false
  for _, notice in ipairs(context.notices) do
    assert(notice.severity == "info" or notice.severity == "warning",
      "notice carried no usable severity: " .. tostring(notice.severity))
    if string.match(notice.text, "corrected for contrast") then corrected = true end
  end
  assert(corrected, "no contrast correction was recorded on a derived palette")
  assertEqual(#context.errors, 0,
    "the legibility pass was reported as a failure: "
      .. table.concat(context.errors, "\n"))
  assertEqual(context.errorLabel, nil, "a notice put a banner on the screen")

  -- A component that genuinely fails must still reach the overlay, so the
  -- fix cannot have been "stop reporting things".
  pump(context, 1)
  assertEqual(#context.errors, 1, "a real failure stopped being reported")
  assert(string.match(context.errors[1], "exploder failed"), context.errors[1])
  assert(context.errorLabel, "a real failure was not shown")
end

--- Several independent dashboards, on one model and across a model change.
---
--- EdgeTX runs every Lua widget in one interpreter state, so two AeroGrid
--- instances on two custom screens share a Lua state, a set of loaded modules
--- and a set of globals. Anything a module keeps at its own scope is therefore
--- shared between dashboards that are supposed to know nothing about each
--- other, and the tracked simulator model has exactly this arrangement: two
--- App mode screens whose widgets select the sim and sim2 dashboards.
---
--- A model change needs no handling at all, and that is worth recording
--- rather than rediscovering. LayoutFactory::deleteCustomScreens runs before
--- loadModel and loadCustomScreens after it, so every widget is destroyed and
--- rebuilt; the host is never asked to notice that the model moved underneath
--- it. The firmware comment there says loadModel can re-enter the UI refresh
--- loop, so a widget that tried to survive one would read torn-down data.
local function testMultipleScreens()
  local previous = radio.modelFilename
  local widgetPath = makeWidget("screens", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: fallback
    type: placeholder
    col: 0
    row: 0
    colSpan: 4
    rowSpan: 4
]])

  writeFile(widgetPath .. "layouts/model1--alpha.yaml", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: alt
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Alt
      source: Alt
      precision: 0
]])

  writeFile(widgetPath .. "layouts/model1--beta.yaml", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Pack
      source: RxBt
      precision: 1
  - id: mode
    type: flight-mode
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]])

  writeFile(widgetPath .. "layouts/other--alpha.yaml", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: speed
    type: metric
    col: 0
    row: 0
    colSpan: 4
    rowSpan: 2
    config:
      label: Speed
      source: GSpd
      precision: 0
]])

  --- Ids of the components an instance actually built.
  local function idsOf(context)
    local ids = {}
    for index, entry in ipairs(context.components) do ids[index] = entry.placement.id end
    table.sort(ids)
    return table.concat(ids, ",")
  end

  --- An instance renders one page, not a stack of them it could swap.
  local function visiblePages(context)
    local count = 0
    for _, child in ipairs(context.root.children) do
      if not child.hidden then count = count + 1 end
    end
    return count
  end

  resetRadio()
  radio.modelFilename = "model1.yml"

  -- Two Dashboard IDs, one model: two separate screens of the same radio.
  local alpha = createLoaded({x = 0, y = 0, w = 480, h = 272},
    {DashID = "alpha", Theme = "modern"}, widgetPath)
  local beta = createLoaded({x = 0, y = 0, w = 480, h = 272},
    {DashID = "beta", Theme = "modern"}, widgetPath)

  assertEqual(alpha.layoutPath, widgetPath .. "layouts/model1--alpha.yaml")
  assertEqual(beta.layoutPath, widgetPath .. "layouts/model1--beta.yaml")
  assertEqual(idsOf(alpha), "alt")
  assertEqual(idsOf(beta), "mode,pack")

  -- Nothing may be shared but the modules themselves. A service registry held
  -- at module scope would hand one dashboard the other's subscriptions.
  assert(alpha.root ~= beta.root, "two instances share a root")
  assert(alpha.page ~= beta.page, "two instances share a page")
  assert(alpha.serviceRuntime ~= beta.serviceRuntime,
    "two instances share a service registry")
  assert(alpha.serviceRuntime.byId.telemetry
    ~= beta.serviceRuntime.byId.telemetry,
    "two instances share a telemetry service, and so share subscriptions")

  -- Running them together must not let either disturb the other.
  for _ = 1, 60 do
    tick(20)
    definition.refresh(alpha)
    definition.refresh(beta)
  end

  assertEqual(#alpha.errors, 0, table.concat(alpha.errors, "\n"))
  assertEqual(#beta.errors, 0, table.concat(beta.errors, "\n"))
  assertEqual(idsOf(alpha), "alt", "an instance changed what it rendered")
  assertEqual(idsOf(beta), "mode,pack", "an instance changed what it rendered")
  assertEqual(entryById(alpha, "alt").instance.value.properties.text, "100")
  assertEqual(entryById(beta, "pack").instance.value.properties.text, "24.0")

  -- Each instance renders exactly one page and offers no way to turn it.
  -- Paging between dashboards is EdgeTX sliding between custom screens, not
  -- anything this host does, so an event must not be able to change the page.
  assertEqual(visiblePages(alpha), 1, "an instance rendered more than one page")
  assertEqual(visiblePages(beta), 1, "an instance rendered more than one page")
  assertEqual(definition.event(alpha, 34), false,
    "the host consumed an event it has no page to turn with")
  assertEqual(alpha.layoutPath, widgetPath .. "layouts/model1--alpha.yaml",
    "an event changed which layout an instance was showing")
  assertEqual(visiblePages(alpha), 1, "an event added a page")

  -- A different model resolves a different file for the same Dashboard ID.
  -- EdgeTX rebuilds every widget across a model change, so this is what the
  -- radio really does rather than a reload the host would have to detect.
  radio.modelFilename = "other.yml"
  local switched = createLoaded({x = 0, y = 0, w = 480, h = 272},
    {DashID = "alpha", Theme = "modern"}, widgetPath)
  assertEqual(switched.layoutPath, widgetPath .. "layouts/other--alpha.yaml")
  assertEqual(idsOf(switched), "speed")
  assertEqual(#switched.errors, 0, table.concat(switched.errors, "\n"))

  -- A model with no file of its own falls back to the dashboard-wide layout,
  -- then to the shipped default, rather than failing to load.
  radio.modelFilename = "third.yml"
  local fallback = createLoaded({x = 0, y = 0, w = 480, h = 272},
    {DashID = "gamma", Theme = "modern"}, widgetPath)
  assertEqual(fallback.layoutPath, widgetPath .. "layouts/default.yaml")
  assertEqual(idsOf(fallback), "fallback")

  -- The instances created before the switch are untouched by it, because
  -- nothing about them was keyed on a global.
  assertEqual(idsOf(alpha), "alt", "a later instance disturbed an earlier one")
  assertEqual(alpha.layoutPath, widgetPath .. "layouts/model1--alpha.yaml")

  radio.modelFilename = previous
end

--- An event consumed by one component must stop propagating.
local function testEventConsumption()
  local widgetPath = makeWidget("consumer", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: eater
    type: eater
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: pulse
    type: heartbeat
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]], {
    ["eater.lua"] = [==[
local eater = {id = "eater", apiVersion = 1, supportedSpans = {"any"}}
function eater.create(parent, rect, settings, services)
  return {panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan")), seen = 0}
end
function eater.event(context)
  context.seen = context.seen + 1
  return true
end
return eater
]==],
  })

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.components, 2)

  assertEqual(definition.event(context, 32), true, "event was not consumed")
  assertEqual(entryById(context, "eater").instance.seen, 1)
  -- The later component must never see a consumed event.
  assertEqual(entryById(context, "pulse").instance.events, 0)
end

--- Contract, span, and module-resolution failures are visible and survivable.
local function testContractRejections()
  local widgetPath = makeWidget("contract", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: toobig
    type: heartbeat
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 4
  - id: oldapi
    type: legacy
    col: 2
    row: 0
    colSpan: 1
    rowSpan: 1
  - id: renamed
    type: mismatch
    col: 3
    row: 0
    colSpan: 1
    rowSpan: 1
  - id: absent
    type: nosuchcomponent
    col: 2
    row: 1
    colSpan: 1
    rowSpan: 1
  - id: good
    type: placeholder
    col: 3
    row: 1
    colSpan: 1
    rowSpan: 1
]], {
    ["legacy.lua"] = [==[
return {id = "legacy", apiVersion = 99, create = function() return {} end}
]==],
    ["mismatch.lua"] = [==[
return {id = "somethingelse", apiVersion = 1, create = function() return {} end}
]==],
  })

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)

  assertEqual(#context.components, 1, "only the valid component should load")
  assertEqual(context.components[1].placement.id, "good")
  assertEqual(#context.errors, 4)

  local joined = table.concat(context.errors, "\n")
  assert(string.match(joined, "toobig: component does not support span 2x4"), joined)
  assert(string.match(joined, "oldapi: incompatible component API"), joined)
  assert(string.match(joined, "renamed: component module id somethingelse"), joined)
  assert(string.match(joined, "absent:"), joined)
end

--- A corrupt layout must report an error instead of raising.
local function testCorruptLayout()
  local widgetPath = makeWidget("corrupt", "version: 1\n\tcomponents: []\n")
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)

  assertEqual(#context.components, 0)
  assert(#context.errors > 0, "corrupt layout reported no error")
  assert(context.errorLabel, "corrupt layout was not shown")
end

--- EdgeTX aborts any widget callback exceeding 20000 VM instructions with
--- "CPU limit". That ceiling is invisible to ordinary assertions, so measure
--- every callback the firmware can invoke and keep real headroom.
---
--- This must be measured against the largest layout the schema permits, not
--- the shipped one: a 4 x 4 grid admits sixteen single-cell components, and an
--- earlier staged loader passed comfortably on five while failing on sixteen.
local function testInstructionBudget()
  local BUDGET = 20000
  local CEILING = BUDGET * 0.75

  local function measure(fn, ...)
    local ticks = 0
    -- The mock's property validation stands in for `parseParam`, which is C++
    -- and costs a script nothing. Counting it here would measure the fixture.
    setPropertyValidation(false)
    setCallCounting(false)
    -- Count exactly as the firmware does: a hook every 200 instructions.
    debug.sethook(function() ticks = ticks + 1 end, "", 200)
    local ok, err = pcall(fn, ...)
    debug.sethook()
    setCallCounting(true)
    setPropertyValidation(true)
    assert(ok, "callback raised: " .. tostring(err))
    return ticks * 200
  end

  --- Build a layout that fills the grid with single-cell metrics.
  local function fullGridLayout(count, componentType)
    componentType = componentType or "metric"
    local lines = {"version: 1", "grid:", "  columns: 4", "  rows: 4", "components:"}
    for i = 1, count do
      local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
      lines[#lines + 1] = "  - id: m" .. i
      lines[#lines + 1] = "    type: " .. componentType
      lines[#lines + 1] = "    col: " .. col
      lines[#lines + 1] = "    row: " .. row
      lines[#lines + 1] = "    colSpan: 1"
      lines[#lines + 1] = "    rowSpan: 1"
      lines[#lines + 1] = "    config:"
      lines[#lines + 1] = "      label: Metric " .. i
      lines[#lines + 1] = "      unit: V"
      lines[#lines + 1] = "      accent: cyan"
      lines[#lines + 1] = "      rangeMin: 0"
      lines[#lines + 1] = "      rangeMax: 100"
      lines[#lines + 1] = "      warning: 80"
      lines[#lines + 1] = "      critical: 90"
      lines[#lines + 1] = "      precision: 1"
      lines[#lines + 1] = "      visual: bar"
      -- A distinct live source per cell, so the telemetry service really does
      -- carry sixteen subscriptions rather than sixteen names it rejects.
      lines[#lines + 1] = "      source: S" .. i
    end
    return table.concat(lines, "\n") .. "\n"
  end

  --- Every service, exercised at the largest layout the schema permits.
  --- The five services are spread across sixteen single-cell diagnostic
  --- panels, each subscribing to something different, so the measurement
  --- covers the whole service layer rather than telemetry alone.
  local PROBE_SPECS = {
    {service = "telemetry", source = "S1"},
    {service = "telemetry", source = "S2"},
    {service = "telemetry", source = "S3"},
    {service = "telemetry", source = "RxBt"},
    {service = "navigation", source = "GPS", extra = "Dist"},
    {service = "navigation", source = "GPS2"},
    {service = "model", index = 0},
    {service = "model", index = 1},
    {service = "model", index = 2},
    {service = "control", source = "trim-ail", index = 0},
    {service = "control", source = "trim-ele", index = 1},
    {service = "control", source = "trim-rud", index = 2},
    {service = "control", source = "trim-thr", index = 3},
    {service = "extrema", source = "S4", extra = "sa"},
    {service = "extrema", source = "S5"},
    {service = "extrema", source = "S6"},
  }

  --- Build a layout that fills the grid with service diagnostic panels.
  local function probeGridLayout()
    local lines = {"version: 1", "grid:", "  columns: 4", "  rows: 4", "components:"}
    for i, spec in ipairs(PROBE_SPECS) do
      local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
      lines[#lines + 1] = "  - id: p" .. i
      lines[#lines + 1] = "    type: service-probe"
      lines[#lines + 1] = "    col: " .. col
      lines[#lines + 1] = "    row: " .. row
      lines[#lines + 1] = "    colSpan: 1"
      lines[#lines + 1] = "    rowSpan: 1"
      lines[#lines + 1] = "    config:"
      lines[#lines + 1] = "      service: " .. spec.service
      lines[#lines + 1] = "      label: Probe " .. i
      if spec.source then
        lines[#lines + 1] = "      source: " .. spec.source
      end
      if spec.extra then
        lines[#lines + 1] = "      extra: " .. spec.extra
      end
      lines[#lines + 1] = "      index: " .. (spec.index or 0)
    end
    return table.concat(lines, "\n") .. "\n"
  end

  --- Build a layout that fills the grid with one component type.
  --- Every core component has to be measured at the largest layout the schema
  --- permits, not at the span the shipped dashboard happens to use.
  ---@param componentType string
  ---@param configFor fun(index: integer): string[] Config lines for one cell.
  local function typedGridLayout(componentType, configFor)
    local lines = {"version: 1", "grid:", "  columns: 4", "  rows: 4", "components:"}
    for i = 1, 16 do
      local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
      lines[#lines + 1] = "  - id: c" .. i
      lines[#lines + 1] = "    type: " .. componentType
      lines[#lines + 1] = "    col: " .. col
      lines[#lines + 1] = "    row: " .. row
      lines[#lines + 1] = "    colSpan: 1"
      lines[#lines + 1] = "    rowSpan: 1"
      lines[#lines + 1] = "    config:"
      for _, line in ipairs(configFor(i)) do
        lines[#lines + 1] = "      " .. line
      end
    end
    return table.concat(lines, "\n") .. "\n"
  end

  --- Every core component, at sixteen single cells, with the services each one
  --- must genuinely drive while it is measured.
  local CORE_EXERCISES = {
    {
      type = "metric",
      services = {"telemetry", "extrema"},
      config = function(index)
        return {
          "preset: " .. (index % 2 == 0 and "altitude" or "speed"),
          "source: S" .. index,
          "extrema: flight",
        }
      end,
    },
    {
      type = "flight-timer",
      services = {"model"},
      config = function(index)
        return {"timer: " .. ((index - 1) % 3), "warning: 60", "critical: 20"}
      end,
    },
    {
      type = "flight-mode",
      services = {"model"},
      config = function() return {"showIndex: true"} end,
    },
    {
      type = "tx-battery",
      services = {"model"},
      config = function()
        return {"packEmpty: 6.6", "packFull: 8.4", "warning: 7.0", "showPercent: true"}
      end,
    },
    {
      type = "variable-indicator",
      services = {"control"},
      config = function(index)
        local visuals = {"none", "bar", "bipolar-bar", "radial"}
        return {
          "binding: global",
          "index: " .. ((index - 1) % 4),
          "visual: " .. visuals[(index - 1) % 4 + 1],
        }
      end,
    },
    {
      type = "trim-panel",
      services = {"control"},
      config = function()
        -- Four indicators each, so the panel builds and drives the most
        -- objects it ever can.
        return {"indicators: all", "readout: percent", "scale: auto"}
      end,
    },
    {
      type = "model-identity",
      services = {"model"},
      config = function() return {"presentation: both", "showLabels: true"} end,
    },
    {
      -- Every panel walks a cells table on every refresh, so sixteen of them
      -- is the worst case for the one component that does per-entry work.
      type = "cell-battery",
      services = {"telemetry"},
      config = function(index)
        return {
          "source: Cels",
          "lowestSource: Cels-",
          "cells: 4",
          "warning: 3.5",
          "critical: " .. (index % 2 == 0 and "3.3" or "3.4"),
        }
      end,
    },
    {
      type = "link-status",
      services = {"telemetry", "extrema"},
      config = function(index)
        return {
          "rssiSource: " .. (index % 2 == 0 and "RSSI" or "1RSS"),
          "qualitySource: RQly",
          "reading: " .. (index % 2 == 0 and "auto" or "rssi"),
          "extrema: flight",
        }
      end,
    },
    {
      -- Four distinct GPS sources, so the navigation service really carries
      -- more than one subscription and pays for its trigonometry.
      type = "navigation",
      services = {"navigation", "telemetry"},
      config = function(index)
        local sources = {"GPS", "GPS2", "GPS3", "GPS4"}
        return {
          "source: " .. sources[(index - 1) % 4 + 1],
          "presentation: detailed",
        }
      end,
    },
  }

  local worst, worstName = 0, "none"
  local worstSteady, worstSteadyName = 0, "none"
  local worstReflow, worstReflowName = 0, "none"
  local worstOther, worstOtherName = 0, "none"

  local function record(name, cost)
    assert(cost < CEILING, string.format(
      "%s used %d instructions, over the %d ceiling (firmware limit %d)",
      name, cost, CEILING, BUDGET))
    if cost > worst then worst = cost; worstName = name end
    -- Steady state runs on every frame, so track it separately.
    if string.find(name, "steady", 1, true) and cost > worstSteady then
      worstSteady = cost
      worstSteadyName = name
    end
    -- Reflow is tracked apart from everything else because `REFLOW_BATCH`
    -- decides it and nothing else, so it is the one cost the dashboard can
    -- move by changing a constant. See the assertion after the exercises.
    if string.find(name, "reflow", 1, true) then
      if cost > worstReflow then worstReflow = cost; worstReflowName = name end
    elseif cost > worstOther then
      worstOther = cost
      worstOtherName = name
    end
  end

  --- Load one widget package end to end, measuring every callback.
  ---@param expectedServices? string[] Services this layout must actually run.
  local function exercise(label, path, expectedComponents, expectedServices)
    local zone = {x = 0, y = 0, w = 480, h = 272}
    local context
    record(label .. " create", measure(function()
      context = definition.create(zone, DEFAULT_OPTIONS, path)
    end))

    local steps = 0
    while context.stage do
      local stage = context.stage
      record(label .. " refresh/" .. stage, measure(definition.refresh, context))
      steps = steps + 1
      assert(steps < 400, label .. ": staged load never finished")
    end

    assertEqual(#context.components, expectedComponents, label .. ": component count")
    assertEqual(#context.errors, 0, label .. ": " .. table.concat(context.errors, "\n"))

    -- Steady state must be measured across real frames, advancing the clock,
    -- or rate limiting makes every sampled frame trivially cheap and the
    -- measurement meaningless. Sample enough frames to include the worst.
    local before = {}
    for index, entry in ipairs(context.components) do
      before[index] = entry.nextRefresh
    end

    local revisions = {}
    for id, instance in pairs(context.serviceRuntime.byId) do
      revisions[id] = instance.revision
    end

    for _ = 1, 60 do
      tick(1)
      record(label .. " refresh/steady", measure(definition.refresh, context))
    end

    -- Prove the sampled frames actually did work. A scheduling bug that
    -- silently stopped dispatching would otherwise make this test pass by
    -- measuring nothing at all.
    for index, entry in ipairs(context.components) do
      assert(entry.nextRefresh ~= before[index], label .. ": "
        .. entry.placement.id .. " was never refreshed during the sample")
    end

    -- The same applies to the services, whose updates are charged to these
    -- very callbacks: a layout that subscribed to nothing would measure the
    -- service layer at zero and hide whatever it really costs.
    for _, id in ipairs(expectedServices or {}) do
      local instance = context.serviceRuntime.byId[id]
      assert(instance, label .. ": the " .. id .. " service was never built")
      assert(instance.count > 0,
        label .. ": nothing subscribed to the " .. id .. " service")
      assert(instance.revision > revisions[id],
        label .. ": the " .. id .. " service never updated during the sample")
      assert(not instance.failed, label .. ": the " .. id .. " service failed")
    end

    record(label .. " background", measure(definition.background, context))
    record(label .. " event", measure(definition.event, context, 32))

    zone.w = 320
    zone.h = 240
    local passes = 0
    repeat
      record(label .. " refresh/reflow", measure(definition.refresh, context))
      passes = passes + 1
      assert(passes < 400, label .. ": reflow never finished")
    until not context.reflowIndex
    return context
  end

  exercise("shipped", sourcePath, 10,
    {"telemetry", "model", "control", "extrema", "navigation"})
  exercise("full grid", makeWidget("budget-16", fullGridLayout(16)), 16,
    {"telemetry"})

  -- Every core component, one type at a time, at sixteen single cells. A
  -- component measured only at the span the shipped dashboard uses would hide
  -- exactly the cost that matters: sixteen of it on one screen.
  for _, spec in ipairs(CORE_EXERCISES) do
    exercise(spec.type .. " x16",
      makeWidget("budget-" .. spec.type, typedGridLayout(spec.type, spec.config)),
      16, spec.services)
  end

  -- Sixteen diagnostic panels spanning all five services: the worst case the
  -- schema permits for the service layer itself.
  exercise("service probes", makeWidget("budget-probes", probeGridLayout()), 16,
    {"telemetry", "model", "control", "extrema", "navigation"})

  -- A layout whose components all demand every frame defeats staggering, so
  -- the per-frame cap is the only thing bounding cost. Prove it holds.
  local greedyPath = makeWidget("budget-greedy", fullGridLayout(16, "greedy"), {
    ["greedy.lua"] = [==[
local greedy = {
  id = "greedy",
  apiVersion = 1,
  supportedSpans = {"any"},
  refreshInterval = 0,
  -- Declared because the shared grid layout writes them, and an undeclared
  -- key is now reported rather than ignored.
  settings = {
    -- Every key `fullGridLayout` writes, because an undeclared key is now
    -- reported rather than ignored and this fixture stands in for a real
    -- component.
    {key = "label", type = "string", default = ""},
    {key = "source", type = "string", default = ""},
    {key = "unit", type = "string", default = ""},
    {key = "precision", type = "number", default = 0},
    {key = "visual", type = "string", default = "bar"},
    {key = "rangeMin", type = "number", default = 0},
    {key = "rangeMax", type = "number", default = 100},
    {key = "warning", type = "number"},
    {key = "critical", type = "number"},
    {key = "accent", type = "string", default = "cyan"},
  },
}
function greedy.create(parent, rect, settings, services)
  local panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))
  return {panel = panel, ticks = 0, label = services.primitives.label(
    panel.root, services.theme, {x = 4, y = 4, w = 40, text = "0",
    font = services.fonts.label})}
end
function greedy.refresh(context)
  context.ticks = context.ticks + 1
  context.label:set({text = tostring(context.ticks)})
end
return greedy
]==],
  })
  exercise("greedy", greedyPath, 16)

  -- A reflow must not be the most expensive thing the dashboard does.
  --
  -- This pins the conclusion of measuring `REFLOW_BATCH` rather than a number
  -- somebody liked. Reflow cost is linear in the batch, so it is the one
  -- callback whose cost is chosen rather than earned, and choosing it larger
  -- than the work it competes with buys nothing: the dashboard still cannot
  -- start faster than its slowest loader stage. At a batch of 4 the worst
  -- reflow was 8532 against a slowest stage of 7508 and this failed; at 3 it
  -- is 6448 and passes; below 3 it falls further for no gain, because the
  -- loader does not move.
  --
  -- It is deliberately a comparison and not a ceiling. A ceiling that the old
  -- value also satisfied would prove nothing, and a ceiling chosen today
  -- becomes a number nobody dares touch. If the loader is ever made cheaper,
  -- this starts failing, and that is correct: it would mean reflow had become
  -- the binding constraint again and the batch is due another measurement.
  -- Without this, the comparison below passes when nothing reflowed at all:
  -- a zero is less than everything. Found by breaking the recording and
  -- watching the comparison stay green.
  assert(worstReflow > 0,
    "no reflow callback was measured, so the comparison below proves nothing")
  assert(worstOther > 0, "no other callback was measured")

  assert(worstReflow < worstOther, string.format(
    "%s used %d, more than the dashboard's most expensive other callback"
    .. " (%s at %d), so REFLOW_BATCH is set higher than it buys anything",
    worstReflowName, worstReflow, worstOtherName, worstOther))

  print(string.format("  budget headroom: worst callback %s used %d of %d",
    worstName, worst, BUDGET))
  print(string.format("  steady state:    worst frame %s used %d of %d",
    worstSteadyName, worstSteady, BUDGET))
  print(string.format("  reflow:          worst %s used %d, against %s at %d",
    worstReflowName, worstReflow, worstOtherName, worstOther))
end

--- A component created large and then shrunk must hide what no longer fits,
--- and regain it when the panel grows again.
local function testMetricReconcilesOnResize()
  local widgetPath = makeWidget("reconcile", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: big
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Pack
      unit: V
      rangeMin: 18
      rangeMax: 25
      precision: 1
      visual: bar
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  local instance = entryById(context, "big").instance

  assert(instance.unit, "unit was never created")
  assert(instance.range, "range was never created")
  assertEqual(instance.unit.hidden, false)
  assertEqual(instance.range.hidden, false)

  --- Drain a batched reflow.
  local function settle()
    local passes = 0
    repeat
      definition.refresh(context)
      passes = passes + 1
      assert(passes < 100, "reflow never finished")
    until not context.reflowIndex
  end

  -- Shrink until the panel can no longer afford the optional rows.
  zone.w = 320
  zone.h = 140
  settle()

  local bounds = boundsOf(entryById(context, "big"))
  assertEqual(instance.unit.hidden, true, "shed unit was left visible")
  assertEqual(instance.range.hidden, true, "shed range was left visible")

  for _, object in ipairs({instance.label, instance.value, instance.badge}) do
    assert(object.properties.y < bounds.h, "visible content escaped the panel")
  end

  -- Growing again must restore what was shed rather than leave it hidden.
  zone.w = 480
  zone.h = 272
  settle()
  assertEqual(instance.unit.hidden, false, "unit was not restored")
  assertEqual(instance.range.hidden, false, "range was not restored")
end

--- A failed runtime module must never lead to an error inside a callback.
local function testRuntimeFailureIsContained()
  local widgetPath = makeWidget("brokenruntime")
  os.execute("rm -f '" .. widgetPath .. "lib/layout_store.lua'")

  local context = definition.create({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)

  assertEqual(context.runtimeFailed, true)
  assertEqual(context.stage, nil, "a broken runtime must not stage a load")
  assert(string.match(table.concat(context.errors, "\n"), "runtime module failed"))

  -- Changing an option previously restaged a load that indexed a nil module.
  definition.update(context, {DashID = "other", Theme = "modern"})
  assertEqual(context.reloadState, nil, "a broken runtime must not restage")

  for _ = 1, 5 do
    local ok, err = pcall(definition.refresh, context)
    assert(ok, "refresh raised after a runtime failure: " .. tostring(err))
  end
  local ok, err = pcall(definition.background, context)
  assert(ok, "background raised after a runtime failure: " .. tostring(err))
  assertEqual(#context.components, 0)
end

local function testModelFilenames()
  local previous = radio.modelFilename
  for _, name in ipairs({"model1.yml", "Kavan Sonic.yml", "FPV-7in.yml"}) do
    radio.modelFilename = name
    local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
      DEFAULT_OPTIONS, referencePath)
    assertEqual(context.layoutPath, referencePath .. "layouts/default.yaml",
      "unexpected layout for " .. name)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    assertEqual(#context.components, 5)
  end
  radio.modelFilename = previous
end

--- Collect a diagnostic panel's rendered rows as a label-to-text mapping.
local function probeRows(instance)
  local rows = {}
  for index = 1, #instance.keys do
    local key = instance.keys[index]
    if not key.hidden then
      local label = key.properties.text
      if label ~= "" then rows[label] = instance.values[index].properties.text end
    end
  end
  return rows
end

--- Milestone 5's deliverable: diagnostic views that prove normalized service
--- output independently of any production component's rendering. The shipped
--- diagnostics layouts load from their Dashboard ID alone, on any model, and
--- every service reports through the same panel contract.
local function testServiceDiagnostics()
  resetRadio()
  local zone = {x = 0, y = 0, w = 480, h = 272}

  --- Load one diagnostics page and let its services settle.
  local function page(dashboardId)
    local context = createLoaded(zone, {DashID = dashboardId, Theme = "modern"},
      sourcePath)
    -- A dashboard-scoped layout is found without a model-specific file.
    assertEqual(context.layoutPath,
      sourcePath .. "layouts/" .. dashboardId .. ".yaml")
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    for _ = 1, 80 do
      tick(20)
      definition.refresh(context)
    end
    return context
  end

  local first = page("services")
  assertEqual(#first.components, 2)

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
  -- The configured native distance sensor wins over the computed one.
  assertEqual(navigation.DIST, "812.0m")
  assertEqual(navigation.BRG, "9 deg")

  local second = page("services2")
  assertEqual(#second.components, 3)

  local modelRows = probeRows(entryById(second, "model").instance)
  assertEqual(modelRows.MODEL, "Test Model")
  assertEqual(modelRows.IMAGE, "plane.png")
  assertEqual(modelRows.MODE, "Sport")
  assertEqual(modelRows.TXV, "7.9V")
  assertEqual(modelRows.T0, "1:30")

  local control = probeRows(entryById(second, "control").instance)
  assertEqual(control["TRIM-AIL"], "30 23%")
  assertEqual(control.RATES, "4.5")

  local extrema = probeRows(entryById(second, "extrema").instance)
  assertEqual(extrema.ARM, "ARMED")
  assert(string.match(extrema.FLIGHT, "^#1 "), extrema.FLIGHT)

  assertEqual(#second.errors, 0, table.concat(second.errors, "\n"))
end

--- Every diagnostic panel must keep its rows inside its own container, at real
--- font heights, and must shed rows rather than draw past the bottom edge.
local function testDiagnosticsFitTheirPanels()
  resetRadio()
  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone,
    {DashID = "services2", Theme = "modern"}, sourcePath)

  --- Drain a batched reflow.
  local function settle()
    local passes = 0
    repeat
      definition.refresh(context)
      passes = passes + 1
      assert(passes < 100, "reflow never finished")
    until not context.reflowIndex
  end

  local function assertContained(what)
    for _, entry in ipairs(context.components) do
      local bounds = boundsOf(entry)
      local instance = entry.instance
      local lineHeight = themeModule.fontHeight(instance.fonts.label)
      for index = 1, #instance.keys do
        local key = instance.keys[index]
        if not key.hidden then
          assert(key.properties.y + lineHeight <= bounds.h, what .. ": "
            .. entry.placement.id .. " row " .. index .. " ran past its panel")
          local value = instance.values[index].properties
          assert(value.x + value.w <= bounds.w,
            what .. ": " .. entry.placement.id .. " row ran past the right edge")
          assert(key.properties.x + key.properties.w <= value.x,
            what .. ": " .. entry.placement.id .. " label overlaps its value")
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
  assert(entryById(context, "model").instance.visibleRows < tallest,
    "a shrunk panel did not shed rows")

  zone.w = 480
  zone.h = 272
  settle()
  assertContained("restored")
  assertEqual(entryById(context, "model").instance.visibleRows, tallest,
    "rows were not restored when the panel grew again")

  for _ = 1, 4 do
    tick(50)
    definition.refresh(context)
  end
  local rows = probeRows(entryById(context, "model").instance)
  assertEqual(rows.MODEL, "Test Model", "a restored row kept stale text")
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

--- A missing service module must leave the dashboard running and visibly say
--- so, rather than raising inside a widget callback.
local function testMissingServiceModule()
  local widgetPath = makeWidget("noservice", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
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
      label: Pack
      source: RxBt
]])
  os.execute("rm -f '" .. widgetPath .. "lib/navigation_service.lua'")

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)

  assertEqual(#context.components, 2, "a missing service disabled a component")
  assert(string.match(table.concat(context.errors, "\n"), "navigation:"),
    table.concat(context.errors, "\n"))

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

--- A layout carrying one of each core component, at a span each one supports.
--- Every component reads real radio state, so the assertions below are about
--- what the radio actually says rather than about mocked component internals.
local CORE_LAYOUT = [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: countdown
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 0
      warning: 120
      critical: 30
  - id: countup
    type: flight-timer
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 1
  - id: mode
    type: flight-mode
    col: 0
    row: 1
    colSpan: 1
    rowSpan: 1
    config:
      showIndex: true
  - id: battery
    type: tx-battery
    col: 1
    row: 1
    colSpan: 1
    rowSpan: 1
    config:
      packEmpty: 6.6
      packFull: 8.4
      warning: 7.0
      critical: 6.8
      showPercent: true
  - id: gv
    type: variable-indicator
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      binding: global
      index: 1
      visual: bar
  - id: identity
    type: model-identity
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      presentation: both
      showLabels: true
  - id: trims
    type: trim-panel
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 1
    config:
      indicators: all
      orientation: horizontal
      readout: raw
  - id: dial
    type: variable-indicator
    col: 2
    row: 3
    colSpan: 1
    rowSpan: 1
    config:
      binding: source
      source: Curr
      label: Current
      visual: radial
      rangeMin: 0
      rangeMax: 120
  - id: swing
    type: variable-indicator
    col: 3
    row: 3
    colSpan: 1
    rowSpan: 1
    config:
      binding: global
      index: 0
      visual: bipolar-bar
]]

--- Advance a context far enough for every service and component to settle.
local function settle(context, count)
  for _ = 1, (count or 60) do
    tick(20)
    definition.refresh(context)
  end
end

--- Every declared key belongs to a row that is drawn, and every drawn row has
--- one.
---
--- This is the property, stated once. A component declares what it paints and
--- `primitives.changed` compares exactly that, so a key present for a row
--- that is shed is work with no reader, and a row that is drawn with no key
--- is a row nothing can repaint. Checked at both sizes, because the shed
--- direction and the revealed direction fail differently.
local function assertDeclaresWhatItDraws(cells, link, alt, nav, when)
  local function check(component, what, shown, key)
    local declared = component.rendered[key] ~= nil
    assertEqual(declared, shown, when .. ": " .. what
      .. (shown and " is drawn but declares no " or " declares a ")
      .. key .. (shown and " key" or " key it does not draw"))
  end

  check(cells, "the cell count", cells.showDetail, "count")
  check(cells, "the pack row", cells.showDetail, "pack")
  check(link, "the link detail row", link.showDetail, "detail")
  check(link, "the link row", link.showDetail, "link")
  check(alt, "the metric's range row", alt.showRange, "range")
  check(alt, "the metric's secondary", alt.showSecondary, "secondary")
  check(nav, "the bearing row", nav.showDetail, "detail")
  check(nav, "the origin row", nav.showDetail, "origin")
  check(nav, "the coordinate row", nav.showCoordinates, "coordinates")
end

--- A row that comes back shows what is true now, not what was true when it
--- was shed.
---
--- Four components shed supporting rows on a small panel, and `apply` does
--- not write a row it is not drawing. So a value that moves while a row is
--- hidden leaves that row holding an old wording, and the row is only correct
--- again if something forces a repaint when it reappears.
---
--- Three of the four forced it by discarding the last drawn record in
--- `update`. That works and it is remembering rather than construction: the
--- fourth, `trim-panel`, gets it for free by not declaring a row it has shed,
--- so the key reappearing is itself the change `primitives.changed` sees.
--- All four now do that, and the discards are gone.
---
--- The care this needs is in what moves when. The value is moved **while the
--- row is hidden** and nothing at all is moved at the reveal, because a
--- change in the same window as the reveal would repaint under any
--- implementation and prove nothing. Under a component that declares a row it
--- does not draw, the moved value is recorded while hidden and never
--- painted, so the reveal finds the record already matching and repaints
--- nothing. That is the stale row this is looking for.
local function testShedRowsComeBackCurrent()
  resetRadio()
  local widgetPath = makeWidget("reveal", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: cells
    type: cell-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels
      showCount: true
      showPack: true
  - id: link
    type: link-status
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      rssiSource: RSSI
      qualitySource: RQly
      reading: quality
  - id: alt
    type: metric
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      label: Alt
      source: Alt
      unit: m
      precision: 0
      extrema: source
      extremaSource: Alt+
      secondarySource: VSpd
      secondaryLabel: VS
  - id: nav
    type: navigation
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: GPS
      presentation: detailed
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

  radio.values[130] = {4.11, 4.09, 4.12}
  radio.values[140] = -70
  radio.values[141] = 88
  radio.values[106] = 120
  radio.values[120] = 2.5
  radio.values[109] = {
    lat = 47.3769, lon = 8.5417,
    ["pilot-lat"] = 47.3700, ["pilot-lon"] = 8.5400,
  }
  settle(context, 60)

  local cells = entryById(context, "cells").instance
  local link = entryById(context, "link").instance
  local alt = entryById(context, "alt").instance
  local nav = entryById(context, "nav").instance

  -- The precondition: every row under test is on screen at this span. Without
  -- this the shed below is not a shed and the reveal is not a reveal.
  assertEqual(cells.showDetail, true, "the cell panel shed its rows too early")
  assertEqual(link.showDetail, true, "the link panel shed its rows too early")
  assertEqual(alt.showRange, true, "the metric shed its range row too early")
  assertEqual(alt.showSecondary, true, "the metric shed its secondary too early")
  assertEqual(nav.showDetail, true, "the nav panel shed its rows too early")
  assertEqual(nav.showCoordinates, true, "the nav panel shed its coordinates")

  local function reflow(width, height)
    zone.w, zone.h = width, height
    local passes = 0
    repeat
      definition.refresh(context)
      passes = passes + 1
      assert(passes < 100, "reflow never finished")
    until not context.reflowIndex
    settle(context, 60)
  end

  reflow(240, 140)

  assertEqual(cells.showDetail, false, "the cell panel kept rows it cannot fit")
  assertEqual(link.showDetail, false, "the link panel kept rows it cannot fit")
  assertEqual(alt.showRange, false, "the metric kept a range row it cannot fit")
  assertEqual(alt.showSecondary, false, "the metric kept a row it cannot fit")
  assertEqual(nav.showDetail, false, "the nav panel kept rows it cannot fit")
  assertEqual(nav.showCoordinates, false, "the nav panel kept its coordinates")

  assertDeclaresWhatItDraws(cells, link, alt, nav, "shed")

  -- Everything moves here, while the rows are hidden and nothing is drawing
  -- them, and nothing moves after this point.
  radio.values[130] = {4.11, 4.09, 4.12, 4.10, 4.08}
  radio.values[140] = -95
  radio.values[141] = 42
  radio.values[120] = -3.5
  radio.values[109] = {
    lat = 47.4000, lon = 8.6000,
    ["pilot-lat"] = 47.3700, ["pilot-lon"] = 8.5400,
  }
  settle(context, 60)

  reflow(480, 272)

  assertDeclaresWhatItDraws(cells, link, alt, nav, "revealed")
  assertEqual(cells.showDetail, true, "the cell rows never came back")
  assertEqual(link.showDetail, true, "the link rows never came back")
  assertEqual(alt.showSecondary, true, "the metric's secondary never came back")
  assertEqual(nav.showDetail, true, "the nav rows never came back")
  assertEqual(nav.showCoordinates, true, "the coordinate row never came back")

  -- Five cells now, not three. A stale row would still say 3S.
  assertEqual(cells.countLabel.properties.text, "5S",
    "a revealed cell count still reports the pack it was shed with")
  -- With quality leading, the supporting row names RSSI, which fell from
  -- -70 to -95 while the row was not on screen.
  assert(string.find(link.linkLabel.properties.text, "-95", 1, true),
    "a revealed link row still reports the RSSI it was shed with: "
    .. tostring(link.linkLabel.properties.text))
  -- The vertical speed reversed while the row was not on screen.
  assert(string.find(alt.secondary.properties.text, "-3", 1, true),
    "a revealed secondary row still reports the value it was shed with: "
    .. tostring(alt.secondary.properties.text))
  -- The model moved, so both the bearing row and the coordinates changed.
  assert(string.find(nav.coordinatesLabel.properties.text, "47.4", 1, true),
    "a revealed coordinate row still reports the position it was shed with: "
    .. tostring(nav.coordinatesLabel.properties.text))
  assertEqual(nav.detailLabel.properties.text, nav.detail,
    "a revealed bearing row disagrees with what the panel last declared")
  assertEqual(cells.countLabel.properties.text, cells.countText,
    "a revealed cell count disagrees with what the panel last declared")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A trim panel sheds text it has no room for, and stops producing it.
---
--- Four indicators each carry a caption, a bar and a readout, and a cell too
--- narrow for text keeps only the bar. What the panel used to do was hide the
--- text and then go on positioning it on every reflow, formatting it four
--- times a frame, and writing it into labels nobody could see. That is the
--- same invisible work the header pass found, and it is why this panel's
--- reflow was the most expensive callback in the dashboard.
---
--- So this checks both halves at the two spans that decide them: the text
--- exists where there is room for it, and is not merely hidden but not made
--- where there is not. The reveal is driven by a real reflow, because a
--- caption written once when the row appears is wrong if the row can appear
--- without anything writing it.
local function testTrimPanelShedsText()
  resetRadio()
  local layout = [==[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: trims
    type: trim-panel
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      indicators: all
      orientation: horizontal
      readout: raw
  - id: tight
    type: metric
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Alt
      source: Alt
      unit: m
      precision: 0
]==]
  local widget = makeWidget("trim-shed", layout)
  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widget)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context)

  local trims = entryById(context, "trims").instance
  assertEqual(#trims.indicators, 4)

  -- The shared reconcile is what keeps every component off its hidden rows.
  -- It is proved on a metric rather than on the trim panel, which guards the
  -- call itself and so never reaches reconcile with a row staying shed. The
  -- metric is built at a span that has a unit and then narrowed until it
  -- does not, which is the state reconcile is being asked about.
  local tight = entryById(context, "tight").instance
  assert(tight.unit, "the metric never built a unit to shed")
  assertEqual(tight.unit.hidden, false, "a 2 x 2 metric shed its unit")

  -- Two rows tall and half the width: room for all three parts.
  assertEqual(trims.showCaption, true, "a 2 x 2 trim panel shed its captions")
  assertEqual(trims.showValue, true, "a 2 x 2 trim panel shed its readouts")
  assertEqual(trims.indicators[1].caption.properties.text, "AIL")
  assertEqual(trims.indicators[1].caption.hidden, false)
  assertEqual(trims.indicators[1].valueText, "+30",
    "240 raw is 30 trim units")

  -- Shrinking the host zone narrows every cell past what text needs, and
  -- shortens the metric beside it past the row its unit needs.
  zone.w = 240
  zone.h = 130
  local passes = 0
  repeat
    definition.refresh(context)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not context.reflowIndex
  settle(context)

  assertEqual(trims.showCaption, false,
    "a narrowed trim panel kept captions it has no room for")
  assertEqual(trims.showValue, false,
    "a narrowed trim panel kept readouts it has no room for")
  assert(trims.indicators[1].caption.hidden, "a shed caption stayed on screen")
  assert(trims.indicators[1].value.hidden, "a shed readout stayed on screen")

  -- Hidden is not the point. The declaration is what the panel draws, so a
  -- readout it has shed must not be in it: nothing formats a string for a
  -- label that is not on screen.
  assertEqual(trims.rendered.text1, nil,
    "a shed readout was still being formatted every frame")
  assertEqual(trims.rendered.fraction1 ~= nil, true,
    "the bar stopped being declared, which is the part that is still drawn")
  assertEqual(trims.indicators[1].valueText, "",
    "a shed readout left its last wording behind as if still current")

  -- Invisible work leaves no trace on screen, so nothing else in this suite
  -- can see it. The harness counts writes into LVGL for exactly this: a row
  -- the panel has shed must cost nothing to keep shed, however many reflows
  -- pass over it.
  local captionWrites = trims.indicators[1].caption.writes
  local valueWrites = trims.indicators[1].value.writes
  local captionCalls = trims.indicators[1].caption.visibilityCalls
  local valueCalls = trims.indicators[1].value.visibilityCalls
  local unitWrites = tight.unit.writes
  zone.w = 236
  passes = 0
  repeat
    definition.refresh(context)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not context.reflowIndex
  settle(context)

  assertEqual(trims.indicators[1].caption.writes, captionWrites,
    "a reflow repositioned a caption the panel had already shed")
  assertEqual(trims.indicators[1].value.writes, valueWrites,
    "a reflow repositioned a readout the panel had already shed")
  assertEqual(trims.indicators[1].caption.visibilityCalls, captionCalls,
    "a reflow hid a caption that was already hidden")
  assertEqual(trims.indicators[1].value.visibilityCalls, valueCalls,
    "a reflow hid a readout that was already hidden")
  assert(tight.unit.hidden, "a short metric found room for its unit")
  assertEqual(tight.unit.writes, unitWrites,
    "reconcile repositioned a row its component had hidden")
  zone.w = 240
  passes = 0
  repeat
    definition.refresh(context)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not context.reflowIndex

  -- Widening again must bring the text back with its wording, not with
  -- whatever it held when it was shed.
  zone.w = 480
  zone.h = 272
  passes = 0
  repeat
    definition.refresh(context)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not context.reflowIndex
  settle(context)

  assertEqual(trims.showCaption, true, "captions never came back")
  assertEqual(trims.indicators[1].caption.properties.text, "AIL",
    "a revealed caption came back blank")
  assertEqual(trims.indicators[1].caption.hidden, false)
  assertEqual(trims.indicators[1].value.properties.text, "+30",
    "a revealed readout came back with what it held when it was shed")

  -- A reflow that changes nothing about visibility still has to move the
  -- rows, or a panel that merely narrows leaves its text where it was.
  local captionBefore = trims.indicators[2].caption.properties.x
  zone.w = 420
  passes = 0
  repeat
    definition.refresh(context)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not context.reflowIndex
  settle(context)

  assertEqual(trims.showCaption, true,
    "a mild narrowing shed captions that still fit")
  assert(trims.indicators[2].caption.properties.x < captionBefore,
    "a narrowed panel left its captions at their old positions")
  assertEqual(trims.indicators[2].caption.hidden, false,
    "a caption that never changed visibility was hidden by the reflow")
  assertEqual(trims.indicators[1].caption.properties.text, "AIL",
    "a reflow that kept the captions rewrote one of them blank")

  -- A panel built small has never had a caption to write, so revealing one
  -- has to write it rather than reveal whatever creation happened to leave.
  -- This is the case the first reveal above cannot prove: that panel was
  -- built wide, so its captions already said the right thing.
  resetRadio()
  local narrowZone = {x = 0, y = 0, w = 240, h = 240}
  local narrow = createLoaded(narrowZone, DEFAULT_OPTIONS,
    makeWidget("trim-shed-narrow", layout))
  assertEqual(#narrow.errors, 0, table.concat(narrow.errors, "\n"))
  settle(narrow)

  local born = entryById(narrow, "trims").instance
  assertEqual(born.showCaption, false, "a 240 px panel found room for captions")
  assertEqual(born.indicators[1].caption.properties.text, "",
    "a panel built without room wrote captions nobody could read")

  narrowZone.w = 480
  narrowZone.h = 272
  passes = 0
  repeat
    definition.refresh(narrow)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not narrow.reflowIndex
  settle(narrow)

  assertEqual(born.showCaption, true, "a widened panel never found room")
  assertEqual(born.indicators[1].caption.properties.text, "AIL",
    "a caption revealed for the first time came back blank")
  assertEqual(born.indicators[1].caption.hidden, false)
end


--- Each core component must render what the radio reports, in the state the
--- radio's own values imply.
local function testCoreComponents()
  resetRadio()
  local widgetPath = makeWidget("core", CORE_LAYOUT)
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  assertEqual(#context.components, 9)
  settle(context)

  -- A countdown shows what EdgeTX's timer says, takes its name from the
  -- model, and states the total it is counting down from.
  local countdown = entryById(context, "countdown").instance
  assertEqual(countdown.text, "1:30")
  assertEqual(countdown.labelValue, "FLIGHT", "the timer's own name was ignored")
  assertEqual(countdown.detail, "OF 5:00")
  assertEqual(countdown.stateName, "warning", "90s left is inside the warning")
  assertEqual(countdown.badge.properties.text, "WARN")

  -- A count-up timer has no total and therefore no progress to draw.
  local countup = entryById(context, "countup").instance
  assertEqual(countup.text, "1:04")
  assertEqual(countup.detail, "COUNTING UP")
  assertEqual(countup.stateName, "normal")

  -- An expired countdown must never read like a healthy timer.
  radio.timers[0].value = -15
  settle(context, 12)
  assertEqual(countdown.text, "-0:15", "an expired countdown lost its sign")
  assertEqual(countdown.detail, "ELAPSED PAST ZERO")
  assertEqual(countdown.stateName, "critical")
  radio.timers[0].value = 90

  -- EdgeTX lets a countdown be shown as time used rather than time left, and
  -- says so with showElapsed. The fixture omitted the field entirely, so this
  -- branch was permanently false and no component ever reached it: the same
  -- 300 second timer with 90 seconds left must read 3:30 used, not 1:30 left,
  -- and it is no longer a countdown to warn about.
  radio.timers[0].showElapsed = true
  settle(context, 12)
  assertEqual(countdown.text, "3:30", "showElapsed did not flip the timer")
  radio.timers[0].showElapsed = false
  settle(context, 12)
  assertEqual(countdown.text, "1:30", "the timer did not flip back")

  local mode = entryById(context, "mode").instance
  assertEqual(mode.text, "Sport")
  assertEqual(mode.detail, "MODE 1")

  -- The transmitter pack: voltage is authoritative, the percentage is an
  -- estimate and says so.
  local battery = entryById(context, "battery").instance
  assertEqual(battery.text, "7.9V")
  assertEqual(battery.detail, "72% EST")
  assertEqual(battery.stateName, "normal")
  radio.values[320] = 6.7
  settle(context, 12)
  assertEqual(battery.stateName, "critical")
  assertEqual(battery.badge.properties.text, "CRIT")
  radio.values[320] = 7.9

  -- A global variable takes its name, bounds, precision, and unit from
  -- EdgeTX, and AeroGrid never writes one.
  local gv = entryById(context, "gv").instance
  assertEqual(gv.text, "10%")
  assertEqual(gv.labelValue, "GV2")
  assertEqual(gv.detail, "GV2 FM1", "the flight mode the value was read for")
  -- -100 to 100 crosses zero, so the bar carries a tick at its centre.
  assert(gv.bar.markerFraction, "a bar over a signed range lost its zero tick")
  assertEqual(gv.bar.marker.hidden, false)

  -- A global variable holds a separate value per flight mode, so switching
  -- mode has to re-read it. This previously asserted that the value did NOT
  -- move, reasoning about EdgeTX's inheritance, and it could not have failed
  -- either way: the mock ignored the flight mode argument entirely and
  -- answered the same number for every mode. It was asserting the fixture's
  -- limitation and calling it firmware behaviour.
  radio.flightMode, radio.flightModeName = 2, "Land"
  settle(context, 12)
  assertEqual(gv.text, "60%", "the value stored for the new flight mode was not read")
  assertEqual(gv.detail, "GV2 FM2", "the flight mode row went stale")

  -- A mode with no value of its own does inherit, and that is a different
  -- observation from never having looked.
  radio.flightMode, radio.flightModeName = 3, "Cruise"
  settle(context, 12)
  assertEqual(gv.text, "10%", "an inherited value was not inherited")
  assertEqual(gv.detail, "GV2 FM3", "the flight mode row went stale")

  radio.flightMode, radio.flightModeName = 1, "Sport"
  settle(context, 12)
  assertEqual(gv.text, "10%")

  -- The same component bound to a telemetry source instead.
  local dial = entryById(context, "dial").instance
  assertEqual(dial.text, "10.0A")
  assert(dial.radial, "the radial presentation was not built")
  -- 10 of 0..120 is a small part of a 270 degree sweep.
  assertEqual(dial.radial.arc.properties.endAngle, 135 + 23)

  -- A dial that is redrawn has to stay where it was put. The firmware offsets
  -- a round object by its radius on every update, so a gauge whose value moves
  -- crept up and to the left until it left its panel entirely -- once per
  -- reading, which on a live telemetry feed is a few seconds.
  local arc = dial.radial.arc
  local expectedX = dial.radial.centreX - dial.radial.radius
  local expectedY = dial.radial.centreY - dial.radial.radius
  assertEqual(arc.round.drawn.x, expectedX, "an arc was not built at its centre")
  assertEqual(arc.round.drawn.y, expectedY, "an arc was not built at its centre")
  for reading = 1, 8 do
    radio.values[103] = 10 + reading * 5
    settle(context, 12)
  end
  -- The precondition of a drift test is that the dial actually moved, and it
  -- is pinned rather than merely required to differ: 50 of 0 to 120 is 113
  -- degrees of the 270 degree sweep, drawn from 135. A sweep that changed
  -- for the wrong reason would satisfy "it is no longer 158".
  assertEqual(arc.properties.endAngle, 248,
    "the dial never moved, so a drift test proves nothing")
  assertEqual(arc.round.drawn.x, expectedX, "the dial drifted horizontally")
  assertEqual(arc.round.drawn.y, expectedY, "the dial drifted vertically")

  -- Trims are read through EdgeTX's own sources, in stored trim units.
  local trims = entryById(context, "trims").instance
  assertEqual(#trims.indicators, 4)
  assertEqual(trims.indicators[1].valueText, "+30", "240 raw is 30 trim units")
  assertEqual(trims.indicators[2].valueText, "-15")
  assertEqual(trims.indicators[3].valueText, "+8")
  assertEqual(trims.indicators[4].valueText, "0")
  -- This panel is one row tall, which is not enough for a caption above a
  -- bar, so it sheds them. Asserting the caption's text here would assert
  -- something nobody can see; that it is hidden is the fact on screen. The
  -- text is checked at a span that keeps it, in testTrimPanelShedsText.
  assertEqual(trims.showCaption, false,
    "a one-row trim panel found room for captions")
  assert(trims.indicators[1].caption.hidden,
    "a shed caption was left on screen")
  -- A positive trim fills rightward from the centre of its own bar.
  local fill = trims.indicators[1].bar.fill.properties
  assert(fill.x >= trims.indicators[1].bar.x + math.floor(trims.indicators[1].bar.w / 2),
    "a positive trim filled the wrong side of centre")

  local identity = entryById(context, "identity").instance
  assertEqual(identity.text, "Test Model")
  assertEqual(identity.labelsText, "fpv")
  assert(identity.image, "a model bitmap that exists was not shown")
  assertEqual(identity.image.properties.file, "/IMAGES/plane.png")

  -- A bipolar bar measures each side against its own bound.
  local swing = entryById(context, "swing").instance
  assertEqual(swing.text, "4.5")
  assert(swing.bipolar, "the bipolar presentation was not built")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- Every component must degrade visibly rather than raise when the radio
--- cannot answer: a firmware without the API, a source that does not exist, a
--- timer index out of range, and a model bitmap that is not on the card.
local function testComponentsDegrade()
  resetRadio()
  local widgetPath = makeWidget("degrade", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: timer
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 7
  - id: gv
    type: variable-indicator
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      binding: source
      source: NoSuchSensor
  - id: trims
    type: trim-panel
    col: 0
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      indicators: pair
      trim1: not-a-trim
      trim2: also-not-a-trim
  - id: identity
    type: model-identity
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 2
    config:
      presentation: both
  - id: mode
    type: flight-mode
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 1
  - id: battery
    type: tx-battery
    col: 0
    row: 3
    colSpan: 2
    rowSpan: 1
]])

  -- A firmware without a flight mode API, and a model with no bitmap.
  local realFlightMode = getFlightMode
  local realGetInfo = model.getInfo
  getFlightMode = nil
  model.getInfo = function()
    return {filename = radio.modelFilename, name = "No Picture", bitmap = "gone.png"}
  end

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  local ok, err = pcall(settle, context)
  getFlightMode = realFlightMode
  model.getInfo = realGetInfo
  assert(ok, "a component raised inside a callback: " .. tostring(err))

  local function assertUnavailable(id)
    local instance = entryById(context, id).instance
    assertEqual(instance.stateName, "unavailable", id .. " hid a missing source")
    assertEqual(instance.badge.properties.text, "N/A",
      id .. " reported its state by colour alone")
  end

  assertUnavailable("timer")
  assertUnavailable("gv")
  assertUnavailable("trims")
  assertUnavailable("mode")

  assertEqual(entryById(context, "timer").instance.text, "--:--")
  assertEqual(entryById(context, "timer").instance.detail, "NO TIMER")
  assertEqual(entryById(context, "trims").instance.indicators[1].valueText, "--")

  -- A bitmap the card does not have falls back to the model name rather than
  -- leaving an empty hole where the picture would be.
  local identity = entryById(context, "identity").instance
  assert(identity.area.showImage,
    "the degradation test must run on a panel that could show an image")
  assertEqual(identity.text, "No Picture")
  assertEqual(identity.image, nil, "a missing bitmap was still opened")
  assertEqual(identity.value.hidden, false, "the name fallback was hidden")

  -- The transmitter voltage does not depend on any of that, so it stays live.
  assertEqual(entryById(context, "battery").instance.stateName, "normal")
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- Every core component must survive a zone change and stay inside its own
--- container afterwards, at a size that sheds most of its optional content.
local function testCoreComponentsReflow()
  resetRadio()
  local widgetPath = makeWidget("core-reflow", CORE_LAYOUT)
  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  settle(context, 20)

  local function drain()
    local passes = 0
    repeat
      definition.refresh(context)
      passes = passes + 1
      assert(passes < 200, "reflow never finished")
    until not context.reflowIndex
  end

  --- Assert every visible object sits inside the container it belongs to.
  local function assertContained(what)
    for _, entry in ipairs(context.components) do
      local bounds = boundsOf(entry)
      local panel = panelOf(entry)
      assertEqual(panel.w, bounds.w, what .. ": " .. entry.placement.id
        .. " did not follow its container width")
      assertEqual(panel.h, bounds.h, what .. ": " .. entry.placement.id
        .. " did not follow its container height")

      for _, object in ipairs(lvglMock.objects) do
        if object.parent == entry.instance.panel.root and not object.hidden then
          local properties = object.properties
          local right = (properties.x or 0) + (properties.w or 0)
          local bottom = (properties.y or 0) + (properties.h or 0)
          assert(right <= bounds.w + 1, what .. ": " .. entry.placement.id
            .. " drew past its right edge, " .. right .. " in " .. bounds.w)
          assert(bottom <= bounds.h + 1, what .. ": " .. entry.placement.id
            .. " drew past its bottom edge, " .. bottom .. " in " .. bounds.h)
        end
      end
    end
  end

  assertContained("full size")

  zone.w = 320
  zone.h = 140
  drain()
  settle(context, 10)
  assertContained("shrunk")

  zone.w = 480
  zone.h = 272
  drain()
  settle(context, 10)
  assertContained("restored")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A layout carrying the three telemetry-specialized components at spans that
--- exercise every part of them: a cells table, both link source styles, and
--- navigation both computing a distance and preferring a native one.
local TELEMETRY_LAYOUT = [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: cell-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels
      lowestSource: Cels-
      label: Pack
      cells: 4
      warning: 3.5
      critical: 3.3
  - id: link
    type: link-status
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      rssiSource: RSSI
      qualitySource: RQly
      reading: auto
      warning: 50
      critical: 30
      extrema: source
      extremaSource: RQly-
  - id: elrs
    type: link-status
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      rssiSource: 1RSS
      qualitySource: RQly
      reading: rssi
      barMin: -110
      barMax: -30
      warning: -90
      critical: -100
  - id: nav
    type: navigation
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: GPS
      label: Nav
      presentation: detailed
  - id: native
    type: navigation
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: GPS2
      distanceSource: Dist
      label: Native
      presentation: compass
]]

--- Each telemetry component must render what the radio reports, in the state
--- the radio's own values imply.
local function testTelemetryComponents()
  resetRadio()
  local widgetPath = makeWidget("telemetry", TELEMETRY_LAYOUT)
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  assertEqual(#context.components, 5)
  settle(context)

  -- The pack is judged by its worst cell, and the summed pack voltage is
  -- supporting detail rather than the headline.
  local pack = entryById(context, "pack").instance
  assertEqual(pack.text, "4.09V")
  assertEqual(pack.countText, "4S")
  assertEqual(pack.packText, "16.4V PACK")
  assertEqual(pack.stateName, "normal")
  assertEqual(pack.summary.count, 4)
  assertEqual(pack.summary.shape, "cells")

  -- One sagging cell must take the panel critical even though the pack sum
  -- barely moves: 15.6 V across four cells still looks healthy.
  radio.values[130] = {4.11, 3.25, 4.09, 4.12}
  radio.values[131] = 3.25
  settle(context, 12)
  assertEqual(pack.text, "3.25V")
  assertEqual(pack.stateName, "critical")
  assertEqual(pack.badge.properties.text, "CRIT")

  -- A cell that stops reporting is called out against the configured count.
  radio.values[130] = {4.11, 4.13, 4.09}
  radio.values[131] = 4.09
  settle(context, 12)
  assertEqual(pack.countText, "3S OF 4", "a lost cell was not reported")
  assertEqual(pack.stateName, "normal")

  -- Link quality leads under `auto`, because a percentage means the same
  -- thing on every protocol where RSSI does not.
  local link = entryById(context, "link").instance
  assertEqual(link.primaryName, "quality")
  assertEqual(link.text, "96%")
  assertEqual(link.stateName, "normal")
  -- Both link panels are 2 x 1, which is 65 px tall, and shed their supporting
  -- rows to keep the reading large. What those rows say is covered at a span
  -- that shows them, below; asserting their text here described strings the
  -- panel does not draw.
  assertEqual(link.showDetail, false)

  radio.values[141] = 44
  settle(context, 12)
  assertEqual(link.stateName, "warning")
  assertEqual(link.badge.properties.text, "WARN")
  radio.values[141] = 22
  settle(context, 12)
  assertEqual(link.stateName, "critical")

  -- A dBm source keeps its own unit and its own thresholds; nothing converts
  -- one protocol's numbers into another's.
  local elrs = entryById(context, "elrs").instance
  assertEqual(elrs.primaryName, "rssi")
  assertEqual(elrs.text, "-72dBm")
  assertEqual(elrs.stateName, "normal")
  radio.values[143] = -95
  settle(context, 12)
  assertEqual(elrs.stateName, "warning", "a dBm threshold must count downward")
  radio.values[143] = -72

  -- Navigation computes distance and bearing from the pilot position EdgeTX
  -- recorded, and says in words what the direction means.
  local nav = entryById(context, "nav").instance
  assertEqual(nav.text, "778m")
  -- Fitted to the row rather than overrunning it. Whichever wording is chosen
  -- has to fit, which is the property that matters; pinning the string alone
  -- would pass on a helper that always returned the shortest one.
  assertEqual(nav.detail, "BRG 009")
  assertEqual(nav.origin, "NORTH UP")
  assert(themeModule.textWidth(nav.fonts.label, nav.detail) <= nav.detailWidth,
    "the bearing row overran its box")
  assert(themeModule.textWidth(nav.fonts.label, nav.origin) <= nav.originWidth,
    "the origin caption overran its box")
  assertEqual(nav.coordinates, "47.37690 8.54170")
  assertEqual(nav.stateName, "normal")
  assert(nav.compass, "the detailed presentation must carry the dial")
  -- The pointer is a real direction, not a ring resting at north.
  -- Visibility is the arc's sweep, not its opacity: passing opacity stopped
  -- the whole ring rendering on a radio.
  assert(nav.compass.ring.properties.startAngle
    ~= nav.compass.ring.properties.endAngle,
    "a known bearing must sweep a visible pointer")

  -- A configured native distance sensor wins over the computed one, because
  -- the receiver may compute it from data this dashboard never sees.
  local native = entryById(context, "native").instance
  assertEqual(native.text, "812.0m")
  assertEqual(native.feed.distanceSource, "source")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- Telemetry degradation, which is what milestone 7 is actually about: a link
--- that drops and returns, a fix that never arrives, a home position EdgeTX
--- never recorded, a cells source that answers with the wrong shape, and a
--- protocol that populates no RSSI sensor at all.
local function testTelemetryDegrades()
  resetRadio()
  local widgetPath = makeWidget("telemetry-degrade", TELEMETRY_LAYOUT)
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  settle(context)

  local pack = entryById(context, "pack").instance
  local link = entryById(context, "link").instance
  local nav = entryById(context, "nav").instance

  assertEqual(pack.stateName, "normal")
  assertEqual(nav.stateName, "normal")

  -- Disconnect. Every reading keeps its last value, marked, and the link
  -- panel says so in the one place a pilot will look.
  radio.rssi = 0
  pump(context, 40)

  assertEqual(pack.stateName, "stale", "a dropped link hid the last cells")
  assertEqual(pack.text, "4.09V", "a stale poll overwrote the reading")
  assertEqual(pack.badge.properties.text, "STALE")

  assertEqual(link.stateName, "critical", "a dead link is the measurement")
  -- The badge carries the state. Which of the several ways a link can fail is
  -- carried by the supporting row, at a span that has one; this panel is
  -- 2 x 1 and sheds it.
  assertEqual(link.badge.properties.text, "CRIT")

  assertEqual(nav.stateName, "stale")
  assertEqual(nav.text, "778m", "the last known position was discarded")
  assertEqual(nav.origin, "LAST KNOWN")

  -- Reconnect. Nothing may be left marked once readings arrive again.
  radio.rssi = 80
  pump(context, 40)
  assertEqual(pack.stateName, "normal")
  assertEqual(link.stateName, "normal")
  assertEqual(link.badge.properties.text, "")
  assertEqual(nav.stateName, "normal")
  assertEqual(nav.origin, "NORTH UP")

  -- A fix EdgeTX has not acquired reports zero for both axes, which is a real
  -- place off the coast of Africa and must never be shown as one.
  radio.values[109].lat = 0
  radio.values[109].lon = 0
  pump(context, 40)
  assertEqual(nav.stateName, "unavailable")
  assertEqual(nav.badge.properties.text, "N/A")
  assertEqual(nav.origin, "NO FIX")
  assertEqual(nav.text, "--", "a missing fix was shown as a distance")
  assertEqual(nav.coordinates, "-- , --")
  -- The dial must not point anywhere when there is nowhere to point.
  assertEqual(nav.compass.ring.properties.startAngle,
    nav.compass.ring.properties.endAngle,
    "an unknown bearing must draw a zero length pointer")

  -- A fix without a home position: the position is perfectly good, but a
  -- distance and a bearing would be measured from nowhere.
  radio.values[109].lat = 47.3769
  radio.values[109].lon = 8.5417
  radio.values[109]["pilot-lat"] = 0
  radio.values[109]["pilot-lon"] = 0
  pump(context, 40)
  assertEqual(nav.stateName, "normal", "a missing home is not a broken fix")
  -- A missing home position leaves the fix good, so the panel is not badged
  -- at all and only the caption changes.
  assertEqual(nav.badge.properties.text, "")
  assert(string.match(nav.origin, "^NO HOME"), nav.origin)
  assertEqual(nav.text, "--")
  assertEqual(nav.detail, "BRG --", "a bearing was invented without a home")
  assertEqual(nav.origin, "NO HOME POS")
  assertEqual(nav.coordinates, "47.37690 8.54170",
    "the position itself is still known")

  -- A table whose entries cannot be cell voltages. The explicit lowest-cell
  -- source keeps the reading alive, and the count row says the table is gone.
  -- A sensor fault and an undetected pack want different fixes, so they read
  -- differently; the row shortens to suit its width rather than clipping.
  radio.values[130] = {0, -1, 99}
  pump(context, 40)
  assertEqual(pack.summary.shape, "invalid")
  assertEqual(pack.text, "4.09V")
  assertEqual(pack.countText, "BAD CELLS")
  assert(themeModule.textWidth(pack.fonts.label, pack.countText)
    <= pack.detailWidth, "the cell-count row overran its box")
  assertEqual(pack.packText, "", "a pack sum was computed from nonsense")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A cells source that is not a cells source.
---
--- "Cels-" carries the cells unit but returns a plain number, which milestone
--- 5 found and normalized, so a layout naming it here resolves to a numeric
--- reading rather than a table. That is a configuration mistake, not a failed
--- link, and it reads differently: the detail row says which fix is needed.
local function testCellSourceShapes()
  resetRadio()
  local widgetPath = makeWidget("cell-shapes", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: extreme
    type: cell-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels-
      label: Wrong
  - id: voltage
    type: cell-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: RxBt
      label: Pack voltage
  - id: absent
    type: cell-battery
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: NoSuchSensor
      label: Missing
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  pump(context, 40)

  for _, id in ipairs({"extreme", "voltage"}) do
    local instance = entryById(context, id).instance
    assertEqual(instance.summary.shape, "number",
      id .. " read a plain number as a cells table")
    assertEqual(instance.stateName, "unavailable")
    -- The wording shortens to the row it is given, so the assertion is that
    -- the panel says this at all rather than that it says it at full length.
    assert(string.match(instance.countText, "^NOT"),
      id .. " reported a shape problem as a missing source")
    assertEqual(instance.text, "--", "a number was shown as a cell voltage")
  end

  -- A sensor the radio has never heard of is a different problem again, and
  -- keeps the ordinary wording.
  local absent = entryById(context, "absent").instance
  assertEqual(absent.summary.shape, "none")
  assertEqual(absent.stateName, "unavailable")
  assertEqual(absent.badge.properties.text, "N/A")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A refresh short-circuit is a cache, and a cache that misses a change shows
--- the pilot an old number with a straight face. Each of these is a change
--- that leaves the primary reading exactly where it was.
local function testRefreshSeesEverythingItDraws()
  resetRadio()
  local widgetPath = makeWidget("stale-rows", TELEMETRY_LAYOUT)
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  settle(context)

  -- Three of four cells sagging moves the pack sum by 0.6 V without moving
  -- the lowest cell, which is the reading the panel leads with.
  local pack = entryById(context, "pack").instance
  radio.values[130] = {3.80, 4.10, 4.10, 4.10}
  radio.values[131] = 3.80
  settle(context, 20)
  assertEqual(pack.text, "3.80V")
  assertEqual(pack.packText, "16.1V PACK")

  radio.values[130] = {3.80, 3.90, 3.90, 3.90}
  settle(context, 20)
  assertEqual(pack.text, "3.80V", "the lowest cell should not have moved")
  assertEqual(pack.packText, "15.5V PACK", "the pack row froze on an old sum")

  -- Link quality sits pinned at 100 for most of a flight while RSSI falls
  -- away, so the supporting RSSI row is exactly the one that must keep up.
  local link = entryById(context, "link").instance
  radio.values[141] = 100
  radio.values[140] = 70
  settle(context, 20)
  assertEqual(link.text, "100%")

  radio.values[140] = 41
  settle(context, 20)
  assertEqual(link.text, "100%", "link quality should not have moved")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A GPS sensor only becomes known once telemetry has delivered it, and until
--- a fix arrives nothing else about the reading changes. A panel that started
--- before the sensor appeared must stop saying the source is missing.
local function testNavigationSeesItsSensorAppear()
  resetRadio()
  local widgetPath = makeWidget("late-gps", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: nav
    type: navigation
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: LateGps
      presentation: detailed
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  settle(context, 20)

  local nav = entryById(context, "nav").instance
  assertEqual(nav.stateName, "unavailable")
  assertEqual(nav.badge.properties.text, "N/A")
  assertEqual(nav.origin, "NO GPS SOURCE")

  -- The sensor arrives, but without a position yet: this is the cold start,
  -- and it is a different message from a layout naming a sensor that is not
  -- there. Nothing else in the snapshot moves, so only `known` says so.
  radio.fields.LateGps = {id = 150, name = "LateGps", desc = "Late GPS", unit = 40}
  radio.values[150] = {lat = 0, lon = 0, ["pilot-lat"] = 0, ["pilot-lon"] = 0}
  radioMock.indexFields()
  settle(context, 60)

  assertEqual(nav.stateName, "unavailable")
  assertEqual(nav.badge.properties.text, "N/A",
    "a sensor that appeared was still reported as a missing source")
  assertEqual(nav.origin, "NO FIX")

  -- And then a real position.
  radio.values[150] = {
    lat = 47.3769, lon = 8.5417,
    ["pilot-lat"] = 47.3700, ["pilot-lon"] = 8.5400,
  }
  settle(context, 60)
  assertEqual(nav.stateName, "normal")
  assertEqual(nav.text, "778m")

  radio.fields.LateGps = nil
  radio.values[150] = nil
  radioMock.indexFields()
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A protocol that populates no RSSI sensor reads zero from getRSSI() on a
--- perfectly live link. Reporting that as a dead link pinned every reading
--- stale in milestone 5, and it is exactly as wrong here: the panel must say
--- the sensor is absent, keep the quality reading, and stay out of alarm.
local function testProtocolWithoutRssi()
  resetRadio()
  local widgetPath = makeWidget("no-rssi", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
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
      warning: 50
      critical: 30
  - id: rssionly
    type: link-status
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      rssiSource: RSSI
      reading: rssi
]])

  -- A live link whose protocol has no RSSI sensor: values keep arriving while
  -- the indicator reads zero, and no RSSI sensor exists to be resolved.
  local realRssi = radio.fields.RSSI
  radio.rssi = 0
  radio.rssiAbsent = true
  radio.fields.RSSI = nil
  radioMock.indexFields()

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  settle(context, 60)

  local link = entryById(context, "link").instance
  assertEqual(link.primaryName, "quality",
    "auto must fall back to the source the protocol actually has")
  assertEqual(link.text, "96%", "a live reading was discarded as a dead link")
  assertEqual(link.stateName, "normal")
  assertEqual(link.badge.properties.text, "")

  -- A panel configured for RSSI alone on such a protocol has nothing to show,
  -- and must say the sensor is missing rather than report zero or claim the
  -- link is down.
  local rssiOnly = entryById(context, "rssionly").instance
  assertEqual(rssiOnly.stateName, "unavailable")
  assertEqual(rssiOnly.badge.properties.text, "N/A")
  assertEqual(rssiOnly.text, "N/A", "an absent sensor was reported as zero")

  radio.fields.RSSI = realRssi
  resetRadio()
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

--- Every telemetry component must survive a zone change and stay inside its
--- own container, at a size that sheds most of its optional content.
local function testTelemetryComponentsReflow()
  resetRadio()
  local widgetPath = makeWidget("telemetry-reflow", TELEMETRY_LAYOUT)
  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  settle(context, 20)

  local function drain()
    local passes = 0
    repeat
      definition.refresh(context)
      passes = passes + 1
      assert(passes < 200, "reflow never finished")
    until not context.reflowIndex
  end

  --- Assert every visible object sits inside the container it belongs to.
  --- An arc is positioned by its centre, so its bounds are derived rather
  --- than read straight from x and y.
  local function assertContained(what)
    for _, entry in ipairs(context.components) do
      local bounds = boundsOf(entry)
      local instance = entry.instance

      for _, object in ipairs(lvglMock.objects) do
        if object.parent == instance.panel.root and not object.hidden then
          local properties = object.properties
          local right, bottom
          if object.kind == "arc" then
            -- Where the firmware would actually paint it, not the centre the
            -- caller asked for: the two part company as soon as an arc is
            -- updated without restating its centre.
            local drawn = object.round.drawn
            local diameter = object.round.radius() * 2
            assert(drawn.x >= -1 and drawn.y >= -1, what .. ": " .. entry.placement.id
              .. " drew an arc off its top or left edge, at "
              .. drawn.x .. "," .. drawn.y)
            right = drawn.x + diameter
            bottom = drawn.y + diameter
          else
            right = (properties.x or 0) + (properties.w or 0)
            bottom = (properties.y or 0) + (properties.h or 0)
          end
          assert(right <= bounds.w + 1, what .. ": " .. entry.placement.id
            .. " drew past its right edge, " .. right .. " in " .. bounds.w)
          assert(bottom <= bounds.h + 1, what .. ": " .. entry.placement.id
            .. " drew past its bottom edge, " .. bottom .. " in " .. bounds.h)
        end
      end
    end
  end

  assertContained("full size")
  local nav = entryById(context, "nav").instance
  assertEqual(nav.compass.ring.hidden, false, "the dial was never shown")
  assertEqual(nav.coordinatesLabel.hidden, false, "coordinates were never shown")
  local firstRadius = nav.compass.ring.properties.radius

  zone.w = 320
  zone.h = 140
  drain()
  settle(context, 10)
  assertContained("shrunk")
  -- Supporting rows are shed before the dominant reading is touched, and the
  -- dial shrinks with the panel rather than overflowing it.
  assertEqual(nav.coordinatesLabel.hidden, true, "shed coordinates stayed visible")
  assert(nav.compass.ring.properties.radius < firstRadius,
    "the dial did not shrink with its panel")

  zone.w = 480
  zone.h = 272
  drain()
  settle(context, 10)
  assertContained("restored")
  assertEqual(nav.compass.ring.hidden, false, "the dial was not restored")
  assertEqual(nav.compass.ring.properties.radius, firstRadius,
    "the dial was not restored to its full size")
  assertEqual(nav.coordinatesLabel.hidden, false, "coordinates were not restored")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A metric large enough to carry its supporting row, so the altitude
--- preset's extrema source and secondary reading are proven somewhere the
--- shipped dashboard's span cannot take away.
local function testMetricPresetDetail()
  resetRadio()
  local widgetPath = makeWidget("preset-detail", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: altitude
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      preset: altitude
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  settle(context)

  local altitude = entryById(context, "altitude").instance
  assertEqual(altitude.extremeFeed.name, "Alt+", "the preset lost its extrema")
  assertEqual(altitude.range.properties.text, "MAX 180")
  assertEqual(altitude.secondary.properties.text, "VS 2.5m/s")
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end


testEdgeTxTheme()
testCustomTheme()
testRadialReflow()
testCreateFailureIsCleaned()
testFailureIsolation()
testErrorsClearTheMenuButton()
testNothingReadableUnderTheMenuButton()
testNoticesAreNotErrors()
testMultipleScreens()
testEventConsumption()
testContractRejections()
testCorruptLayout()
testModelFilenames()
testMetricReconcilesOnResize()
testRuntimeFailureIsContained()
testServiceDiagnostics()
testDiagnosticsFitTheirPanels()
testMissingServiceModule()
testCoreComponents()
testTrimPanelShedsText()
testShedRowsComeBackCurrent()
testComponentsDegrade()
testCoreComponentsReflow()
testMetricPresetDetail()
testTelemetryComponents()
testTelemetryDegrades()
testCellSourceShapes()
testRefreshSeesEverythingItDraws()
testNavigationSeesItsSensorAppear()
testProtocolWithoutRssi()
testTelemetryComponentsReflow()
testInstructionBudget()

print("AeroGrid widget integration test passed")
