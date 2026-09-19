-- Build every mock case through the real host and dump what is drawn.
-- Emits Lua source assigning a global CASES table, for the renderer to read.
local root = assert(..., "repository root argument is required")
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local hostIo = io

local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
edgetx.constants()
local lcdMock = edgetx.lcd()
local lvglMock = edgetx.lvgl()
local radioMock = edgetx.radio(hostIo)

io = {
  open = hostIo.open,
  read = function(handle, size) return handle:read(size) end,
  close = function(handle) return handle:close() end,
}

local widgetChunk = assert(loadfile(sourcePath .. "main.lua"))
local definition = widgetChunk()
for _, name in ipairs({"create", "update", "refresh"}) do
  local original = definition[name]
  definition[name] = function(...)
    local first, second = original(...)
    lvglMock.settle()
    return first, second
  end
end

local widgetPath = root .. "/build/flow-widget/"
os.execute("rm -rf '" .. widgetPath .. "'")
os.execute("mkdir -p '" .. widgetPath .. "'")
os.execute("cp -R '" .. sourcePath .. ".' '" .. widgetPath .. "'")

local function writeFile(path, text)
  local handle = assert(hostIo.open(path, "w"))
  handle:write(text)
  handle:close()
end

--- The cases, chosen to cover the rule's interesting corners.
local CONFIG = {
  ["tx-battery"] = "      label: TX\n      packEmpty: 6.6\n      packFull: 8.4\n      showPercent: true\n",
  metric = "      label: ALT\n      source: Alt\n      unit: m\n      rangeMin: 0\n      rangeMax: 400\n      precision: 0\n      visual: bar\n",
  ["metric-radial"] = "      label: CURR\n      source: Curr\n      unit: A\n      rangeMin: 0\n      rangeMax: 120\n      precision: 1\n      visual: radial\n",
  navigation = "      label: HOME\n      source: GPS\n      presentation: detailed\n",
  ["link-status"] = "      label: LINK\n      rssiSource: 1RSS\n      qualitySource: RQly\n      reading: rssi\n",
  ["cell-battery"] = "      label: PACK\n      source: Cels\n      reading: lowest\n      visual: bar\n",
}
local ORDER = {"tx-battery", "metric", "metric-radial", "navigation",
  "link-status", "cell-battery"}
local SPANS = {"1x1", "2x1", "2x2", "4x2"}

--- Both zones a panel can be built in.
---
--- The shipped dashboards are Full screen custom screens, which is what the
--- user is looking at, and App mode reserves a strip for the menu button that
--- pushes every panel's content down. The difference is large enough to change
--- what a panel draws, so both are rendered rather than one being assumed.
local ZONES = {
  {name = "widget", make = function() return lvglMock.fullScreenZone() end},
  {name = "appmode", make = function() return lvglMock.appZone() end},
}

local function layoutFor(typeName, colSpan, rowSpan)
  local realType = typeName == "metric-radial" and "metric" or typeName
  return table.concat({
    "version: 1\n",
    "theme:\n  mode: modern\n",
    "grid:\n  columns: 4\n  rows: 4\n",
    "components:\n",
    "  - id: subject\n",
    "    type: ", realType, "\n",
    "    col: 0\n    row: 0\n",
    "    colSpan: ", tostring(colSpan), "\n",
    "    rowSpan: ", tostring(rowSpan), "\n",
    "    config:\n", CONFIG[typeName],
  })
end

local themeModule = assert(loadfile(sourcePath .. "lib/theme.lua"))()

local fontNames = {}
for _, name in ipairs({"TINSIZE", "SMLSIZE", "MIDSIZE", "DBLSIZE", "XXLSIZE"}) do
  fontNames[edgetx.firmware[name]] = name
end

local function quote(text)
  return string.format("%q", tostring(text == nil and "" or text))
end

local out = {"CASES = {\n"}

for _, zone in ipairs(ZONES) do
for _, typeName in ipairs(ORDER) do
  for _, span in ipairs(SPANS) do
    local colSpan = tonumber(string.sub(span, 1, 1))
    local rowSpan = tonumber(string.sub(span, 3, 3))

    writeFile(widgetPath .. "layouts/default.yaml",
      layoutFor(typeName, colSpan, rowSpan))

    radioMock.reset()
    -- The readings the panels display, so the mock shows real strings.
    radioMock.state.values[130] = {4.11, 4.09, 4.12}
    radioMock.state.values[140] = -72
    radioMock.state.values[141] = 88
    radioMock.state.values[106] = 128
    radioMock.state.values[120] = 24.5
    radioMock.state.values[109] = {
      lat = 47.3769, lon = 8.5417,
      ["pilot-lat"] = 47.3700, ["pilot-lon"] = 8.5400,
    }

    local context = definition.create(zone.make(),
      {DashID = "main", Theme = "modern"}, widgetPath)
    local guard = 0
    while context.stage do
      definition.refresh(context)
      guard = guard + 1
      assert(guard < 400, "staged load never finished for " .. typeName)
    end
    for _ = 1, 60 do
      radioMock.tick(20)
      definition.refresh(context)
    end

    local entry = context.components[1]
    assert(entry, typeName .. " " .. span .. ": " ..
      table.concat(context.errors, "; "))

    -- Reverse the palette so the renderer gets colours it can print.
    local rgbOf = {}
    for token, flags in pairs(context.theme.color) do
      rgbOf[flags] = context.theme.rgb[token]
    end
    for name, flags in pairs(context.theme.alertColor or {}) do
      rgbOf[flags] = (context.theme.alertRgb or {})[name]
    end

    local bounds = entry.container.properties
    out[#out + 1] = string.format(
      "  {component = %q, span = %q, zone = %q, w = %d, h = %d, objects = {\n",
      typeName, span, zone.name, bounds.w, bounds.h)

    local function walk(object, depth)
      for _, child in ipairs(object.children) do
        local p = child.properties
        local x, y = p.x, p.y
        if child.round then x, y = child.round.drawn.x, child.round.drawn.y end
        local font = p.font
        if type(font) == "function" then font = font() end
        out[#out + 1] = string.format(
          "    {kind = %q, depth = %d, x = %d, y = %d, w = %s, h = %s,"
            .. " hidden = %s, font = %q, rgb = %s, text = %s,"
            .. " filled = %s, thickness = %s, rounded = %s,"
            .. " radius = %s, startAngle = %s, endAngle = %s,"
            .. " bgRgb = %s, bgStart = %s, bgEnd = %s,"
            .. " textW = %d, lineH = %d},\n",
          child.kind, depth, x or 0, y or 0,
          tostring(p.w or "nil"), tostring(p.h or "nil"),
          tostring(child.hidden == true),
          fontNames[font] or "",
          tostring(rgbOf[p.color] or "nil"),
          quote(p.text),
          tostring(p.filled == true),
          tostring(p.thickness or "nil"),
          tostring(p.rounded or "nil"),
          tostring(p.radius or "nil"),
          tostring(p.startAngle or "nil"),
          tostring(p.endAngle or "nil"),
          -- An arc carries two sweeps: the foreground one it was asked for
          -- and a background ring behind it. `compass` uses exactly that
          -- pairing, so a renderer that draws only the foreground shows a
          -- pointer floating with no dial around it.
          tostring(rgbOf[p.bgColor] or "nil"),
          tostring(p.bgStartAngle or "nil"),
          tostring(p.bgEndAngle or "nil"),
          -- The real measurement, the same one placement now uses, so the
          -- proposed arrangement flows against what is drawn rather than
          -- against an estimate.
          (child.kind == "label" and font)
            and themeModule.measureText(font, p.text or "") or 0,
          (child.kind == "label" and font)
            and themeModule.fontHeight(font) or 0)
        walk(child, depth + 1)
      end
    end
    walk(entry.container, 0)

    out[#out + 1] = "  }},\n"
  end
end
end

out[#out + 1] = "}\n"
-- The palette, so the page can draw a surface and a canvas behind the panels.
local theme = assert(loadfile(sourcePath .. "lib/theme.lua"))()
local resolved = theme.build("modern")
out[#out + 1] = "FONTS = {\n"
for _, name in ipairs({"TINSIZE", "SMLSIZE", "MIDSIZE", "DBLSIZE", "XXLSIZE"}) do
  local flags = edgetx.firmware[name]
  out[#out + 1] = string.format("  %s = {height = %d, ascent = %d},\n",
    name, themeModule.fontHeight(flags), themeModule.fontAscent(flags))
end
out[#out + 1] = "}\n"

out[#out + 1] = "PALETTE = {\n"
for _, token in ipairs({"canvas", "surface", "border", "track", "text",
    "textMuted", "textFaint", "cyan", "green", "amber", "orange", "critical"}) do
  out[#out + 1] = string.format("  %s = %d,\n", token, resolved.rgb[token])
end
out[#out + 1] = "}\n"

print(table.concat(out))
