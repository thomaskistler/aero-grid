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

-- Objects whose clear() is still awaiting EdgeTX's deferred cleanup.
local pendingClears = {}

--- Emulate the firmware's post-callback ref cleanup.
--- EdgeTX runs callRefs() AFTER a widget callback returns, and a pending
--- clear() then invalidates every ref in that object's child list, including
--- children created after the clear but within the same callback. Modelling
--- clear() as an immediate flag hid a real defect, so this mirrors the
--- firmware's ordering instead.
-- When true, deferred cleanup is withheld, exactly as the firmware withholds
-- it while the widget is off screen or once an error has been reported.
local deferCleanup = false

local function settleLvgl()
  if deferCleanup then return end
  if #pendingClears == 0 then return end

  local pending = pendingClears
  pendingClears = {}
  for _, object in ipairs(pending) do
    object.clearRequest = false
    for _, child in ipairs(object.children) do
      child.invalid = true
    end
    object.children = {}
  end
end

local function newObject(kind, parent, properties)
  local object = {
    kind = kind,
    parent = parent,
    properties = properties,
    children = {},
    cleared = false,
    hidden = false,
    invalid = false,
  }

  local function assertUsable(object)
    if object.invalid then
      error("Invalid object (it has been probably been cleared).", 0)
    end
  end

  function object:set(changes)
    assertUsable(self)
    for key, value in pairs(changes) do self.properties[key] = value end
  end

  function object:clear()
    assertUsable(self)
    self.cleared = true
    if not self.clearRequest then
      self.clearRequest = true
      pendingClears[#pendingClears + 1] = self
    end
  end

  if parent then parent.children[#parent.children + 1] = object end
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
  image = constructor("image"),
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

-- Vertical speed, which the metric's altitude preset takes as its secondary
-- reading. It is never derived from altitude; an absent sensor simply leaves
-- the secondary row unavailable.
radio.fields.VSpd = {id = 120, name = "VSpd", desc = "Vertical speed", unit = 5}
radio.values[120] = 2.5
radio.sensors[19] = {name = "VSpd", prec = 1}

-- A flight pack. EdgeTX returns a table of individual cell voltages for the
-- base cells source, and a plain number for its extremes, which is exactly the
-- shape mismatch cell-battery has to survive.
radio.fields.Cels = {id = 130, name = "Cels", desc = "Cells", unit = 38}
radio.fields["Cels-"] = {id = 131, name = "Cels-", desc = "Cell min", unit = 38}
radio.fields["Cels+"] = {id = 132, name = "Cels+", desc = "Cell max", unit = 38}
radio.values[130] = {4.11, 4.13, 4.09, 4.12}
radio.values[131] = 4.09
radio.values[132] = 4.13
radio.sensors[20] = {name = "Cels", prec = 2}

-- Link sensors. FrSky populates RSSI in dB; ELRS populates 1RSS in dBm
-- alongside RQly as a percentage, and the two protocols never both apply.
radio.fields.RSSI = {id = 140, name = "RSSI", desc = "RSSI", unit = 17}
radio.fields.RQly = {id = 141, name = "RQly", desc = "Link quality", unit = 13}
radio.fields["RQly-"] = {id = 142, name = "RQly-", desc = "Link quality min", unit = 13}
radio.fields["1RSS"] = {id = 143, name = "1RSS", desc = "Antenna 1", unit = 29}
radio.values[140] = 78
radio.values[141] = 96
radio.values[142] = 62
radio.values[143] = -72
radio.sensors[21] = {name = "RSSI", prec = 0}
radio.sensors[22] = {name = "RQly", prec = 0}

-- Further GPS sources, so a layout that fills the grid with navigation panels
-- really does carry more than one subscription.
radio.fields.GPS3 = {id = 119, name = "GPS3", desc = "GPS 3", unit = 40}
radio.fields.GPS4 = {id = 121, name = "GPS4", desc = "GPS 4", unit = 40}
radio.values[119] = radio.values[109]
radio.values[121] = radio.values[109]

--- Does this radio's protocol populate an RSSI sensor at all?
--- Some do not, and EdgeTX's getRSSI() then reads zero on a perfectly live
--- link. That is a different situation from a dead link and the two must not
--- be simulated by the same flag, or a test cannot tell them apart either.
radio.rssiAbsent = false

--- Files the radio reports through `fstat`, keyed by absolute path.
--- Model bitmaps live under /IMAGES/ on the SD card, which the host running
--- these tests does not have, so the mock answers for them directly.
radio.files = {["/IMAGES/plane.png"] = 4096}

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
  radio.rssiAbsent = false
  radio.values[100] = 24.0
  radio.values[103] = 10
  radio.values[106] = 100
  radio.values[300] = 1024
  radio.values[130] = {4.11, 4.13, 4.09, 4.12}
  radio.values[131] = 4.09
  radio.values[140] = 78
  radio.values[141] = 96
  radio.values[109].lat = 47.3769
  radio.values[109].lon = 8.5417
  radio.values[109]["pilot-lat"] = 47.3700
  radio.values[109]["pilot-lon"] = 8.5400
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
  --
  -- The RSSI indicator is not the same thing as the telemetry stream: on a
  -- protocol that populates no RSSI sensor, getRSSI() reads zero while values
  -- keep arriving. `rssiAbsent` simulates that, and nothing else does.
  if field and field.unit and radio.rssi == 0 and not radio.rssiAbsent then
    return 0
  end

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
  -- The radio's own SD card comes first, so a test can describe a model
  -- bitmap that the host filesystem does not have.
  local size = radio.files[filename]
  if size then return {size = size} end

  local handle = hostIo.open(filename, "rb")
  if not handle then return nil end
  size = handle:seek("end")
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
      min: 18
      max: 25.2
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
      min: 0
      max: 120
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
      min: 0
      max: 400
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
      title: PHASE 1
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

-- App mode occupies the full TX16S-class display; 1 x 1 loses the top bar.
local appContext = testRendersInBothModes("app mode", {x = 0, y = 0, w = 480, h = 272})
testRendersInBothModes("1 x 1", {x = 0, y = 0, w = 480, h = 232})

--- Milestone 7's deliverable: the shipped dashboard must demonstrate the
--- complete ten-component catalogue, loading each from its own module without
--- error and keeping each one inside the container the host gave it.
local SHIPPED_TYPES = {
  "metric", "flight-timer", "flight-mode", "tx-battery",
  "variable-indicator", "trim-panel", "model-identity",
  "cell-battery", "link-status", "navigation",
}

local function testShippedLayout()
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
  assertEqual(pack.countText, "4S")
  assertEqual(pack.packText, "16.4V PACK")

  local link = entryById(context, "link").instance
  assertEqual(link.primaryName, "quality", "auto must prefer link quality")
  assertEqual(link.text, "96%")
  assertEqual(link.stateName, "normal")

  local nav = entryById(context, "nav").instance
  assertEqual(nav.text, "778m")
  assertEqual(nav.detail, "BRG 009 N")
  -- The caption shares its row with the bearing, so on a 2 x 2 panel the full
  -- wording does not fit and must abbreviate rather than clip. It read
  -- "NORTH UP FROM" on a radio before this was handled.
  assertEqual(nav.origin, "NORTH UP")
  assert(nav.compass, "the shipped dashboard must demonstrate the dial")
end

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
  deferCleanup = true
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
  deferCleanup = false
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
      min: 0
      max: 100
]])

  local zone = {x = 0, y = 0, w = 480, h = 272}
  local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
  local dial = entryById(context, "dial")
  assert(dial.instance.radial, "radial visualization was not created")

  -- EdgeTX positions an arc by its centre: LvglWidgetArc::build calls setPos,
  -- and LvglWidgetRoundObject::setPos stores x - radius. A test that read x
  -- as a corner would pass while the arc was drawn a radius off the panel.
  local arc = dial.instance.radial.arc.properties
  local bounds = boundsOf(dial)
  local firstRadius = arc.radius
  local box = primitivesModule.arcBounds(arc.x, arc.y, arc.radius)
  assert(box.x >= 0 and box.y >= 0, "radial was drawn off its own panel")
  assert(box.x + box.w <= bounds.w, "radial overflows its panel")
  assert(box.y + box.h <= bounds.h, "radial overflows its panel")

  -- The value must not sit underneath the arc.
  local value = dial.instance.value.properties
  assert(value.x + value.w <= box.x, "value overlaps the radial")

  zone.w = 240
  zone.h = 160
  definition.refresh(context)

  local resized = dial.instance.radial.arc.properties
  local newBounds = boundsOf(dial)
  local newBox = primitivesModule.arcBounds(resized.x, resized.y, resized.radius)
  assert(resized.radius < firstRadius, "radial did not shrink with the panel")
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
          "armSource: sa",
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
        return {"min: 6.6", "max: 8.4", "warning: 7.0", "showPercent: true"}
      end,
    },
    {
      type = "variable-indicator",
      services = {"control"},
      config = function(index)
        local presentations = {
          "value", "horizontal-bar", "bipolar-bar", "radial",
        }
        return {
          "binding: global",
          "index: " .. ((index - 1) % 4),
          "presentation: " .. presentations[(index - 1) % 4 + 1],
        }
      end,
    },
    {
      type = "trim-panel",
      services = {"control"},
      config = function()
        -- Four indicators each, so the panel builds and drives the most
        -- objects it ever can.
        return {"mode: all", "display: percent", "scale: auto"}
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
          "primary: " .. (index % 2 == 0 and "auto" or "rssi"),
          "extrema: flight",
          "armSource: sa",
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
      DEFAULT_OPTIONS, referencePath)
    assertEqual(context.layoutPath, referencePath .. "layouts/default.yaml",
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
      min: 6.6
      max: 8.4
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
      presentation: horizontal-bar
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
      mode: all
      orientation: horizontal
      display: raw
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
      presentation: radial
      min: 0
      max: 120
  - id: swing
    type: variable-indicator
    col: 3
    row: 3
    colSpan: 1
    rowSpan: 1
    config:
      binding: global
      index: 0
      presentation: bipolar-bar
]]

--- Advance a context far enough for every service and component to settle.
local function settle(context, count)
  for _ = 1, (count or 60) do
    tick(20)
    definition.refresh(context)
  end
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
  radio.timers[0] = {value = -15, start = 300, name = "Flight", persistent = 1}
  settle(context, 12)
  assertEqual(countdown.text, "-0:15", "an expired countdown lost its sign")
  assertEqual(countdown.detail, "ELAPSED PAST ZERO")
  assertEqual(countdown.stateName, "critical")
  radio.timers[0] = {value = 90, start = 300, name = "Flight", persistent = 1}

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

  -- EdgeTX resolves global variable inheritance, so the value read for two
  -- flight modes is frequently identical. The row that names the mode has to
  -- follow the mode anyway, or it reports the wrong one with a straight face.
  radio.flightMode, radio.flightModeName = 2, "Land"
  settle(context, 12)
  assertEqual(gv.text, "10%", "the inherited value should not have moved")
  assertEqual(gv.detail, "GV2 FM2", "the flight mode row went stale")
  radio.flightMode, radio.flightModeName = 1, "Sport"
  settle(context, 12)

  -- The same component bound to a telemetry source instead.
  local dial = entryById(context, "dial").instance
  assertEqual(dial.text, "10.0A")
  assert(dial.radial, "the radial presentation was not built")
  -- 10 of 0..120 is a small part of a 270 degree sweep.
  assertEqual(dial.radial.arc.properties.endAngle, 135 + 23)

  -- Trims are read through EdgeTX's own sources, in stored trim units.
  local trims = entryById(context, "trims").instance
  assertEqual(#trims.indicators, 4)
  assertEqual(trims.indicators[1].valueText, "+30", "240 raw is 30 trim units")
  assertEqual(trims.indicators[2].valueText, "-15")
  assertEqual(trims.indicators[3].valueText, "+8")
  assertEqual(trims.indicators[4].valueText, "0")
  assertEqual(trims.indicators[1].caption.properties.text, "AIL")
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
      mode: pair
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
    return {filename = modelFilename, name = "No Picture", bitmap = "gone.png"}
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
    assertEqual(instance.badge.properties.text, "NO SOURCE",
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

      for _, object in ipairs(objects) do
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
      primary: auto
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
      primary: rssi
      min: -110
      max: -30
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
  -- EdgeTX's own minimum for the leading source, explicitly named.
  assertEqual(link.detail, "MIN 62")
  assertEqual(link.linkDetail, "RSSI 78dB")

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
  assertEqual(nav.detail, "BRG 009 N")
  assertEqual(nav.origin, "NORTH UP")
  assertEqual(nav.coordinates, "47.37690 8.54170")
  assertEqual(nav.stateName, "normal")
  assert(nav.compass, "the detailed presentation must carry the dial")
  -- The pointer is a real direction, not a ring resting at north.
  assertEqual(nav.compass.ring.properties.opacity, 255)

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
  settle(context, 40)

  assertEqual(pack.stateName, "stale", "a dropped link hid the last cells")
  assertEqual(pack.text, "4.09V", "a stale poll overwrote the reading")
  assertEqual(pack.badge.properties.text, "STALE")

  assertEqual(link.stateName, "critical", "a dead link is the measurement")
  assertEqual(link.badge.properties.text, "NO LINK")
  assertEqual(link.linkDetail, "LINK DOWN")

  assertEqual(nav.stateName, "stale")
  assertEqual(nav.text, "778m", "the last known position was discarded")
  assertEqual(nav.origin, "LAST KNOWN")

  -- Reconnect. Nothing may be left marked once readings arrive again.
  radio.rssi = 80
  settle(context, 40)
  assertEqual(pack.stateName, "normal")
  assertEqual(link.stateName, "normal")
  assertEqual(link.badge.properties.text, "")
  assertEqual(nav.stateName, "normal")
  assertEqual(nav.origin, "NORTH UP")

  -- A fix EdgeTX has not acquired reports zero for both axes, which is a real
  -- place off the coast of Africa and must never be shown as one.
  radio.values[109].lat = 0
  radio.values[109].lon = 0
  settle(context, 40)
  assertEqual(nav.stateName, "unavailable")
  assertEqual(nav.badge.properties.text, "NO FIX")
  assertEqual(nav.text, "--", "a missing fix was shown as a distance")
  assertEqual(nav.coordinates, "-- , --")
  -- The dial must not point anywhere when there is nowhere to point.
  assertEqual(nav.compass.ring.properties.opacity, 0)

  -- A fix without a home position: the position is perfectly good, but a
  -- distance and a bearing would be measured from nowhere.
  radio.values[109].lat = 47.3769
  radio.values[109].lon = 8.5417
  radio.values[109]["pilot-lat"] = 0
  radio.values[109]["pilot-lon"] = 0
  settle(context, 40)
  assertEqual(nav.stateName, "normal", "a missing home is not a broken fix")
  assertEqual(nav.badge.properties.text, "NO HOME")
  assertEqual(nav.text, "--")
  assertEqual(nav.detail, "BRG --", "a bearing was invented without a home")
  assertEqual(nav.origin, "NO HOME POS")
  assertEqual(nav.coordinates, "47.37690 8.54170",
    "the position itself is still known")

  -- A table whose entries cannot be cell voltages. The explicit lowest-cell
  -- source keeps the reading alive, and the count row says the table is gone.
  radio.values[130] = {0, -1, 99}
  settle(context, 40)
  assertEqual(pack.summary.shape, "invalid")
  assertEqual(pack.text, "4.09V")
  assertEqual(pack.countText, "NO CELLS")
  assertEqual(pack.packText, "", "a pack sum was computed from nonsense")

  assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
  resetRadio()
end

--- A cells source that is not a cells source.
---
--- "Cels-" carries the cells unit but returns a plain number, which milestone
--- 5 found and normalized, so a layout naming it here resolves to a numeric
--- reading rather than a table. That is a configuration mistake, not a failed
--- link, and it reads differently: "NOT CELLS" says which fix is needed.
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
  settle(context, 40)

  for _, id in ipairs({"extreme", "voltage"}) do
    local instance = entryById(context, id).instance
    assertEqual(instance.summary.shape, "number",
      id .. " read a plain number as a cells table")
    assertEqual(instance.stateName, "unavailable")
    assertEqual(instance.badge.properties.text, "NOT CELLS",
      id .. " reported a shape problem as a missing source")
    assertEqual(instance.text, "--", "a number was shown as a cell voltage")
  end

  -- A sensor the radio has never heard of is a different problem again, and
  -- keeps the ordinary wording.
  local absent = entryById(context, "absent").instance
  assertEqual(absent.summary.shape, "none")
  assertEqual(absent.stateName, "unavailable")
  assertEqual(absent.badge.properties.text, "NO SOURCE")

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
  assertEqual(link.linkDetail, "RSSI 70dB")

  radio.values[140] = 41
  settle(context, 20)
  assertEqual(link.text, "100%", "link quality should not have moved")
  assertEqual(link.linkDetail, "RSSI 41dB", "the RSSI row froze during a fade")

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
  assertEqual(nav.badge.properties.text, "NO SOURCE")
  assertEqual(nav.origin, "NO GPS SOURCE")

  -- The sensor arrives, but without a position yet: this is the cold start,
  -- and it is a different message from a layout naming a sensor that is not
  -- there. Nothing else in the snapshot moves, so only `known` says so.
  radio.fields.LateGps = {id = 150, name = "LateGps", desc = "Late GPS", unit = 40}
  radio.values[150] = {lat = 0, lon = 0, ["pilot-lat"] = 0, ["pilot-lon"] = 0}
  indexFields()
  settle(context, 60)

  assertEqual(nav.stateName, "unavailable")
  assertEqual(nav.badge.properties.text, "NO FIX",
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
  indexFields()
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
      primary: auto
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
      primary: rssi
]])

  -- A live link whose protocol has no RSSI sensor: values keep arriving while
  -- the indicator reads zero, and no RSSI sensor exists to be resolved.
  local realRssi = radio.fields.RSSI
  radio.rssi = 0
  radio.rssiAbsent = true
  radio.fields.RSSI = nil
  indexFields()

  local context = createLoaded({x = 0, y = 0, w = 480, h = 272},
    DEFAULT_OPTIONS, widgetPath)
  settle(context, 60)

  local link = entryById(context, "link").instance
  assertEqual(link.primaryName, "quality",
    "auto must fall back to the source the protocol actually has")
  assertEqual(link.text, "96%", "a live reading was discarded as a dead link")
  assertEqual(link.stateName, "normal")
  assertEqual(link.badge.properties.text, "")
  assertEqual(link.linkDetail, "NO RSSI SENSOR")

  -- A panel configured for RSSI alone on such a protocol has nothing to show,
  -- and must say the sensor is missing rather than report zero or claim the
  -- link is down.
  local rssiOnly = entryById(context, "rssionly").instance
  assertEqual(rssiOnly.stateName, "unavailable")
  assertEqual(rssiOnly.badge.properties.text, "NO SENSOR")
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

      for _, object in ipairs(objects) do
        if object.parent == instance.panel.root and not object.hidden then
          local properties = object.properties
          local right, bottom
          if object.kind == "arc" then
            local box = primitivesModule.arcBounds(
              properties.x, properties.y, properties.radius)
            assert(box.x >= -1 and box.y >= -1, what .. ": " .. entry.placement.id
              .. " drew an arc off its top or left edge")
            right = box.x + box.w
            bottom = box.y + box.h
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
