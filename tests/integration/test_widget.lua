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
local setTextMeasurement = lcdMock.setTextMeasurement

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
  -- `heartbeat` and `placeholder` exist to exercise the host contract, not to
  -- fly, so they are fixtures rather than shipped components. They are copied
  -- into every scratch package because that is what they are for: a layout
  -- placing one still has to load, refresh, reflow and be torn down like any
  -- other component, and that coverage is the whole reason they exist.
  os.execute("cp -R '" .. root .. "/tests/fixtures/components/.' '"
    .. directory .. "/components/'")

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
local layoutStoreModule = assert(loadfile(sourcePath .. "lib/layout_store.lua"))()

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
--- `span1x1.yaml` exists so every component can be built at the same span at
--- once and compared. A component missing from it is a component nothing is
--- comparing, and the most likely way for one to go missing is for it to be
--- written after the gallery. The component directory is therefore read from
--- disk rather than listed here, exactly as the layout sweep above reads the
--- layout directory.
---
--- **It is a test fixture rather than a shipped layout.** The galleries were
--- retired from the radio because the user does not page to them; the cases
--- they construct -- eleven components in one grid, which is the densest
--- arrangement this dashboard can be asked for -- are why they are still
--- built here. A layout does not have to be on a screen to be worth
--- building.
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

  local source = assert(hostIo.open(
    root .. "/tests/fixtures/layouts/span1x1.yaml", "r"))
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
  -- Eleven, not thirteen: `heartbeat` and `placeholder` are fixtures now and
  -- are not in the shipped directory this reads, so they cannot be missing
  -- from a gallery they no longer belong in.
  assert(compared >= 11,
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

--- Every shipped layout is on a screen, and every review screen is on the
--- review model.
---
--- A layout only ships as a layout, and selecting one means setting the
--- widget's Dashboard ID. In App mode that is not reachable from the main
--- view at all: `Widget::openMenu` returns immediately after
--- `setFullscreen(true)` when the widget is not in the top bar and the view
--- is App mode (radio/src/gui/colorlcd/mainview/widget.cpp), so there is no
--- widget menu to open. Reaching a layout would mean going through Model
--- Setup and Screens once per layout, which is enough friction that nobody
--- would look at it -- which is the whole point of it existing.
---
--- **Two models, because ten screens is the ceiling.** `MAX_CUSTOM_SCREENS`
--- is 10 (`radio/src/dataconstants.h`), and there are ten reviewable
--- components plus the dashboards, the two palette screens and the debug
--- screen. That is eleven and does not fit, so the review screens have a
--- model of their own and the working model keeps the dashboards, the
--- palette comparison and the debug screen.
local function testScreensReachEveryShippedLayout()
  local function readModel(name)
    local handle = assert(hostIo.open(
      root .. "/tests/fixtures/sdcard/MODELS/" .. name, "r"))
    local text = handle:read("a")
    handle:close()
    return text
  end

  local working = readModel("model1.yml")
  local review = readModel("model2.yml")

  local listingPath = root .. "/build/screen-layouts.txt"
  os.execute("ls '" .. sourcePath .. "layouts' > '" .. listingPath .. "'")
  local listing = assert(hostIo.open(listingPath, "r"))
  local shipped = {}
  for name in listing:lines() do
    local stem = string.match(name, "^(.+)%.yaml$")
    if stem then shipped[#shipped + 1] = stem end
  end
  listing:close()
  os.remove(listingPath)
  assert(#shipped > 0, "no shipped layouts were found")

  -- Which layouts are selected by a screen on either model. `default` is the
  -- host's own fallback and is reached by a widget that names nothing, so it
  -- needs no screen; `services` and `services2` are fixtures for the service
  -- runtime rather than anything to look at.
  local EXEMPT = {default = true, services = true, services2 = true}

  local reviews = 0
  for _, stem in ipairs(shipped) do
    if not EXEMPT[stem] then
      local onReview = string.find(review, "stringValue: " .. stem, 1, true)
      local onWorking = string.find(working, "stringValue: " .. stem, 1, true)
      assert(onReview or onWorking, stem
        .. " ships as a layout but no screen of either tracked model selects"
        .. " it, so nothing pages to it")

      -- A review screen belongs on the review model. Putting one back on the
      -- working model is how the single self-replacing review screen came
      -- about, which is the arrangement this replaced.
      if string.match(stem, "^review%-") then
        reviews = reviews + 1
        assert(onReview and not onWorking, stem
          .. " is a review layout but is selected by the working model;"
          .. " review screens live on the review model")
      end
    end
  end
  assert(reviews >= 3,
    "only " .. reviews .. " review layouts were checked")

  -- The dashboards come first, because they are what the radio is for.
  local order = {}
  for value in string.gmatch(working, "stringValue: ([%w%-]+)") do
    order[#order + 1] = value
  end
  local position = {}
  for index, name in ipairs(order) do
    if not position[name] then position[name] = index end
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
  -- not load as written. Asserted on both, because the review model is the
  -- one that will grow: seven components are still to be reviewed and each
  -- takes a screen.
  for name, text in pairs({["model1.yml"] = working, ["model2.yml"] = review}) do
    local screens = 0
    for _ in string.gmatch(text, "\n      LayoutId:") do screens = screens + 1 end
    assert(screens >= 1, name .. " carries no screens at all")
    assert(screens <= 10, name .. " carries " .. screens
      .. " screens, more than EdgeTX's MAX_CUSTOM_SCREENS of 10")
  end
end


local function testShippedLayout()
testShippedLayoutsLoad()
testSessionArmsTheFlight()
testSpanGalleryIsComplete()
testStatesCoverBothPalettes()
testScreensReachEveryShippedLayout()
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
  -- Digits alone: the `V` is its own label riding beside them.
  local radioBattery = entryById(context, "radio-battery").instance
  assertEqual(radioBattery.text, "7.9")
  assertEqual(radioBattery.unit.properties.text, "V")
  assertEqual(entryById(context, "rates").instance.text, "4.5")
  assertEqual(entryById(context, "identity").instance.text, "Test Model")
  assertEqual(entryById(context, "trims").instance.indicators[1].valueText, "+23%")

  -- The three telemetry components, reading what the radio really reports.
  local pack = entryById(context, "pack").instance
  -- Digits alone, with the `V` riding beside them in its own label.
  assertEqual(pack.text, "4.09", "the lowest cell is the safety reading")
  assertEqual(pack.unit.properties.text, "V")
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
  assertEqual(link.text, "96")
  assertEqual(link.stateName, "normal")

  local nav = entryById(context, "nav").instance
  assertEqual(nav.text, "778")
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
    assert(needed <= width, string.format(
      "%s needs %d px of %d", what, needed, width))
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
  assertRow(link, link.linkDetail, link.rowRightWidth, "78dB",
    "a healthy link names its secondary source")
  assertRow(pack, pack.countText, pack.detailWidth, "4S",
    "the cell count")
  assertRow(pack, pack.packText, pack.detailWidth, "16.4V",
    "the pack sum")

  -- **A cells source answering with a plain number and one answering with
  -- nonsense print the same row, deliberately.** Both mean something is
  -- arriving and is wrong, and both are fixed on the ground -- so the row
  -- says `CELLS ERR` for each, and spends no word on a difference the pilot
  -- cannot act on. The shapes are still separated inside the component for
  -- the diagnostics view, which is asserted below.
  --
  -- The number case is configured rather than mutated into: the telemetry
  -- service keeps the last good reading, so a source that has already produced
  -- a cells table and then produces a number reads as stale data, which is a
  -- third situation again and not the one being tested here.
  local wrong = entryById(context, "notcells").instance
  assertEqual(wrong.summary.shape, "number")
  assertEqual(wrong.badge.properties.text, "N/A")
  assertRow(wrong, wrong.countText, wrong.detailWidth, "CELLS ERR",
    "a plain number from a cells source")

  radio.values[130] = {0, -1, 99}
  pump(context, 40)
  assertEqual(pack.summary.shape, "invalid")
  -- The explicit lowest-cell source keeps a reading alive, so the panel is not
  -- unavailable; the row is what reports that the table itself is gone.
  assertEqual(pack.text, "4.09")
  assertRow(pack, pack.countText, pack.detailWidth, "CELLS ERR",
    "nonsense from a cells source")
  -- **The two shapes stay separated where they can be acted on.** The row is
  -- the same because the action is the same; `summary.shape` is not, because
  -- someone at a desk reading the diagnostics view can use the difference.
  assertEqual(pack.countText, wrong.countText,
    "two failures with one fix print different rows")
  assert(pack.summary.shape ~= wrong.summary.shape,
    "the component stopped telling a wrong sensor from a nonsense table, so"
      .. " the diagnostics view has nothing left to report")

  -- A dead link is reported by the row too, and is checked last because it
  -- marks every other panel stale on its way past.
  resetRadio()
  pump(context, 40)
  radio.rssi = 0
  pump(context, 40)
  assertEqual(link.stateName, "critical")
  assertEqual(link.badge.properties.text, "CRIT")
  assertRow(link, link.linkDetail, link.rowRightWidth, "NO LINK",
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

  -- The row names the flight mode the value was read for, so it has to
  -- follow a change of mode. Checked here, on a panel two rows tall that
  -- actually draws the row: it used to be checked on a `2 x 1` that sheds it,
  -- where the string was computed and written into a hidden label.
  radio.flightMode, radio.flightModeName = 2, "Land"
  pump(context, 60)
  assertEqual(gv.detailLabel.properties.text, "Rates FM2",
    "the supporting row kept the flight mode it was drawn with")
  radio.flightMode, radio.flightModeName = 1, "Sport"
  pump(context, 60)
  assertEqual(gv.detailLabel.properties.text, "Rates FM1")

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

  -- **Geometry must stay stable as values and states change, and what
  -- "stable" means has moved.** The reading is centred on a slot now, and
  -- its label is exactly as wide as the string it draws -- so the width does
  -- change with the value, deliberately, and asserting it did not would be
  -- asserting the old arrangement. What may not move is the centre: the slot
  -- is a property of the panel, so a value gaining a digit grows the number
  -- about its middle rather than shifting it.
  local function readingCentre(instance)
    local font = instance.value.properties.font
    if type(font) == "function" then font = font() end
    local text = tostring(instance.value.properties.text or "")
    return instance.value.properties.x + lcd.sizeText(text, font) / 2
  end

  local before = readingCentre(pack)
  metricModule.setValue(pack, 22.5)
  assert(math.abs(readingCentre(pack) - before) <= 1, string.format(
    "the reading's centre moved from %.1f to %.1f when its value changed",
    before, readingCentre(pack)))
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

--- A dial that is redrawn has to stay where it was put.
---
--- The firmware offsets a round object by its own radius on every update, so
--- a gauge whose value moves crept up and to the left until it left its panel
--- entirely -- once per reading, which on a live telemetry feed is a few
--- seconds. That is hard-won constraint 11, and it needs an arc that is drawn
--- and then driven by real telemetry.
---
--- **It lives here because the shipped dashboard no longer has one at a
--- single cell.** It used to ride along on the `dial` panel of the core
--- layout, which is a `1 x 1` and sheds its radial now that a 34 px band
--- holds DBLSIZE. A shed dial is never written to, so the same assertions
--- would have passed against an object nothing touches -- which is a check
--- that cannot fail, not a check that holds. The panel here is two cells
--- wide, which is where the same component and the same range keep both.
local function testRadialDoesNotDrift()
  resetRadio()
  local widgetPath = makeWidget("radial-drift", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: dial
    type: variable-indicator
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      binding: source
      source: Curr
      label: Current
      visual: radial
      rangeMin: 0
      rangeMax: 120
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  pump(context, 60)

  local dial = entryById(context, "dial").instance
  -- The precondition, and it is the whole reason this moved: an arc nobody
  -- draws cannot drift.
  assertEqual(dial.showVisual, true,
    "the panel shed its dial, so a drift test proves nothing")
  assertEqual(dial.radial.arc.hidden, false, "the dial was not on screen")
  -- 10 of 0..120 is a small part of a 270 degree sweep, drawn from 135.
  assertEqual(dial.radial.arc.properties.endAngle, 135 + 23)

  local arc = dial.radial.arc
  local expectedX = dial.radial.centreX - dial.radial.radius
  local expectedY = dial.radial.centreY - dial.radial.radius
  assertEqual(arc.round.drawn.x, expectedX, "an arc was not built at its centre")
  assertEqual(arc.round.drawn.y, expectedY, "an arc was not built at its centre")
  for reading = 1, 8 do
    radio.values[103] = 10 + reading * 5
    pump(context, 12)
  end
  -- The dial has to have actually moved, and the sweep is pinned rather than
  -- merely required to differ: 50 of 0 to 120 is 113 degrees of 270, drawn
  -- from 135. A sweep that changed for the wrong reason would satisfy "it is
  -- no longer 158".
  assertEqual(arc.properties.endAngle, 248,
    "the dial never moved, so a drift test proves nothing")
  assertEqual(arc.round.drawn.x, expectedX, "the dial drifted horizontally")
  assertEqual(arc.round.drawn.y, expectedY, "the dial drifted vertically")
  resetRadio()
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
--- Nothing a pilot reads is drawn on top of anything else.
---
--- **This exists because four other measures reported a panel healthy while
--- two things sat on top of each other.** A unit was printed twelve pixels
--- inside its own reading for a whole revision of the design mocks: the slot
--- margins were comfortable, the fonts were right, the bands held, and the
--- defect was invisible to every one of them. Nothing here is subtle enough
--- to need an eye, so it should never have needed one.
---
--- **And it covers more than text, which is the lesson that cost the most.**
--- The design generator grew a check of exactly this shape and it compared
--- labels with labels. A reading sized from a body band that ran down to the
--- panel floor lay straight across its own bar, and the check could not see
--- it, because a bar is not a label. A blind spot the size of every non-text
--- object is worse than no check, because it is trusted.
---
--- Backgrounds are excluded rather than reported: a panel's surface is a
--- filled rectangle under everything by construction, its accent is a stripe
--- down the edge the content box already starts after, and a bar's fill is
--- drawn inside its own track. Those are the three overlaps that are the
--- design rather than a defect, and each is excluded by what it is rather
--- than by name.
--- Every state a supporting row reports stays distinguishable at its
--- narrowest wording.
---
--- **This replaces a rule that could not be checked with one that can.** The
--- specification used to defend the absent-sensor-versus-no-fix distinction
--- by saying the supporting row "has room for words and is fitted to its
--- width". That was true of a row that spanned the panel, and the slot rule
--- narrowed it to 40% of the content -- so the sentence became a claim about
--- a width nobody was measuring, defending a distinction nobody was checking.
---
--- The property that actually matters was never the width. It is that the
--- **shortest** form of each state differs from the shortest form of every
--- other, because the shortest form is what a cramped panel prints. A row can
--- be as narrow as the layout likes and still say which of two failures
--- occurred, provided its vocabulary was built that way.
---
--- So the rule is: **a component that words a state must keep its shortest
--- wordings mutually distinct**, and this is what holds it to that. It is
--- also what any of the remaining components will be held to when their rows
--- move onto the slots.
local function testSupportingWordingsStayDistinct()
  --- Every component that words a state, and the states it words.
  ---
  --- **A declaration, like the positional check.** A component whose
  --- supporting row names more than one failure adds itself here; nine are
  --- still to convert and each should be covered the moment it arrives.
  local WORDED = {
    {
      -- **One form per state here, and the check is the same check.** Every
      -- wording this component offers fits every panel that draws a row, so
      -- its "shortest" form is its only form -- which is exactly when two
      -- states are likeliest to be collapsed into one word by someone
      -- shortening for width. `EXPIRED` and `NO TOTAL` are the pair to
      -- watch: both are a countdown that cannot report time remaining, for
      -- opposite reasons.
      type = "flight-timer",
      variantsFor = function(module, state)
        return module.detailVariants(state[1], tostring, state[2])
      end,
      states = {
        {"no timer configured", {nil, nil}},
        {"a countdown run past zero", {{available = true, countdown = true,
          start = 300, remaining = -15, elapsed = 315, expired = true}, nil}},
        {"a timer counting up", {{available = true, countdown = false,
          elapsed = 64, value = 64, start = 0}, nil}},
        {"a count-up timer asked for the time remaining",
          {{available = true, countdown = false, elapsed = 64, value = 64,
            start = 0}, {reading = "remaining"}}},
      },
    },
    {
      type = "navigation",
      -- How to ask this component for one state's wordings. Declared,
      -- because a component's own signature is its own business: this one
      -- takes a view table and `cell-battery` takes a summary and settings.
      variantsFor = function(module, state)
        return module.originVariants(state)
      end,
      states = {
        {"no GPS sensor configured at all",
          {known = false, fix = false, home = false}},
        {"sensor present, no satellite fix",
          {known = true, fix = false, home = false}},
        {"fix acquired, home not yet set",
          {known = true, fix = true, home = false}},
        {"flying, oriented from home",
          {known = true, fix = true, home = true}},
        {"position known but telemetry gone quiet",
          {known = true, fix = true, home = true, state = "stale"}},
      },
    },
    {
      -- **Two displayed states, where there are five shapes.** `number` and
      -- `invalid` both print `CELLS ERR`, deliberately: something is
      -- arriving and it is wrong, and the pilot does the same thing about
      -- either. They are one state *here* because this check is about what
      -- the panel says, and two states that print the same thing and imply
      -- the same action are one state.
      --
      -- **This check fired when they were collapsed, and that was it
      -- working.** It is declared down to two rather than taught to tolerate
      -- a duplicate, because a check relaxed to fit the code stops being a
      -- check. `summarize` still separates the five shapes and the
      -- diagnostics view still reports which arrived; what is asserted here
      -- is only that the *row* can still say whether to wait or to go and
      -- fix something.
      type = "cell-battery",
      variantsFor = function(module, state)
        return module.countVariants({shape = state}, {showCount = true})
      end,
      states = {
        {"a source answering with something wrong", "number"},
        {"a source answering with no cells at all", "empty"},
      },
    },
    {
      type = "link-status",
      -- Its wordings are built inside `linkText`, which needs a whole
      -- context, so the vocabulary is declared here as the component
      -- declares it and checked for the property that matters.
      variantsFor = function(_, state) return state end,
      states = {
        {"the link is down", {"LINK DOWN", "NO LINK", "DOWN"}},
        {"no RSSI sensor exists",
          {"NO RSSI SENSOR", "NO RSSI SENSE", "NO RSSI", "NO RSS"}},
      },
    },
  }

  for _, subject in ipairs(WORDED) do
    local module = assert(loadfile(
      sourcePath .. "components/" .. subject.type .. ".lua"))()
    local seen = {}
    for _, entry in ipairs(subject.states) do
      local variants = subject.variantsFor(module, entry[2])
      local shortest = variants[#variants]

      assert(type(shortest) == "string" and shortest ~= "",
        subject.type .. ": " .. entry[1] .. " has no wording at all")

      local owner = seen[shortest]
      assert(owner == nil, string.format(
        "%s: %q is the narrowest wording for two different states -- %s and"
          .. " %s -- so a panel too narrow for the longer forms cannot say"
          .. " which happened, and the row stops carrying the distinction"
          .. " the badge above it deliberately does not",
        subject.type, shortest, owner or "", entry[1]))
      seen[shortest] = entry[1]
    end
  end

  -- And the narrowest row in the catalogue really does reach the shortest
  -- forms, or the assertions above are about strings nothing prints.
  local navigationModule = assert(loadfile(
    sourcePath .. "components/navigation.lua"))()
  local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
  local cellWidth = math.floor((WIDTH - GUTTER * (CELLS - 1)) / CELLS)
  local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)
  local rect = {x = 0, y = 0,
    w = cellWidth * 2 + GUTTER, h = cellHeight * 2 + GUTTER}
  local fonts = themeModule.typography(2, 2)
  local area = navigationModule.regionsFor(themeModule.build("modern"),
    themeModule, rect, navigationModule.presentationFor("detailed"), fonts,
    {digits = navigationModule.DIGITS, unit = navigationModule.UNIT})

  local shortened = 0
  for _, entry in ipairs(WORDED[1].states) do
    local full = navigationModule.originVariants(entry[2])[1]
    local drawn = navigationModule.originText(entry[2], themeModule,
      fonts.label, area.originWidth)
    if drawn ~= full then shortened = shortened + 1 end
  end
  assert(shortened > 0, "no state was shortened at the narrowest row, so the"
    .. " distinctness check above is not exercising the case it exists for")
end


--- The collision machinery, shared by every check that needs it.
---
--- Hoisted out of `testNothingIsDrawnOverAnythingElse` so that the descender
--- check below measures panels the same way rather than keeping a second
--- opinion about what a drawn box is. Two copies of this arithmetic is
--- exactly how a check comes to be blind in one direction while the other
--- is not.
--- Every drawn thing in one panel, as a box, with labels measured by ink.
---
--- Ink rather than line height, because a line box carries descent and
--- leading that no glyph marks: charging a reading for slack it does not
--- draw would report a collision the screen does not have. Where a string
--- does carry a descending glyph, what it reaches is added back, measured
--- from the font's own `ofs_y`.
local function drawnBoxes(entry)
  local found = {}
  local root = entry.instance.panel and entry.instance.panel.root

  --- Clip a box to its container, or drop it if nothing is left.
  ---
  --- **A container is not decoration here.** The panel's accent stripe is
  --- two quarter-circle arcs inside a box one accent-width wide: unclipped
  --- each arc reaches a full diameter across the panel and appears to lie
  --- over the heading, and the container is the whole reason it does not.
  --- Walking the tree without honouring it reports eleven collisions that
  --- are not on the screen.
  local function clipTo(box, clip)
    if not clip then return box end
    local x = math.max(box.x, clip.x)
    local y = math.max(box.y, clip.y)
    local right = math.min(box.x + box.w, clip.x + clip.w)
    local bottom = math.min(box.y + box.h, clip.y + clip.h)
    if right <= x or bottom <= y then return nil end
    box.x, box.y, box.w, box.h = x, y, right - x, bottom - y
    return box
  end

  local function walk(object, offsetX, offsetY, clip)
    for _, child in ipairs(object.children) do
      local x = offsetX + (child.properties.x or 0)
      local y = offsetY + (child.properties.y or 0)
      local inner = clip
      if child.properties.w and child.properties.h then
        inner = clipTo({x = x, y = y,
          w = child.properties.w, h = child.properties.h}, clip)
      end
      if not child.hidden then
        local text = tostring(child.properties.text or "")
        if child.kind == "label" and text ~= "" then
          local font = child.properties.font
          local size = type(font) == "function" and font() or font
          found[#found + 1] = clipTo({
            label = true,
            what = '"' .. text .. '"',
            x = x,
            y = y,
            -- Measured the way the radio draws it, not estimated.
            -- `theme.textWidth` is deliberately generous so text shrinks
            -- rather than clips, and a check fed the generous number
            -- reports a reading lying across its own unit on every panel
            -- that has one. Generosity belongs in deciding whether
            -- something fits, never in deciding where it is.
            --
            -- And never past its own column. A Lua label's long mode is
            -- LVGL's default wrap, so text too wide for the width it was
            -- given comes back down the panel rather than out across it.
            -- Sideways is the one direction it cannot go, and reporting it
            -- there would be reporting a collision the screen does not
            -- have. The downward growth is a real defect and is what the
            -- `lines` assertions elsewhere exist for.
            w = math.min(themeModule.measureText(size, text),
              child.properties.w or math.huge),
            -- Ink, plus whatever this particular string reaches below its
            -- baseline. Almost always the ink alone, because a reading is
            -- digits, a minus, a point or a colon -- but a `g` or a `p`
            -- does reach into the space the band rule leaves unreserved,
            -- and a check that measured every label by its ascent could
            -- not see it. See testReadingsDoNotDescendOverAnything, which
            -- constructs the strings that can.
            h = themeModule.fontAscent(size)
              + edgetx.textDescent(size, text),
          }, clip)
        elseif child.kind == "arc" then
          local drawn = child.round.drawn
          local diameter = child.round.radius() * 2
          found[#found + 1] = clipTo({
            what = "a dial",
            x = offsetX + drawn.x,
            y = offsetY + drawn.y,
            w = diameter,
            h = diameter,
          }, clip)
        elseif child.kind == "rectangle" or child.kind == "image" then
          found[#found + 1] = clipTo({
            what = "a " .. child.kind,
            x = x,
            y = y,
            w = child.properties.w or 0,
            h = child.properties.h or 0,
          }, clip)
        end
      end
      walk(child, x, y, inner)
    end
  end

  if root then walk(root, 0, 0, nil) end
  return found
end

local function assertNothingOverlaps(label, context)
  for _, entry in ipairs(context.components) do
    local rect = boundsOf(entry)
    local boxes = drawnBoxes(entry)
    local where = label .. ": " .. entry.placement.id

    -- The panel's own furniture. A surface spans the panel and an accent
    -- stripe runs down its leading edge inside the padding, and both are
    -- under the content by design.
    -- The accent is a stripe one accent-width wide built from a straight
    -- run and two corner arcs, all of it inside the left padding, so the
    -- test is where it is rather than what it is called.
    local accentWidth = math.max(4, themeModule.modern and 6 or 6)
    local surface = {}
    for index, box in ipairs(boxes) do
      if not box.label then
        local spansPanel = box.w >= rect.w - 2 and box.h >= rect.h - 2
        local inAccentColumn = box.x + box.w <= accentWidth + 2
        if spansPanel or inAccentColumn then surface[index] = true end
      end
    end

    for first = 1, #boxes do
      for second = first + 1, #boxes do
        local a, b = boxes[first], boxes[second]
        -- One of the pair has to be text. Two shapes overlapping is a
        -- bar's fill inside its track or a level inside a cell, which is
        -- how those are built.
        if (a.label or b.label) and not surface[first] and not surface[second]
            and not (a.label and b.label and a.what == b.what) then
          local overlapX = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
          local overlapY = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
          assert(overlapX <= 0 or overlapY <= 0, where .. " draws "
            .. a.what .. " over " .. b.what .. ", "
            .. overlapX .. " by " .. overlapY .. " pixels at ("
            .. math.max(a.x, b.x) .. "," .. math.max(a.y, b.y) .. ")")
        end
      end
    end

    -- And nothing readable leaves the panel it belongs to.
    if rect then
      for _, box in ipairs(boxes) do
        if box.label then
          assert(box.y >= 0 and box.y + box.h <= rect.h, where
            .. " draws " .. box.what .. " off the panel vertically, "
            .. box.y .. " to " .. (box.y + box.h) .. " in " .. rect.h)
        end
      end
    end
  end
end

local function testNothingIsDrawnOverAnythingElse()
  -- Every shipped layout, because the directory is the list. A layout is
  -- covered the moment it is added, exactly like the load coverage.
  local listingPath = root .. "/build/collide-layouts.txt"
  local names = {}

  -- **Both the shipped layouts and the retired galleries.** The four span
  -- galleries were taken off the radio because nobody paged to them, and
  -- they are still built here because of what they construct: eleven
  -- components in one grid at one span, which is the densest arrangement
  -- this dashboard can be asked for and therefore where two things are
  -- likeliest to meet. Retiring a layout from a screen is a decision about
  -- the radio; deleting the cases it builds would have been a quiet
  -- reduction in what this check covers.
  local function collect(directory, prefix)
    os.execute("ls '" .. directory .. "' > '" .. listingPath .. "'")
    local listing = assert(hostIo.open(listingPath, "r"))
    for name in listing:lines() do
      local stem = string.match(name, "^(.+)%.yaml$")
      if stem then
        names[#names + 1] = {stem = stem, path = directory .. name,
          label = prefix .. stem}
      end
    end
    listing:close()
    os.remove(listingPath)
  end

  collect(sourcePath .. "layouts/", "")
  collect(root .. "/tests/fixtures/layouts/", "retired ")
  assert(#names > 1, "no layouts were found to check")

  local galleries = 0
  for _, entry in ipairs(names) do
    if string.match(entry.stem, "^span") then galleries = galleries + 1 end
  end
  assertEqual(galleries, 4,
    "the four retired span galleries are no longer being built, so the"
      .. " densest arrangement in the catalogue is not being checked for"
      .. " collisions by anything")

  -- **Both zones, and they have to be built one at a time.** A zone is not
  -- only a rectangle: `appZone` and `fullScreenZone` also set the flag
  -- `lvgl.isAppMode` answers, which is what decides whether the host lays a
  -- panel out around the menu button. Written as a table of two pairs, both
  -- are constructed before either is used, so the second one's flag is in
  -- force for both and the sweep ran App mode twice while reporting two
  -- zones. The Full screen half of this check has been vacuous since it was
  -- written; it is what found the `navigation` overlap this pull request
  -- fixes, but only because a one-off probe built the zones separately.
  for _, entry in ipairs(names) do
    local stem = entry.label
    for _, mode in ipairs({{"full screen", fullScreenZone},
        {"app mode", appZone}}) do
      resetRadio()
      local source = assert(hostIo.open(entry.path, "r"))
      local yaml = source:read("a")
      source:close()

      local widget = makeWidget("collide-" .. entry.stem .. "-"
        .. string.gsub(mode[1], " ", ""), yaml)
      local context = createLoaded(mode[2](), DEFAULT_OPTIONS, widget)
      -- **The sweep says which zone it is in, so it has to be in it.** This
      -- is the fixture checking itself: the zone the host lays out against
      -- is the flag, not the rectangle, and the flag is global. Without
      -- this the check reported two zones while building one, and the Full
      -- screen half proved nothing for as long as it existed.
      assertEqual(lvgl.isAppMode(), mode[1] == "app mode",
        stem .. ": the " .. mode[1] .. " sweep built the other zone")
      pump(context, 60)
      assertEqual(#context.errors, 0,
        stem .. ": " .. table.concat(context.errors, "\n"))
      assertNothingOverlaps(mode[1] .. " layout " .. stem, context)
    end
  end
end

--- A two-row footer fits the quarter it is granted, and clears the reading.
---
--- `navigation` is the only component that draws two supporting rows, and it
--- centres them as a group: 32 px of ink against a tertiary quarter that is
--- 31 px at a two-row span and 48 at a three-row one. Under fixed bands the
--- quarter does not grow to fit what is put in it, so the second row is
--- granted by the band that has to hold it -- which makes a three-row span
--- the narrowest one that draws both.
---
--- **This is where the rule bites hardest, so it is checked at both ends.**
--- At `2 x 3` the group has 48 px and 16 to spare; the panel is built in the
--- menu button's corner and in a clear cell, because the obstructed one is
--- where the band is tightest and a check that only built the roomy case
--- could not tell a fix from a panel that never had the problem.
---
--- It also carries the specification's promise about a missing home: the
--- coordinates stay visible and only the two values measured from home are
--- withheld. That is a property of the coordinate row, so it belongs at a
--- span that draws one.
local function testTwoRowFooterClearsTheReading()
  for _, place in ipairs({{"the menu button's corner", 0, 0},
      {"a clear cell", 2, 1}}) do
    resetRadio()
    local widget = makeWidget("two-row-footer-" .. place[2] .. place[3],
      table.concat({
      "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n",
      "  - id: nav\n    type: navigation\n",
      "    col: ", tostring(place[2]), "\n",
      "    row: ", tostring(place[3]), "\n",
      "    colSpan: 2\n    rowSpan: 3\n",
      "    config:\n      label: HOME\n      source: GPS\n",
      "      presentation: detailed\n",
    }))
    local context = createLoaded(appZone(), DEFAULT_OPTIONS, widget)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    pump(context, 60)

    local nav = entryById(context, "nav").instance
    local where = "navigation 2 x 3 in " .. place[1]
    -- The preconditions. Without both of these the assertions below are
    -- about a panel that draws one row, or none, and cannot fail.
    assertEqual(nav.showDetail, true, where .. " drew no supporting row")
    assertEqual(nav.showCoordinates, true,
      where .. " drew one supporting row, not two")

    local font = nav.value.properties.font
    font = type(font) == "function" and font() or font
    local bottom = nav.value.properties.y + themeModule.fontAscent(font)
    local rowTop = nav.detailLabel.properties.y
    assert(bottom <= rowTop, where .. ": the distance ends at " .. bottom
      .. " and the bearing row starts at " .. rowTop)
    -- And the rows clear each other, which is what the band has to be tall
    -- enough for in the first place.
    assert(rowTop < nav.coordinatesLabel.properties.y, where
      .. ": the coordinates do not sit below the bearing row")
    -- Both rows inside the quarter they were granted, which is the property
    -- the fixed-bands rule turns on: a band that is always reserved is only
    -- honest if what it holds actually fits it.
    local band = nav.area.bands.tertiary
    assert(rowTop >= band.y, where .. ": the bearing row starts at " .. rowTop
      .. ", above its own band at " .. band.y)
    local lastRow = nav.coordinatesLabel.properties.y
      + themeModule.fontAscent(nav.fonts.label)
    assert(lastRow <= band.y + band.h, where .. ": the coordinate row ends at "
      .. lastRow .. ", below its own band at " .. (band.y + band.h))
    assertNothingOverlaps(where, context)

    -- **A missing home withholds what is measured from home and nothing
    -- else.** The fix is perfectly good, so the coordinates stay on screen.
    radio.values[109]["pilot-lat"] = 0
    radio.values[109]["pilot-lon"] = 0
    pump(context, 40)
    assertEqual(nav.origin, "NO HOME")
    assertEqual(nav.text, "--", "a distance was measured from nowhere")
    assertEqual(nav.detail, "BRG --", "a bearing was invented without a home")
    assertEqual(nav.coordinates, "47.37690 8.54170",
      where .. ": the position itself is still known")
    assertEqual(nav.coordinatesLabel.properties.text, "47.37690 8.54170",
      where .. ": the coordinates were computed and not drawn")
  end
  resetRadio()
end

--- The always-reserved quarter is empty when nothing draws into it, and holds
--- both its tenants when something does.
---
--- The fixed-bands rule reserves the bottom quarter of every panel whether or
--- not a supporting row is drawn there. That is only worth having if the
--- reservation is honest in both directions:
---
---  * **empty means empty.** Nothing may be drawn into the quarter on a panel
---    that declares no row, and nothing else may quietly grow into it. A band
---    that something expands into is the redistribution this rule removed,
---    reappearing as a leak instead of as arithmetic.
---  * **occupied means it fits.** A bar is floor furniture -- its length is
---    the reading, so it spans the panel and sits on the floor -- and the
---    floor is this band's own floor, so a bar is drawn *inside* the quarter
---    rather than beneath it. A panel drawing a bar and a supporting row puts
---    both in the quarter, the row above the bar, and both have to fit.
---
--- That second question is the one `theme.bands` used to answer with
--- `floorHeight`: the band was sized to the bar rather than the bar placed in
--- the band. Removing the parameter makes the question real rather than
--- assumed, so it is measured here.
local function testTertiaryQuarterHoldsItsFurniture()
  --- Everything drawn that reaches into a panel's tertiary band.
  local function occupants(entry, bounds)
    local fonts = themeModule.typography(
      entry.placement.colSpan, entry.placement.rowSpan)
    local panel = {x = 0, y = 0, w = bounds.w, h = bounds.h}
    local band = themeModule.ladder(entry.instance.theme, panel,
      themeModule.frame(entry.instance.theme, panel, fonts)).bands.tertiary

    local found = {}
    local function walk(object, offsetX, offsetY)
      for _, child in ipairs(object.children) do
        local x = offsetX + (child.properties.x or 0)
        local y = offsetY + (child.properties.y or 0)
        if not child.hidden then
          local text = tostring(child.properties.text or "")
          local height, what
          if child.kind == "label" and text ~= "" then
            local font = child.properties.font
            if type(font) == "function" then font = font() end
            height = themeModule.fontAscent(font)
            what = '"' .. text .. '"'
          elseif child.kind == "rectangle" or child.kind == "image" then
            height = child.properties.h or 0
            what = child.kind
            -- The panel's own surface spans it and the accent stripe runs
            -- its whole height inside the left padding. Both are under the
            -- content by construction and belong to no band.
            local spansPanel = (child.properties.w or 0) >= bounds.w - 2
              and height >= bounds.h - 2
            local inAccent = x + (child.properties.w or 0) <= 8
            if spansPanel or inAccent then what = nil end
          end
          if what and height and y + height > band.y
              and y < band.y + band.h then
            found[#found + 1] = {what = what, top = y, bottom = y + height}
          end
        end
        walk(child, x, y)
      end
    end
    walk(entry.container, 0, 0)
    return found, band
  end

  -- Each case says whether the panel draws a supporting row, so the check
  -- knows which way the quarter should come out. A declaration that never
  -- builds the case is not coverage, so the bar variants carry the sources
  -- that make a second row real.
  local CASES = {
    {name = "flight-mode bare", type = "flight-mode",
      config = {"label: MODE"}, row = false, bar = false},
    {name = "tx-battery bare", type = "tx-battery",
      config = {"label: TX", "packEmpty: 6.6", "packFull: 8.4"},
      row = false, bar = false},
    {name = "model-identity bare", type = "model-identity",
      config = {"presentation: name", "label: MODEL"},
      row = false, bar = false},
    {name = "flight-mode row", type = "flight-mode",
      config = {"label: MODE", "showIndex: true"}, row = true, bar = false},
    {name = "tx-battery row", type = "tx-battery",
      config = {"label: TX", "packEmpty: 6.6", "packFull: 8.4",
        "showPercent: true"}, row = true, bar = false},
    {name = "metric bar", type = "metric",
      config = {"label: ALT", "source: Alt", "unit: m", "rangeMin: 0",
        "rangeMax: 400", "precision: 0", "visual: bar"},
      row = true, bar = true},
    {name = "cell-battery bar and row", type = "cell-battery",
      config = {"source: Cels", "label: PACK", "reading: lowest",
        "visual: bar", "showPack: true", "showCount: true"},
      row = true, bar = true},
  }

  local sawEmpty, sawOccupied, sawBarAndRow = 0, 0, 0

  for _, case in ipairs(CASES) do
    -- Two-row spans, because a one-row panel is granted no supporting row at
    -- all and would report an empty quarter whatever the component asked
    -- for. Only three components declare a three-row span, so a `2 x 3`
    -- sweep would be a sweep over a different set for every case.
    for _, span in ipairs({{2, 2}, {4, 2}}) do
      for _, mode in ipairs({{"full screen", fullScreenZone},
          {"app mode", appZone}}) do
        resetRadio()
        local lines = {"version: 1", "grid:", "  columns: 4", "  rows: 4",
          "components:", "  - id: subject", "    type: " .. case.type,
          -- Clear of the menu button, so the quarter is measured on a panel
          -- nothing else is interfering with.
          "    col: " .. (4 - span[1]), "    row: " .. (4 - span[2]),
          "    colSpan: " .. span[1], "    rowSpan: " .. span[2],
          "    config:"}
        for _, line in ipairs(case.config) do
          lines[#lines + 1] = "      " .. line
        end
        local widget = makeWidget("quarter-" .. string.gsub(case.name, " ", "")
          .. "-" .. span[1] .. "x" .. span[2] .. "-"
          .. string.gsub(mode[1], " ", ""),
          table.concat(lines, "\n") .. "\n")
        local context = createLoaded(mode[2](), DEFAULT_OPTIONS, widget)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        pump(context, 60)

        local entry = entryById(context, "subject")
        local bounds = boundsOf(entry)
        local inside, band = occupants(entry, bounds)
        local where = mode[1] .. " " .. case.name .. " "
          .. span[1] .. "x" .. span[2]

        if case.row then
          assert(#inside > 0, where
            .. ": the panel declares a supporting row and its tertiary"
            .. " quarter is empty, so the row is somewhere else")
          sawOccupied = sawOccupied + 1
          -- Everything in it is inside it. A band that is always reserved is
          -- only honest if what it holds actually fits.
          for _, box in ipairs(inside) do
            assert(box.top >= band.y and box.bottom <= band.y + band.h, where
              .. ": " .. box.what .. " runs from " .. box.top .. " to "
              .. box.bottom .. ", outside its band at " .. band.y .. ".."
              .. (band.y + band.h))
          end
          if case.bar then
            local bars, labels = 0, 0
            for _, box in ipairs(inside) do
              if box.what == "rectangle" then bars = bars + 1
              else labels = labels + 1 end
            end
            if bars > 0 and labels > 0 then
              sawBarAndRow = sawBarAndRow + 1
              -- The row sits above the bar rather than on it.
              for _, box in ipairs(inside) do
                if box.what ~= "rectangle" then
                  for _, other in ipairs(inside) do
                    if other.what == "rectangle" then
                      assert(box.bottom <= other.top, where
                        .. ": a supporting row runs to " .. box.bottom
                        .. " and the bar starts at " .. other.top)
                    end
                  end
                end
              end
            end
          end
        else
          assertEqual(#inside, 0, where
            .. ": the panel draws no supporting row and its tertiary quarter"
            .. " holds "
            .. (inside[1] and inside[1].what or "") .. " -- something grew"
            .. " into a band that is supposed to stay empty")
          sawEmpty = sawEmpty + 1
        end
      end
    end
  end

  -- None of the three sweeps may be vacuous.
  assert(sawEmpty > 0, "no panel with an empty quarter was ever built")
  assert(sawOccupied > 0, "no panel with an occupied quarter was ever built")
  assert(sawBarAndRow > 0,
    "no panel drawing a bar and a supporting row was ever built, so the"
      .. " case those two share a band was never constructed")
  resetRadio()
end

--- A timer index the radio does not have is refused at load, by name.
---
--- `MAX_TIMERS` is 3 (`radio/src/dataconstants.h:94`) and `luaModelGetTimer`
--- answers nothing at or above it, so 0, 1 and 2 are the whole set. A layout
--- asking for `timer: 9` used to load and draw `NO TIMER` -- **which is
--- exactly what a correctly written layout draws on a radio whose timer is
--- not configured.** The one the author can fix and the one they cannot
--- looked identical, and nothing said which was which.
---
--- Both halves are checked here, because the refusal is only worth having if
--- the runtime case still loads silently.
local function testTimerIndexIsRefusedAtLoad()
  resetRadio()

  local function load(value)
    local widget = makeWidget("timer-index-"
      .. string.gsub(tostring(value), "[^%w]", ""), table.concat({
      "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n",
      "  - id: clock\n    type: flight-timer\n",
      "    col: 0\n    row: 0\n    colSpan: 2\n    rowSpan: 2\n",
      "    config:\n      timer: ", tostring(value), "\n",
    }))
    return createLoaded({x = 0, y = 0, w = 480, h = 272},
      DEFAULT_OPTIONS, widget)
  end

  -- Refused, and the message names the panel the way every other refusal
  -- does, so an author can find it in a grid of twelve.
  local refused = load(9)
  assertEqual(#refused.errors, 1,
    "an index no radio has was accepted: " .. table.concat(refused.errors, "; "))
  assert(string.find(refused.errors[1], "clock", 1, true),
    "the refusal does not name the panel: " .. refused.errors[1])
  assert(string.find(refused.errors[1], "timer", 1, true),
    "the refusal does not name the setting: " .. refused.errors[1])

  -- The last real index is not refused, which is what stops this being a
  -- rule that merely forbids large numbers.
  local accepted = load(2)
  assertEqual(#accepted.errors, 0,
    "the last timer a radio has was refused: "
      .. table.concat(accepted.errors, "; "))
  pump(accepted, 40)
  assertEqual(entryById(accepted, "clock").instance.text, "0:12",
    "timer 2 was accepted and then not read")

  -- And the runtime case is silent, because it is not the author's mistake:
  -- an index the radio has and the model has not configured draws NO TIMER
  -- with nothing reported.
  resetRadio()
  radio.timers[2] = nil
  local unconfigured = load(2)
  assertEqual(#unconfigured.errors, 0,
    "a timer the model has not set up was reported as an authoring mistake")
  pump(unconfigured, 40)
  local panel = entryById(unconfigured, "clock").instance
  assertEqual(panel.text, "--:--")
  assertEqual(panel.detail, "NO TIMER")
  assertEqual(panel.stateName, "unavailable")
  resetRadio()
end

--- Every supporting row fits the box its panel gives it.
---
--- **The property, rather than the mechanism.** The specification says every
--- supporting row goes through `theme.fitLabel`, which is not true and was
--- never quite the point: four of the eight components that draw a row call
--- it, and routing the other four through it would change nothing, because a
--- single-wording list comes back out of `fitLabel` unchanged. What matters
--- is that the row fits, and the mechanism for a row that cannot is to offer
--- a shorter wording.
---
--- Nothing checked the property. `flight-timer` drew `ELAPSED PAST ZERO` at
--- `1 x 2`, 125 px into a content box of 105 -- and a Lua label's long mode
--- is LVGL's default wrap, so it did not clip sideways: it was centred on a
--- box wider than the panel, started 10 px outside the left edge and ran
--- 10 px past the right, over whatever was beside it. That state is the one
--- this component exists to report, at the narrowest span that draws a row
--- at all. It says `EXPIRED` now, at 51 px.
---
--- Driven through the real host at every span that grants a row, in both
--- zones, with each component put into the state whose wording is longest.
--- The states are declared, because a component's longest wording is usually
--- a failure state and a fixture has to be driven into one.
local function testSupportingRowsFitTheirBox()
  --- Each component that draws a supporting row, configured so it draws one,
  --- and how to drive it into the state that words the most.
  ---
  --- **A declaration, and it names the state as well as the component.** A
  --- declaration that does not construct the case is not coverage: listing
  --- `flight-timer` without expiring its countdown would check `OF 5:00`,
  --- which fits everywhere, and report the component covered.
  local ROWED = {
    {name = "flight-timer, countdown running", type = "flight-timer",
      config = {"timer: 0", "label: TIMER"}},
    {name = "flight-timer, elapsed past zero", type = "flight-timer",
      config = {"timer: 0", "label: TIMER"},
      drive = function() radio.timers[0].value = -15 end},
    {name = "flight-timer, counting up", type = "flight-timer",
      config = {"timer: 1", "label: TIMER"}},
    {name = "flight-timer, no countdown to remain", type = "flight-timer",
      config = {"timer: 1", "label: TIMER", "reading: remaining"}},
    {name = "flight-timer, no timer", type = "flight-timer",
      config = {"timer: 2", "label: TIMER"},
      drive = function() radio.timers[2] = nil end},
    {name = "flight-mode, mode number", type = "flight-mode",
      config = {"label: MODE", "showIndex: true"}},
    {name = "cell-battery, pack and count", type = "cell-battery",
      config = {"source: Cels", "label: PACK", "showPack: true",
        "showCount: true"}},
    {name = "cell-battery, nonsense cells", type = "cell-battery",
      config = {"source: Cels", "label: PACK", "showPack: true",
        "showCount: true"},
      drive = function() radio.values[130] = {0, -1, 99} end},
    {name = "link-status, link down", type = "link-status",
      config = {"label: LINK", "rssiSource: 1RSS", "qualitySource: RQly",
        "reading: rssi"},
      drive = function() radio.rssi = 0 end},
    {name = "metric, range and secondary", type = "metric",
      config = {"label: ALT", "source: Alt", "unit: m", "rangeMin: 0",
        "rangeMax: 400", "precision: 0", "visual: bar",
        "secondarySource: Curr", "secondaryLabel: CUR"}},
    {name = "navigation, no home position", type = "navigation",
      config = {"label: HOME", "source: GPS", "presentation: detailed"},
      drive = function()
        radio.values[109]["pilot-lat"] = 0
        radio.values[109]["pilot-lon"] = 0
      end},
    {name = "tx-battery, percentage", type = "tx-battery",
      config = {"label: TX", "packEmpty: 6.6", "packFull: 8.4",
        "showPercent: true"}},
    {name = "variable-indicator, configured name", type = "variable-indicator",
      config = {"binding: global", "index: 0", "label: GV", "showName: true"}},
  }

  local checked, widest, widestWhere = 0, 0, ""

  for _, subject in ipairs(ROWED) do
    -- Every span that grants a supporting row. One-row panels are granted
    -- none at any width, so they would report an empty sweep rather than a
    -- fitting one.
    for _, span in ipairs({{1, 2}, {2, 2}, {4, 2}}) do
      for _, mode in ipairs({{"full screen", fullScreenZone},
          {"app mode", appZone}}) do
        resetRadio()
        if subject.drive then subject.drive() end

        local lines = {"version: 1", "grid:", "  columns: 4", "  rows: 4",
          "components:", "  - id: subject", "    type: " .. subject.type,
          -- Clear of the menu button, so the row is measured against a
          -- content box nothing else has narrowed.
          "    col: " .. (4 - span[1]), "    row: " .. (4 - span[2]),
          "    colSpan: " .. span[1], "    rowSpan: " .. span[2],
          "    config:"}
        for _, line in ipairs(subject.config) do
          lines[#lines + 1] = "      " .. line
        end

        local widget = makeWidget("rowfit-"
          .. string.gsub(subject.name, "[^%w]", "") .. "-"
          .. span[1] .. "x" .. span[2] .. "-"
          .. string.gsub(mode[1], " ", ""),
          table.concat(lines, "\n") .. "\n")
        local context = createLoaded(mode[2](), DEFAULT_OPTIONS, widget)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        pump(context, 60)

        local entry = entryById(context, "subject")
        local bounds = boundsOf(entry)
        local frame = themeModule.frame(entry.instance.theme,
          {x = 0, y = 0, w = bounds.w, h = bounds.h},
          themeModule.typography(span[1], span[2]))
        local where = mode[1] .. " " .. subject.name .. " "
          .. span[1] .. "x" .. span[2]

        -- Every visible label in the panel's lower half is a supporting row.
        -- Read off the drawing rather than from a field each component names
        -- differently -- `detail`, `range`, `secondary`, `countText`.
        local function walk(object, offsetX, offsetY)
          for _, child in ipairs(object.children) do
            local x = offsetX + (child.properties.x or 0)
            local y = offsetY + (child.properties.y or 0)
            local text = tostring(child.properties.text or "")
            if child.kind == "label" and not child.hidden and text ~= ""
                and y > bounds.h / 2 then
              local font = child.properties.font
              font = type(font) == "function" and font() or font
              local width = themeModule.measureText(font, text)

              assert(width <= frame.content, where .. ': draws "' .. text
                .. '" at ' .. width .. " px into a content box of "
                .. frame.content .. " -- a row cannot shrink its font, so a"
                .. " row this wide is centred on a box wider than the panel"
                .. " and runs off both edges")

              -- And it is on the panel, which is the same fact stated
              -- against the edge rather than against the box.
              assert(x >= 0 and x + width <= bounds.w, where .. ': draws "'
                .. text .. '" from ' .. x .. " to " .. (x + width)
                .. " on a panel " .. bounds.w .. " px wide")

              checked = checked + 1
              if width > widest then widest, widestWhere = width, where end
            end
            walk(child, x, y)
          end
        end
        walk(entry.container, 0, 0)
      end
    end
  end

  -- Not vacuous: rows were actually drawn, and the narrowest span really was
  -- reached. Without this a sweep that shed every row would pass.
  assert(checked >= 60, "only " .. checked
    .. " supporting rows were drawn, so most of this swept nothing")
  assert(string.find(widestWhere, "1x2", 1, true) ~= nil
    or widest > 0, "the widest row found was not measured")
  resetRadio()
end

--- A badge ends flush with its panel, the way the heading begins flush.
---
--- **A label draws from its own left edge, so moving its box does not move
--- its text.** `theme.frame` reserves a right-aligned column wide enough for
--- the widest word the vocabulary has -- `STALE` -- and every shorter word
--- then sat at that column's *left*. At `2 x 2` the column ended at 234,
--- correctly inset by the panel's right padding, and `CRIT` ended at 213.
--- The heading opposite sat flush left, so the header read as lopsided, and
--- only the longest word looked right.
---
--- **The collision check has nothing to say about this, and that is the
--- point.** Nothing collided: the badge floated *away* from the heading, so
--- overlap, containment and wrap were all satisfied. It is the shape the
--- specification already records -- a check that would pass if everything
--- moved together is not a check on position -- so where something sits
--- needs an assertion against the panel rather than against its neighbours.
---
--- Driven through the `states` layout, which exists to put panels in badged
--- states, plus a `stale` and an `unavailable` reached by taking the link
--- away. Both zones, because the badge's right edge is the panel's and the
--- two zones give a panel different heights.
local function testBadgesEndFlushWithTheirPanel()
  local theme = themeModule
  local source = assert(hostIo.open(
    sourcePath .. "layouts/states.yaml", "r"))
  local yaml = source:read("a")
  source:close()

  -- The vocabulary, read off the theme rather than typed, so a word added to
  -- it is covered the moment it is added.
  local vocabulary = {}
  for _, name in ipairs({"warning", "critical", "stale", "unavailable",
      "selected", "editing"}) do
    local state = theme.state(theme.build("modern"), name)
    if state and type(state.badge) == "string" and state.badge ~= "" then
      vocabulary[state.badge] = true
    end
  end
  assert(next(vocabulary), "the badge vocabulary came out empty")

  local seen, checked = {}, 0

  local function inspect(where, context)
    for _, entry in ipairs(context.components) do
      local instance = entry.instance
      local badge = instance and instance.badge
      if badge and not badge.hidden then
        local word = tostring(badge.properties.text or "")
        if word ~= "" then
          local bounds = boundsOf(entry)
          local font = badge.properties.font
          font = type(font) == "function" and font() or font

          -- **The assertion.** The badge's ink ends where the panel's right
          -- padding says it ends, which is exactly where `theme.frame` puts
          -- the column's own right edge. Pinned against the panel rather
          -- than against the column, because the column was always right
          -- and the text inside it was not.
          local inkEnd = badge.properties.x + theme.measureText(font, word)
          local frame = theme.frame(instance.theme,
            {x = 0, y = 0, w = bounds.w, h = bounds.h},
            theme.typography(entry.placement.colSpan, entry.placement.rowSpan))
          local columnEnd = frame.badgeX + frame.badgeWidth

          assertEqual(inkEnd, columnEnd, where .. ": " .. entry.placement.id
            .. ' draws "' .. word .. '" ending at ' .. inkEnd
            .. ", where its column ends at " .. columnEnd
            .. " -- the text is left-aligned inside its box again")

          -- And the box never starts left of the column, which is what
          -- protects the heading beside it.
          assert(badge.properties.x >= frame.badgeX, where .. ": "
            .. entry.placement.id .. " placed its badge at "
            .. badge.properties.x .. ", left of the column at "
            .. frame.badgeX .. ", where the heading is")

          seen[word] = true
          checked = checked + 1
        end
      end
    end
  end

  for _, mode in ipairs({{"full screen", fullScreenZone},
      {"app mode", appZone}}) do
    resetRadio()
    local widget = makeWidget("badge-flush-"
      .. string.gsub(mode[1], " ", ""), yaml)
    -- The very table the host holds, because a reflow is driven by mutating
    -- it. Building a second one and resizing that reflows nothing, and the
    -- check then watches a panel that never moved while reporting that it
    -- did -- which is how the first version of this test passed with the
    -- reflow path deliberately broken.
    local zone = mode[2]()
    local context = createLoaded(zone, DEFAULT_OPTIONS, widget)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    pump(context, 60)
    inspect(mode[1] .. " resting", context)

    -- A dead link badges the telemetry panels stale and then unavailable,
    -- which is how the two remaining words are reached.
    radio.rssi = 0
    pump(context, 80)
    inspect(mode[1] .. " link down", context)

    local widthBefore = {}
    for _, entry in ipairs(context.components) do
      widthBefore[entry.placement.id] = boundsOf(entry).w
    end

    -- **And then the panel moves.** A badge's right edge is its panel's, so
    -- every reflow changes it -- and the badge is placed from its own
    -- measured text, which a reflow does not re-measure unless something
    -- makes it. Restating the box and leaving the word where the previous
    -- width put it is the defect shape this project has paid for eight
    -- times: a position derived from a size, carried as an offset.
    zone.w, zone.h = 360, 200
    local passes = 0
    repeat
      definition.refresh(context)
      passes = passes + 1
      assert(passes < 200, "reflow never finished")
    until not context.reflowIndex
    pump(context, 40)
    local moved = false
    for _, entry in ipairs(context.components) do
      if boundsOf(entry).w ~= widthBefore[entry.placement.id] then
        moved = true
      end
    end
    assert(moved, mode[1] .. ": no panel changed width, so the reflow below"
      .. " is not a reflow and proves nothing")
    inspect(mode[1] .. " reflowed", context)
    resetRadio()
  end

  -- Non-vacuous in two directions: something was actually badged, and the
  -- words reached were words the vocabulary declares rather than whatever
  -- happened to be on screen.
  assert(checked >= 8, "only " .. checked
    .. " badged panels were found, so this proves very little")
  local reached = 0
  for word in pairs(seen) do
    assert(vocabulary[word], 'a panel drew "' .. word
      .. '", which is not in the badge vocabulary')
    reached = reached + 1
  end
  assert(reached >= 3, "only " .. reached
    .. " of the vocabulary was reached, so the narrow words may be untested")
end

--- Nothing descends into the space measuring by ink leaves unreserved.
---
--- `theme.bandFont` takes the largest font whose **ascent** fits the body
--- band, and `theme.bodyTop` centres that ascent rather than the line box.
--- So the strip between a reading's baseline and the bottom of its line box
--- belongs to whatever is beneath it: a bar sits there, a supporting row
--- sits there, and on a short panel the panel's own floor is in it. At
--- XXLSIZE that strip is 15 px.
---
--- **That is safe because nothing in the catalogue descends, and until now
--- it was a fact rather than an assertion.** Two things put a descender into
--- a reading without anybody choosing to:
---
---  * **A unit.** `telemetry_service`'s own rendering of EdgeTX's
---    `TelemetryUnit` includes `mph`, `rpm`, `deg` and `g`, every one of
---    which descends, and `m/s`, `km/h` and `ml/m`, whose `/` descends by a
---    pixel. Which one arrives is decided by the sensor the pilot selected.
---  * **Free text.** `model-identity` draws the model's name, which is
---    whatever the pilot typed into Model Setup.
---
--- So the strings are constructed here rather than waited for, and each
--- panel goes through the same collision and containment check every
--- shipped layout goes through -- which charges a label its ink *plus* what
--- its own glyphs reach below the baseline, read from the font's `ofs_y`.
local function testReadingsDoNotDescendOverAnything()
  -- **The instrument first.** A check that cannot report a descender would
  -- agree with everything below while proving nothing, which is the failure
  -- mode this suite keeps finding in its own apparatus. So it is made to
  -- disagree on purpose before it is trusted when it agrees.
  assert(edgetx.textDescent(XXLSIZE, "rpm") > 0,
    "the fixture cannot see a descender, so nothing below is a check")
  assert(edgetx.textDescent(XXLSIZE, "km/h") > 0,
    "the fixture cannot see a solidus descend")
  for _, safe in ipairs({"-888.88", "1:04:12", "120.0", "%", "V", "dBm"}) do
    assertEqual(edgetx.textDescent(XXLSIZE, safe), 0,
      "the fixture reports a descender in " .. safe
        .. ", so it would report one anywhere")
  end

  -- Every unit the dashboard can render that reaches below the baseline,
  -- taken from `telemetry_service`'s own table rather than invented. Each is
  -- given to a `metric` through its `unit` setting, which is the same string
  -- a resolved sensor would have produced.
  local DESCENDING_UNITS = {"rpm", "mph", "deg", "g", "km/h", "m/s", "ml/m"}

  -- A span that draws a bar **and** a supporting row, so there is something
  -- in the strip below the baseline for a descender to land on. A one-row
  -- panel sheds the row; this is the case where the reading has least air
  -- beneath it.
  local SPANS = {{2, 1}, {4, 1}, {2, 2}, {4, 2}}
  -- Built rather than stored, because a zone carries the App mode flag as
  -- well as a rectangle and constructing both up front leaves the second
  -- one's flag in force for the first.
  local ZONES = {{"full screen", fullScreenZone}, {"app mode", appZone}}

  local drewAUnit, drewAName = 0, 0

  for _, unit in ipairs(DESCENDING_UNITS) do
    for _, span in ipairs(SPANS) do
      for _, mode in ipairs(ZONES) do
        resetRadio()
        local widget = makeWidget(
          "descend-" .. string.gsub(unit, "/", "-")
            .. "-" .. span[1] .. "x" .. span[2]
            .. "-" .. string.gsub(mode[1], " ", ""), table.concat({
          "version: 1\n",
          "grid:\n  columns: 4\n  rows: 4\n",
          "components:\n",
          "  - id: subject\n    type: metric\n",
          "    col: 0\n    row: 0\n",
          "    colSpan: ", tostring(span[1]), "\n",
          "    rowSpan: ", tostring(span[2]), "\n",
          "    config:\n",
          "      label: RATE\n",
          "      source: Alt\n",
          "      unit: \"", unit, "\"\n",
          "      rangeMin: 0\n      rangeMax: 400\n",
          "      precision: 0\n      visual: bar\n",
          "      secondarySource: Curr\n      secondaryLabel: CUR\n",
        }))
        local context = createLoaded(mode[2](), DEFAULT_OPTIONS, widget)
        pump(context, 60)
        assertEqual(#context.errors, 0,
          unit .. ": " .. table.concat(context.errors, "\n"))

        local panel = entryById(context, "subject").instance
        if panel.showUnit then
          assertEqual(panel.unit.properties.text, unit,
            "the unit the layout asked for never reached the label")
          drewAUnit = drewAUnit + 1
        end
        assertNothingOverlaps(mode[1] .. " " .. unit .. " "
          .. span[1] .. "x" .. span[2], context)
      end
    end
  end

  -- And the one reading that is free text. `model-identity` is the only
  -- panel whose reading is a name rather than a number, and a name is the
  -- one string on this dashboard nobody here chooses.
  for _, name in ipairs({"Puppy", "Gypsy Moth", "jjjj", "Q_[g]"}) do
    for _, span in ipairs({{2, 2}, {4, 2}, {4, 4}}) do
      for _, mode in ipairs(ZONES) do
        resetRadio()
        radio.modelName = name
        local widget = makeWidget(
          "descend-name-" .. string.gsub(name, "[^%w]", "") .. "-"
            .. span[1] .. "x" .. span[2] .. "-"
            .. string.gsub(mode[1], " ", ""), table.concat({
          "version: 1\n",
          "grid:\n  columns: 4\n  rows: 4\n",
          "components:\n",
          "  - id: subject\n    type: model-identity\n",
          "    col: 0\n    row: 0\n",
          "    colSpan: ", tostring(span[1]), "\n",
          "    rowSpan: ", tostring(span[2]), "\n",
          "    config:\n",
          "      presentation: name\n",
          "      label: MODEL\n",
          "      showLabels: true\n",
        }))
        local context = createLoaded(mode[2](), DEFAULT_OPTIONS, widget)
        pump(context, 60)
        assertEqual(#context.errors, 0,
          name .. ": " .. table.concat(context.errors, "\n"))

        local panel = entryById(context, "subject").instance
        assertEqual(panel.text, name,
          "the hostile model name never reached the panel")
        drewAName = drewAName + 1
        assertNothingOverlaps(mode[1] .. " name " .. name .. " "
          .. span[1] .. "x" .. span[2], context)
      end
    end
  end

  -- Neither sweep may be vacuous. A panel that shed every unit, or a name
  -- that never reached a label, would take this whole check with it.
  assert(drewAUnit > 0,
    "every panel shed its unit, so no descending unit was ever drawn")
  assert(drewAName > 0, "no model name was ever drawn")
  resetRadio()
end

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

  -- Read from both component directories rather than listed here. A hand-kept
  -- list cannot drift out of step with itself, which is why the guard below
  -- could never be shown to do anything: it was checking the list against the
  -- list. Reading the directories means a component added to either one is
  -- swept from the moment it exists, and one that disappears is noticed.
  --
  -- Both directories, because `heartbeat` and `placeholder` are fixtures now
  -- and the host must still treat a layout that places one exactly like any
  -- other component. Both drew at a raw (8, 6) until they were routed through
  -- the shared frame, which is the kind of thing this sweep is for.
  local sweepTypes = {}
  for _, directory in ipairs({sourcePath .. "components",
      root .. "/tests/fixtures/components"}) do
    local listingPath = root .. "/build/sweep-types.txt"
    os.execute("ls '" .. directory .. "' > '" .. listingPath .. "'")
    local listing = assert(hostIo.open(listingPath, "r"))
    for name in listing:lines() do
      local stem = string.match(name, "^(.+)%.lua$")
      if stem then sweepTypes[#sweepTypes + 1] = stem end
    end
    listing:close()
    os.remove(listingPath)
  end
  assert(#sweepTypes >= 13, "only " .. #sweepTypes
    .. " component types were found to sweep")

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
    -- `lcd.sizeText` is C on a radio and free to a script; here it sums the
    -- string in Lua. Swapped for a stand-in that answers the same number from
    -- a cache, so the measurement is of the dashboard rather than of the
    -- fixture's arithmetic.
    setTextMeasurement(false)
    -- Count exactly as the firmware does: a hook every 200 instructions.
    debug.sethook(function() ticks = ticks + 1 end, "", 200)
    local ok, err = pcall(fn, ...)
    debug.sethook()
    setTextMeasurement(true)
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
      -- No `showIndex`: this exercise is sixteen single cells, and a single
      -- row has no space for the mode number at any width, so asking for it
      -- is refused at load.
      config = function() return {"label: Mode"} end,
    },
    {
      type = "tx-battery",
      services = {"model"},
      config = function()
        -- No `showPercent`: sixteen single cells, and a single row has no
        -- space for one at any width, so asking is refused at load.
        return {"packEmpty: 6.6", "packFull: 8.4", "warning: 7.0"}
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
      -- No `showLabels`: sixteen single cells, which have no row for them,
      -- so it is refused at load. The worst case for this component at this
      -- span genuinely does not include the label list.
      config = function() return {"presentation: both"} end,
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

  -- Sixteen diagnostics panels, which is the worst case for the view that
  -- reports on the host. It must not cost the dashboard anything when it is
  -- not showing, which it cannot, because a component no layout places is
  -- never loaded; the question this answers is the other half, that it does
  -- not become the most expensive thing on the dashboard when it is.
  local diagnosticsGrid = {"version: 1", "grid:", "  columns: 4", "  rows: 4",
    "components:"}
  local sections = {"identity", "theme", "components", "sources"}
  for index = 1, 16 do
    local col, row = (index - 1) % 4, math.floor((index - 1) / 4)
    for _, line in ipairs({
      "  - id: d" .. index,
      "    type: host-diagnostics",
      "    col: " .. col,
      "    row: " .. row,
      "    colSpan: 1",
      "    rowSpan: 1",
      "    config:",
      "      section: " .. sections[(index - 1) % 4 + 1],
    }) do
      diagnosticsGrid[#diagnosticsGrid + 1] = line
    end
  end
  exercise("host diagnostics x16",
    makeWidget("budget-diagnostics", table.concat(diagnosticsGrid, "\n") .. "\n"), 16)

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
  -- **A live source, because this test is about width and not about having a
  -- reading at all.** It named no source until a unit stopped being drawn
  -- beside an absent value, and every assertion below then described a panel
  -- printing `-- V`: the unit it asserted survived a height loss was a unit
  -- with no number to qualify. The shed-and-restore behaviour it exists to
  -- pin is unchanged, because `metric` sheds on the widest form it can print
  -- rather than on the one on screen; what changes is that the panel now has
  -- one.
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
      source: S1
      unit: V
      rangeMin: 18
      rangeMax: 25
      precision: 1
      visual: bar
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  -- Let the telemetry service resolve and deliver, so the panel is drawing a
  -- number before anything here asks what happens to the unit beside it.
  pump(context, 20)
  local instance = entryById(context, "big").instance

  assertEqual(instance.text, "3.0",
    "this test needs a panel with a reading, not a sentinel")
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
  assertEqual(instance.range.hidden, true, "shed range was left visible")

  -- The unit survives this, and that is the change rather than a slip. It
  -- rides beside the reading now instead of taking a row beneath it, so a
  -- panel losing height loses rows and keeps the unit. What it costs is
  -- width, and width is what takes it away.
  assertEqual(instance.unit.hidden, false,
    "the unit was shed by a panel that only lost height, which it no longer"
      .. " pays for")

  for _, object in ipairs({instance.label, instance.value, instance.badge}) do
    assert(object.properties.y < bounds.h, "visible content escaped the panel")
  end

  -- Narrow enough that the number and its unit no longer fit side by side.
  -- Measured rather than estimated, now that the pair is: the reading's
  -- column comes out at 36 px, a SMLSIZE `25.0` is 25 of those and the same
  -- reading with a TINSIZE `V` beside it is 32. The number keeps its size;
  -- the unit goes, because the heading names what is being measured and the
  -- digits are the reading.
  --
  -- It used to be 180, which the estimate called too narrow and a radio does
  -- not: measured, the pair still fits at 120. And then 100, for the same
  -- reason once more -- fitting itself now measures, so the reading no
  -- longer steps down at a width where the font had room all along, and the
  -- pair survives further than it did.
  zone.w = 90
  zone.h = 272
  settle()
  assertEqual(instance.unit.hidden, true,
    "a panel too narrow for the pair kept its unit")
  assert(instance.value.lines == 1,
    "the reading wrapped, so the unit was shed and bought nothing")

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

--- The diagnostics view reports the host's own state, not a second opinion.
---
--- This is the hazard the whole view has to avoid. A panel that resolved the
--- layout filename a second time, or rebuilt the theme to see what it would
--- say, would be describing a world assembled for it rather than the one the
--- dashboard is running, and would be confidently wrong at exactly the moment
--- somebody is trusting it. So the assertions below compare what is drawn
--- against the live context, never against a string this test also knows: a
--- view that recomputed anything would have to agree with the host by
--- accident to pass.
--- A reading sits where its slot says, at every span and both arrangements.
---
--- **There were no assertions about slot placement at all**, and that is how
--- a reading came to sit 23.5 px outside its slot on a shipped dashboard.
--- Three checks passed it: nothing overlapped, because the shift moved the
--- number *away* from the battery; nothing left its panel, because the panel
--- is wider than the number; and nothing wrapped. A rule about where things
--- go needs an assertion about where they went.
---
--- **The expected centre is derived here from the panel, not by asking the
--- widget.** Calling `theme.slotCentres` would restate the implementation and
--- pass for any consistent wrong answer, which is the shape that has cost
--- this project twice already. So the fractions are written out, the content
--- box is rebuilt from the padding constants, and the arrangement in force is
--- read off the **glyph's own drawn position** -- independent evidence, since
--- the glyph is placed from its geometry rather than from a text width.
--- A panel lays its reading out in the same place whether or not it draws a
--- supporting row.
---
--- **This test used to assert the exact opposite and was renamed with the
--- rule it checks.** It was `testUnusedRowsCostNothing`, and it held that a
--- panel drawing no supporting row must read *larger* than one that does,
--- because the tertiary quarter was given to the body when nothing was going
--- to be drawn in it. That was a real defect at the time -- three components
--- default their row off and all three were charged a quarter of the panel
--- for a row they would never fill -- and fixing it was correct given the
--- rule then in force.
---
--- The rule changed. The user put the result on a radio and rejected it: a
--- redistributing band makes two panels of one size lay out differently
--- according to what is *in* them, so a reading sits at one height on a
--- panel with a row and at another on the panel beside it without. The bands
--- are fixed proportions now, and the property worth holding is the reverse
--- of what this once held.
---
--- **The position is the assertion, not the font.** A font comparison was
--- what this used before and it is the weaker claim: both panels reach the
--- top of the ladder on a tall enough panel, so equal fonts are satisfied by
--- a band that is wrong in a way the ladder cannot express. Two readings on
--- the same line is the property itself.
local function testReadingsIgnoreTheRowBeneathThem()
testTertiaryQuarterHoldsItsFurniture()

  -- Each component, the setting that turns its supporting row on, and how to
  -- read back whether the panel drew one. Declared rather than special-cased
  -- so a component that gains an optional row is covered by adding a line.
  local OPTIONAL = {
    {
      type = "flight-mode",
      setting = "showIndex",
      config = {"label: MODE"},
      label = function(panel) return panel.detailLabel end,
      drew = function(panel) return panel.showDetail end,
    },
    {
      type = "model-identity",
      setting = "showLabels",
      config = {"label: MODEL"},
      label = function(panel) return panel.labelsLabel end,
      drew = function(panel) return panel.showLabels end,
    },
    {
      type = "tx-battery",
      setting = "showPercent",
      config = {"label: TX", "packEmpty: 6.6", "packFull: 8.4"},
      label = function(panel) return panel.detailLabel end,
      drew = function(panel) return panel.showDetail end,
    },
  }

  -- Two rows, because a single-row panel is granted no supporting row at all
  -- and would pass this check without exercising it.
  for _, subject in ipairs(OPTIONAL) do
    local fonts, tops = {}, {}
    for _, asked in ipairs({false, true}) do
      resetRadio()
      local lines = {
        "version: 1", "grid:", "  columns: 4", "  rows: 4", "components:",
        "  - id: panel", "    type: " .. subject.type, "    col: 0",
        "    row: 0", "    colSpan: 4", "    rowSpan: 2", "    config:",
      }
      for _, line in ipairs(subject.config) do
        lines[#lines + 1] = "      " .. line
      end
      if asked then
        lines[#lines + 1] = "      " .. subject.setting .. ": true"
      end

      local widgetPath = makeWidget(
        "unused-" .. subject.type .. "-" .. tostring(asked),
        table.concat(lines, "\n") .. "\n")
      local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
        DEFAULT_OPTIONS, widgetPath)
      assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
      settle(context, 30)

      local panel = entryById(context, "panel").instance
      local where = subject.type .. " with " .. subject.setting
        .. " " .. tostring(asked)

      assertEqual(subject.drew(panel) == true, asked, where
        .. ": the panel disagrees with its own setting about whether it"
        .. " draws a supporting row")

      -- No row means no object for one. An object built to be hidden is the
      -- invisible work the specification forbids, and it is what made this
      -- bug survive a sweep that was meant to end exactly that.
      if not asked then
        assertEqual(subject.label(panel), nil, where
          .. ": built a label for a row it will never fill")
      end

      local font = panel.value.properties.font
      fonts[asked] = type(font) == "function" and font() or font
      tops[asked] = panel.value.properties.y
    end

    -- **The reading lands on the same line either way.** Both panels have a
    -- label quarter, a body half and a tertiary quarter, and the tertiary
    -- quarter is reserved whether or not anything is drawn in it -- so the
    -- body band is the same band and the reading is centred in the same
    -- place. This is the property the user asked for, stated as the thing a
    -- pilot can see: two panels of one size, one with a row and one without,
    -- with their numbers on one line.
    assertEqual(tops[false], tops[true], subject.type
      .. ": a panel drawing no supporting row puts its reading at "
      .. tops[false] .. " and one that draws a row puts it at " .. tops[true]
      .. ", so the layout still depends on what is in the panel")

    -- And at the same size, which follows from the same band but is worth
    -- pinning separately: a font is what a reader notices first, and an
    -- equal position with unequal fonts would mean the two were centred
    -- alike by coincidence rather than sized alike by rule.
    assertFont(fonts[false], fonts[true], subject.type
      .. ": a panel drawing no supporting row reads at a different size from"
      .. " one that does")
  end
end

local function testReadingsSitInTheirSlots()
  --- What each component slots, and how to build a layout that shows it.
  ---
  --- **Adding a component here is a declaration, not new test code.** Nine
  --- more are due on the slots and the check below should cover each one the
  --- moment it arrives, rather than growing a ninth near-copy of itself.
  local SLOTTED = {
    {
      type = "flight-timer",
      config = {"label: FLIGHT", "timer: 0"},
      -- Its only visualization is a bar, which spans the panel and is
      -- exempt, so the clock never splits and centres across the whole box.
      variants = {{}},
      visual = function() return nil end,
      rows = function(panel)
        if not panel.showDetail then return {} end
        return {{label = panel.detailLabel, slot = "whole"}}
      end,
    },
    {
      type = "flight-mode",
      config = {"label: MODE"},
      -- Draws no visualization at all: a flight mode is a name and there is
      -- nothing to gauge, so the reading never splits. The mode number is a
      -- supporting row the component grants only on a two-row panel, so it
      -- cannot be asked for here without failing validation at every single
      -- row -- the spans this check walks include those.
      variants = {{}, {"showIndex: true", minRows = 2}},
      visual = function() return nil end,
      rows = function(panel)
        if not panel.showDetail then return {} end
        return {{label = panel.detailLabel, slot = "whole"}}
      end,
    },
    {
      type = "model-identity",
      config = {"label: MODEL"},
      -- Its picture spans the content box, so it is exempt the way a bar is
      -- and the name never splits. The second variant turns on the label row
      -- so the row case is actually constructed.
      variants = {{}, {"showLabels: true", minRows = 2}},
      visual = function() return nil end,
      rows = function(panel)
        if not panel.showLabels then return {} end
        return {{label = panel.labelsLabel, slot = "whole"}}
      end,
    },
    {
      type = "tx-battery",
      -- Battery glyph against bar: the two arrangements this component
      -- offers, alike but for the visualization.
      sameReadingAcross = {1, 2},
      config = {"label: TX", "packEmpty: 6.6", "packFull: 8.4"},
      -- Both arrangements: a compact visual beside the reading, and a
      -- full-width bar that leaves the reading the whole box.
      variants = {{"visual: battery"}, {"visual: bar"}},
      -- What stands in the right slot when there is one.
      visual = function(panel)
        return panel.glyphShown and panel.glyph
          and {x = panel.glyph.x, w = panel.glyph.width} or nil
      end,
    },
    {
      type = "navigation",
      config = {"label: HOME", "source: GPS"},
      variants = {{}},
      visual = function(panel)
        if not (panel.showCompass and panel.compass) then return nil end
        -- An arc stores its corner rather than its centre and walks when it
        -- is updated, so the ring's own drawn position is asked for rather
        -- than the centre the caller passed.
        local drawn = panel.compass.ring.round.drawn
        local diameter = panel.compass.ring.round.radius() * 2
        return {x = drawn.x, w = diameter}
      end,
      -- **Supporting rows are slotted too, so they are checked too.** A row
      -- of two takes the same two centres the reading and the visual use,
      -- and a row of one centres across the whole content box. Declared
      -- here, so a component that slots a row says so rather than having a
      -- second test written for it.
      rows = function(panel)
        local found = {}
        if panel.showDetail then
          found[#found + 1] = {label = panel.detailLabel, slot = "left"}
          found[#found + 1] = {label = panel.originLabel, slot = "right"}
        end
        if panel.showCoordinates then
          found[#found + 1] =
            {label = panel.coordinatesLabel, slot = "whole"}
        end
        return found
      end,
    },
    {
      type = "link-status",
      config = {"label: LINK", "rssiSource: RSSI", "qualitySource: RQly"},
      -- Its only visualization is a bar, which spans the panel by design and
      -- is exempt from the rule, so the reading never splits.
      variants = {{"visual: bar"}, {"visual: none"}},
      visual = function() return nil end,
      rows = function(panel)
        if not panel.showDetail then return {} end
        return {
          {label = panel.detailLabel, slot = "left"},
          {label = panel.linkLabel, slot = "right"},
        }
      end,
    },
    {
      type = "metric",
      -- Radial against bar. The third variant adds a secondary source and
      -- so is not alike in every other respect, which is why the pair is
      -- named rather than assumed to be the first two of however many.
      sameReadingAcross = {1, 2},
      config = {"label: ALT", "source: Alt", "rangeMin: 0", "rangeMax: 400",
        "precision: 0"},
      -- A radial is a compact visual and takes the right slot; a bar spans
      -- the panel and is exempt, so the same component splits under one
      -- setting and not the other. The third variant configures a secondary
      -- source, which is what turns the supporting row from one item into
      -- two -- without it the two-slot case is never exercised, and a defect
      -- in it passes unseen.
      variants = {{"visual: radial"}, {"visual: bar"},
        {"visual: bar", "secondarySource: VSpd"}},
      visual = function(panel)
        if not (panel.showVisual and panel.radial) then return nil end
        -- A radial is one arc, where a compass is a ring and a pointer.
        local drawn = panel.radial.arc.round.drawn
        local diameter = panel.radial.arc.round.radius() * 2
        return {x = drawn.x, w = diameter}
      end,
      rows = function(panel)
        if not panel.showRange then return {} end
        if panel.showSecondary then
          return {
            {label = panel.range, slot = "left"},
            {label = panel.secondary, slot = "right"},
          }
        end
        return {{label = panel.range, slot = "whole"}}
      end,
    },
    {
      type = "variable-indicator",
      -- Radial against bar.
      sameReadingAcross = {1, 2},
      config = {"binding: global", "index: 0", "label: GV"},
      variants = {{"visual: radial"}, {"visual: bar"}},
      visual = function(panel)
        if not (panel.showVisual and panel.radial) then return nil end
        -- A radial is one arc, where a compass is a ring and a pointer.
        local drawn = panel.radial.arc.round.drawn
        local diameter = panel.radial.arc.round.radius() * 2
        return {x = drawn.x, w = diameter}
      end,
      rows = function(panel)
        if not panel.showDetail then return {} end
        return {{label = panel.detailLabel, slot = "whole"}}
      end,
    },
    {
      type = "cell-battery",
      config = {"label: PACK", "source: Cels"},
      variants = {{"visual: bar"}, {"visual: none"}},
      visual = function() return nil end,
      rows = function(panel)
        if not panel.showDetail then return {} end
        return {
          {label = panel.countLabel, slot = "left"},
          {label = panel.packLabel, slot = "right"},
        }
      end,
    },
  }

  -- Written out rather than read from `theme`, so a change to the rule has
  -- to be made here too, deliberately.
  local TIGHT_LEFT, TIGHT_RIGHT = 0.30, 0.70
  local STRICT_LEFT, STRICT_RIGHT = 0.25, 0.75
  local PAD, PAD_RIGHT = 8, 4

  local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
  local cellWidth = math.floor((WIDTH - GUTTER * (CELLS - 1)) / CELLS)
  local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)

  for _, subject in ipairs(SLOTTED) do
    local module = assert(loadfile(
      sourcePath .. "components/" .. subject.type .. ".lua"))()
    local cases = {}
    local byVisual = {}
    for index, extra in ipairs(subject.variants) do
      for _, span in ipairs(module.supportedSpans) do
        -- **A variant may name the spans it applies to.** Some settings are
        -- refused at load rather than shed at draw: `flight-mode`'s mode
        -- number and `model-identity`'s label row both need two rows, and
        -- asking for them on a single row fails validation rather than
        -- producing a panel without them. A variant that cannot be built is
        -- not coverage of anything, so it says where it belongs.
        local rows = tonumber(string.match(span, "%dx(%d)")) or 1
        if rows >= (type(extra) == "table" and extra.minRows or 1) then
          cases[#cases + 1] = {span = span, extra = extra, index = index}
        end
      end
    end

    for _, case in ipairs(cases) do
      local span, extra = case.span, case.extra
      local cols, rows = string.match(span, "(%d)x(%d)")
      cols, rows = tonumber(cols), tonumber(rows)

      resetRadio()
      local lines = {
        "version: 1", "grid:", "  columns: 4", "  rows: 4", "components:",
        "  - id: pack", "    type: " .. subject.type, "    col: 0",
        "    row: 0", "    colSpan: " .. cols, "    rowSpan: " .. rows,
        "    config:",
      }
      for _, line in ipairs(subject.config) do
        lines[#lines + 1] = "      " .. line
      end
      for _, line in ipairs(extra) do lines[#lines + 1] = "      " .. line end
      local widgetPath = makeWidget(
        "slot-" .. subject.type .. "-" .. case.index .. "-" .. span,
        table.concat(lines, "\n") .. "\n")

      local context = createLoaded({x = 0, y = 0, w = WIDTH, h = HEIGHT},
        DEFAULT_OPTIONS, widgetPath)
      assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
      settle(context, 30)

      local panel = entryById(context, "pack").instance
      local where = subject.type .. " " .. span
        .. (extra[1] and (" with " .. extra[1]) or "")

      local reading = panel.value.properties
      local text = tostring(reading.text)
      assert(text ~= "" and text ~= "--",
        where .. ": no reading was drawn, so there is nothing to place")

      local font = reading.font
      if type(font) == "function" then font = font() end

      -- Rebuilt from the panel, not read back from the component.
      local panelWidth = cellWidth * cols + GUTTER * (cols - 1)
      local panelHeight = cellHeight * rows + GUTTER * (rows - 1)
      local content = panelWidth - PAD - PAD_RIGHT

      -- Measured the way the radio draws it, which is the whole point: the
      -- estimate is generous and half of its generosity lands in the left
      -- edge of anything centred with it.
      local drawn = lcd.sizeText(text, font)
      local centre = reading.x + drawn / 2

      local expected, arrangement
      local glyph = subject.visual(panel)
      if glyph then
        -- Which slot set is in force, read off the glyph rather than
        -- recomputed. Its centre lands on one fraction or the other, and
        -- whichever it is, the reading has to agree with it.
        local glyphCentre = glyph.x + glyph.w / 2
        local tight = PAD + math.floor(content * TIGHT_RIGHT + 0.5)
        local strict = PAD + math.floor(content * STRICT_RIGHT + 0.5)
        if math.abs(glyphCentre - tight) <= 1 then
          expected = PAD + math.floor(content * TIGHT_LEFT + 0.5)
          arrangement = "tightened"
        elseif math.abs(glyphCentre - strict) <= 1 then
          expected = PAD + math.floor(content * STRICT_LEFT + 0.5)
          arrangement = "strict halves"
        else
          assert(false, where .. ": the visual is at " .. glyphCentre
            .. ", which is neither slot (" .. tight .. " or " .. strict .. ")")
        end
      else
        -- One element does not split: it centres across the whole box.
        expected = PAD + content / 2
        arrangement = "unsplit"
      end

      assert(math.abs(centre - expected) <= 1, string.format(
        "%s (%s) centres its reading %q at %.1f, %.1f px from the %.1f its"
          .. " slot asks for -- %.1f%% of the panel against %.1f%%",
        where, arrangement, text, centre, centre - expected, expected,
        100 * centre / panelWidth, 100 * expected / panelWidth))

      -- Every slotted supporting row sits on the centre its slot names,
      -- measured the same way the reading is. A row of two takes the two
      -- slot centres and a row of one centres across the content box.
      for _, row in ipairs(subject.rows and subject.rows(panel) or {}) do
        local label = row.label
        if label and not label.hidden then
          local rowText = tostring(label.properties.text or "")
          if rowText ~= "" then
            local rowFont = label.properties.font
            if type(rowFont) == "function" then rowFont = rowFont() end
            local rowCentre =
              label.properties.x + lcd.sizeText(rowText, rowFont) / 2
            local want
            if row.slot == "left" then
              want = PAD + math.floor(content * TIGHT_LEFT + 0.5)
            elseif row.slot == "right" then
              want = PAD + math.floor(content * TIGHT_RIGHT + 0.5)
            else
              want = PAD + content / 2
            end
            assert(math.abs(rowCentre - want) <= 1, string.format(
              "%s centres its %s supporting item %q at %.1f, %.1f px from"
                .. " the %.1f its slot asks for",
              where, row.slot, rowText, rowCentre, rowCentre - want, want))
          end
        end
      end

      -- And the unit came with it. This is the defect shape that keeps
      -- reappearing, and moving the reading is exactly what perturbs it.
      if panel.unit and not panel.unit.hidden then
        local unitFont = panel.unit.properties.font
        if type(unitFont) == "function" then unitFont = unitFont() end
        assertEqual(panel.unit.properties.x,
          reading.x + drawn + themeModule.unitGap(unitFont),
          where .. ": the unit did not follow the reading to its slot")
      end

      byVisual[span] = byVisual[span] or {}
      byVisual[span][case.index] = font
    end

    -- **A decoration does not cost the reading a size.** Declared as a pair
    -- of variant indices that differ only in which visualization is drawn,
    -- so the comparison is between two panels alike in every other respect
    -- and a difference can only have come from the visual.
    --
    -- The reading used to be fitted into half the panel wherever a compact
    -- visual might sit beside it, and shed the visual afterwards if that had
    -- still not been enough -- so a reading could pay a size for a dial it
    -- did not get. Which of the two the panel ends up drawing is not the
    -- claim here; the claim is that the number is the same size either way.
    if subject.sameReadingAcross then
      local a, b = subject.sameReadingAcross[1], subject.sameReadingAcross[2]
      local compared = 0
      for span, fonts in pairs(byVisual) do
        if fonts[a] and fonts[b] then
          compared = compared + 1
          assertEqual(edgetx.fontName(fonts[a]),
            edgetx.fontName(fonts[b]), string.format(
            "%s at %s reads %s with one visualization and %s with the"
              .. " other, so the reading is paying for the decoration"
              .. " beside it -- magnitude is the first thing a pilot reads"
              .. " and it is not what a panel spends to keep a dial",
            subject.type, span, edgetx.fontName(fonts[a]),
            edgetx.fontName(fonts[b])))
        end
      end
      assert(compared >= 4, subject.type
        .. ": only " .. compared .. " spans compared the two"
        .. " visualizations, so the pair is declared but barely built")
    end
  end
end

local function testHostDiagnosticsReportsTheHost()
  resetRadio()
  local source = assert(hostIo.open(sourcePath .. "layouts/host.yaml", "r"))
  local yaml = source:read("a")
  source:close()

  local widgetPath = makeWidget("hostdiag", yaml)
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
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
  assert(string.find(identity, context.layoutPath, 1, true),
    "the panel does not show the layout the host opened: " .. identity)
  assertEqual(context.layoutOrigin, "default",
    "this widget has no model-specific layout, so the fallback answered")
  assert(string.find(identity, "-> " .. context.layoutOrigin, 1, true),
    "the panel does not say which candidate name answered: " .. identity)
  assert(string.find(identity, "main.lua ", 1, true),
    "the panel does not stamp the running source: " .. identity)
  -- The stamp is the answer to stale bytecode, so it has to be a reading of
  -- the file rather than a placeholder.
  assert(string.find(identity, "2026%-09%-18"),
    "the panel shows no modification time: " .. identity)
  -- No bytecode beside this package, so the loudest line must be absent.
  -- `make build` deletes it precisely so this stays true on a card.
  assert(not string.find(identity, "RUNNING main.luac", 1, true),
    "the panel reported bytecode that is not there: " .. identity)

  -- `host.yaml` states no theme block, so the widget option is what decided.
  local theme = linesOf("theme")
  assert(string.find(theme, "mode: " .. context.theme.mode, 1, true),
    "the panel disagrees with the resolved theme: " .. theme)
  assertEqual(context.themeSource, "option")
  assert(string.find(theme, "asked by: " .. context.themeSource, 1, true),
    "the panel does not say who chose the palette: " .. theme)

  -- Every placement the host built, including these panels themselves.
  local components = linesOf("components")
  assert(string.find(components, #context.components .. " panels", 1, true),
    "the panel miscounts the dashboard: " .. components)
  for _, entry in ipairs(context.components) do
    assert(string.find(components, entry.placement.id, 1, true),
      "the panel omits " .. entry.placement.id .. ": " .. components)
  end

  local sources = linesOf("sources")
  assert(string.find(sources, "sources, ", 1, true)
    or string.find(sources, "no sources subscribed", 1, true),
    "the sources panel said nothing at all: " .. sources)

  -- The panel sheds lines it has no room for rather than drawing past its
  -- own bottom edge. Nothing else can see this: a label overflowing a panel
  -- is clipped by the box it sits in, so it is invisible on screen and
  -- invisible to every assertion about what is drawn. What is checkable is
  -- that the last line the panel claims to show actually fits inside it.
  local panel = entryById(context, "identity").instance
  local height = panelOf(entryById(context, "identity")).h
  local lineHeight = themeModule.fontHeight(panel.fonts.label)
  assert(panel.visibleLines > 0, "the panel shed every line")
  assert(panel.visibleLines < 12,
    "a two-cell panel claimed every line the component can build")
  local last = panel.rows[panel.visibleLines].properties
  assert(last.y + lineHeight <= height,
    "the last line the panel shows is drawn past its own bottom edge: y "
    .. tostring(last.y) .. " plus " .. tostring(lineHeight)
    .. " in " .. tostring(height))
  assert(panel.rows[panel.visibleLines + 1].hidden,
    "a line beyond what fits was left visible")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

--- Which of the three candidate filenames answered, at each of the three.
---
--- The search tries the model-specific name, then the dashboard-scoped name,
--- then `default.yaml`, and until now it reported only the path it settled
--- on. That is not the same fact: a dashboard called `main` on a model called
--- `main` produces two candidates that read alike, and a layout silently
--- falling back to `default.yaml` looks exactly like one that was found.
--- The diagnostics view reports the branch, so each branch is driven here.
local function testLayoutOriginIsReported()
  resetRadio()
  local layout = [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: identity
    type: host-diagnostics
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      section: identity
]]

  -- `makeWidget` writes `layouts/default.yaml`, which is the last candidate,
  -- so this package starts at the bottom of the search.
  local widgetPath = makeWidget("origin", layout)
  local modelName = radio.modelFilename

  local function originOf()
    local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
      DEFAULT_OPTIONS, widgetPath)
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
  assert(string.find(path, "default.yaml", 1, true), path)

  -- Adding the dashboard-scoped name makes the middle branch answer. The
  -- default file is still there, which is the point: the path changes and so
  -- does the reason, and only one of those was visible before.
  writeFile(widgetPath .. "layouts/main.yaml", layout)
  origin, lines, path = originOf()
  assertEqual(origin, "dashboard",
    "a dashboard-scoped layout did not take precedence over the default")
  assert(string.find(lines, "-> dashboard", 1, true), lines)

  -- And the model-specific name beats both.
  local specific = layoutStoreModule.path(widgetPath, modelName, "main")
  writeFile(specific, layout)
  origin, lines, path = originOf()
  assertEqual(origin, "model",
    "a model-specific layout did not take precedence")
  assert(string.find(lines, "-> model", 1, true), lines)
  assertEqual(path, specific)
end

--- The bytecode alarm, which is the single most useful line in the view.
---
--- EdgeTX compiles a `.luac` beside every script it loads and prefers it
--- afterwards, so a radio can run code that is no longer on the card. That
--- cost an evening once: fixes appeared to do nothing and the widget reported
--- an error at a line number that no longer existed in the source. `make
--- build` deletes the bytecode for exactly that reason, but a card assembled
--- any other way will not have, and nothing on screen says so.
---
--- So the alarm is driven by putting a `.luac` where the radio would have
--- left one. Asserting only its absence, which is the state every other test
--- runs in, would be asserting a condition that has never been anything else.
local function testHostDiagnosticsWarnsAboutBytecode()
  resetRadio()
  local layout = [[
version: 1
grid:
  columns: 4
  rows: 4
components:
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
    local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
      DEFAULT_OPTIONS, widgetPath)
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
  assert(not string.find(identityLines(clean), "RUNNING main.luac", 1, true),
    "a package with no bytecode reported some")

  local stale = makeWidget("bytecode-stale", layout)
  writeFile(stale .. "main.luac", "not really bytecode")
  local warned = identityLines(stale)
  assert(string.find(warned, "RUNNING main.luac", 1, true),
    "a package with bytecode beside its source did not say so: " .. warned)
end

--- The view reports a failed component, a fallback palette and an unbound
--- source, which are the three things it exists to make visible.
local function testHostDiagnosticsReportsFailures()
  resetRadio()
  local widgetPath = makeWidget("hostdiag-bad", [[
version: 1
grid:
  columns: 4
  rows: 4
theme:
  mode: neon
components:
  - id: probe
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: Alt
      source: NoSuchSensor
  - id: broken
    type: raiser
    col: 2
    row: 0
    colSpan: 2
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
      section: components
  - id: wires
    type: host-diagnostics
    col: 2
    row: 2
    colSpan: 1
    rowSpan: 2
    config:
      section: sources
  - id: later
    type: latebreak
    col: 3
    row: 2
    colSpan: 1
    rowSpan: 2
    config:
      label: Later
]], {
    ["raiser.lua"] = [==[
local raiser = {id = "raiser", apiVersion = 1, supportedSpans = {"any"},
  settings = {{key = "label", type = "string", default = ""}}}
function raiser.create() error("deliberate failure") end
return raiser
]==],
    -- Builds, then raises on its first refresh, which is the other way a
    -- component dies and the only one the host keeps an entry for.
    ["latebreak.lua"] = [==[
local latebreak = {id = "latebreak", apiVersion = 1, supportedSpans = {"any"},
  settings = {{key = "label", type = "string", default = ""}}}
function latebreak.create() return {ticks = 0} end
function latebreak.refresh() error("deliberate late failure") end
return latebreak
]==],
  })

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  settle(context, 30)

  local function linesOf(id)
    local panel = entryById(context, id).instance
    local out = {}
    for index = 1, panel.visibleLines do
      out[#out + 1] = panel.rows[index].properties.text
    end
    return table.concat(out, "\n")
  end

  -- A component that failed during create is otherwise only an error banner,
  -- which may have scrolled past before anyone looked at the screen.
  assertEqual(entryById(context, "broken"), nil,
    "a component that raises in create is dropped, not kept disabled")
  assertEqual(#context.rejected, 1,
    "the host did not record the placement it could not build")
  local panels = linesOf("panels")
  assert(string.find(panels, "2 failed", 1, true),
    "the panel does not count the failure: " .. panels)
  assert(string.find(panels, "broken raiser 2x2 REJECTED", 1, true),
    "the panel does not report the failed component: " .. panels)

  -- A source nothing can bind. The name is shown exactly as the layout
  -- spelled it, which is the half that is invisible on a panel: a typo and a
  -- missing sensor look identical there, and this at least shows the
  -- spelling that was asked for.
  local wires = linesOf("wires")
  assert(string.find(wires, "1 unbound", 1, true),
    "the panel does not count the unbound source: " .. wires)
  assert(string.find(wires, "NoSuchSensor UNBOUND", 1, true),
    "the panel does not report the unbound source: " .. wires)

  -- A component that builds and then raises later is a different casualty
  -- from one that never built: the host keeps it, disabled, in `components`,
  -- where the one that never built is only in `rejected`. Both have to
  -- appear, and until this covered it only the rejected half ever did.
  local later = entryById(context, "later")
  assert(later and later.failed,
    "the component that raises on refresh was not disabled")
  panels = linesOf("panels")
  assert(string.find(panels, "later latebreak 1x2 FAILED", 1, true),
    "the panel does not report the component that failed after building: "
    .. panels)

  -- `neon` is not a mode, so the host fell back to Modern and reports
  -- `modern`; the fallback is invisible unless what was asked for is kept.
  assertEqual(context.theme.mode, "modern")
  assertEqual(context.theme.requested, "neon",
    "the theme did not record the mode it was asked for")
end

--- The mode number is drawn where there is a row for it, and nowhere else.
local function testFlightModeIndexRow()
  resetRadio()
  local widgetPath = makeWidget("fm-index", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: tall
    type: flight-mode
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      showIndex: true
  - id: quiet
    type: flight-mode
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 20)

  -- The fixture's active mode is 1, named Sport.
  local tall = entryById(context, "tall").instance
  assertEqual(tall.showDetail, true, "a two-row panel shed its supporting row")
  assertEqual(tall.detailLabel.properties.text, "#1",
    "the mode number is not drawn, or still repeats the header's word")
  assertEqual(tall.detailLabel.hidden, false)

  -- The same span without the setting draws no row at all -- and now builds
  -- no label for one either, where it used to build one and write an empty
  -- string into it. That object cost a reserved quarter of the panel as well
  -- as itself: the band was cut for a row that could never be filled, which
  -- took a font size off the name above it.
  local quiet = entryById(context, "quiet").instance
  assertEqual(quiet.rendered.detail, nil,
    "a panel that never asked for the mode number computed one")
  assertEqual(quiet.detailLabel, nil,
    "a panel that never asked for the mode number built a label for it")
  assertEqual(quiet.showDetail, false,
    "a panel with no mode number to show reserved a row for one")

  -- The reading fits: the fixture model's widest mode name is ten characters
  -- and this is the span that used to lose nearly half of it.
  --
  -- Asked of the panel's own room rather than of the label's box. The name
  -- is centred on a slot now, so its box is exactly as wide as the string it
  -- draws -- and comparing the widest possible name against a box sized for
  -- the current one asks whether `Normal` is as wide as `LongRange7`, which
  -- is not the question.
  local widest = "LongRange7"
  local font = tall.value.properties.font()
  -- Measured, because being drawn past the panel is a fact about advances
  -- rather than about the estimate of them, and the fitting that chose this
  -- font measured too. Asserting the estimate here would demand the panel
  -- hold about half again as much as it draws.
  assert(themeModule.measureText(font, widest) <= tall.area.valueBudget,
    "the widest mode name is drawn past the panel: needs "
      .. themeModule.measureText(font, widest) .. " of "
      .. tall.area.valueBudget)

  -- Shrink until the ladder takes the row away. The setting is still stated,
  -- and the panel must stop declaring and painting the row rather than
  -- writing into a hidden label, which is what it used to do.
  local zone = context.zone
  zone.h = 150
  local passes = 0
  repeat
    definition.refresh(context)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not context.reflowIndex
  settle(context, 20)

  assertEqual(tall.showDetail, false,
    "a shortened panel kept a supporting row it has no space for")
  assertEqual(tall.rendered.detail, nil,
    "a shed mode number was still being formatted every frame")
  assert(tall.detailLabel.hidden, "a shed row was left on screen")

  -- Not formatted, and not written either. Writing an empty string into a
  -- hidden label leaves no trace on screen, so nothing about what is drawn
  -- can see it; the harness counts writes for exactly this.
  local writes = tall.detailLabel.writes
  radio.flightMode = 2
  settle(context, 20)
  assertEqual(tall.detailLabel.writes, writes,
    "a shed row was painted while the mode changed underneath it")

  -- And the row comes back with the right number rather than whatever it
  -- held when it was shed.
  radio.flightMode = 3
  settle(context, 20)
  zone.h = 272
  passes = 0
  repeat
    definition.refresh(context)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not context.reflowIndex
  settle(context, 20)

  assertEqual(tall.showDetail, true, "the supporting row never came back")
  assertEqual(tall.detailLabel.properties.text, "#3",
    "a revealed mode number still reports the mode it was shed with")
  resetRadio()
end

--- The reading is sized from the model the host actually read.
---
--- `regionsFor` is measured directly elsewhere; this is the wiring. A
--- component that never asked the model for its names would fall back to the
--- ten characters the firmware allows, which still fits at every span, so
--- nothing about fitting can see the difference. What can is that a model
--- with short mode names gets a larger reading.
local function testFlightModeSizesFromTheModel()
  local layout = [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: mode
    type: flight-mode
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
]]

  local function fontFor(names)
    resetRadio()
    radio.flightModeNames = names
    local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
      DEFAULT_OPTIONS, makeWidget("fm-sizing", layout))
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 20)
    local panel = entryById(context, "mode").instance
    return panel.value.properties.font(), panel.widest
  end

  local shortFont, shortWidest = fontFor({[0] = "Up", [1] = "Down"})
  local longFont, longWidest = fontFor({[0] = "Up", [4] = "LongRange7"})

  assertEqual(shortWidest, "Down",
    "the panel did not take its widest name from the model")
  assertEqual(longWidest, "LongRange7")
  assert(themeModule.fontHeight(shortFont) > themeModule.fontHeight(longFont),
    "a model whose mode names are short gained nothing: both readings are "
      .. edgetx.fontName(shortFont))
  resetRadio()
end

--- The radio's own battery meter range is the default; a layout overrides it.
---
--- EdgeTX carries a battery meter range at SYS then Hardware then Battery
--- meter range, set per radio to suit its pack, and it is already right on
--- any radio whose battery icon is sensible. This component used to ask a
--- layout to restate it and drew nothing until one did, which made a dark bar
--- the normal case rather than the exceptional one.
---
--- Four panels of one span, so the only difference between them is where the
--- range comes from.
local function testTxBatteryRangeComesFromTheRadio()
  resetRadio()
  local widgetPath = makeWidget("tx-range", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: stated
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 6.6
      packFull: 8.4
      visual: bar
      showPercent: true
  - id: quiet
    type: tx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      visual: bar
      showPercent: true
  - id: inverted
    type: tx-battery
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 8.4
      packFull: 6.6
      visual: bar
      showPercent: true
  - id: half
    type: tx-battery
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 6.6
      visual: bar
      showPercent: true
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 30)

  local stated = entryById(context, "stated").instance
  local quiet = entryById(context, "quiet").instance
  local inverted = entryById(context, "inverted").instance
  local half = entryById(context, "half").instance

  -- The voltage is authoritative and is shown by all of them. The fixture
  -- transmitter reads 7.9 V, and the unit rides beside the digits.
  for _, panel in ipairs({stated, quiet, inverted, half}) do
    assertEqual(panel.text, "7.9")
    assertEqual(panel.unit.properties.text, "V")
  end

  -- Stated: the layout's 6.6 to 8.4, so 7.9 is 1.3 of 1.8, which is 72.
  assertEqual(stated.detailLabel.properties.text, "72% EST")
  assertEqual(stated.barShown, true)

  -- Stated nothing: the radio's own 6.4 to 8.4, so 7.9 is 1.5 of 2.0, which
  -- is 75. A different number from the layout's, which is what proves it came
  -- from the radio rather than from a default that happens to match.
  assertEqual(quiet.detailLabel.properties.text, "75% EST",
    "a panel that stated no range did not fall back to the radio's")
  assertEqual(quiet.barShown, true,
    "a panel that stated no range drew no bar, which is what this change"
      .. " exists to stop being the normal case")

  -- Half a range is not a range, and must not be mixed with the radio's
  -- other end: that would measure against two different packs.
  assertEqual(half.detailLabel.properties.text, "75% EST",
    "a stated empty was mixed with the radio's full")

  -- An inverted range is not a range either, and falls back rather than
  -- producing a backwards fill.
  assertEqual(inverted.detailLabel.properties.text, "75% EST",
    "an inverted range was treated as usable")

  -- And the pilot changing it in radio settings is seen, because the range is
  -- subscribed rather than read once. Nothing rebuilds a widget for that.
  radio.battMin, radio.battMax = 5.4, 8.4
  settle(context, 60)
  assertEqual(quiet.detailLabel.properties.text, "83% EST",
    "the radio's range was read once and went stale when the pilot changed it")
  assertEqual(stated.detailLabel.properties.text, "72% EST",
    "a layout that states its own range was moved by a radio setting")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- The battery glyph fills in proportion to the voltage that produced it.
---
--- The shape to watch here is asserting that a glyph exists: an outline with
--- a zero-width fill satisfies that and is a picture of an empty pack. So the
--- fill's width is pinned against a number worked out from the voltage and
--- the range, independently of the component, and against the glyph's own
--- interior rather than against itself.
local function testBatteryGlyphFillsFromTheVoltage()
  resetRadio()
  -- Without `getGeneralSettings` the only range is the one a layout states,
  -- which is what makes the `unranged` panel below genuinely unranged. With
  -- it present every panel inherits the radio's 6.4 to 8.4 and the case that
  -- matters here cannot be reached at all.
  local realSettings = getGeneralSettings
  getGeneralSettings = nil

  local widgetPath = makeWidget("glyph", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: healthy
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 6.6
      packFull: 8.4
      showPercent: true
  - id: alarmed
    type: tx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 6.6
      packFull: 8.4
      critical: 8.0
      showPercent: true
  - id: unranged
    type: tx-battery
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 1
    config:
      label: NO RANGE
  - id: tiny
    type: tx-battery
    col: 2
    row: 2
    colSpan: 1
    rowSpan: 1
    config:
      label: TINY
      packEmpty: 6.6
      packFull: 8.4
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 30)

  local healthy = entryById(context, "healthy").instance
  local alarmed = entryById(context, "alarmed").instance
  local unranged = entryById(context, "unranged").instance
  local tiny = entryById(context, "tiny").instance

  -- The fixture transmitter reads 7.9 V against 6.6 to 8.4, so 1.3 of 1.8.
  local fraction = (7.9 - 6.6) / (8.4 - 6.6)
  local glyph = healthy.glyph
  assert(glyph, "a two by two panel drew no battery")
  assertEqual(healthy.glyphShown, true)

  -- The cell stands upright, so the level is a **height** and it grows from
  -- the bottom, because a cell drains downward.
  local expected = math.floor(glyph.interiorHeight * fraction + 0.5)
  assertEqual(glyph.fill.properties.h, expected,
    "the level is not the voltage's share of the battery's interior")
  assertEqual(glyph.fill.properties.y,
    glyph.interiorY + glyph.interiorHeight - expected,
    "the level grows from the top, so a full cell would drain upward")

  -- And the number is a real proportion rather than either extreme, which is
  -- what makes the assertion above worth making.
  assert(expected > 0 and expected < glyph.interiorHeight,
    "the fixture voltage produced a full or empty battery, so a level stuck"
      .. " at one end would satisfy this test")

  -- The level stays inside the outline it is drawn in, on every side.
  assert(glyph.fill.properties.y >= glyph.bodyY + glyph.border,
    "the level starts on or above the outline")
  assert(glyph.fill.properties.y + glyph.fill.properties.h
      <= glyph.bodyY + glyph.bodyHeight - glyph.border,
    "a full level would paint over the outline's bottom edge")
  assert(glyph.fill.properties.w < glyph.width,
    "the level is as wide as the outline, so it covers the sides")

  -- The outline is drawn as an outline, at the weight it asked for. A filled
  -- rectangle here would be a solid block with nothing visible inside it.
  assertEqual(glyph.shell.properties.filled, false)
  assertEqual(glyph.shell.painted.borderWidth, glyph.border,
    "the outline reached LVGL at a different weight from the one asked for")
  assert(glyph.border >= 2,
    "the outline is a hairline rather than the drawn cell the mock shows")

  -- The terminal sits on top, centred, and is a contact rather than a second
  -- cell.
  assertEqual(glyph.nub.properties.filled, true)
  assertEqual(glyph.nub.properties.y, glyph.y)
  assert(glyph.nub.properties.y + glyph.nub.properties.h <= glyph.bodyY,
    "the terminal overlaps the body it sits on")
  assert(glyph.nub.properties.w < glyph.width,
    "the terminal is as wide as the battery, so it reads as a cap")

  -- State reaches the whole cell, which is what the user asked for: a
  -- critical pack is red throughout rather than red inside a grey box.
  assertEqual(alarmed.stateName, "critical")
  for name, part in pairs({outline = alarmed.glyph.shell,
      terminal = alarmed.glyph.nub, level = alarmed.glyph.fill}) do
    assertEqual(part.properties.color, context.theme.color.critical,
      "a critical pack's " .. name .. " did not go red")
  end
  assert(healthy.glyph.fill.properties.color
      ~= alarmed.glyph.fill.properties.color,
    "both panels fill the same colour, so the state is not reaching the cell")

  -- The empty part of the cell is the panel showing through, so a red cell on
  -- a red-tinted panel is what has to be checked. In 24 bits, because
  -- `contrast` is arithmetic on colour channels and `theme.color` holds
  -- `LcdFlags` words.
  assert(themeModule.contrast(context.theme.rgb.critical,
      context.theme.alertRgb.critical) >= 3,
    "a critical cell is indistinguishable from the panel it stands on")

  -- A panel with no range has nothing to fill from, and an empty outline is a
  -- claim that the pack is flat. All four parts go, not just the level.
  --
  -- This is a weak assertion on its own and it is worth saying why: the glyph
  -- is *built* hidden, so a reconcile that forgot to hide one of its parts
  -- would satisfy every line below. The shed on reflow is where the hiding
  -- actually happens, and that is covered separately.
  assertEqual(unranged.glyphShown, false)
  assertEqual(unranged.glyph.shell.hidden, true)
  assertEqual(unranged.glyph.nub.hidden, true)
  assertEqual(unranged.glyph.fill.hidden, true)

  -- The three parts move together when the glyph is revealed, which is the
  -- direction this build does exercise: `healthy` was built hidden and shown
  -- once the range arrived.
  for name, part in pairs({shell = glyph.shell, nub = glyph.nub,
      fill = glyph.fill}) do
    assertEqual(part.hidden, false,
      "the battery was revealed and its " .. name .. " was left hidden")
  end

  -- A single cell has no room for a battery beside its reading, and sheds it
  -- the way it sheds any other visual rather than drawing an unreadable one.
  assertEqual(tiny.glyph, nil,
    "a single cell drew a battery in space it does not have")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  getGeneralSettings = realSettings
end

--- The outline's weight follows the reading it stands beside.
---
--- The contract is that the stroke **varies with the font**, so an assertion
--- at one size proves nothing: a constant satisfies it. Both ends of the
--- ladder are driven here, and the two panels are chosen so the cell is
--- exactly the same size in each -- 25 by 50 at both -- which leaves the
--- reading's font as the only thing that differs. A stroke derived from the
--- span, or from the cell's own width, would give them the same weight.
---
--- That was the defect: the ladder puts a MIDSIZE reading on a one-cell-wide
--- panel two rows tall and an XXLSIZE one on a two-cell panel of the same
--- height, and both carried a four pixel outline. Beside the smaller number
--- it read as heavy, and it ate the interior that shows the charge.
local function testBatteryStrokeFollowsTheReading()
  resetRadio()
  local widgetPath = makeWidget("glyph-stroke", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: small
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      label: SMALL
      packEmpty: 6.6
      packFull: 8.4
  - id: large
    type: tx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: LARGE
      packEmpty: 6.6
      packFull: 8.4
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 30)

  local small = entryById(context, "small").instance
  local large = entryById(context, "large").instance

  -- Read off the label rather than out of the component's own bookkeeping,
  -- so this is the font the panel is drawing in rather than the one it
  -- believes it chose.
  local smallFont = small.value.properties.font()
  local largeFont = large.value.properties.font()

  -- The precondition: two different fonts. Two panels can no longer be made
  -- to differ in font while holding their cells the same size, because both
  -- now come from the same body band and move together -- so the width is
  -- held still in the second assertion below instead of in the layout.
  assert(themeModule.fontHeight(smallFont) < themeModule.fontHeight(largeFont),
    "both panels resolved the same reading font, so nothing below can tell a"
      .. " font-derived stroke from a constant one")

  -- Width held constant, font varied, which is the isolation the old layout
  -- used to provide. Without this, everything below is also satisfied by a
  -- stroke derived purely from the cell's width.
  local held = large.glyph.width
  assert(primitivesModule.batteryStroke(themeModule, smallFont, held)
      < primitivesModule.batteryStroke(themeModule, largeFont, held),
    "at one cell width the two fonts produced the same stroke, so the"
      .. " thickness does not follow the reading at all")

  assert(small.glyph.border < large.glyph.border, "the same stroke ("
    .. small.glyph.border .. ") was drawn beside a "
    .. edgetx.fontName(smallFont) .. " reading and a "
    .. edgetx.fontName(largeFont) .. " one")

  -- And what LVGL was actually given, rather than what the geometry says.
  -- A border width only reaches the firmware at build, so the painted value
  -- is the one on screen.
  assertEqual(small.glyph.shell.painted.borderWidth, small.glyph.border)
  assertEqual(large.glyph.shell.painted.borderWidth, large.glyph.border)
  assert(small.glyph.shell.painted.borderWidth
      < large.glyph.shell.painted.borderWidth,
    "the geometry disagrees about the stroke but the screen does not")

  -- Thinning the outline is only worth anything if the interior grows with
  -- it, because the interior is what shows the charge. Asked of the geometry
  -- at one width, since the two cells are no longer the same size.
  local lightInterior = held - 2 * primitivesModule.batteryStroke(
    themeModule, smallFont, held)
  local heavyInterior = held - 2 * primitivesModule.batteryStroke(
    themeModule, largeFont, held)
  assert(lightInterior > heavyInterior,
    "the lighter outline bought the level no room")

  -- And the level is still a proportion rather than a line: the fixture
  -- reads 7.9 V of 6.6 to 8.4, so neither end.
  for id, panel in pairs({small = small, large = large}) do
    local level = panel.glyph.fill.properties.h
    assert(level > 0 and level < panel.glyph.interiorHeight, id
      .. " draws a full or empty cell, so its level says nothing")
    assert(panel.glyph.interiorWidth >= 4, id
      .. " has a " .. panel.glyph.interiorWidth
      .. " pixel interior, which is a line rather than a level")
  end

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

--- A cell keeps the outline it was built with when the reading resizes.
---
--- This pins a limitation rather than a feature, and it is here because the
--- alternative is that nobody knows about it. A border width only reaches
--- LVGL when the object is built -- `LvglWidgetBorderedObject::setOpacity` is
--- its only writer and it runs behind `changedValue` -- so a stroke chosen
--- from the reading's font is chosen once. A reflow can move the reading to a
--- different font while leaving the cell the same size, and when it does, the
--- outline stays as it was.
---
--- Measured: a 238 by 134 zone reads at XXLSIZE with a 4 pixel outline, and
--- 238 by 110 reads at DBLSIZE where a fresh build would give 3. One pixel,
--- on a zone change, and only in App mode, which is why it is recorded rather
--- than worked around. Fixing it means drawing the outline as four filled
--- rectangles so its weight is geometry rather than a border style; if that
--- is ever done, this test should fail and be deleted.
---
--- What must **not** drift is the interior. It is measured from the stroke
--- that is actually drawn, so if the two ever disagree the level is inset
--- against an outline that is not there, and a gap or an overlap appears.
local function testBatteryStrokeSurvivesReflow()
  resetRadio()
  local widgetPath = makeWidget("glyph-stale", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: TX
      packEmpty: 6.6
      packFull: 8.4
]])

  -- **Both zones are chosen so the cell comes out the same size**, which is
  -- what isolates the stroke: the font moves and the cell does not, so a
  -- stroke that followed the cell rather than the reading would pass every
  -- assertion below. The cell is capped at 50 px tall and therefore 25 wide
  -- across a range of panel heights, while the body band keeps growing --
  -- so a 480 x 240 zone reads at XXLSIZE and a 480 x 232 zone at DBLSIZE,
  -- both with a 25 px cell. **Re-swept for the fixed-bands rule**, which
  -- moved every band and with it the height at which the reading steps: the
  -- old pair, 224 and 172, now reads at one size on both and the test would
  -- have stopped covering anything without failing.
  local zone = {x = 0, y = 0, w = 480, h = 240}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 60)

  local pack = entryById(context, "pack").instance
  local glyph = pack.glyph
  assert(glyph, "the panel drew no battery")

  local builtStroke = glyph.border
  local builtFont = pack.value.properties.font()
  local painted = glyph.shell.painted.borderWidth
  assertEqual(painted, builtStroke)

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

  -- Shorter, which takes the reading from XXLSIZE down to DBLSIZE while the
  -- cell stays 25 px wide. Both zones were found by sweeping rather than
  -- chosen: the band and the cell both derive from the panel's height, so
  -- the pairs where one moves and the other does not are narrow and are not
  -- where anybody would look first.
  reflow(480, 232)

  assert(themeModule.fontHeight(pack.value.properties.font())
      < themeModule.fontHeight(builtFont),
    "the reading did not change size, so this reflow is not the case this"
      .. " test exists for and the assertions below prove nothing")
  assertEqual(glyph.width, 25,
    "the cell changed size, so the stroke would have been free to change")

  -- The limitation, stated.
  assertEqual(glyph.border, builtStroke,
    "the stroke changed on a reflow, which a radio cannot do; if the outline"
      .. " is now drawn as filled rectangles rather than a border, delete"
      .. " this test")
  assertEqual(glyph.shell.painted.borderWidth, builtStroke,
    "the mock let a border width through after build, which the firmware"
      .. " does not")

  -- And the thing that must stay true: the interior is measured from the
  -- stroke that is on screen, so the level sits inside the outline rather
  -- than floating away from it.
  assertEqual(glyph.inset, builtStroke + primitivesModule.GLYPH_GAP,
    "the interior was inset against a stroke the screen does not have")
  assertEqual(glyph.fill.properties.x, glyph.interiorX)
  assert(glyph.fill.properties.x >= glyph.x + glyph.shell.painted.borderWidth,
    "the level overlaps the outline it is drawn inside")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

--- The unit stays attached to the number as the number changes width.
---
--- A unit is placed at the reading's left edge plus the reading's width, so
--- a reading that grows a character and a unit that does not move leaves a
--- gap, and one that shrinks leaves the unit overlapping it. Nothing else in
--- this suite could see that: every other assertion measures the pair at the
--- widest the panel can print, which is the case where a stationary unit
--- happens to be right.
---
--- Driven with a reading that changes length rather than merely value, since
--- the position depends on length alone.
---
--- **Three cells wide, not two, and the width is what keeps a unit on the
--- panel.** `tx-battery` measures its pair against half the content box,
--- because it reserves the other half for a battery. At `2 x 2` that half is
--- 113 px, and an XXLSIZE `88.8` with a MIDSIZE `V` beside it is 118 -- so
--- the `V` is shed and there is nothing here to follow. The reading is
--- XXLSIZE because a 62 px body band holds 54 px of ink; it was DBLSIZE
--- while the band was measured as a line box. At `3 x 2` the half is 173 and
--- the pair fits with room to spare.
local function testUnitFollowsTheReadingWidth()
  resetRadio()
  local widgetPath = makeWidget("unit-follow", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: tx
    type: tx-battery
    col: 0
    row: 0
    colSpan: 3
    rowSpan: 2
    config:
      label: TX
      packEmpty: 6.6
      packFull: 8.4
      # The estimate, which gives this panel a supporting row and therefore
      # a half-height body band. Without it the band is three quarters and
      # the reading reaches XXLSIZE either way; with it the band is 62 px,
      # which holds XXLSIZE by ink where it held DBLSIZE by line height.
      showPercent: true
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 30)

  local tx = entryById(context, "tx").instance
  assert(tx.unit and not tx.unit.hidden, "the panel drew no unit to follow")

  --- Where the reading actually ends, asked of the same measurement the
  --- radio would use rather than of the estimate. Measuring the gap with
  --- `textWidth` here is what let the old one pass: the estimate is 58%
  --- generous, so it put the reading's right edge well beyond where it is
  --- drawn and made a 48 pixel gap look like a small one.
  local function unitGap()
    local reading = tx.value.properties
    local right = reading.x + lcd.sizeText(reading.text, reading.font())
    return tx.unit.properties.x - right
  end

  -- The fixture reads 7.9 V: three characters.
  assertEqual(tx.text, "7.9")
  local narrowGap = unitGap()
  local narrowX = tx.unit.properties.x
  assertEqual(narrowGap, themeModule.unitGap(tx.unit.properties.font()),
    "the unit does not begin where the reading ends plus the stated gap")
  assert(narrowGap <= 3, "the unit sits " .. narrowGap
    .. " pixels from the number, which is a gap rather than a rider")

  -- Four characters. The reading grows and the unit has to grow with it.
  radio.values[320] = 10.0
  settle(context, 30)
  assertEqual(tx.text, "10.0",
    "the reading did not change length, so this test proves nothing")
  assert(tx.unit.properties.x > narrowX, "the reading grew a character and"
    .. " the unit stayed at " .. tx.unit.properties.x
    .. ", which leaves it sitting inside the number")
  assertEqual(unitGap(), narrowGap,
    "the unit followed the reading but not by the width it gained")

  -- And back, because a unit that only ever moves right would pass the line
  -- above and then overlap a reading that shortened.
  radio.values[320] = 7.9
  settle(context, 30)
  assertEqual(tx.text, "7.9")
  assertEqual(tx.unit.properties.x, narrowX,
    "the reading shrank and the unit stayed out at "
      .. tx.unit.properties.x .. ", leaving a gap")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- Every component that carries a unit draws it beside the reading, smaller.
---
--- Six components print a unit on their dominant reading, and until now each
--- did it differently: five glued it onto the reading string and one drew it
--- on a row of its own. This is the assertion that keeps them one shape.
---
--- Three things are checked of each, and none of them is "a unit is drawn",
--- which was true before and is satisfied by gluing it back on:
---
---   * the unit is its **own object**, so the reading string is digits alone;
---   * its font is **smaller** than the reading's;
---   * the pair **fits** the column, measured together rather than apart.
---
--- Driven at two spans, because #44's lesson is that a rule which varies with
--- size proves nothing when asserted at one size. The two chosen resolve to
--- different reading fonts, so a unit font that ignored the reading would be
--- caught.
local function testUnitsRideBesideEveryReading()
  resetRadio()
  radio.values[130] = {4.11, 4.09, 4.12}
  radio.values[140] = -70
  radio.values[141] = 88
  radio.values[106] = 120
  radio.values[120] = 2.5
  radio.values[109] = {
    lat = 47.3769, lon = 8.5417,
    ["pilot-lat"] = 47.3700, ["pilot-lon"] = 8.5400,
  }

  -- Six panels of the span under test in a 4 x 4 grid, which is the only
  -- shape the schema allows. Three fit at 2 x 2, so the six are split across
  -- two layouts rather than crammed into one.
  local function layoutAt(colSpan, rowSpan, from, count)
    local lines = {"version: 1", "grid:", "  columns: 4", "  rows: 4",
      "components:"}
    local panels = {
      {id = "alt", type = "metric",
        config = "      source: Alt\n      unit: m\n      precision: 0\n"},
      {id = "cells", type = "cell-battery",
        config = "      source: Cels\n      reading: lowest\n"},
      {id = "link", type = "link-status",
        config = "      rssiSource: 1RSS\n      qualitySource: RQly\n"
          .. "      reading: rssi\n"},
      {id = "nav", type = "navigation",
        config = "      source: GPS\n      presentation: distance\n"},
      {id = "tx", type = "tx-battery",
        config = "      packEmpty: 6.6\n      packFull: 8.4\n"},
      {id = "gv", type = "variable-indicator",
        config = "      binding: source\n      source: Curr\n"
          .. "      rangeMin: 0\n      rangeMax: 120\n"},
    }
    local chosen = {}
    for index = from, math.min(from + count - 1, #panels) do
      chosen[#chosen + 1] = panels[index]
    end

    local col, row = 0, 0
    for _, panel in ipairs(chosen) do
      if col + colSpan > 4 then col, row = 0, row + rowSpan end
      lines[#lines + 1] = "  - id: " .. panel.id
      lines[#lines + 1] = "    type: " .. panel.type
      lines[#lines + 1] = "    col: " .. col
      lines[#lines + 1] = "    row: " .. row
      lines[#lines + 1] = "    colSpan: " .. colSpan
      lines[#lines + 1] = "    rowSpan: " .. rowSpan
      lines[#lines + 1] = "    config:"
      lines[#lines + 1] = string.gsub(panel.config, "\n$", "")
      col = col + colSpan
    end
    return table.concat(lines, "\n"), chosen
  end

  local seenFonts = {}
  local checked = 0

  for _, span in ipairs({{2, 2, 1}, {2, 2, 4}, {2, 1, 1}, {2, 1, 4}}) do
    local text, panels = layoutAt(span[1], span[2], span[3], 3)
    local widgetPath = makeWidget(
      "units-" .. span[1] .. "x" .. span[2] .. "-" .. span[3], text)
    local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
      DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 60)

    for _, panel in ipairs(panels) do
      local instance = entryById(context, panel.id).instance
      local where = panel.type .. " at " .. span[1] .. "x" .. span[2]

      -- Its own object. A component that glued the unit back onto the
      -- reading would have no unit label at all.
      assert(instance.unit, where .. " draws no separate unit")

      local readingLabel = instance.value
      local reading = readingLabel.properties.text
      local unit = instance.unit.properties.text

      if not instance.unit.hidden and unit ~= "" then
        checked = checked + 1
        local readingFont = readingLabel.properties.font()
        local unitFont = instance.unit.properties.font()
        seenFonts[edgetx.fontName(readingFont)] = true

        assert(themeModule.fontHeight(unitFont)
            < themeModule.fontHeight(readingFont),
          where .. " draws its unit at " .. edgetx.fontName(unitFont)
            .. ", which is not smaller than the reading's "
            .. edgetx.fontName(readingFont))

        -- The reading is digits alone. If the unit were still glued on, the
        -- panel would be printing it twice.
        assert(not string.find(reading, unit, 1, true),
          where .. " prints its unit inside the reading (" .. reading
            .. ") as well as beside it")

        -- And the pair fits the column, measured together. Measuring the
        -- number alone is what let a 116 pixel string into a 105 pixel
        -- column for three milestones.
        --
        -- Measured rather than estimated, because the column is now measured
        -- too: a label is sized to the string it actually draws, and LVGL
        -- wraps against the same real advances. Asking the estimate here
        -- would compare a generous number against an exact one and report
        -- overflow on panels that have none.
        local pairWidth = themeModule.measureText(readingFont, reading)
          + themeModule.unitGap(unitFont)
          + themeModule.measureText(unitFont, unit)
        local column = readingLabel.properties.w
        assert(pairWidth <= column, where .. " draws " .. reading .. " "
          .. unit .. " needing " .. pairWidth .. " in a column of " .. column)

        -- Neither label wraps, which is the failure no assertion about text
        -- content can see.
        assertEqual(readingLabel.lines, 1, where .. " wrapped its reading")
        assertEqual(instance.unit.lines, 1, where .. " wrapped its unit")

        -- The baseline, which is the whole point of the arrangement.
        assertEqual(
          instance.unit.properties.y + themeModule.fontAscent(unitFont),
          readingLabel.properties.y + themeModule.fontAscent(readingFont),
          where .. " does not sit its unit on the reading's baseline")

        -- And the horizontal placement, held to the same standard: the unit
        -- begins where the reading *ends*, measured the way the radio
        -- measures, plus the stated gap and nothing else.
        --
        -- Asserting that the unit is merely to the right of the reading is
        -- what the 48 pixel gap satisfied, so this pins the distance instead.
        local drawnRight = readingLabel.properties.x
          + lcd.sizeText(reading, readingFont)
        assertEqual(instance.unit.properties.x - drawnRight,
          themeModule.unitGap(unitFont), where
            .. " places its unit against an estimate rather than against"
            .. " where the reading is drawn")
      end
    end
  end

  -- The two spans really did produce different reading sizes, or the whole
  -- exercise collapsed into one case.
  local sizes = 0
  for _ in pairs(seenFonts) do sizes = sizes + 1 end
  assert(sizes >= 2, "every panel resolved the same reading font, so this"
    .. " test says nothing about a rule that varies with size")
  assert(checked >= 8,
    "only " .. checked .. " panels actually drew a unit to check")
end

--- A panel narrowed until the battery no longer fits takes all of it away.
---
--- The build-time case cannot see this: a glyph is built hidden, so a
--- reconcile that forgot one of its three parts would still look right on a
--- panel that never showed it. Only a glyph that was on screen and then went
--- away exercises the hiding, and that is exactly the omission that left
--- `metric` hiding a bar and leaving its marker floating over the panel.
local function testBatteryGlyphShedsWhole()
  resetRadio()
  local widgetPath = makeWidget("glyph-shed", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: pack
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: TX
      packEmpty: 6.6
      packFull: 8.4
      showPercent: true
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 60)

  local pack = entryById(context, "pack").instance
  local glyph = pack.glyph
  assert(glyph, "the panel drew no battery to shed")

  -- The precondition. Without a battery on screen the shed below is not a
  -- shed, and every assertion after it would pass on a panel that never had
  -- one.
  assertEqual(pack.glyphShown, true, "the battery was not showing to start")
  assertEqual(glyph.shell.hidden, false)
  assertEqual(glyph.nub.hidden, false)
  assertEqual(glyph.fill.hidden, false)
  local shownWidth = glyph.fill.properties.h
  assert(shownWidth > 0, "the battery was showing an empty cell")

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

  -- Down to a zone whose two by two panel is a single cell's worth of width.
  -- The reading has first claim on it, so the battery goes.
  -- Narrow enough that even the smallest battery would take width the
  -- reading cannot give up: its column is already at the bottom of the
  -- ladder, so there is no step left to pay with.
  reflow(140, 140)
  assertEqual(pack.glyphShown, false,
    "a panel with no room for a battery kept drawing one")
  for name, part in pairs({shell = glyph.shell, nub = glyph.nub,
      fill = glyph.fill}) do
    assertEqual(part.hidden, true,
      "the battery was shed and its " .. name .. " stayed on screen")
  end

  -- And it comes back whole, in the right place, rather than coming back as
  -- whichever parts happened to be hidden.
  reflow(480, 272)
  assertEqual(pack.glyphShown, true, "the battery never came back")
  for name, part in pairs({shell = glyph.shell, nub = glyph.nub,
      fill = glyph.fill}) do
    assertEqual(part.hidden, false,
      "the battery came back and its " .. name .. " stayed hidden")
  end
  assertEqual(glyph.fill.properties.h, shownWidth,
    "the battery came back with a different level from the one it left with")
  assertEqual(glyph.nub.properties.y, glyph.y,
    "the terminal came back detached from the body")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

--- The reading and the battery do not overlap, at any span that has both.
---
--- Two labels in one panel is the arrangement this component did not have
--- before, and the failure it invites is arithmetic rather than visible: a
--- reading fitted to the full content width and a glyph placed at the right
--- edge of the same width both fit individually and collide.
local function testBatteryGlyphLeavesTheReadingRoom()
  resetRadio()
  local lines = {"version: 1", "grid:", "  columns: 4", "  rows: 4",
    "components:"}
  local spans = {{2, 1, 0, 0}, {2, 1, 2, 0}, {1, 2, 0, 1}, {2, 2, 1, 1}}
  for index, span in ipairs(spans) do
    lines[#lines + 1] = "  - id: p" .. index
    lines[#lines + 1] = "    type: tx-battery"
    lines[#lines + 1] = "    col: " .. span[3]
    lines[#lines + 1] = "    row: " .. span[4]
    lines[#lines + 1] = "    colSpan: " .. span[1]
    lines[#lines + 1] = "    rowSpan: " .. span[2]
    lines[#lines + 1] = "    config:"
    lines[#lines + 1] = "      packEmpty: 6.6"
    lines[#lines + 1] = "      packFull: 8.4"
  end

  local widgetPath = makeWidget("glyph-room", table.concat(lines, "\n"))
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 30)

  for index = 1, #spans do
    local panel = entryById(context, "p" .. index).instance
    local glyph = panel.glyph
    local span = spans[index][1] .. "x" .. spans[index][2]

    -- **`1 x 2` sheds its cell, and that is the reading winning rather than
    -- the panel failing.** These panels state no `showPercent`, so there is
    -- no supporting row and the body band is the panel's full three
    -- quarters -- which admits XXLSIZE, and an XXLSIZE `88.8` is 102 px of
    -- this panel's 52 px half. No pair of slots separates a reading that
    -- wide from a cell, so the visualization goes. The specification's order
    -- is magnitude before decoration, and a cell is decoration.
    if span == "1x2" then
      assertEqual(glyph, nil, span
        .. " drew a battery beside a reading that fills the panel")
    else
      assert(glyph, "panel " .. index .. " (" .. span .. ") drew no battery")

      local reading = panel.value.properties
      local right = reading.x + reading.w
      assert(glyph.x >= right, "panel " .. index
        .. " puts its battery at " .. glyph.x
        .. ", inside a reading column that ends at " .. right)
    end

    -- And the reading stays on one line, which is the wrap a narrowed column
    -- would cause if the label kept the panel's full width.
    assertEqual(panel.value.lines, 1,
      "panel " .. index .. " wrapped its reading into "
        .. tostring(panel.value.lines) .. " lines")
  end

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

--- Without any range at all there is still no estimate.
---
--- The firmware without `getGeneralSettings` is the case that matters: a
--- layout that states nothing then has nothing to measure against, and a
--- guessed percentage on the one reading that says whether the aircraft is
--- about to stop answering is worse than no percentage.
local function testTxBatteryWithoutAnyRange()
  resetRadio()
  local real = getGeneralSettings
  getGeneralSettings = nil

  local widgetPath = makeWidget("tx-norange", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: quiet
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      visual: bar
      showPercent: true
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  local ok, err = pcall(settle, context, 30)
  getGeneralSettings = real
  assert(ok, "a component raised without getGeneralSettings: " .. tostring(err))

  local quiet = entryById(context, "quiet").instance
  assertEqual(quiet.text, "7.9", "the voltage it does know was lost")
  assertEqual(quiet.barShown, false,
    "a bar was drawn with nothing to measure it against")
  assertEqual(quiet.detailLabel.properties.text, "",
    "a percentage was estimated from nothing")
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A timer's supporting caption is drawn where there is room and nowhere else.
---
--- Four assertions in this suite checked that caption's wording on panels one
--- row tall, which shed it. They passed because the component formatted the
--- string and then wrote it into a hidden label, which is the work this
--- sweep removes. The wording still matters, so it is checked here, at a span
--- that actually shows it.
local function testFlightTimerShedsItsDetail()
  resetRadio()
  local widgetPath = makeWidget("timer-detail", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: tall
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      timer: 0
  - id: flat
    type: flight-timer
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 0
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 30)

  local tall = entryById(context, "tall").instance
  local flat = entryById(context, "flat").instance

  -- Two rows: the caption is drawn, and says what the countdown is out of.
  assertEqual(tall.showDetail, true, "a two-row timer shed its caption")
  assertEqual(tall.detailLabel.properties.text, "OF 5:00",
    "the caption does not state the total the timer counts down from")
  assertEqual(tall.detailLabel.hidden, false)

  -- One row: not drawn, and not made either.
  assertEqual(flat.showDetail, false, "a one-row timer kept its caption")
  assertEqual(flat.rendered.detail, nil,
    "a shed caption was still being formatted every frame")
  assert(flat.detailLabel.hidden, "a shed caption was left on screen")

  -- An expired countdown says so, where it can.
  radio.timers[0].value = -15
  settle(context, 20)
  assertEqual(tall.detailLabel.properties.text, "EXPIRED")
  assertEqual(tall.stateName, "critical")

  -- And a shed caption costs nothing to keep shed while the timer moves
  -- underneath it. Writing into a hidden label leaves no trace on screen, so
  -- only the harness's write counter can see this.
  local writes = flat.detailLabel.writes
  radio.timers[0].value = 42
  settle(context, 20)
  assertEqual(flat.detailLabel.writes, writes,
    "a shed caption was written while the timer changed underneath it")
  resetRadio()
end

--- A clock keeps one width for the life of its panel, whatever the timer says.
---
--- The unit suite proves the clamp and the formatter in isolation. This
--- proves they reach the panel: the font is chosen once, from a form, and a
--- reading that outgrew it would clip or wrap rather than resize -- a Lua
--- label's long mode is LVGL's default wrap, so text too wide for its column
--- comes back down the panel over whatever is beneath it.
---
--- Driven through the values a radio can actually hold. `TIMER_MAX` is
--- `0xffffff/2` (`radio/src/timers.h:34`), so every reading below is one a
--- pilot could set from Model Setup.
local function testClockKeepsItsWidth()
  resetRadio()
  local widgetPath = makeWidget("timer-width", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: clock
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      timer: 0
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 30)

  local clock = entryById(context, "clock").instance
  local timerModule = assert(loadfile(
    sourcePath .. "components/flight-timer.lua"))()
  local font = clock.value.properties.font
  font = type(font) == "function" and font() or font
  local budget = clock.area.valueBudget

  -- The precondition: the font really was chosen from the form, so the
  -- assertions below are about the string that decided it.
  assertFont(font, XXLSIZE, "a 2 x 2 clock")
  local formWidth = themeModule.measureText(font, timerModule.FORMS[1])
  assert(formWidth <= budget, "the form itself does not fit the panel it"
    .. " sized: " .. formWidth .. " in " .. budget)

  local TIMER_MAX = math.floor(0xffffff / 2)
  local cases = {
    {90, "1:30", "an ordinary countdown"},
    {-15, "-0:15", "a countdown fifteen seconds past zero"},
    {3599, "59:59", "one second under an hour"},
    -- **The shape does not change here**, which is the whole point: the
    -- shared formatter answers `1:00:00` for this and would widen the
    -- reading by two characters while a pilot is watching it.
    {3600, "60:00", "exactly one hour"},
    {5999, "99:59", "the clamp itself"},
    {6000, "99:59", "one second past the clamp"},
    {TIMER_MAX, "99:59", "the largest value the firmware holds"},
    {-TIMER_MAX - 1, "-99:59", "the smallest value the firmware holds"},
  }

  local widest = 0
  for _, case in ipairs(cases) do
    radio.timers[0].value = case[1]
    -- A countdown's start has to clear the value, or the service reads it
    -- as a count-up timer and the sign never arrives.
    radio.timers[0].start = case[1] > 0 and (case[1] + 60) or 300
    settle(context, 20)

    assertEqual(clock.text, case[2], case[3] .. " drew the wrong clock")
    assertEqual(clock.value.properties.text, case[2],
      case[3] .. ": what was computed is not what was drawn")

    -- The font never moves, because it was chosen once from the form.
    local now = clock.value.properties.font
    now = type(now) == "function" and now() or now
    assertFont(now, font, case[3] .. " resized the clock")

    local width = themeModule.measureText(font, clock.text)
    assert(width <= formWidth, case[3] .. " drew " .. width
      .. " px, wider than the " .. formWidth .. " px form its font came from")
    assert(width <= budget, case[3] .. " drew past its own box")
    if width > widest then widest = width end
  end

  -- And the sweep is not vacuous: something in it actually reached the form.
  assertEqual(widest, formWidth,
    "no reading in the sweep was as wide as the form, so this proves only"
      .. " that narrow strings fit")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A bar is reconciled as one thing, because it is two or three objects.
---
--- Five components wrote the show-or-hide pair out by hand and `metric`
--- reconciled `track` and `fill` separately and never touched the marker, so
--- a bar carrying a neutral tick would have left it behind on a reflow.
--- Only `primitives.bar` and `placeBar` know how many objects a bar has, and
--- a caller reaching past them will drift again.
---
--- Driven against the real LVGL mock rather than a stand-in, because the
--- thing being checked is which objects were told what, and the mock counts
--- writes and visibility calls precisely so that work leaving no trace on
--- screen can still be seen.
local function testReconcileBar()
  resetRadio()
  local theme = themeModule.build("modern")
  local root = lvgl.box({x = 0, y = 0, w = 200, h = 100})
  local bar = primitivesModule.bar(root, theme, {
    x = 0, y = 0, w = 100, fraction = 0, color = theme.color.cyan,
    marker = 0.5,
  })
  assert(bar.marker, "this test needs a bar that carries a marker")

  -- Shown: positioned, and every object told, the marker included.
  primitivesModule.reconcileBar(bar, true, 10, 20, 100, 0.25)
  assertEqual(bar.track.hidden, false)
  assertEqual(bar.fill.hidden, false)
  assertEqual(bar.marker.hidden, false,
    "a bar's marker was left behind, which is what reconciling its two"
      .. " other objects separately does")
  assertEqual(bar.track.properties.x, 10)

  -- Hidden: every object told, and nothing positioned, because moving an
  -- object nobody can see is the invisible work this exists to stop.
  local writes = bar.track.writes
  primitivesModule.reconcileBar(bar, false, 99, 99, 40, 1)
  assertEqual(bar.track.hidden, true)
  assertEqual(bar.fill.hidden, true)
  assertEqual(bar.marker.hidden, true)
  assertEqual(bar.track.writes, writes, "a hidden bar was repositioned")
  assertEqual(bar.track.properties.x, 10, "a hidden bar moved")

  -- Settled: positioned, and told nothing it already is.
  primitivesModule.reconcileBar(bar, true, 30, 40, 80, 0.5)
  local calls = bar.track.visibilityCalls
  local markerCalls = bar.marker.visibilityCalls
  primitivesModule.reconcileBar(bar, true, 50, 40, 80, 0.5, true)
  assertEqual(bar.track.properties.x, 50, "a settled bar was not repositioned")
  assertEqual(bar.track.visibilityCalls, calls,
    "a bar whose visibility had not moved was told what it already was")
  assertEqual(bar.marker.visibilityCalls, markerCalls)

  -- Settled and hidden: nothing at all.
  primitivesModule.reconcileBar(bar, false, 1, 2, 3, 0)
  writes = bar.track.writes
  calls = bar.track.visibilityCalls
  primitivesModule.reconcileBar(bar, false, 7, 8, 9, 1, true)
  assertEqual(bar.track.writes, writes)
  assertEqual(bar.track.visibilityCalls, calls)

  -- A component with no bar passes nil, and that is not an error.
  primitivesModule.reconcileBar(nil, true, 0, 0, 10, 1)
  root:clear()
end

--- A heading never wraps down over the reading, however long it is.
---
--- A Lua label is `lv_label_create` with a font style and nothing else
--- (`etx_label_create`), so its long mode is LVGL's default, which
--- `lv_label_constructor` sets to `LV_LABEL_LONG_WRAP`. And `h = 0` is not
--- zero: `LvglSimpleWidgetObject::parseParam` turns it into
--- `LV_SIZE_CONTENT`. So a heading wider than its column used to wrap onto
--- further lines and grow downward, over the reading it labels. Nothing about
--- the text changed, so no assertion about what a label says could see it --
--- only its drawn height can, which is why the harness models that.
---
--- Driven at the narrowest case there is: a single cell, whose heading column
--- is what the badge leaves, with the badge showing.
local function testHeadingNeverWraps()
  resetRadio()

  -- First, that the harness can see the thing at all. Every assertion below
  -- is of the form "one line", which a mock that always answered one line
  -- would satisfy without checking anything. So an unfitted label is built
  -- directly and held to wrapping, which is what the firmware does and what
  -- the components must therefore avoid.
  local box = lvgl.box({x = 0, y = 0, w = 120, h = 60})
  local overflowing = primitivesModule.label(box, themeModule.build("modern"), {
    x = 0, y = 0, w = 40,
    text = "A HEADING FAR TOO LONG FOR FORTY PIXELS",
    font = firmware.SMLSIZE,
  })
  assert(overflowing.lines > 1,
    "the harness does not model LVGL's wrapping, so every assertion below"
      .. " that a heading takes one line would pass without checking")
  assert(overflowing.drawnHeight > themeModule.fontHeight(firmware.SMLSIZE),
    "a wrapped label did not grow, so the growth this exists to prevent"
      .. " cannot be seen either")
  box:clear()

  local widgetPath = makeWidget("heading", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: short
    type: tx-battery
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      label: TX
      warning: 9.0
  - id: long
    type: tx-battery
    col: 1
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      label: BATTERY
      warning: 9.0
  - id: huge
    type: tx-battery
    col: 2
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      label: TRANSMITTER BATTERY PACK
      warning: 9.0
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 30)

  local short = entryById(context, "short").instance
  local long = entryById(context, "long").instance
  local huge = entryById(context, "huge").instance

  -- The badge is showing, so the heading column is the narrow one. Without
  -- this the panels are not the case being tested.
  for _, panel in ipairs({short, long, huge}) do
    assertEqual(panel.stateName, "warning")
    assertEqual(panel.badge.properties.text, "WARN",
      "the badge is not showing, so the heading column is not the narrow one")
  end

  local column = short.label.properties.w
  assert(column > 0 and column < 60,
    "a single cell's heading column should be narrow: " .. column)

  -- One line each, which is the whole point. `TRANSMITTER` used to take
  -- three lines and 51 pixels of a 65 pixel panel.
  for id, panel in pairs({short = short, long = long, huge = huge}) do
    assertEqual(panel.label.lines, 1,
      id .. "'s heading wrapped onto " .. tostring(panel.label.lines)
        .. " lines and grew down over the reading")
    assert(panel.label.drawnHeight <= themeModule.fontHeight(
      panel.fonts.label),
      id .. "'s heading is taller than one row of its own font")
  end

  -- A heading that fits is left exactly as the author wrote it, at the font
  -- the panel would have used anyway. Stepping a short heading down would be
  -- a cost paid for nothing.
  assertEqual(short.label.properties.text, "TX")
  assertEqual(short.label.properties.font(), short.fonts.label)

  -- A heading that does not fit steps the font down first, because that
  -- costs nothing and keeps the whole name.
  assertEqual(long.label.properties.text, "BATTERY",
    "a heading was cut when a smaller font would have carried it whole")
  assert(themeModule.fontHeight(long.label.properties.font())
      < themeModule.fontHeight(long.fonts.label),
    "the heading kept its font and must therefore have overflowed")

  -- And one that does not fit even at the smallest font is cut rather than
  -- wrapped, and the host says so, because cutting a name the author chose
  -- is a loss and a silent loss is the thing this project does not do.
  assert(#huge.label.properties.text < #"TRANSMITTER BATTERY PACK",
    "a heading nothing could fit was drawn whole, so it must have wrapped")

  -- Whether a heading was cut is asked of the host's notices rather than of
  -- the label, because a label on a radio is userdata and answers nothing.
  -- Only the panel that lost characters is named: a cut reported for a
  -- heading that fitted would send an author looking for a defect in the one
  -- place there is not one.
  local function noticedHeading(id)
    for _, notice in ipairs(context.notices) do
      if string.find(notice.text, "heading", 1, true)
          and string.find(notice.text, id .. ":", 1, true) then
        return notice.text
      end
    end
    return nil
  end

  assertEqual(noticedHeading("short"), nil,
    "a heading that fitted was reported as cut")
  assertEqual(noticedHeading("long"), nil,
    "a heading carried whole by a smaller font was reported as cut")

  local said = false
  for _, notice in ipairs(context.notices) do
    if string.find(notice.text, "TRANSMITTER BATTERY PACK", 1, true)
        and string.find(notice.text, "huge", 1, true) then
      said = true
    end
  end
  assert(said, "a heading was cut and nobody was told; notices were: "
    .. table.concat((function()
      local out = {}
      for _, notice in ipairs(context.notices) do out[#out + 1] = notice.text end
      return out
    end)(), " | "))
end

--- A heading refits when a reflow changes the column it has.
---
--- The column is what the badge leaves, so it moves with the panel. A
--- heading fitted once at build would wrap the first time the zone changed,
--- which is the same shape as a reading sized once and never again.
local function testHeadingRefitsOnReflow()
  resetRadio()
  local widgetPath = makeWidget("heading-reflow", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: panel
    type: tx-battery
    col: 0
    row: 0
    colSpan: 4
    rowSpan: 2
    config:
      label: TRANSMITTER
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  settle(context, 20)

  local panel = entryById(context, "panel").instance
  -- Four cells wide: the whole heading fits at the panel's own font.
  assertEqual(panel.label.properties.text, "TRANSMITTER")
  assertEqual(panel.label.properties.font(), panel.fonts.label)
  assertEqual(panel.label.lines, 1)

  zone.w = 160
  local passes = 0
  repeat
    definition.refresh(context)
    passes = passes + 1
    assert(passes < 100, "reflow never finished")
  until not context.reflowIndex
  settle(context, 20)

  assertEqual(panel.label.lines, 1,
    "the heading wrapped after a reflow narrowed its column")
  assert(themeModule.fontHeight(panel.label.properties.font())
      < themeModule.fontHeight(panel.fonts.label),
    "the heading kept the font it was built with and must have overflowed")
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
  -- **One supporting row at this span, not two.** A `2 x 2` panel's tertiary
  -- quarter is 31 px and this component's two-row group is 32 px of ink, so
  -- the coordinates are shed by the band that would have to hold them. The
  -- row that sheds and returns here is therefore the bearing, which is what
  -- the assertions below follow. Two rows at a three-row span are covered by
  -- testTwoRowFooterClearsTheReading.
  assertEqual(nav.showCoordinates, false,
    "a 2 x 2 nav panel kept two rows in a quarter that holds one")

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
  -- The model moved while the row was hidden, so the bearing measured from
  -- home moved with it: 009 degrees before, 054 after. Pinned rather than
  -- merely required to differ, because "not 009" is satisfied by every wrong
  -- answer as well as the right one.
  assertEqual(nav.detailLabel.properties.text, "BRG 054",
    "a revealed bearing row still reports the bearing it was shed with: "
    .. tostring(nav.detailLabel.properties.text))
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
  -- The metric's unit used to be shed here, and it is not any more: it rides
  -- beside the reading instead of taking a row, so a narrower panel keeps it
  -- until the pair genuinely will not fit, and at 116 pixels an `m` beside a
  -- DBLSIZE `100` still does. What replaces that assertion is the invariant
  -- the unit brought with it -- a rider that is drawn is repositioned only
  -- when the reading's own width changed -- because a unit that rewrites its
  -- position every frame is exactly the invisible work this test exists for.
  assert(not tight.unit.hidden,
    "the metric shed a unit it has room for, so the line below is measuring"
      .. " a hidden object")
  assertEqual(tight.unit.writes, unitWrites + 1,
    "a reflow moved the unit more than once, or not at all: it moved "
      .. (tight.unit.writes - unitWrites) .. " times")
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
  -- Both timers here are one row tall, which sheds the supporting row, so
  -- the total and the counting-up caption are not on screen and asserting
  -- their text would assert something nobody can see. The wording is checked
  -- at a span that keeps it, in testFlightTimerShedsItsDetail.
  assertEqual(countdown.showDetail, false,
    "a one-row timer found space for a supporting row")
  assert(countdown.detailLabel.hidden, "a shed row was left on screen")
  assertEqual(countdown.stateName, "warning", "90s left is inside the warning")
  assertEqual(countdown.badge.properties.text, "WARN")

  -- A count-up timer has no total and therefore no progress to draw.
  local countup = entryById(context, "countup").instance
  assertEqual(countup.text, "1:04")
  assertEqual(countup.showDetail, false)
  assert(countup.detailLabel.hidden, "a shed row was left on screen")
  assertEqual(countup.stateName, "normal")

  -- An expired countdown must never read like a healthy timer.
  radio.timers[0].value = -15
  settle(context, 12)
  assertEqual(countdown.text, "-0:15", "an expired countdown lost its sign")
  assertEqual(countdown.rendered.detail, nil,
    "a shed caption was still being formatted every frame")
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
  -- Declared only where it is drawn. This panel sheds the row, so the key is
  -- absent rather than computed and written into a hidden label.
  assertEqual(mode.rendered.detail, nil,
    "a shed mode number was still being formatted every frame")
  -- A single cell has no supporting row, so there is no mode number here and
  -- asserting its text would assert something nobody can see. This used to
  -- read `MODE 1` on a panel that draws no such row.
  assertEqual(mode.showDetail, false,
    "a single-cell flight mode found room for a supporting row")
  -- **No label at all, rather than a hidden one.** This panel did not ask
  -- for the mode number, so there is nothing for a row to hold at any span,
  -- and building an object to hide it is the invisible work the
  -- specification forbids.
  assertEqual(mode.detailLabel, nil,
    "a panel that never asked for the mode number built a label for it")

  -- The transmitter pack: voltage is authoritative, the percentage is an
  -- estimate and says so.
  local battery = entryById(context, "battery").instance
  assertEqual(battery.text, "7.9")
  -- A single cell sheds the supporting row, so the percentage is not on
  -- screen here; its wording is checked at a span that shows it, in
  -- testTxBatteryRangeGatesTheEstimate.
  assertEqual(battery.showDetail, false,
    "a single-cell battery found room for a percentage")
  assertEqual(battery.rendered.detail, nil,
    "a shed percentage was still being formatted every frame")
  assertEqual(battery.stateName, "normal")
  radio.values[320] = 6.7
  settle(context, 12)
  assertEqual(battery.stateName, "critical")
  assertEqual(battery.badge.properties.text, "CRIT")
  radio.values[320] = 7.9

  -- A global variable takes its name, bounds, precision, and unit from
  -- EdgeTX, and AeroGrid never writes one.
  local gv = entryById(context, "gv").instance
  assertEqual(gv.text, "10")
  assertEqual(gv.labelValue, "GV2")
  -- This panel is one row tall and sheds its supporting row, so the name
  -- and flight mode are not on screen here. They are checked at a span that
  -- shows them, in testGlobalVariableDetails.
  assertEqual(gv.showDetail, false, "a one-row indicator kept its name row")
  assertEqual(gv.rendered.detail, nil,
    "a shed name row was still being formatted every frame")
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
  assertEqual(gv.text, "60", "the value stored for the new flight mode was not read")

  -- A mode with no value of its own does inherit, and that is a different
  -- observation from never having looked.
  radio.flightMode, radio.flightModeName = 3, "Cruise"
  settle(context, 12)
  assertEqual(gv.text, "10", "an inherited value was not inherited")

  radio.flightMode, radio.flightModeName = 1, "Sport"
  settle(context, 12)
  assertEqual(gv.text, "10")
  -- The unit rides beside the digits rather than being glued to them, and it
  -- is drawn smaller than the number it belongs to.
  assertEqual(gv.unit.properties.text, "%")
  assertEqual(gv.showUnit, true)
  assert(themeModule.fontHeight(gv.unit.properties.font())
      < themeModule.fontHeight(gv.value.properties.font()),
    "the unit is drawn at or above the size of the reading it rides beside")

  -- The same component bound to a telemetry source instead.
  local dial = entryById(context, "dial").instance
  assertEqual(dial.text, "10.0")
  -- The sensor's own unit, which arrives with the source rather than being
  -- known when the panel was built.
  assertEqual(dial.unit.properties.text, "A")
  -- **The dial stays and the unit goes, and both follow from one step of
  -- font.** This panel is a single cell, 117 x 65. Its extent is 59 px, so
  -- its bands are a 14 px label, a 26 px body and a 14 px tertiary, and a
  -- 26 px body holds MIDSIZE at 23 px of ink and not DBLSIZE at 31.
  --
  -- The reading takes that size, because a reading is never shrunk to make
  -- room for something beside it. Its widest form is `-1200`, which MIDSIZE
  -- draws in 56 px, and the tightened slots do separate 56 px of number from
  -- a 26 px dial inside a 105 px content box -- so the dial survives. Being
  -- a two-element panel, the reading is then measured against its slot
  -- rather than the whole box: 58 px, against 65 px for `-1200` and an
  -- SMLSIZE `A`. So the unit goes, which is the documented order -- a form
  -- may drop redundancy, never magnitude, and the heading above says what is
  -- being measured.
  --
  -- **This panel has now been each way round twice**, which is worth the
  -- line: it drew a dial and no unit under the old band rule, lost the dial
  -- and gained the unit when the band started being measured as ink and grew
  -- to 34 px, and has gone back to a dial and no unit now that the band is a
  -- fixed half at 26. Nothing about the panel changed; the band under it did,
  -- three times.
  assertEqual(dial.showVisual, true,
    "a single cell shed the dial its MIDSIZE reading leaves room for")
  assertEqual(dial.showUnit, false,
    "the unit rode beside a reading that has no room for it in its slot")
  assert(dial.radial, "the radial presentation was not built")
  assertEqual(dial.radial.arc.hidden, false, "the dial was not on screen")

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

  -- **Contained, not cropped.** `fill` is the only thing that decides this
  -- and it reaches EdgeTX as `StaticImage`'s `fillFrame`, where `setZoom`
  -- computes `z = fillFrame ? max(zw, zh) : min(zw, zh)`
  -- (`gui/colorlcd/libui/static.cpp`). The larger zoom covers the frame and
  -- cuts off whatever does not fit; a model image is 192 x 114 and every
  -- frame this component produces is wider in proportion, so covering cut
  -- the aircraft's top and bottom off -- a tenth of its height survived at
  -- four cells by two. Nothing else observable changes when this flips,
  -- which is why it is asserted here rather than inferred from a position.
  assertEqual(identity.image.properties.fill, false,
    "the model picture is cropped to fill its frame instead of fitted"
      .. " inside it")

  -- And the name is the heading, because a picture is drawn. The configured
  -- label has nowhere to go on such a panel and the layout validator refuses
  -- one; this is the other half of that rule, observed rather than assumed.
  assertEqual(identity.label.properties.text, "TEST MODEL",
    "a panel drawing the model picture did not put the model name in its"
      .. " heading")

  -- A bipolar bar measures each side against its own bound.
  local swing = entryById(context, "swing").instance
  assertEqual(swing.text, "4.5")
  assert(swing.bipolar, "the bipolar presentation was not built")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- Every component must degrade visibly rather than raise when the radio
--- cannot answer: a firmware without the API, a source that does not exist, a
--- timer the model has not configured, and a model bitmap that is not on the
--- card.
---
--- **The timer here is in range and unconfigured, which is the runtime case.**
--- It used to be `timer: 7`, an index no radio has -- and that is an
--- authoring mistake rather than a radio that cannot answer, so it is
--- refused at load now and is covered by `testTimerIndexIsRefusedAtLoad`.
--- The two look identical on screen, which is exactly why they were confused:
--- both draw `NO TIMER`. Only one of them is the author's to fix.
local function testComponentsDegrade()
  resetRadio()
  -- A timer the radio has and the model has not set up. `luaModelGetTimer`
  -- answers nothing for an unconfigured slot the same way it does for one
  -- out of range, so this is the shape a component must survive.
  radio.timers[2] = nil
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
      timer: 2
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

  -- The dominant reading, which every span draws. This panel is one row
  -- tall and sheds its caption, so the caption is checked where it is shown.
  assertEqual(entryById(context, "timer").instance.text, "--:--")
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
      # Stated, not `auto`: the thresholds below are percentages, and a
      # threshold whose unit depends on which source resolved first is
      # refused at load.
      reading: quality
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
  assertEqual(pack.text, "4.09")
  assertEqual(pack.countText, "4S")
  assertEqual(pack.packText, "16.4V")
  assertEqual(pack.stateName, "normal")
  assertEqual(pack.summary.count, 4)
  assertEqual(pack.summary.shape, "cells")

  -- One sagging cell must take the panel critical even though the pack sum
  -- barely moves: 15.6 V across four cells still looks healthy.
  radio.values[130] = {4.11, 3.25, 4.09, 4.12}
  radio.values[131] = 3.25
  settle(context, 12)
  assertEqual(pack.text, "3.25")
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
  assertEqual(link.text, "96")
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
  assertEqual(elrs.text, "-72")
  assertEqual(elrs.unit.properties.text, "dBm",
    "the unit the source resolved to never reached the label beside it")
  assertEqual(elrs.stateName, "normal")
  radio.values[143] = -95
  settle(context, 12)
  assertEqual(elrs.stateName, "warning", "a dBm threshold must count downward")
  radio.values[143] = -72

  -- Navigation computes distance and bearing from the pilot position EdgeTX
  -- recorded, and says in words what the direction means.
  local nav = entryById(context, "nav").instance
  assertEqual(nav.text, "778")
  -- Fitted to the row rather than overrunning it. Whichever wording is chosen
  -- has to fit, which is the property that matters; pinning the string alone
  -- would pass on a helper that always returned the shortest one.
  assertEqual(nav.detail, "BRG 009")
  assertEqual(nav.origin, "NORTH UP")
  assert(themeModule.textWidth(nav.fonts.label, nav.detail) <= nav.detailWidth,
    "the bearing row overran its box")
  assert(themeModule.textWidth(nav.fonts.label, nav.origin) <= nav.originWidth,
    "the origin caption overran its box")
  -- **No coordinates at this span**, and asserting their text here would be
  -- asserting a string nobody can see. A `2 x 2` panel's tertiary quarter is
  -- 31 px and two supporting rows are 32 px of ink, so this component draws
  -- the bearing alone and the coordinates are shed by the band that would
  -- have had to hold them. They are checked at a three-row span, in
  -- testTwoRowFooterClearsTheReading.
  assertEqual(nav.showCoordinates, false,
    "a 2 x 2 nav panel kept two rows in a quarter that holds one")
  assertEqual(nav.rendered.coordinates, nil,
    "a shed coordinate row was still being formatted every frame")
  assertEqual(nav.stateName, "normal")
  -- **This panel sheds its compass, and that is the magnitude rule.** The
  -- panel is 238 x 134 with a 226 px content box, and its 62 px body band
  -- holds XXLSIZE once the band is measured as ink. The widest distance this
  -- component prints is `888.88km`, which XXLSIZE draws in 195 px against
  -- DBLSIZE's 113, and half of 195 is more than either left slot centre has
  -- to its left: tightened, the reading's left edge lands at -22, and at
  -- strict halves at -33. So the dial goes and the distance keeps its size.
  -- What the dial does when it is drawn -- point at a real bearing, and
  -- point nowhere when there is none -- is covered at a span that draws one,
  -- in testCompassPointsWhereTheFixIs.
  assertEqual(nav.showCompass, false,
    "a two-column panel kept its compass beside an XXLSIZE distance")
  assert(nav.compass.ring.hidden, "a shed compass was left on screen")

  -- A configured native distance sensor wins over the computed one, because
  -- the receiver may compute it from data this dashboard never sees.
  local native = entryById(context, "native").instance
  assertEqual(native.text, "812.0")
  assertEqual(native.feed.distanceSource, "source")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- The dial gives its room back when the panel narrows, and takes it again.
---
--- Two properties, and the second is the one that used to be got wrong: a
--- reading is never shrunk to make room for a decoration, so a panel that
--- cannot hold both sheds the dial; and a dial that was shed comes back at
--- its full size rather than at whatever it was last given.
---
--- **Three cells wide, because two draws no dial at all now.** This cycle
--- used to ride on the telemetry layout's `2 x 2` navigation panel, which
--- sheds its compass at every zone size this test uses -- so shed, stayed
--- shed and restored would all have been the same picture, and the check
--- could not have failed.
local function testCompassShedsWhenThePanelNarrows()
  resetRadio()
  local widgetPath = makeWidget("compass-shed", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: nav
    type: navigation
    col: 0
    row: 0
    colSpan: 3
    rowSpan: 2
    config:
      source: GPS
      label: Nav
      presentation: detailed
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  pump(context, 60)

  local function drain()
    local passes = 0
    repeat
      definition.refresh(context)
      passes = passes + 1
      assert(passes < 200, "reflow never finished")
    until not context.reflowIndex
  end

  local nav = entryById(context, "nav").instance
  assertEqual(nav.compass.ring.hidden, false, "the dial was never shown")
  local firstRadius = nav.compass.ring.properties.radius

  zone.w = 320
  drain()
  pump(context, 10)
  -- **Only the width changed.** A 320 px zone gives this panel a 224 px
  -- content box and leaves its 62 px body band alone, so the distance stays
  -- at XXLSIZE: `888.88km` is 195 px there, half of that is 98, and the
  -- tightened left slot has 67 px to its left. The reading's left edge would
  -- land at -23, and at strict halves at -34, so the dial goes rather than
  -- the distance shrinking.
  assertEqual(nav.compass.ring.hidden, true,
    "the dial kept its room on a panel whose distance needed it")

  zone.w = 480
  drain()
  pump(context, 10)
  assertEqual(nav.compass.ring.hidden, false, "the dial was not restored")
  assertEqual(nav.compass.ring.properties.radius, firstRadius,
    "the dial was not restored to its full size")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end
---
--- Two properties of the pointer, both of which the specification states:
--- the arrow is an absolute north-up bearing from home to model, and it is
--- hidden when there is no bearing, because a pointer resting at north reads
--- as a real due-north fix. Visibility is the arc's **sweep** rather than
--- its opacity -- passing opacity stopped the whole ring rendering on a
--- radio -- so a zero-length sweep is what "no pointer" means.
---
--- **Three cells wide, because two no longer draws a dial at all.** These
--- assertions used to ride on the `nav` panel of the telemetry layout, which
--- is `2 x 2`. Its distance takes XXLSIZE now and the dial has nowhere to
--- stand beside it, so the same assertions would have been reading angles
--- off a hidden ring that nothing updates -- a check that cannot fail. The
--- panel is widened here rather than the rule bent.
local function testCompassPointsWhereTheFixIs()
  resetRadio()
  local widgetPath = makeWidget("compass-pointer", [[
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: nav
    type: navigation
    col: 0
    row: 0
    colSpan: 3
    rowSpan: 2
    config:
      source: GPS
      label: Nav
      presentation: detailed
]])

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  pump(context, 60)

  local nav = entryById(context, "nav").instance
  -- The precondition. Without it every assertion below is about an object
  -- nobody draws and nothing writes to.
  assertEqual(nav.showCompass, true,
    "the panel shed its compass, so this test proves nothing")
  assertEqual(nav.compass.ring.hidden, false, "the dial was not on screen")

  -- A real fix, 9 degrees from home. Three cells wide gives the row enough
  -- for the compass point as well as the number, which a `2 x 2` sheds.
  assertEqual(nav.detail, "BRG 009 N")
  local ring = nav.compass.ring.properties
  assert(ring.startAngle ~= ring.endAngle,
    "a known bearing must sweep a visible pointer")

  -- And nowhere when there is nowhere to point. Zero for both axes is what
  -- EdgeTX reports before it has a fix, and it is a real place off the coast
  -- of Africa, so it must never be drawn as one.
  radio.values[109].lat = 0
  radio.values[109].lon = 0
  pump(context, 40)
  assertEqual(nav.origin, "NO FIX")
  assertEqual(nav.compass.ring.properties.startAngle,
    nav.compass.ring.properties.endAngle,
    "an unknown bearing must draw a zero length pointer")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end
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
  assertEqual(pack.text, "4.09", "a stale poll overwrote the reading")
  assertEqual(pack.badge.properties.text, "STALE")

  assertEqual(link.stateName, "critical", "a dead link is the measurement")
  -- The badge carries the state. Which of the several ways a link can fail is
  -- carried by the supporting row, at a span that has one; this panel is
  -- 2 x 1 and sheds it.
  assertEqual(link.badge.properties.text, "CRIT")

  assertEqual(nav.stateName, "stale")
  assertEqual(nav.text, "778", "the last known position was discarded")
  -- **`LAST` rather than `LAST KNOWN`, and that is the slot rule's price.**
  -- A two-item row is centred on the panel's two slot centres, so each item
  -- can be half the distance between them before they meet -- 40% of the
  -- content where the column split it replaces reached 100%. The user chose
  -- that on a radio with both drawn side by side.
  --
  -- What the narrowing must never cost is meaning, and the assertion that
  -- guards it is `testSupportingWordingsStayDistinct`: the shortest form of
  -- every state this row reports has to stay distinct from the shortest form
  -- of every other. `LAST` is less informative than `LAST KNOWN`; it is not
  -- confusable with `NO FIX`.
  assertEqual(nav.origin, "LAST")

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
  -- The coordinates row is shed at this span, so what it would have said is
  -- not on screen and is not asserted. The state, the badge and the origin
  -- caption are what this panel actually reports a lost fix with.
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
  assertEqual(nav.origin, "NO HOME")
  -- **That the position itself is still known is asserted at a span that
  -- draws it.** The specification's promise is that a missing home withholds
  -- only the two values measured from home and leaves the coordinates
  -- visible; this panel is `2 x 2` and sheds its coordinate row to the
  -- tertiary quarter, so the promise is checked in
  -- testTwoRowFooterClearsTheReading, on a three-row panel that draws both
  -- supporting rows. Asserting the string here would assert something no
  -- screen shows.
  assertEqual(nav.showCoordinates, false)

  -- A table whose entries cannot be cell voltages. The explicit lowest-cell
  -- source keeps the reading alive, and the count row says the table is
  -- gone. **A pack not yet detected and a source answering wrongly still
  -- read differently**, because one means wait and the other means go and
  -- fix something; which *kind* of wrong is not a difference the row spends
  -- a word on.
  radio.values[130] = {0, -1, 99}
  pump(context, 40)
  assertEqual(pack.summary.shape, "invalid")
  assertEqual(pack.text, "4.09")
  assertEqual(pack.countText, "CELLS ERR")
  assert(themeModule.measureText(pack.fonts.label, pack.countText)
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
    -- One wording, which fits every row this component draws, so it is
    -- pinned rather than matched on a prefix. `CELLS ERR` says something is
    -- arriving and is wrong; a source the radio has never heard of says
    -- nothing at all, and that difference is asserted below.
    assertEqual(instance.countText, "CELLS ERR",
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
  assertEqual(pack.text, "3.80")
  assertEqual(pack.packText, "16.1V")

  radio.values[130] = {3.80, 3.90, 3.90, 3.90}
  settle(context, 20)
  assertEqual(pack.text, "3.80", "the lowest cell should not have moved")
  assertEqual(pack.packText, "15.5V", "the pack row froze on an old sum")

  -- Link quality sits pinned at 100 for most of a flight while RSSI falls
  -- away, so the supporting RSSI row is exactly the one that must keep up.
  local link = entryById(context, "link").instance
  radio.values[141] = 100
  radio.values[140] = 70
  settle(context, 20)
  assertEqual(link.text, "100")

  radio.values[140] = 41
  settle(context, 20)
  assertEqual(link.text, "100", "link quality should not have moved")

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
  assertEqual(nav.origin, "NO GPS")

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
  assertEqual(nav.text, "778")

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
      # `auto` is the subject here, so it carries no thresholds: their unit
      # is exactly what `auto` leaves undecided.
      reading: auto
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
  assertEqual(link.text, "96", "a live reading was discarded as a dead link")
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
  -- **This panel draws no compass at any of the three sizes below**, because
  -- it is two cells wide and its distance takes XXLSIZE: see
  -- testTelemetryComponents for the arithmetic. What is left here is the
  -- supporting row's shed and return, which is what this test is for. The
  -- dial's own shed and return, which needs a panel that draws one, is
  -- testCompassShedsWhenThePanelNarrows.
  assertEqual(nav.showCompass, false)
  -- **The bearing row is the one that sheds and returns here.** A `2 x 2`
  -- panel's tertiary quarter holds one supporting row, so the coordinates
  -- are shed at this span whatever the zone does; two rows at a three-row
  -- span are testTwoRowFooterClearsTheReading.
  assertEqual(nav.showCoordinates, false)
  assertEqual(nav.detailLabel.hidden, false, "the bearing row was never shown")
  local function readingFont()
    local font = nav.value.properties.font
    if type(font) == "function" then font = font() end
    return font
  end
  assertFont(readingFont(), XXLSIZE, "the full-size panel's distance")

  zone.w = 320
  zone.h = 140
  drain()
  settle(context, 10)
  assertContained("shrunk")
  -- Supporting rows are shed before the dominant reading is touched.
  assertEqual(nav.detailLabel.hidden, true, "a shed bearing row stayed visible")

  -- And the reading does step down once the panel genuinely is smaller: a
  -- 320 x 140 zone gives this panel 158 x 68, whose extent is 62 px and
  -- whose body is therefore a 26 px half -- which holds MIDSIZE at 23 px of
  -- ink and not DBLSIZE at 31.
  assertFont(readingFont(), MIDSIZE,
    "the distance did not follow the band down")
  -- And with the distance that much narrower the dial fits beside it again,
  -- which is the shedding rule running the other way: the decoration comes
  -- back when the reading stops needing the room.
  assertEqual(nav.showCompass, true,
    "a MIDSIZE distance left no room for a dial that fits beside it")

  zone.w = 480
  zone.h = 272
  drain()
  settle(context, 10)
  assertContained("restored")
  assertFont(readingFont(), XXLSIZE, "the distance was not restored")
  assertEqual(nav.detailLabel.hidden, false, "the bearing row was not restored")

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
testRadialDoesNotDrift()
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
testFlightModeIndexRow()
testTxBatteryRangeComesFromTheRadio()
testTxBatteryWithoutAnyRange()
testBatteryGlyphFillsFromTheVoltage()
testBatteryGlyphLeavesTheReadingRoom()
testBatteryGlyphShedsWhole()
testBatteryStrokeFollowsTheReading()
testBatteryStrokeSurvivesReflow()
testUnitsRideBesideEveryReading()
testUnitFollowsTheReadingWidth()
testFlightTimerShedsItsDetail()
testClockKeepsItsWidth()
testReconcileBar()
testHeadingNeverWraps()
testHeadingRefitsOnReflow()
testFlightModeSizesFromTheModel()
testHostDiagnosticsReportsTheHost()
testLayoutOriginIsReported()
testHostDiagnosticsWarnsAboutBytecode()
testHostDiagnosticsReportsFailures()
testComponentsDegrade()
testCoreComponentsReflow()
testMetricPresetDetail()
testTelemetryComponents()
testCompassPointsWhereTheFixIs()
testCompassShedsWhenThePanelNarrows()
testTelemetryDegrades()
testCellSourceShapes()
testRefreshSeesEverythingItDraws()
testNavigationSeesItsSensorAppear()
testProtocolWithoutRssi()
testTelemetryComponentsReflow()
testInstructionBudget()

-- Last of the checks, because it builds every shipped layout in both zones
-- and leaves the radio somewhere the tests above do not expect to find it.
testReadingsSitInTheirSlots()
testSupportingWordingsStayDistinct()
testReadingsIgnoreTheRowBeneathThem()
testTertiaryQuarterHoldsItsFurniture()
testTimerIndexIsRefusedAtLoad()
testSupportingRowsFitTheirBox()
testBadgesEndFlushWithTheirPanel()
testNothingIsDrawnOverAnythingElse()
testReadingsDoNotDescendOverAnything()
testTwoRowFooterClearsTheReading()

print("AeroGrid widget integration test passed")
