-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local hostIo = io

STRING = 3
SMLSIZE = 3
BOLD = 1

lcd = {
  RGB = function(red, green, blue)
    return red * 65536 + green * 256 + blue
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

assertEqual(definition.name, "AeroGrid")
assertEqual(definition.useLvgl, true)
assert(type(definition.background) == "function", "host must expose background")

--- Find a loaded component entry by its layout id.
local function entryById(context, id)
  for _, entry in ipairs(context.components) do
    if entry.placement.id == id then return entry end
  end
  return nil
end

--- Report whether two rendered panels share any pixel.
local function panelsOverlap(first, second)
  local a, b = first.properties, second.properties
  return a.x < b.x + b.w and b.x < a.x + a.w
    and a.y < b.y + b.h and b.y < a.y + a.h
end

--- Architecture checkpoint: the shipped layout must load two separately authored
--- component modules and render them correctly in App mode and ordinary 1 x 1.
local function testCheckpointRendersInBothModes(label, zone)
  local context = definition.create(zone, {DashID = "main"}, sourcePath)

  assertEqual(#context.errors, 0, label .. ": " .. table.concat(context.errors, "\n"))
  assertEqual(#context.components, 3, label .. ": component count")
  assertEqual(context.layoutPath, sourcePath .. "layouts/default.yaml")

  local types = {}
  for _, entry in ipairs(context.components) do
    types[entry.module.id] = true
  end
  assert(types.placeholder and types.heartbeat,
    label .. ": expected two independently authored component modules")

  for _, entry in ipairs(context.components) do
    local panel = entry.instance.panel.properties
    assert(panel.x >= 0 and panel.y >= 0, label .. ": panel outside zone origin")
    assert(panel.x + panel.w <= zone.w, label .. ": panel exceeds zone width")
    assert(panel.y + panel.h <= zone.h, label .. ": panel exceeds zone height")
    assert(panel.w > 0 and panel.h > 0, label .. ": panel collapsed")
  end

  for first = 1, #context.components do
    for second = first + 1, #context.components do
      assert(not panelsOverlap(context.components[first].instance.panel,
        context.components[second].instance.panel),
        label .. ": rendered panels overlap")
    end
  end

  return context
end

-- App mode occupies the full TX16S-class display; 1 x 1 loses the top bar.
local appContext = testCheckpointRendersInBothModes("app mode", {x = 0, y = 0, w = 480, h = 272})
testCheckpointRendersInBothModes("1 x 1", {x = 0, y = 0, w = 480, h = 232})

assertEqual(appContext.components[1].instance.panel.properties.w, 238)
assertEqual(appContext.components[2].instance.panel.properties.h, 272)

--- Settings defaults declared by the module reach the component instance.
assertEqual(appContext.components[1].settings.title, "AEROGRID")
assertEqual(entryById(appContext, "pulse").settings.label, "HEARTBEAT")

--- Zone changes reflow every component through the isolated resize dispatch.
local zone = appContext.zone
zone.w = 320
zone.h = 240
definition.refresh(appContext)
assertEqual(appContext.root.properties.w, 320)
assertEqual(appContext.root.properties.h, 240)
assertEqual(appContext.components[1].instance.panel.properties.w, 158)

--- Foreground and background lifecycle callbacks reach live components.
local pulse = entryById(appContext, "pulse")
local ticksBefore = pulse.instance.ticks
definition.refresh(appContext)
definition.refresh(appContext)
assertEqual(pulse.instance.ticks, ticksBefore + 2, "refresh was not dispatched")

definition.background(appContext)
assertEqual(pulse.instance.backgroundTicks, 1, "background was not dispatched")

--- Changing Dashboard ID tears down and rebuilds without leaking components.
definition.update(appContext, {DashID = "alternate"})
definition.refresh(appContext)
assertEqual(appContext.root.cleared, true)
definition.refresh(appContext)
assertEqual(#appContext.components, 3)

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
function exploder.create(parent, rect)
  return {panel = lvgl.box(parent, {x = rect.x, y = rect.y, w = rect.w, h = rect.h})}
end
function exploder.refresh()
  error("exploder failed", 0)
end
return exploder
]==],
  })

  local context = definition.create({x = 0, y = 0, w = 480, h = 272},
    {DashID = "main"}, widgetPath)
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

  local context = definition.create({x = 0, y = 0, w = 480, h = 272},
    {DashID = "main"}, widgetPath)

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
  local context = definition.create({x = 0, y = 0, w = 480, h = 272},
    {DashID = "main"}, widgetPath)

  assertEqual(#context.components, 0)
  assert(#context.errors > 0, "corrupt layout reported no error")
  assert(context.errorLabel, "corrupt layout was not shown")
end

--- Several real model filenames must each resolve and fall back cleanly.
local function testModelFilenames()
  local previous = modelFilename
  for _, name in ipairs({"model1.yml", "Kavan Sonic.yml", "FPV-7in.yml"}) do
    modelFilename = name
    local context = definition.create({x = 0, y = 0, w = 480, h = 272},
      {DashID = "main"}, sourcePath)
    assertEqual(context.layoutPath, sourcePath .. "layouts/default.yaml",
      "unexpected layout for " .. name)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    assertEqual(#context.components, 3)
  end
  modelFilename = previous
end

testFailureIsolation()
testContractRejections()
testCorruptLayout()
testModelFilenames()

print("AeroGrid widget integration test passed")
