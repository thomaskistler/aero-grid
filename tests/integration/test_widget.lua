-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local hostIo = io

STRING = 3
SMLSIZE = 3
MIDSIZE = 4
DBLSIZE = 5
XXLSIZE = 6
TINSIZE = 2
BOLD = 1

COLOR_THEME_PRIMARY1 = 101
COLOR_THEME_PRIMARY2 = 102
COLOR_THEME_PRIMARY3 = 103
COLOR_THEME_SECONDARY1 = 104
COLOR_THEME_SECONDARY2 = 105
COLOR_THEME_SECONDARY3 = 106
COLOR_THEME_FOCUS = 107
COLOR_THEME_EDIT = 108
COLOR_THEME_ACTIVE = 109
COLOR_THEME_WARNING = 110
COLOR_THEME_DISABLED = 111

--- Pack a 24-bit color into RGB565, matching EdgeTX's display format.
local function toRgb565(rgb)
  local red = math.floor(rgb / 65536) % 256
  local green = math.floor(rgb / 256) % 256
  local blue = rgb % 256
  return math.floor(red * 31 / 255) * 2048
    + math.floor(green * 63 / 255) * 32
    + math.floor(blue * 31 / 255)
end

-- A deliberately light EdgeTX theme, so contrast correction must engage.
local edgeTxRoles = {
  [COLOR_THEME_PRIMARY1] = 0x000000,
  [COLOR_THEME_PRIMARY2] = 0xFFFFFF,
  [COLOR_THEME_PRIMARY3] = 0x9E9E9E,
  [COLOR_THEME_SECONDARY1] = 0x1B3A57,
  [COLOR_THEME_SECONDARY2] = 0x3F7CA8,
  [COLOR_THEME_SECONDARY3] = 0xC8D8E4,
  [COLOR_THEME_FOCUS] = 0x1E88E5,
  [COLOR_THEME_EDIT] = 0xFF8F00,
  [COLOR_THEME_ACTIVE] = 0x43A047,
  [COLOR_THEME_WARNING] = 0xF9A825,
  [COLOR_THEME_DISABLED] = 0x757575,
}

lcd = {
  -- EdgeTX accepts lcd.RGB(r, g, b) or a single packed lcd.RGB(rgb).
  RGB = function(red, green, blue)
    if green == nil and blue == nil then return red end
    return red * 65536 + green * 256 + blue
  end,
  getColor = function(role)
    return toRgb565(edgeTxRoles[role] or 0x000000)
  end,
}

local objects = {}

local function newObject(kind, parent, properties)
  local object = {
    kind = kind,
    parent = parent,
    properties = properties,
    cleared = false,
  }

  function object:set(changes)
    for key, value in pairs(changes) do self.properties[key] = value end
  end

  function object:clear()
    self.cleared = true
  end

  objects[#objects + 1] = object
  return object
end

local function constructor(kind)
  return function(first, second)
    if second then return newObject(kind, first, second) end
    return newObject(kind, nil, first)
  end
end

lvgl = {
  box = constructor("box"),
  rectangle = constructor("rectangle"),
  label = constructor("label"),
  arc = constructor("arc"),
}

local modelFilename = "test-model.yml"

model = {
  getInfo = function()
    return {filename = modelFilename, name = "Test Model"}
  end,
}

function loadScript(filename)
  return loadfile(filename)
end

function fstat(filename)
  local handle = hostIo.open(filename, "rb")
  if not handle then return nil end
  local size = handle:seek("end")
  handle:close()
  return {size = size}
end

io = {
  open = hostIo.open,
  read = function(handle, size) return handle:read(size) end,
  close = function(handle) return handle:close() end,
}

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
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
local themeModule = assert(loadfile(sourcePath .. "lib/theme.lua"))()

assertEqual(definition.name, "AeroGrid")
assertEqual(definition.useLvgl, true)
assert(type(definition.background) == "function", "host must expose background")
assert(type(definition.event) == "function", "host must expose event")
assertEqual(definition.translate("Theme"), "Theme")

local DEFAULT_OPTIONS = {DashID = "main", Theme = "modern"}

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

--- Architecture checkpoint: the shipped layout must load separately authored
--- component modules and render them correctly in App mode and ordinary 1 x 1.
local function testRendersInBothModes(label, zone)
  local context = createLoaded(zone, DEFAULT_OPTIONS, sourcePath)

  assertEqual(#context.errors, 0, label .. ": " .. table.concat(context.errors, "\n"))
  assertEqual(#context.components, 5, label .. ": component count")
  assertEqual(context.layoutPath, sourcePath .. "layouts/default.yaml")

  local types = {}
  for _, entry in ipairs(context.components) do
    types[entry.module.id] = true
  end
  assert(types.metric and types.placeholder and types.heartbeat,
    label .. ": expected three independently authored component modules")

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

-- App mode occupies the full TX16S-class display; 1 x 1 loses the top bar.
local appContext = testRendersInBothModes("app mode", {x = 0, y = 0, w = 480, h = 272})
testRendersInBothModes("1 x 1", {x = 0, y = 0, w = 480, h = 232})

--- The host owns the palette: every panel uses the resolved surface token.
local function testThemeReachesComponents()
  local modern = themeModule.modern()
  assertEqual(appContext.theme.mode, "modern")
  assertEqual(appContext.canvas.properties.color, modern.canvas)

  for _, entry in ipairs(appContext.components) do
    assertEqual(entry.instance.panel.background.properties.color, modern.surface,
      entry.placement.id .. " did not use the theme surface")
  end

  -- Components receive span-appropriate typography from the host.
  local pack = entryById(appContext, "pack")
  local current = entryById(appContext, "current")
  assertEqual(pack.instance.fonts.primary, XXLSIZE)
  assertEqual(current.instance.fonts.primary, DBLSIZE)
end

--- EdgeTX's lvgl.box parses `color` but never paints it, so any background
--- drawn with a box silently inherits the radio's own theme instead of ours.
--- Every visible surface must therefore be a filled rectangle.
local function testBackgroundsArePainted()
  local function assertPainted(object, what)
    assertEqual(object.kind, "rectangle", what .. " must be a rectangle")
    assertEqual(object.properties.filled, true, what .. " must be filled")
    assert(object.properties.color ~= nil, what .. " has no color")
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
  assertEqual(pack.panel.accent.properties.color, modern.cyan)

  -- Falling thresholds: warning at 21.0, critical at 19.8.
  metricModule.setValue(pack, 20.5)
  assertEqual(pack.stateName, "warning")
  assertEqual(pack.badge.properties.text, "WARN")
  assertEqual(pack.panel.accent.properties.color, modern.amber)

  metricModule.setValue(pack, 19.0)
  assertEqual(pack.stateName, "critical")
  assertEqual(pack.badge.properties.text, "CRIT")
  assertEqual(pack.panel.accent.properties.color, modern.critical)

  metricModule.setValue(pack, 24.0, true)
  assertEqual(pack.stateName, "stale")
  assertEqual(pack.badge.properties.text, "STALE")

  metricModule.setValue(pack, nil)
  assertEqual(pack.stateName, "unavailable")
  assertEqual(pack.badge.properties.text, "NO SOURCE")
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
  definition.refresh(appContext)
  assertEqual(appContext.root.properties.w, 320)
  assertEqual(appContext.root.properties.h, 240)
  assertEqual(panelOf(entryById(appContext, "pack")).w, 158)
  local pulse = entryById(appContext, "pulse")
  local ticksBefore = pulse.instance.ticks
  definition.refresh(appContext)
  definition.refresh(appContext)
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
  definition.refresh(appContext)
  assertEqual(appContext.root.cleared, true)
  assert(appContext.stage, "reload did not restage a load")

  local guard = 0
  while appContext.stage do
    definition.refresh(appContext)
    guard = guard + 1
    assert(guard < 200, "reload never finished")
  end
  assertEqual(#appContext.components, 5)

  -- Switching only the theme must also trigger a rebuild.
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, sourcePath)
  definition.update(context, {DashID = "main", Theme = "custom"})
  assertEqual(context.reloadState, "clear")
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
      min: 0
      max: 100
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  local dial = entryById(context, "dial")
  assert(dial.instance.radial, "radial visualization was not created")

  local arc = dial.instance.radial.arc.properties
  local bounds = boundsOf(dial)
  local firstRadius = arc.radius
  assert(arc.x + arc.radius * 2 <= bounds.w, "radial overflows its panel")

  -- The value must not sit underneath the arc.
  local value = dial.instance.value.properties
  assert(value.x + value.w <= arc.x, "value overlaps the radial")

  zone.w = 240
  zone.h = 160
  definition.refresh(context)

  local resized = dial.instance.radial.arc.properties
  local newBounds = boundsOf(dial)
  assert(resized.radius < firstRadius, "radial did not shrink with the panel")
  assert(resized.x + resized.radius * 2 <= newBounds.w,
    "radial overflowed after reflow")
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

--- The demo driver must cycle visible states through the host refresh loop.
local function testDemoCycle()
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, sourcePath)
  local pack = entryById(context, "pack").instance
  local seen = {}
  local badges = {}

  -- One full cycle is five phases of forty-five refreshes.
  for _ = 1, 235 do
    definition.refresh(context)
    seen[pack.stateName] = true
    badges[pack.stateName] = pack.badge.properties.text
  end

  for _, state in ipairs({"normal", "warning", "critical", "stale", "unavailable"}) do
    assert(seen[state], "demo never reached " .. state)
  end

  assertEqual(badges.normal, "")
  assertEqual(badges.warning, "WARN")
  assertEqual(badges.critical, "CRIT")
  assertEqual(badges.stale, "STALE")
  assertEqual(badges.unavailable, "NO SOURCE")
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

testThemeReachesComponents()
testBackgroundsArePainted()
testResponsiveSpans()
testBadgeGeometry()
testMetricStates()
testDemoCycle()
testReflowAndLifecycle()
testOptionReload()

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

  -- Derived from COLOR_THEME_SECONDARY1, so it must not be the Modern surface.
  assert(tokens.canvas ~= modern.canvas, "EdgeTX canvas was not derived")
  -- Critical red stays dashboard-owned so alarms remain recognizable.
  assertEqual(tokens.critical, modern.critical)
  -- Contrast correction must keep body text readable on the derived surface.
  assert(themeModule.contrast(tokens.surface, tokens.text) >= 4.5,
    "derived text failed contrast correction")
  assert(themeModule.contrast(tokens.surface, tokens.canvas) >= 1.0)
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
  assertEqual(context.theme.rgb.surface, 0x101010)
  assertEqual(context.theme.accent, "green")
  -- border is outside the customizable set and must be reported, not applied.
  assertEqual(context.theme.rgb.border, themeModule.modern().border)

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

  definition.refresh(context)

  local boom = entryById(context, "boom")
  local safe = entryById(context, "safe")
  assertEqual(boom.failed, true, "failing component was not disabled")
  assert(string.match(boom.error, "exploder failed"), boom.error)
  assertEqual(safe.failed, nil, "healthy component was disabled")
  assertEqual(#context.errors, 1, "failure was not reported exactly once")
  assert(context.errorLabel, "failure was not shown")

  -- Further refreshes must stay quiet and keep the healthy component running.
  definition.refresh(context)
  definition.refresh(context)
  assertEqual(#context.errors, 1, "failure was reported repeatedly")
  assertEqual(#context.components, 2)
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
local function testInstructionBudget()
  local BUDGET = 20000
  local CEILING = BUDGET * 0.75

  local function measure(fn, ...)
    local ticks = 0
    -- Count exactly as the firmware does: a hook every 200 instructions.
    debug.sethook(function() ticks = ticks + 1 end, "", 200)
    local ok, err = pcall(fn, ...)
    debug.sethook()
    assert(ok, "callback raised: " .. tostring(err))
    return ticks * 200
  end

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local worst = 0
  local worstName = "none"

  local function record(name, cost)
    assert(cost < CEILING, string.format(
      "%s used %d instructions, over the %d ceiling (firmware limit %d)",
      name, cost, CEILING, BUDGET))
    if cost > worst then worst = cost; worstName = name end
  end

  local context
  record("create", measure(function()
    context = definition.create(zone, DEFAULT_OPTIONS, sourcePath)
  end))

  local steps = 0
  while context.stage do
    local stage = context.stage
    record("refresh/" .. stage, measure(definition.refresh, context))
    steps = steps + 1
    assert(steps < 200, "staged load never finished")
  end
  assertEqual(#context.components, 5)
  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

  -- Steady state runs on every screen redraw, so it matters most.
  record("refresh/steady", measure(definition.refresh, context))
  record("background", measure(definition.background, context))
  record("event", measure(definition.event, context, 32))

  -- A zone change reflows every component in one callback.
  zone.w = 320
  zone.h = 240
  record("refresh/reflow", measure(definition.refresh, context))

  print(string.format("  budget headroom: worst callback %s used %d of %d",
    worstName, worst, BUDGET))
end
local function testModelFilenames()
  local previous = modelFilename
  for _, name in ipairs({"model1.yml", "Kavan Sonic.yml", "FPV-7in.yml"}) do
    modelFilename = name
    local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
      DEFAULT_OPTIONS, sourcePath)
    assertEqual(context.layoutPath, sourcePath .. "layouts/default.yaml",
      "unexpected layout for " .. name)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    assertEqual(#context.components, 5)
  end
  modelFilename = previous
end

testEdgeTxTheme()
testCustomTheme()
testRadialReflow()
testCreateFailureIsCleaned()
testFailureIsolation()
testEventConsumption()
testContractRejections()
testCorruptLayout()
testModelFilenames()
testInstructionBudget()

print("AeroGrid widget integration test passed")
