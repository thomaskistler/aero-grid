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
    hidden = false,
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
  hide = function(object) object.hidden = true end,
  show = function(object) object.hidden = false end,
}

local modelFilename = "test-model.yml"

--- Controllable EdgeTX radio state.
--- Services read sources, sensors, timers, and global variables through the
--- firmware's global functions, so the mock owns one table a test can drive
--- and every entry point reads from it.
local radio = {
  rssi = 80,
  fields = {
    RxBt = {id = 100, name = "RxBt", desc = "Rx battery", unit = 1},
    Curr = {id = 103, name = "Curr", desc = "Current", unit = 2},
    Alt = {id = 106, name = "Alt", desc = "Altitude", unit = 9},
    ["Alt+"] = {id = 108, name = "Alt+", desc = "Altitude max", unit = 9},
    GPS = {id = 109, name = "GPS", desc = "GPS", unit = 40},
    GSpd = {id = 112, name = "GSpd", desc = "GPS speed", unit = 7},
    Dist = {id = 115, name = "Dist", desc = "Distance", unit = 9},
    sa = {id = 300, name = "sa", desc = "Switch A"},
    ["trim-ail"] = {id = 310, name = "trim-ail", desc = "Aileron trim"},
    ["tx-voltage"] = {id = 320, name = "tx-voltage", desc = "Tx voltage"},
  },
  values = {
    [100] = 24.0,
    [103] = 10,
    [106] = 100,
    [108] = 180,
    [109] = {
      lat = 47.3769,
      lon = 8.5417,
      ["pilot-lat"] = 47.3700,
      ["pilot-lon"] = 8.5400,
      delay = 1,
    },
    [112] = 42,
    [115] = 812,
    [300] = 1024,
    [310] = 240,
    [320] = 7.9,
  },
  sensors = {
    [0] = {name = "RxBt", prec = 2},
    [1] = {name = "Curr", prec = 1},
    [2] = {name = "Alt", prec = 0},
  },
  timers = {
    [0] = {value = 90, start = 300, name = "Flight", persistent = 1},
  },
  globals = {[0] = 45},
  globalDetails = {[0] = {name = "Rates", min = -100, max = 100, prec = 1, unit = 0}},
  flightMode = 1,
  flightModeName = "Sport",
}

-- Sixteen generic sensors, so a layout that fills the grid can reference a
-- distinct live source per cell instead of sixteen names the radio rejects.
for index = 1, 16 do
  local name = "S" .. index
  radio.fields[name] = {id = 400 + index, name = name, unit = 9}
  radio.values[400 + index] = index * 3
  radio.sensors[index + 2] = {name = name, prec = 1}
end

-- The remaining sources the service diagnostics layouts reference.
radio.fields["trim-ele"] = {id = 311, name = "trim-ele", desc = "Elevator trim"}
radio.fields["trim-rud"] = {id = 312, name = "trim-rud", desc = "Rudder trim"}
radio.fields["trim-thr"] = {id = 313, name = "trim-thr", desc = "Throttle trim"}
radio.fields.GPS2 = {id = 118, name = "GPS2", desc = "GPS 2", unit = 40}
radio.values[311] = -120
radio.values[312] = 0
radio.values[313] = 64
radio.values[118] = radio.values[109]
radio.timers[1] = {value = 64, start = 0, name = "Up"}
radio.timers[2] = {value = 12, start = 60, name = "Glide"}
for index = 1, 3 do
  radio.globals[index] = index * 10
  radio.globalDetails[index] = {
    name = "GV" .. (index + 1), min = -100, max = 100, prec = 0, unit = 1,
  }
end

--- Reverse index from source id to field, rebuilt whenever a test adds one.
--- It exists so the mock costs a table lookup rather than a scan: getValue is
--- a C function in the firmware and costs no VM instructions at all, so a
--- mock that searched would show up in the instruction budget measurement.
local fieldsById = {}

local function indexFields()
  fieldsById = {}
  for _, field in pairs(radio.fields) do fieldsById[field.id] = field end
end

indexFields()

--- Reset the radio to the state every test starts from.
local function resetRadio()
  indexFields()
  radio.rssi = 80
  radio.values[100] = 24.0
  radio.values[103] = 10
  radio.values[106] = 100
  radio.values[300] = 1024
end

function getValue(source)
  local field
  if type(source) == "string" then
    field = radio.fields[source]
    source = field and field.id or nil
  else
    field = fieldsById[source]
  end
  if source == nil then return nil end

  -- EdgeTX returns integer zero for every telemetry source while telemetry is
  -- not streaming. A mock that kept reporting real values instead would let a
  -- freshness bug pass, because nothing would ever look like a dead link.
  if field and field.unit and radio.rssi == 0 then return 0 end

  return radio.values[source]
end

function getFieldInfo(name)
  return radio.fields[name]
end

function getRSSI()
  return radio.rssi, 45, 42
end

function getFlightMode()
  return radio.flightMode, radio.flightModeName
end

model = {
  getInfo = function()
    return {
      filename = modelFilename,
      name = "Test Model",
      bitmap = "plane.png",
      labels = "fpv",
    }
  end,
  getTimer = function(index) return radio.timers[index] end,
  getSensor = function(index) return radio.sensors[index] end,
  getGlobalVariable = function(index) return radio.globals[index] end,
  getGlobalVariableDetails = function(index) return radio.globalDetails[index] end,
}

-- EdgeTX's monotonic clock, in 10ms ticks. Controllable so scheduling is
-- deterministic rather than dependent on wall time.
local clock = 0

function getTime()
  return clock
end

--- Advance the simulated clock.
local function tick(amount)
  clock = clock + (amount or 1)
end

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

--- Real telemetry must drive the shipped dashboard end to end: the host polls
--- through its services, the metric renders what the service normalized, and
--- every state the design system defines is reachable from radio state alone.
local function testTelemetryDrivesComponents()
  resetRadio()
  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, sourcePath)
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

  -- A metric without a configured unit takes the sensor's own.
  assertEqual(current.unit.properties.text, "A")
  -- And without a configured precision, the sensor's precision.
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
    DEFAULT_OPTIONS, sourcePath)
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

testThemeReachesComponents()
testBackgroundsArePainted()
testResponsiveSpans()
testBadgeGeometry()
testMetricStates()
testTelemetryDrivesComponents()
testOnlyReferencedSourcesArePolled()
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
    -- Count exactly as the firmware does: a hook every 200 instructions.
    debug.sethook(function() ticks = ticks + 1 end, "", 200)
    local ok, err = pcall(fn, ...)
    debug.sethook()
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
      lines[#lines + 1] = "      min: 0"
      lines[#lines + 1] = "      max: 100"
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

  local worst, worstName = 0, "none"
  local worstSteady, worstSteadyName = 0, "none"

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

  exercise("shipped", sourcePath, 5, {"telemetry"})
  exercise("full grid", makeWidget("budget-16", fullGridLayout(16)), 16,
    {"telemetry"})

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

  print(string.format("  budget headroom: worst callback %s used %d of %d",
    worstName, worst, BUDGET))
  print(string.format("  steady state:    worst frame %s used %d of %d",
    worstSteadyName, worstSteady, BUDGET))
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
      min: 18
      max: 25
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

testEdgeTxTheme()
testCustomTheme()
testRadialReflow()
testCreateFailureIsCleaned()
testFailureIsolation()
testEventConsumption()
testContractRejections()
testCorruptLayout()
testModelFilenames()
testMetricReconcilesOnResize()
testRuntimeFailureIsContained()
testServiceDiagnostics()
testDiagnosticsFitTheirPanels()
testMissingServiceModule()
testInstructionBudget()

print("AeroGrid widget integration test passed")
