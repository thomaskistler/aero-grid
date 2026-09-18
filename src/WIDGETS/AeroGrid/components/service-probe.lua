-- SPDX-License-Identifier: GPL-2.0-only

--- Diagnostic view over one shared data service.
---
--- This component exists to prove normalized service output independently of
--- any production component's rendering. It asks a service to describe itself
--- as label and value rows and prints them, so a wrong unit, a missing
--- precision, a stale classification, or a bearing measured from the wrong end
--- is visible on the radio before any component depends on it.
---
--- It deliberately renders nothing but text. Rows are laid out from measured
--- EdgeTX font heights, never fixed offsets, and the panel sheds rows it
--- cannot fit rather than drawing past its container.

---@class AeroGridProbeSettings
---@field service "telemetry"|"model"|"control"|"extrema"|"navigation"
---@field source? string Primary source name, where the service takes one.
---@field extra? string Secondary source: native distance, or the arm switch.
---@field index? number Timer or global variable index.
---@field label? string Panel title; defaults to the service name.
---@field accent? string

local probe = {
  id = "service-probe",
  apiVersion = 1,
  supportedSpans = {"any"},
  -- Diagnostics are read, not watched. Two hertz is plenty and leaves the
  -- instruction budget to the services themselves.
  refreshInterval = 50,
  settings = {
    {key = "service", label = "Service", type = "string", default = "telemetry"},
    {key = "source", label = "Source", type = "string", default = ""},
    {key = "extra", label = "Second source", type = "string", default = ""},
    {key = "index", label = "Index", type = "number", default = 0},
    {key = "label", label = "Label", type = "string", default = ""},
    {key = "accent", label = "Accent", type = "string", default = "cyan"},
  },
}

--- Most rows any probe will draw, whatever its span.
local MAX_ROWS = 8

--- Width of the value column as a fraction of the content width.
local VALUE_SHARE = 0.55

--- Subscribe to everything the selected service can report.
--- Subscriptions are made once, in create, so the service knows before its
--- first update exactly which sources this dashboard references.
---@param service table
---@param name string
---@param settings AeroGridProbeSettings
---@return any subject Per-subscription view, where the service has one.
local function subscribe(service, name, settings)
  local source = settings.source
  local extra = settings.extra
  local index = settings.index

  if name == "telemetry" then
    return service:subscribe(source)
  end
  if name == "navigation" then
    return service:subscribe(source, extra)
  end
  if name == "model" then
    service:identity()
    service:flightMode()
    service:txVoltage()
    service:timer(index)
    return nil
  end
  if name == "control" then
    if source ~= "" then service:trim(source) end
    service:globalVariable(index)
    return nil
  end
  if name == "extrema" then
    service:flight(extra)
    if source ~= "" then service:sessionExtrema(source) end
    return nil
  end

  return nil
end

--- Compute the row geometry that fits the current rectangle.
--- Rows are sized from the real line height of the label font, so a display
--- with taller fonts simply shows fewer rows instead of overflowing.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param fonts table
---@return table
function probe.regionsFor(theme, themeBuilder, rect, fonts)
  -- The shared frame, not a second copy of its arithmetic. Repeating it here
  -- meant this panel kept drawing its title into the corner EdgeTX paints its
  -- menu button over, because only the shared helper knows about that.
  local frame = themeBuilder.frame(theme, rect, fonts)
  local pad = frame.pad
  local compact = frame.compact

  local titleHeight = frame.labelHeight
  local lineHeight = titleHeight + 2
  local top = frame.top

  local content = frame.content
  local valueWidth = math.max(1, math.floor(content * VALUE_SHARE))
  local keyWidth = math.max(1, content - valueWidth - 4)

  local room = rect.h - top - pad
  local rows = math.floor(room / lineHeight)
  if rows < 0 then rows = 0 end
  if rows > MAX_ROWS then rows = MAX_ROWS end

  return {
    pad = pad,
    compact = compact,
    content = content,
    titleX = frame.labelX,
    titleWidth = math.max(1, frame.width - frame.labelX - pad),
    titleHidden = frame.labelHidden,
    top = top,
    lineHeight = lineHeight,
    keyWidth = keyWidth,
    valueWidth = valueWidth,
    valueX = pad + keyWidth + 4,
    rows = rows,
  }
end

--- Build the probe's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridProbeSettings
---@param services table
---@return table
function probe.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local presentation = services.state("normal", settings.accent)
  local area = probe.regionsFor(theme, services.themeBuilder, rect, fonts)

  local name = tostring(settings.service or "")
  local service = services[name]

  local context = {
    panel = primitives.panel(parent, rect, theme, presentation),
    theme = theme,
    themeBuilder = services.themeBuilder,
    primitives = primitives,
    fonts = fonts,
    settings = settings,
    serviceName = name,
    service = service,
    rows = {},
    keys = {},
    values = {},
    texts = {},
  }

  -- A service that failed to load leaves the probe visibly unavailable rather
  -- than raising: the dashboard must survive a missing module.
  if service then
    local ok, subject = pcall(subscribe, service, name, settings)
    if ok then context.subject = subject else context.subscribeError = true end
  end

  local title = settings.label
  if type(title) ~= "string" or title == "" then title = name end

  context.title = primitives.label(context.panel.root, theme, {
    x = area.titleX,
    y = area.compact,
    w = area.titleWidth,
    text = string.upper(title),
    color = presentation.label,
    font = fonts.label,
  })
  if area.titleHidden then lvgl.hide(context.title) end

  -- Every row object is created once, up to the cap, so a later enlargement
  -- reveals rows instead of forcing a rebuild.
  for index = 1, MAX_ROWS do
    local y = area.top + (index - 1) * area.lineHeight

    context.keys[index] = primitives.label(context.panel.root, theme, {
      x = area.pad,
      y = y,
      w = area.keyWidth,
      text = "",
      color = theme.color.textFaint,
      font = fonts.label,
    })

    context.values[index] = primitives.label(context.panel.root, theme, {
      x = area.valueX,
      y = y,
      w = area.valueWidth,
      text = "",
      color = theme.color.text,
      font = fonts.label,
    })

    context.texts[index] = ""
    if index > area.rows then
      lvgl.hide(context.keys[index])
      lvgl.hide(context.values[index])
    end
  end

  context.visibleRows = area.rows
  return context
end

--- Ask the service to describe itself and repaint only what changed.
---@param context table
function probe.refresh(context)
  local service = context.service
  local rows = context.rows
  local count = 0

  if service and not context.subscribeError then
    count = service:describe(rows, context.subject) or 0
  elseif not service then
    count = 1
    rows[1] = rows[1] or {}
    rows[1].label = string.upper(context.serviceName)
    rows[1].text = "UNAVAILABLE"
  end

  if count > context.visibleRows then count = context.visibleRows end

  for index = 1, context.visibleRows do
    local row = index <= count and rows[index] or nil
    local key = row and row.label or ""
    local text = row and row.text or ""
    local combined = key .. "\1" .. text

    -- Touching LVGL costs more than comparing a string, and a diagnostic view
    -- that repainted every row every refresh would dominate the frame.
    if combined ~= context.texts[index] then
      context.texts[index] = combined
      context.keys[index]:set({text = key})
      context.values[index]:set({text = text})
    end
  end
end

--- Reposition after a zone change, revealing or shedding rows as room allows.
---@param context table
---@param rect AeroGridRect
function probe.update(context, rect)
  local area = probe.regionsFor(
    context.theme, context.themeBuilder, rect, context.fonts)

  context.primitives.resizePanel(context.panel, rect)
  context.title:set({x = area.titleX, y = area.compact, w = area.titleWidth})
  if area.titleHidden then
    lvgl.hide(context.title)
  else
    lvgl.show(context.title)
  end

  for index = 1, MAX_ROWS do
    local key = context.keys[index]
    local value = context.values[index]
    if index <= area.rows then
      local y = area.top + (index - 1) * area.lineHeight
      key:set({x = area.pad, y = y, w = area.keyWidth})
      value:set({x = area.valueX, y = y, w = area.valueWidth})
      lvgl.show(key)
      lvgl.show(value)
    else
      lvgl.hide(key)
      lvgl.hide(value)
    end
  end

  context.visibleRows = area.rows
  -- Force the next refresh to repaint, because a row that just became visible
  -- still holds the text it had when it was hidden.
  for index = 1, MAX_ROWS do context.texts[index] = "" end
end

return probe
