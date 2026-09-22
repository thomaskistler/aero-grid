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
--- **The shipped dashboards are App mode**, which is what the user is
--- looking at: every screen on both tracked models carries
--- `LayoutId: Layout1x1AM`, and `layout1x1AppMode.cpp:53` registers that id
--- as "App mode". App mode reserves a strip for the menu button that pushes
--- the top-left panel's content down, and its zone is 19 px taller than a
--- Full screen one because EdgeTX's own top bar is gone. Both differences
--- change what a panel draws, so both zones are rendered rather than one
--- being assumed.
---
--- **Corrected: this said Full screen was what the user pages through.** It
--- was the premise #78 overturned, and this comment outlived the correction
--- -- which matters more here than in prose, because a page ordered by the
--- wrong zone puts the figures nobody is looking at first.
local ZONES = {
  {name = "appmode", make = function() return lvglMock.appZone() end},
  {name = "widget", make = function() return lvglMock.fullScreenZone() end},
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

--- The band the real host gave each case it built, so the enumeration at the
--- end of this file can be checked against it rather than merely believed.
local hostBands = {}

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
    -- The content box, taken from the real frame rather than assumed. Its
    -- padding is asymmetric -- the left clears the accent stripe and the
    -- right has nothing to clear -- so a centred group centred on the panel
    -- would sit a couple of pixels off.
    --
    -- **And laid out around the menu button, where the panel meets it.** The
    -- host wraps `frame` per component so a panel in the grid's top left
    -- cell is built around the corner EdgeTX paints its button over; this
    -- called the module's own function and got the unobstructed frame, so
    -- every App mode figure on the page was the figure for a panel nothing
    -- covers. It was found by the band enumeration at the end of this file
    -- disagreeing with the host, which is what that check exists for.
    local rect = {x = 0, y = 0, w = bounds.w, h = bounds.h}
    local reserved
    if context.reserved then
      local width = context.reserved.w - (bounds.x or 0)
      local height = context.reserved.h - (bounds.y or 0)
      if width > 0 and height > 0 then
        reserved = {
          w = width < rect.w and width or rect.w,
          h = height < rect.h and height or rect.h,
        }
      end
    end
    local frame = themeModule.frame(context.theme, rect,
      themeModule.typography(colSpan, rowSpan), reserved)

    -- **The widget's own bands, not a second opinion about them.** The
    -- renderer used to recompute the proportional bands from the panel's
    -- dimensions, and it got two things wrong that the widget gets right: a
    -- bar takes the floor rather than a proportional share, and a heading
    -- overflowing its band pushes the body down. The corrected arithmetic
    -- exists in `theme.bands`, so the honest thing is to report what the
    -- dashboard actually computed and let the page render that.
    local ladder = themeModule.ladder(context.theme, rect, frame)
    local bands = ladder.bands

    -- The widest reading the component can ever print, which is what its
    -- own fitter sizes from. The current value is usually much shorter --
    -- `7.9` against `88.8` -- so asking whether *this* reading fits a slot
    -- would answer a question nobody has.
    local instance = entry.instance
    local widest, widestUnit = "", ""
    local sample = instance and instance.sample
    if type(sample) == "table" then
      if type(sample.digits) == "string" then
        widest, widestUnit = sample.digits, sample.unit or ""
      elseif type(sample[1]) == "string" then
        widest = sample[1]
      end
    end
    if widest == "" then
      local module = entry.module
      widest = type(module.DIGITS) == "string" and module.DIGITS or ""
      widestUnit = type(module.UNIT) == "string" and module.UNIT or ""
    end

    -- Measured at every ladder font rather than scaled from one, so the
    -- question "would this fit in half a panel, and at what size" is answered
    -- with `lcd.sizeText` on the real string rather than an average advance.
    local widths = {}
    for _, name in ipairs({"XXLSIZE", "DBLSIZE", "MIDSIZE", "SMLSIZE",
        "TINSIZE"}) do
      local flags = edgetx.firmware[name]
      widths[#widths + 1] = string.format("%s = {%d, %d}", name,
        themeModule.measureText(flags, widest),
        themeModule.measureText(flags, widestUnit))
    end

    out[#out + 1] = string.format(
      "  {component = %q, span = %q, zone = %q, w = %d, h = %d,"
        .. " pad = %d, content = %d, widest = %q, widestUnit = %q,"
        .. " widestAt = {%s}, compact = %d, top = %d, bottom = %d,"
        .. " labelHeight = %d, bodyY = %d, bodyH = %d,"
        .. " objects = {\n",
      typeName, span, zone.name, bounds.w, bounds.h,
      frame.pad, frame.content, widest, widestUnit,
      table.concat(widths, ", "), frame.compact, frame.top, frame.bottom,
      frame.labelHeight, bands.body.y, bands.body.h)

    hostBands[#hostBands + 1] = {zone = zone.name, component = typeName,
      colSpan = colSpan, rowSpan = rowSpan, band = bands.body.h}

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

--- Every body band this dashboard can build, and where each one occurs.
---
--- **The cases above cannot answer this and never could.** They are six
--- components at four spans, every one of them placed in the grid's top left
--- cell -- which is one placement of a hundred and thirty-six, and is also
--- the one cell EdgeTX paints its menu button over in App mode. A band is a
--- property of the panel's box rather than of what is drawn in it, so the
--- honest way to enumerate them is to walk every placement of every span in
--- both zones and ask `theme.ladder`, which is the widget's own function,
--- with the supporting row both taken and declined.
---
--- Rectangles come from the widget's own `grid.rect`. The App mode
--- reservation is `main.lua`'s own arithmetic: the button is drawn at the
--- screen origin, so what it takes from a panel is whatever of it reaches
--- into that panel's rectangle.
---
--- **That is a second opinion, so it is checked against the first.** Every
--- case built above reports the band the real host gave it, and this walk
--- has to agree with all of them or the generator refuses to emit anything.
--- A generator quietly disagreeing with the widget it reports on is how a
--- page comes to be both trusted and wrong.
local gridModule = assert(loadfile(sourcePath .. "lib/grid.lua"))()
local resolvedTheme = themeModule.build("modern")

local ZONE_GEOMETRY = {
  appmode = {
    zone = {x = 0, y = 0, xabs = 0, yabs = 0, w = 480, h = 272},
    reserved = {
      w = edgetx.firmware.MENU_HEADER_BUTTONS_LEFT,
      h = edgetx.firmware.MENU_HEADER_HEIGHT_PX,
    },
  },
  widget = {
    zone = {x = 0, y = 0, xabs = 0,
      yabs = edgetx.firmware.MENU_HEADER_HEIGHT_PX,
      w = 480, h = 272 - edgetx.firmware.MENU_HEADER_HEIGHT_PX},
  },
}

--- The band a panel at one placement gets, with its row and without it.
local function bandsAt(zoneName, col, row, colSpan, rowSpan)
  local geometry = ZONE_GEOMETRY[zoneName]
  local placement = {col = col, row = row,
    colSpan = colSpan, rowSpan = rowSpan}
  local rect = assert(gridModule.rect(geometry.zone, placement, 4, 4, 4))
  local panel = {x = 0, y = 0, w = rect.w, h = rect.h}

  local reserved
  if geometry.reserved then
    local width = geometry.reserved.w - rect.x
    local height = geometry.reserved.h - rect.y
    if width > 0 and height > 0 then
      reserved = {
        w = width < rect.w and width or rect.w,
        h = height < rect.h and height or rect.h,
      }
    end
  end

  local fonts = themeModule.typography(colSpan, rowSpan)
  local frame = themeModule.frame(resolvedTheme, panel, fonts, reserved)
  -- **One answer, where there used to be three.** The walk asked the ladder
  -- for a panel drawing a supporting row, one drawing none, and one drawing
  -- `navigation`'s two -- because the band was sized from what was going to
  -- be put in it and each of those produced a different body. The bands are
  -- fixed proportions now, so a panel of a given size has exactly one body
  -- band whatever it draws, which is the whole point of the rule and is why
  -- this collapsed from three calls to one.
  return themeModule.ladder(resolvedTheme, panel, frame).room
end

for _, observed in ipairs(hostBands) do
  local band = bandsAt(observed.zone, 0, 0,
    observed.colSpan, observed.rowSpan)
  assert(observed.band == band,
    string.format("the band walk disagrees with the host: %s %s %dx%d drew a"
      .. " %d px body band, and the walk says %d", observed.zone,
      observed.component, observed.colSpan, observed.rowSpan, observed.band,
      band))
end

local bandOrder, bandWhere = {}, {}
for _, zoneName in ipairs({"appmode", "widget"}) do
  for colSpan = 1, 4 do
    for rowSpan = 1, 4 do
      for col = 0, 4 - colSpan do
        for row = 0, 4 - rowSpan do
          local band = bandsAt(zoneName, col, row, colSpan, rowSpan)
          do
            if not bandWhere[band] then
              bandWhere[band] = {}
              bandOrder[#bandOrder + 1] = band
            end
            local key = zoneName .. " " .. colSpan .. "x" .. rowSpan
            bandWhere[band][key] = (bandWhere[band][key] or 0) + 1
          end
        end
      end
    end
  end
end
table.sort(bandOrder)

out[#out + 1] = "BANDS = {\n"
for _, band in ipairs(bandOrder) do
  local keys = {}
  for key in pairs(bandWhere[band]) do keys[#keys + 1] = key end
  table.sort(keys)
  local where = {}
  for _, key in ipairs(keys) do
    where[#where + 1] = string.format("%s x%d", key, bandWhere[band][key])
  end
  out[#out + 1] = string.format("  {band = %d, where = %q},\n", band,
    table.concat(where, ", "))
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
