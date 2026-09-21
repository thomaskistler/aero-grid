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
---@field reading? "auto"|"rssi"|"quality"
---@field label? string
---@field barMin? number Reading treated as empty by the bar.
---@field barMax? number Reading treated as full by the bar.
---@field warning? number
---@field critical? number
---@field extrema? "source"|"flight"|"none"
---@field extremaSource? string Explicit EdgeTX minimum source.
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
    -- Which of the two sources leads the panel. Named `reading` like every
    -- other component that chooses between its own values.
    {key = "reading", label = "Primary reading", type = "string",
      default = "auto", choices = {"auto", "rssi", "quality"}},
    {key = "label", label = "Label", type = "string", default = "LINK"},
    -- The bar's range, in the primary reading's own unit. The defaults suit a
    -- percentage; a dBm source needs its own, which is why they are settings.
    {key = "barMin", label = "Bar minimum", type = "number", default = 0},
    {key = "barMax", label = "Bar maximum", type = "number", default = 100},
    -- No default thresholds: what counts as a bad link depends entirely on
    -- the unit, and a guess would warn constantly on dBm or never on percent.
    -- In the unit of whichever source leads, which is what `reading` selects:
    -- a percentage under `quality` and dBm or dB under `rssi`. There is no
    -- one unit to name here, so the layout has to know which source it chose.
    -- The unit is whichever source `reading` names, so `reading` has to name
    -- one. See `validateSettings`.
    {key = "warning", label = "Warning, in the chosen reading's unit", type = "number"},
    {key = "critical", label = "Critical, in the chosen reading's unit", type = "number"},
    -- A link only ever gets worse downward.
    -- No `direction`. RSSI and link quality both only alarm downward.
    {key = "extrema", label = "Minimum tracked", type = "string",
      default = "none", choices = {"none", "source", "flight"}},
    {key = "extremaSource", label = "Minimum source", type = "string", default = ""},
    {key = "visual", label = "Visualization", type = "string", default = "bar",
      choices = {"bar", "none"}},
    {key = "accent", label = "Accent", type = "string", default = "green",
      choices = {"cyan", "green", "amber", "orange"}},
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
  local wanted = settings.reading

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

--- Reject a threshold whose unit would depend on which source resolved first.
---
--- This panel can lead with RSSI, in dBm and typically negative, or with link
--- quality, in percent and always positive. `reading: auto` picks whichever is
--- available, so `warning: 50` means "below 50 dBm" on one radio and "below
--- 50 percent" on another, decided by which sensor the protocol happens to
--- publish. The number is not wrong in a way anyone can see: it is a
--- plausible value for both, and the panel alarms at the wrong moment rather
--- than failing.
---
--- The vocabulary work documented this by naming the unit "the leading
--- source's", which described the trap accurately and left it in place. A
--- threshold whose meaning is decided at runtime is not a setting, so it is
--- refused at load instead, and the author is told to state which reading
--- they meant.
---@param settings AeroGridLinkSettings
---@return string[] messages
function linkStatus.validateSettings(settings)
  local messages = {}
  if settings.reading ~= "auto" then return messages end

  for _, key in ipairs({"warning", "critical"}) do
    if type(settings[key]) == "number" then
      messages[#messages + 1] = key
        .. " cannot be used with reading: auto, because its unit would be"
        .. " dBm or percent depending on which source resolved first."
        .. " Set reading to rssi or quality."
    end
  end

  return messages
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
    context.rowRightWidth)
end

--- Convert the primary reading into a 0..1 fraction of the configured range.
---@param settings AeroGridLinkSettings
---@param value any
---@return number
function linkStatus.fraction(settings, value)
  if type(value) ~= "number" or value ~= value then return 0 end

  local low = type(settings.barMin) == "number" and settings.barMin or 0
  local high = type(settings.barMax) == "number" and settings.barMax or 100
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
function linkStatus.regionsFor(theme, themeBuilder, rect, layout, fonts,
    sample, out)
  -- The whole arrangement, from the shared builder. This component's only
  -- visualization is a bar, which spans the panel by design and is exempt
  -- from the slot rule, so the reading never splits and centres across the
  -- whole content box.
  local area = themeBuilder.panel(theme, rect, fonts, {
    -- Built through this component's own builder, which the host may have
    -- wrapped to lay the panel out around the menu button's corner.
    frame = themeBuilder.frame(theme, rect, fonts),
    forms = {sample.digits},
    unit = sample.unit,
    draws = {
      rows = layout.showDetail == true,
      visual = layout.showVisual == true and layout.visual ~= "none",
    },
    bar = true,
    -- A bearing-style pair: the secondary source on the left, the link state
    -- on the right.
    rowItems = 2,
  }, out or {})
  return area
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

  local leading = settings.reading == "rssi" and settings.rssiSource
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
    local arm = services.session and services.session.armSource
    extrema:flight(arm ~= "" and arm or nil)
    context.sessionExtrema = extrema:sessionExtrema(leading)
  end

  -- A dBm reading is the widest thing this panel prints, and the sample comes
  -- from that rather than from the current value so the reading never resizes
  -- as the link fades. `dBm` is the widest unit it can carry -- a link quality
  -- reads in percent and an FrSky RSSI in plain dB -- so fitting against it
  -- means a narrower unit never has to be reconsidered.
  context.sample = {digits = "-100", unit = "dBm"}

  local area = linkStatus.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts, context.sample)
  context.detailWidth = area.detailWidth
  context.rowRightWidth = area.rowRightWidth
  context.showDetail = area.showDetail
  -- Built hidden: the unit is not known yet, so nothing here could decide
  -- whether it fits. `showUnitRoom` records that the panel fitted a `dBm` and
  -- has somewhere to put one; `apply` decides the rest.
  context.showUnitRoom = area.showUnit
  context.showUnit = false
  context.unitText = ""
  context.area = area

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation,
    services.themeBuilder)

  context.value = primitives.value(panel.root, theme, {
    x = area.valueX,
    y = area.valueY,
    w = area.valueWidth,
    text = "--",
    color = presentation.value,
    font = area.value,
  })

  -- The unit is whatever the source resolves to, which is not known yet, so
  -- it is built empty and filled once the telemetry service answers.
  context.unit = primitives.unit(panel.root, theme, {
    x = area.valueX,
    y = area.valueY,
    text = "",
    color = theme.color.textMuted,
    font = area.unitFont,
  })

  context.detailLabel = primitives.label(panel.root, theme, {
    x = area.detailX,
    y = area.detailY,
    w = area.detailWidth,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  context.linkLabel = primitives.label(panel.root, theme, {
    x = area.rowRightX,
    y = area.detailY,
    w = area.rowRightWidth,
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
  lvgl.hide(context.unit)
  -- What the panel currently shows, so a reflow that changes nothing about
  -- visibility does not tell every object again what it already is.
  context.showVisual = area.showVisual
  if context.bar and not area.showVisual then
    lvgl.hide(context.bar.track)
    lvgl.hide(context.bar.fill)
  end

  local _, drawn = primitives.changed(context, linkStatus.render)
  linkStatus.apply(context, drawn)
  return context
end

--- Repaint the component from its current subscriptions.
---@param context AeroGridLinkContext
--- Collect everything this panel draws.
---@param context AeroGridLinkContext
---@param out table
function linkStatus.render(context, out)
  local settings = context.settings
  local reading = linkStatus.read(context)

  out.state = linkStatus.resolveState(settings, reading)

  local text = "--"
  if type(reading.value) == "number" then
    local digits = reading.precision
    if type(digits) ~= "number" or digits < 0 then digits = 0 end
    if digits > 3 then digits = 3 end
    text = string.format("%." .. digits .. "f", reading.value)
  elseif reading.sourceState == "absent" then
    -- A source the protocol does not have reads N/A, never zero.
    text = "N/A"
  end
  out.text = text
  -- Declared only where it is drawn, like every other optional element. The
  -- unit is the source's own -- `dBm`, `dB` or `%` -- and it arrives with the
  -- reading rather than being known when the panel is built.
  out.unit = reading.unitText or ""
  out.value = reading.value
  out.primary = reading.primary

  -- A reading the panel is not showing must not leave a bar behind that still
  -- looks like a healthy link.
  out.fraction = out.state == "unavailable" and 0
    or linkStatus.fraction(settings, reading.value)

  if context.showDetail then
    out.detail = linkStatus.detailText(context, reading)
    out.link = linkStatus.linkText(context, reading)
  end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridLinkContext
---@param drawn table
function linkStatus.apply(context, drawn)
  local presentation = context.state(drawn.state, context.settings.accent)

  context.stateName = drawn.state
  context.reading = drawn.value
  context.primaryName = drawn.primary
  context.text = drawn.text
  context.detail = drawn.detail
  context.linkDetail = drawn.link

  context.value:set({text = drawn.text, color = presentation.value})
  -- The unit is the source's own -- `dBm`, `dB` or a percentage -- and it
  -- arrives when the source resolves rather than when the panel is built, so
  -- whether there is room for it is settled here, once, when it turns up.
  local unitText = drawn.unit or ""
  if unitText ~= context.unitText then
    context.unitText = unitText
    local shows = context.showUnitRoom and context.primitives.unitFits(
      context.themeBuilder, context.area.value, context.sample.digits,
      context.area.unitFont, unitText, context.area.content)
    context.unit:set({text = unitText})
    if shows ~= context.showUnit then
      -- Permission only. Whether the unit is *drawn* is settled by
      -- `centreReading` immediately below, which is the one place that
      -- knows both this answer and what the reading currently says; a
      -- show here would be a second opinion, and it would win for one
      -- frame over a panel with no value to qualify.
      context.showUnit = shows
      context.unitAnchor = nil
    end
  end
  context.primitives.centreReading(context, context.themeBuilder,
    context.area, context.area.value, drawn.text)
  context.label:set({color = presentation.label})
  context.primitives.setBadge(context, context.themeBuilder, context.badge,
    context.area.frame, context.fonts.badge, presentation.badge or "",
    presentation.accent)
  context.primitives.stylePanel(context.panel, presentation)

  if context.showDetail then
    context.detailLabel:set({text = drawn.detail})
    context.linkLabel:set({text = drawn.link})
    -- Both items of the row take the panel's slot centres, keyed on what
    -- they say so a steady link pays nothing.
    context.primitives.centreLabel(context, "detailAnchor",
      context.themeBuilder, context.detailLabel, context.area.detailCentre,
      context.area.detailY, context.fonts.label, drawn.detail)
    context.primitives.centreLabel(context, "linkAnchor",
      context.themeBuilder, context.linkLabel, context.area.rowRightCentre,
      context.area.detailY, context.fonts.label, drawn.link)
  end

  if context.bar then
    context.primitives.setBar(context.bar, drawn.fraction, presentation.accent)
  end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridLinkContext
function linkStatus.refresh(context)
  if not context.rssiFeed and not context.qualityFeed then return end
  local changed, drawn = context.primitives.changed(context, linkStatus.render)
  if changed then linkStatus.apply(context, drawn) end
end

--- Reposition after a zone change.
---@param context AeroGridLinkContext
---@param rect AeroGridRect
function linkStatus.update(context, rect)
  local area = linkStatus.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts, context.sample)

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts, context.settings.label,
      context.badgeText)
  context.value:set({
    x = area.pad,
    y = area.valueY,
    w = area.content,
    font = function() return area.value end,
  })

  context.showUnitRoom = area.showUnit
  local shows = area.showUnit and context.primitives.unitFits(
    context.themeBuilder, area.value, context.sample.digits, area.unitFont,
    context.unitText, area.content)
  context.primitives.reconcileUnit(context, context.unit, shows,
    context.themeBuilder, area.valueX, area.valueY, area.value, context.text,
    area.unitFont, shows == context.showUnit)
  context.showUnit = shows
  context.unitAnchor = nil
  context.area = area

  --- Show or hide a supporting row, positioning it only when visible.
  local reconcile = context.primitives.reconcile

  -- Recorded and nothing more, as in `cell-battery`: `render` reads all three
  -- and declares no detail or link key while the row is shed, so the reveal
  -- is a key reappearing rather than something this has to remember to do.
  context.detailWidth = area.detailWidth
  context.rowRightWidth = area.rowRightWidth
  context.showDetail = area.showDetail

  reconcile(context.detailLabel, area.showDetail,
    {x = area.detailX, y = area.detailY, w = area.detailWidth})
  reconcile(context.linkLabel, area.showDetail,
    {x = area.rowRightX, y = area.detailY, w = area.rowRightWidth})

  context.primitives.reconcileBar(context.bar, area.showVisual,
    area.pad, area.barY, area.content,
    linkStatus.fraction(context.settings, context.reading),
    area.showVisual == context.showVisual)
  context.showVisual = area.showVisual
end

return linkStatus
