-- SPDX-License-Identifier: GPL-2.0-only

--- Radio link strength, quality, and freshness.
---
--- RSSI and link quality are separate settings because protocols expose
--- different sensors in different units, and one is never inferred from the
--- other. FrSky reports `RSSI` in dB; ELRS reports `1RSS` and `2RSS` in dBm
--- alongside `RQly` as a percentage; a multi-antenna receiver exposes each
--- antenna as an ordinary source. Nothing here hard-codes a protocol: both
--- sources are named by the layout, and either may be absent.
---
--- Freshness is the hard part, and it is the reason this component exists
--- rather than two metrics side by side. EdgeTX returns integer zero for a
--- telemetry source both when the sensor genuinely reads zero and when nothing
--- is arriving, and `getRSSI()` itself reads zero on a perfectly live link
--- whose protocol never populates an RSSI sensor. Three situations therefore
--- look identical from a single reading and must not:
---
--- - The link is down. The last readings are kept, marked, and the panel says
---   so in words.
--- - The protocol has no RSSI sensor. Link quality carries the panel and the
---   RSSI row says the source is absent rather than reporting zero.
--- - The reading really is zero, which only happens on a live link.
---
--- `telemetryService` already draws that distinction, because it watches
--- whether any source ever contradicted the indicator. This component reads
--- its published link view rather than guessing again.

---@class AeroGridLinkSettings
---@field rssiSource? string
---@field qualitySource? string
---@field primary? "auto"|"rssi"|"quality"
---@field label? string
---@field min? number Reading treated as empty by the bar.
---@field max? number Reading treated as full by the bar.
---@field warning? number
---@field critical? number
---@field extrema? "source"|"flight"|"none"
---@field extremaSource? string Explicit EdgeTX minimum source.
---@field armSource? string Arm switch bounding a flight session.
---@field visual? "bar"|"none"
---@field accent? string

---@class AeroGridLinkContext
---@field panel table
---@field rssiFeed? AeroGridReading
---@field qualityFeed? AeroGridReading
---@field link? table Published link view from the telemetry service.
---@field stateName string

local linkStatus = {
  id = "link-status",
  apiVersion = 1,
  supportedSpans = {
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
  },
  -- Link quality is the one reading a pilot glances at during a fade, but it
  -- is still a number on a screen: five hertz is indistinguishable from fifty
  -- and costs a tenth as much of the shared instruction budget.
  refreshInterval = 20,
  settings = {
    {key = "rssiSource", label = "RSSI source", type = "string", default = "RSSI"},
    -- Never defaulted: link quality is not universal, and inferring it from
    -- RSSI would invent a number the radio never reported.
    {key = "qualitySource", label = "Link quality source", type = "string", default = ""},
    {key = "primary", label = "Primary reading", type = "string", default = "auto"},
    {key = "label", label = "Label", type = "string", default = "LINK"},
    -- The bar's range, in the primary reading's own unit. The defaults suit a
    -- percentage; a dBm source needs its own, which is why they are settings.
    {key = "min", label = "Bar minimum", type = "number", default = 0},
    {key = "max", label = "Bar maximum", type = "number", default = 100},
    -- No default thresholds: what counts as a bad link depends entirely on
    -- the unit, and a guess would warn constantly on dBm or never on percent.
    {key = "warning", label = "Warning level", type = "number"},
    {key = "critical", label = "Critical level", type = "number"},
    {key = "extrema", label = "Minimum tracked", type = "string", default = "none"},
    {key = "extremaSource", label = "Minimum source", type = "string", default = ""},
    {key = "armSource", label = "Arm switch", type = "string", default = ""},
    {key = "visual", label = "Visualization", type = "string", default = "bar"},
    {key = "accent", label = "Accent", type = "string", default = "green"},
  },
}

--- Describe how the component presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
function linkStatus.presentationFor(colSpan, rowSpan)
  local cells = (colSpan or 1) * (rowSpan or 1)
  return {showVisual = cells >= 2, showDetail = cells >= 2}
end

--- Classify one configured source.
---
--- The distinction that matters is between a source the radio does not have
--- and a source it has but that is not currently arriving. The first is a
--- property of the protocol and is permanent until the model changes; the
--- second is a fade, and a pilot needs to tell them apart instantly.
---@param feed any Telemetry subscription, or nil when unconfigured.
---@return "none"|"absent"|"waiting"|"stale"|"live"
function linkStatus.classify(feed)
  if type(feed) ~= "table" then return "none" end
  if feed.name == nil or feed.name == "" then return "none" end
  if not feed.known then return "absent" end
  if feed.available ~= true then return "waiting" end
  if feed.stale == true then return "stale" end
  return "live"
end

--- Choose which reading leads the panel.
---
--- `auto` prefers link quality, because a percentage means the same thing on
--- every protocol where RSSI does not, but it falls back to RSSI rather than
--- showing an empty panel when no quality sensor exists.
---@param settings AeroGridLinkSettings
---@param rssiState string
---@param qualityState string
---@return "rssi"|"quality"
function linkStatus.primaryFor(settings, rssiState, qualityState)
  local wanted = settings.primary

  if wanted == "rssi" then return "rssi" end
  if wanted == "quality" then return "quality" end

  -- Auto: whichever source the radio actually has, quality first.
  if qualityState == "live" or qualityState == "stale" then return "quality" end
  if rssiState == "live" or rssiState == "stale" then return "rssi" end
  if qualityState ~= "none" and qualityState ~= "absent" then return "quality" end
  if rssiState ~= "none" and rssiState ~= "absent" then return "rssi" end
  return qualityState ~= "none" and "quality" or "rssi"
end

--- Resolve the component state.
---
--- A link that is down is not merely stale data: it is the measurement, and it
--- is the most important thing this panel can say. It is therefore reported as
--- critical with its own badge rather than being dimmed like an idle sensor.
--- Link thresholds always count downward.
---@param settings AeroGridLinkSettings
--- A dead link, a protocol with no RSSI sensor and a source that has never
--- reported are three different situations, and the supporting row already
--- names each of them in words. The badge carries only the state, because six
--- characters cannot hold the difference between `NO SENSOR` and `NO LINK`
--- when both are being read at a glance.
---@param reading table Result of linkStatus.read.
---@return string stateName
function linkStatus.resolveState(settings, reading)
  -- Nothing configured that the radio recognizes at all.
  if reading.sourceState == "none" or reading.sourceState == "absent" then
    return "unavailable"
  end

  if reading.linkDown then
    -- Never seen a reading and no link either: the model has not been powered
    -- up yet, which is not a fault and must not shout about one.
    if not reading.available then return "unavailable" end
    return "critical"
  end

  if reading.sourceState == "waiting" then return "unavailable" end
  if reading.sourceState == "stale" then return "stale" end
  if type(reading.value) ~= "number" then return "unavailable" end

  local critical = settings.critical
  local warning = settings.warning
  if type(critical) == "number" and reading.value <= critical then
    return "critical"
  end
  if type(warning) == "number" and reading.value <= warning then
    return "warning"
  end

  return "normal"
end

--- Collect the current state of both sources and the link itself.
--- The result is written into a caller-owned table so a refresh allocates
--- nothing.
---@param context AeroGridLinkContext
---@return table reading
function linkStatus.read(context)
  local out = context.readingCache
  local rssi = context.rssiFeed
  local quality = context.qualityFeed

  out.rssiState = linkStatus.classify(rssi)
  out.qualityState = linkStatus.classify(quality)
  out.primary = linkStatus.primaryFor(
    context.settings, out.rssiState, out.qualityState)

  local feed = out.primary == "quality" and quality or rssi
  out.sourceState = out.primary == "quality" and out.qualityState or out.rssiState
  out.value = nil
  out.unitText = ""
  out.precision = 0
  out.available = false

  if type(feed) == "table" then
    out.available = feed.available == true
    if out.available and type(feed.value) == "number" then out.value = feed.value end
    out.unitText = type(feed.unitText) == "string" and feed.unitText or ""
    out.precision = type(feed.precision) == "number" and feed.precision or 0
  end

  -- The source that is not leading is still printed, on the supporting row,
  -- and it moves on its own schedule. On ELRS link quality sits at 100 for
  -- most of a flight while RSSI falls away, so a refresh that watched only
  -- the leading reading would freeze the one the pilot is actually watching.
  local secondary = out.primary == "quality" and rssi or quality
  out.secondaryState = out.primary == "quality" and out.rssiState or out.qualityState
  out.secondaryValue = nil
  if type(secondary) == "table" and secondary.available == true then
    out.secondaryValue = secondary.value
  end

  -- The link view is the only thing that can tell a dead link from a protocol
  -- that never reports RSSI, because it remembers whether a source ever
  -- contradicted the indicator.
  local link = context.link
  out.linkLive = type(link) == "table" and link.live == true
  out.indicator = type(link) ~= "table" or link.indicator ~= false
  out.rssi = type(link) == "table" and link.rssi or 0
  -- Without a link view at all, fall back to the source's own freshness
  -- rather than claiming the link is down on no evidence.
  out.linkDown = type(link) == "table" and not out.linkLive

  return out
end

--- Format one reading for a supporting row.
---@param feed any
---@param state string Result of linkStatus.classify.
---@return string
function linkStatus.sourceText(feed, state)
  if state == "none" then return "--" end
  -- A source the radio has never heard of is not a zero reading; saying so is
  -- the difference between "this protocol has no RSSI" and "your link died".
  if state == "absent" then return "N/A" end
  if state == "waiting" then return "--" end

  local value = type(feed) == "table" and feed.value or nil
  if type(value) ~= "number" or value ~= value then return "--" end

  local digits = type(feed.precision) == "number" and feed.precision or 0
  if digits < 0 then digits = 0 end
  if digits > 3 then digits = 3 end

  local text = string.format("%." .. digits .. "f", value)
  if type(feed.unitText) == "string" and feed.unitText ~= "" then
    text = text .. feed.unitText
  end
  return text
end

--- Read whichever minimum the layout asked for.
--- `source` mode reads EdgeTX's own "<name>-" sensor, which the radio
--- maintains on its own schedule; `flight` mode reads the dashboard's session
--- minimum, which covers exactly one flight. The two are not interchangeable.
---@param context AeroGridLinkContext
---@return number? value
function linkStatus.minimumValue(context)
  local mode = context.settings.extrema

  if mode == "source" then
    local feed = context.minimumFeed
    if type(feed) ~= "table" or not feed.available then return nil end
    return type(feed.value) == "number" and feed.value or nil
  end

  if mode == "flight" then
    local track = context.sessionExtrema
    if type(track) ~= "table" or not track.available then return nil end
    return type(track.min) == "number" and track.min or nil
  end

  return nil
end

--- Format the supporting detail row's left-hand text.
---@param context AeroGridLinkContext
---@param reading table
---@return string
function linkStatus.detailText(context, reading)
  local variants

  if context.settings.extrema ~= "none" then
    local value = linkStatus.minimumValue(context)
    if type(value) ~= "number" then
      variants = {"MIN --", "--"}
    else
      local text = string.format("%." .. math.max(0, reading.precision) .. "f", value)
      variants = {"MIN " .. text, text}
    end
  elseif reading.primary == "quality" then
    -- With no minimum configured, the row names the secondary source, which is
    -- whichever of the two is not leading the panel.
    local text = linkStatus.sourceText(context.rssiFeed, reading.rssiState)
    variants = {"RSSI " .. text, text}
  else
    local text = linkStatus.sourceText(context.qualityFeed, reading.qualityState)
    variants = {"LQ " .. text, text}
  end

  return context.themeBuilder.fitLabel(variants, context.fonts.label,
    context.detailWidth)
end

--- Format the supporting detail row's right-hand text.
--- This row carries the thing a pilot cannot see from a number: whether the
--- link is up, and whether the radio has an RSSI sensor at all.
---@param context AeroGridLinkContext
---@param reading table
---@return string
function linkStatus.linkText(context, reading)
  local variants
  if reading.linkDown then
    variants = {"LINK DOWN", "NO LINK", "DOWN"}
  elseif not reading.indicator or reading.rssiState == "absent" then
    variants = {"NO RSSI SENSOR", "NO RSSI SENSE", "NO RSSI", "NO RSS"}
  elseif reading.primary == "quality" then
    local text = linkStatus.sourceText(context.rssiFeed, reading.rssiState)
    variants = {"RSSI " .. text, text}
  else
    local text = linkStatus.sourceText(context.qualityFeed, reading.qualityState)
    variants = {"LQ " .. text, text}
  end

  return context.themeBuilder.fitLabel(variants, context.fonts.label,
    context.linkWidth)
end

--- Convert the primary reading into a 0..1 fraction of the configured range.
---@param settings AeroGridLinkSettings
---@param value any
---@return number
function linkStatus.fraction(settings, value)
  if type(value) ~= "number" or value ~= value then return 0 end

  local low = type(settings.min) == "number" and settings.min or 0
  local high = type(settings.max) == "number" and settings.max or 100
  if high <= low then return 0 end

  local fraction = (value - low) / (high - low)
  if fraction < 0 then return 0 end
  if fraction > 1 then return 1 end
  return fraction
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@param sample string Widest value text this component can render.
---@return table
function linkStatus.regionsFor(theme, themeBuilder, rect, layout, fonts, sample)
  local spacing = theme.spacing
  local frame = themeBuilder.frame(theme, rect, fonts)
  local labelHeight = frame.labelHeight
  local top = frame.top
  local showVisual = layout.showVisual and layout.visual ~= "none"
  local showDetail = layout.showDetail

  local function room()
    local below = frame.bottom
    if showVisual then below = below + spacing.barHeight + 2 end
    if showDetail then below = below + labelHeight + 2 end
    return rect.h - top - below
  end

  local comfortable = themeBuilder.fontHeight(MIDSIZE)
  if room() < comfortable and showDetail then showDetail = false end
  if room() < comfortable and showVisual then showVisual = false end

  local value = themeBuilder.fitText(sample, frame.content, math.max(1, room()))
  local valueHeight = themeBuilder.fontHeight(value)
  if top + valueHeight > rect.h then top = math.max(0, rect.h - valueHeight) end

  local barY = math.max(1, rect.h - frame.bottom - spacing.barHeight)
  -- The link state is the longest supporting string this panel prints, so it
  -- takes the wider half of the detail row.
  local detailWidth = math.max(1, math.floor((frame.content - 4) / 3))

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    valueY = top,
    value = value,
    detailY = math.max(1, barY - labelHeight - 2),
    detailWidth = detailWidth,
    linkX = frame.pad + detailWidth + 4,
    linkWidth = math.max(1, frame.content - detailWidth - 4),
    barY = barY,
    showVisual = showVisual,
    showDetail = showDetail,
  }
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridLinkSettings
---@param services table
---@return AeroGridLinkContext
function linkStatus.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local span = services.span
  local layout = linkStatus.presentationFor(span.colSpan, span.rowSpan)
  layout.visual = settings.visual
  local presentation = services.state("normal", settings.accent)

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
    linkDetail = "",
    -- Reused so a refresh allocates nothing; the host pays this per frame.
    readingCache = {},
  }

  local telemetry = services.telemetry
  if telemetry then
    -- Both sources are subscribed even when only one leads the panel: the
    -- other is supporting detail, and a component that subscribed lazily would
    -- have nothing to show the moment the protocol turned out to differ.
    if type(settings.rssiSource) == "string" and settings.rssiSource ~= "" then
      context.rssiFeed = telemetry:subscribe(settings.rssiSource)
    end
    if type(settings.qualitySource) == "string" and settings.qualitySource ~= "" then
      context.qualityFeed = telemetry:subscribe(settings.qualitySource)
    end
    context.link = telemetry:link()
  end

  local leading = settings.primary == "rssi" and settings.rssiSource
    or settings.qualitySource
  if type(leading) ~= "string" or leading == "" then leading = settings.rssiSource end

  local extrema = services.extrema
  if extrema and settings.extrema == "source" then
    local named = settings.extremaSource
    if type(named) == "string" and named ~= "" then
      context.minimumFeed = telemetry and telemetry:subscribe(named) or nil
    else
      context.minimumFeed = extrema:sourceExtreme(leading, "min")
    end
  elseif extrema and settings.extrema == "flight" then
    extrema:flight(settings.armSource ~= "" and settings.armSource or nil)
    context.sessionExtrema = extrema:sessionExtrema(leading)
  end

  -- A dBm reading is the widest thing this panel prints, and the font is
  -- chosen from that rather than from the current value so the reading never
  -- resizes as the link fades.
  context.sample = "-100dBm"

  local area = linkStatus.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts, context.sample)
  context.detailWidth = area.detailWidth
  context.linkWidth = area.linkWidth
  context.showDetail = area.showDetail

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation)

  context.value = primitives.value(panel.root, theme, {
    x = area.pad,
    y = area.valueY,
    w = area.content,
    text = "--",
    color = presentation.value,
    font = area.value,
  })

  context.detailLabel = primitives.label(panel.root, theme, {
    x = area.pad,
    y = area.detailY,
    w = area.detailWidth,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  context.linkLabel = primitives.label(panel.root, theme, {
    x = area.linkX,
    y = area.detailY,
    w = area.linkWidth,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  if layout.showVisual and settings.visual ~= "none" then
    context.bar = primitives.bar(panel.root, theme, {
      x = area.pad,
      y = area.barY,
      w = area.content,
      fraction = 0,
      color = presentation.accent,
    })
  end

  if not area.showDetail then
    lvgl.hide(context.detailLabel)
    lvgl.hide(context.linkLabel)
  end
  if context.bar and not area.showVisual then
    lvgl.hide(context.bar.track)
    lvgl.hide(context.bar.fill)
  end

  linkStatus.apply(context)
  return context
end

--- Repaint the component from its current subscriptions.
---@param context AeroGridLinkContext
function linkStatus.apply(context)
  local settings = context.settings
  local reading = linkStatus.read(context)
  local stateName = linkStatus.resolveState(settings, reading)
  local presentation = context.state(stateName, settings.accent)

  context.stateName = stateName
  context.reading = reading.value
  context.staleReading = reading.sourceState == "stale"
  context.primaryName = reading.primary

  local text = "--"
  if type(reading.value) == "number" then
    local digits = reading.precision
    if type(digits) ~= "number" or digits < 0 then digits = 0 end
    if digits > 3 then digits = 3 end
    text = string.format("%." .. digits .. "f", reading.value)
    if reading.unitText ~= "" then text = text .. reading.unitText end
  elseif reading.sourceState == "absent" then
    -- A source the protocol does not have reads N/A, never zero.
    text = "N/A"
  end
  context.text = text

  context.value:set({text = text, color = presentation.value})
  context.label:set({color = presentation.label})
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  context.primitives.stylePanel(context.panel, presentation)

  -- A row the span sheds is not worth fitting words to. At a single cell both
  -- supporting rows are hidden, and choosing a wording for a label nobody can
  -- see was the whole of this change's steady-state cost.
  if context.showDetail then
  local detail = linkStatus.detailText(context, reading)
  if detail ~= context.detail then
    context.detail = detail
    context.detailLabel:set({text = detail})
  end

  local linkDetail = linkStatus.linkText(context, reading)
  if linkDetail ~= context.linkDetail then
    context.linkDetail = linkDetail
    context.linkLabel:set({text = linkDetail})
  end
  end

  if context.bar then
    -- A reading the panel is not showing must not leave a bar behind that
    -- still looks like a healthy link.
    local fraction = stateName == "unavailable" and 0
      or linkStatus.fraction(settings, reading.value)
    context.primitives.setBar(context.bar, fraction, presentation.accent)
  end
end

--- Advance the component, repainting only when something visible changed.
---@param context AeroGridLinkContext
function linkStatus.refresh(context)
  if not context.rssiFeed and not context.qualityFeed then return end

  local reading = linkStatus.read(context)
  local stale = reading.sourceState == "stale"

  -- Every one of these can change without the primary value moving, and each
  -- one changes what the panel says.
  if context.applied and reading.value == context.reading
      and stale == context.staleReading
      and reading.primary == context.primaryName
      and reading.sourceState == context.appliedSourceState
      and reading.secondaryValue == context.appliedSecondary
      and reading.secondaryState == context.appliedSecondaryState
      and reading.linkDown == context.appliedLinkDown
      and reading.indicator == context.appliedIndicator then
    return
  end

  context.applied = true
  context.appliedSourceState = reading.sourceState
  context.appliedSecondary = reading.secondaryValue
  context.appliedSecondaryState = reading.secondaryState
  context.appliedLinkDown = reading.linkDown
  context.appliedIndicator = reading.indicator
  linkStatus.apply(context)
end

--- Reposition after a zone change.
---@param context AeroGridLinkContext
---@param rect AeroGridRect
function linkStatus.update(context, rect)
  local area = linkStatus.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts, context.sample)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame)
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.content,
    font = function() return area.value end,
  })

  --- Show or hide a supporting row, positioning it only when visible.
  local function reconcile(object, visible, changes)
    if not object then return end
    if visible then
      object:set(changes)
      lvgl.show(object)
    else
      lvgl.hide(object)
    end
  end

  -- A resize changes how much room each row has, so let both wordings be
  -- re-chosen on the refresh that follows.
  if area.detailWidth ~= context.detailWidth then
    context.detailWidth = area.detailWidth
    context.detail = nil
  end
  if area.linkWidth ~= context.linkWidth then
    context.linkWidth = area.linkWidth
    context.linkDetail = nil
  end
  if area.showDetail ~= context.showDetail then
    context.showDetail = area.showDetail
    -- A row that just became visible still holds whatever it had when it was
    -- hidden, so force the next refresh to fit it again.
    context.detail = nil
    context.linkDetail = nil
    context.applied = false
  end

  reconcile(context.detailLabel, area.showDetail,
    {x = area.pad, y = area.detailY, w = area.detailWidth})
  reconcile(context.linkLabel, area.showDetail,
    {x = area.linkX, y = area.detailY, w = area.linkWidth})

  if context.bar then
    if area.showVisual then
      context.primitives.placeBar(context.bar, area.pad, area.barY, area.content,
        linkStatus.fraction(context.settings, context.reading))
      lvgl.show(context.bar.track)
      lvgl.show(context.bar.fill)
    else
      lvgl.hide(context.bar.track)
      lvgl.hide(context.bar.fill)
    end
  end
end

return linkStatus
