-- SPDX-License-Identifier: GPL-2.0-only

--- The active EdgeTX flight mode.
---
--- This is the simplest component in the catalog and deliberately so: EdgeTX
--- resolves the active mode itself, and `getFlightMode()` returns both its
--- index and its configured name. AeroGrid neither infers the mode from
--- switches nor caches a mapping of its own.
---
--- The only real design problem is width. A flight mode name is free text of
--- up to EdgeTX's name length, so the reading is fitted to the panel by
--- measured width as well as height, and the font is chosen from the longest
--- name the radio can produce rather than from the current one, so switching
--- modes never resizes the panel's dominant reading.

---@class AeroGridFlightModeSettings
---@field label? string
---@field accent? string
---@field showIndex? boolean Show the mode number beneath the name.

---@class AeroGridFlightModeContext
---@field panel table
---@field feed? AeroGridFlightMode
---@field stateName string

local flightMode = {
  id = "flight-mode",
  apiVersion = 1,
  supportedSpans = {
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
  },
  -- A flight mode changes when a switch moves, which is rare, and the reading
  -- is radio-local rather than telemetry. Two hertz is responsive enough and
  -- leaves the instruction budget to components that actually need it.
  refreshInterval = 50,
  settings = {
    {key = "label", label = "Label", type = "string", default = "FLIGHT MODE"},
    {key = "accent", label = "Accent", type = "string", default = "green"},
    {key = "showIndex", label = "Show mode number", type = "boolean", default = false},
  },
}

--- Longest flight mode name EdgeTX will report, used to size the reading.
--- `LEN_FLIGHT_MODE_NAME` is 10 on colour targets; an unnamed mode falls back
--- to "FM<n>", which is always shorter.
local WIDEST_NAME = "MMMMMMMMMM"

--- Describe how the component presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
function flightMode.presentationFor(colSpan, rowSpan)
  local cells = (colSpan or 1) * (rowSpan or 1)
  return {showDetail = cells >= 2}
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@return table
function flightMode.regionsFor(theme, themeBuilder, rect, layout, fonts)
  local frame = themeBuilder.frame(theme, rect, fonts)
  local labelHeight = frame.labelHeight
  local top = frame.top
  local showDetail = layout.showDetail

  local function room()
    local below = frame.bottom
    if showDetail then below = below + labelHeight + 2 end
    return rect.h - top - below
  end

  if room() < themeBuilder.fontHeight(MIDSIZE) and showDetail then
    showDetail = false
  end

  local name = themeBuilder.fitText(
    WIDEST_NAME, frame.content, math.max(1, room()))
  local nameHeight = themeBuilder.fontHeight(name)

  if top + nameHeight > rect.h then
    top = math.max(0, rect.h - nameHeight)
  end

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    nameY = top,
    name = name,
    detailY = math.max(1, rect.h - frame.bottom - labelHeight),
    showDetail = showDetail,
  }
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridFlightModeSettings
---@param services table
---@return AeroGridFlightModeContext
function flightMode.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local span = services.span
  local layout = flightMode.presentationFor(span.colSpan, span.rowSpan)
  local presentation = services.state("normal", settings.accent)
  local area = flightMode.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts)

  local context = {
    theme = theme,
    themeBuilder = services.themeBuilder,
    primitives = primitives,
    state = services.state,
    fonts = fonts,
    layout = layout,
    settings = settings,
    stateName = "normal",
    text = "--",
    detail = "",
  }

  local modelService = services.model
  if modelService then context.feed = modelService:flightMode() end

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation)

  context.value = primitives.value(panel.root, theme, {
    x = area.pad,
    y = area.nameY,
    w = area.content,
    text = "--",
    color = presentation.value,
    font = area.name,
  })

  context.detailLabel = primitives.label(panel.root, theme, {
    x = area.pad,
    y = area.detailY,
    w = area.content,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  if not area.showDetail then lvgl.hide(context.detailLabel) end

  flightMode.apply(context)
  return context
end

--- Repaint the component from its current subscription.
---@param context AeroGridFlightModeContext
function flightMode.apply(context)
  local feed = context.feed
  local settings = context.settings
  local available = type(feed) == "table" and feed.available == true
  local presentation = context.state(
    available and "normal" or "unavailable", settings.accent)

  context.stateName = available and "normal" or "unavailable"
  context.text = available and tostring(feed.name) or "--"

  context.value:set({text = context.text, color = presentation.value})
  context.label:set({color = presentation.label})
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  context.primitives.stylePanel(context.panel, presentation)

  local detail = ""
  if settings.showIndex and available then
    detail = "MODE " .. tostring(feed.index)
  end
  if detail ~= context.detail then
    context.detail = detail
    context.detailLabel:set({text = detail})
  end
end

--- Advance the component, repainting only when the mode actually changed.
---@param context AeroGridFlightModeContext
function flightMode.refresh(context)
  local feed = context.feed
  if not feed then return end

  local name = feed.available and feed.name or nil
  if context.applied and name == context.reading then return end

  context.applied = true
  context.reading = name
  flightMode.apply(context)
end

--- Reposition after a zone change.
---@param context AeroGridFlightModeContext
---@param rect AeroGridRect
function flightMode.update(context, rect)
  local area = flightMode.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame)
  context.value:set({
    x = area.pad,
    y = area.nameY,
    w = area.content,
    font = function() return area.name end,
  })

  if area.showDetail then
    context.detailLabel:set({x = area.pad, y = area.detailY, w = area.content})
    lvgl.show(context.detailLabel)
  else
    lvgl.hide(context.detailLabel)
  end
end

return flightMode
