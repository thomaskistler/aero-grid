-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local widgetPath = root .. "/WIDGETS/AeroGrid/"
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

model = {
  getInfo = function()
    return {filename = "test-model.yml", name = "Test Model"}
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

local widgetChunk = assert(loadfile(widgetPath .. "main.lua"))
local definition = widgetChunk()
local zone = {x = 0, y = 0, w = 480, h = 272}
local context = definition.create(zone, {DashID = "main"}, widgetPath)

assert(definition.name == "AeroGrid")
assert(definition.useLvgl == true)
assert(#context.errors == 0, table.concat(context.errors, "\n"))
assert(#context.components == 2)
assert(context.layoutPath == widgetPath .. "layouts/default.yaml")
assert(context.components[1].instance.panel.properties.w == 238)
assert(context.components[2].instance.panel.properties.h == 272)

zone.w = 320
zone.h = 240
definition.refresh(context)
assert(context.root.properties.w == 320)
assert(context.root.properties.h == 240)
assert(context.components[1].instance.panel.properties.w == 158)

definition.update(context, {DashID = "alternate"})
definition.refresh(context)
assert(context.root.cleared == true)
definition.refresh(context)
assert(#context.components == 2)

print("AeroGrid widget integration test passed")