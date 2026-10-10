-- SPDX-License-Identifier: GPL-2.0-only

--- Radio link strength, quality, and freshness.
---
--- RSSI and link quality are separate settings because protocols expose
--- different sensors in different units, and one is never inferred from the
--- other. FrSky reports `RSSI` in dB; ELRS reports `1RSS` and `2RSS` in dBm
--- alongside `RQly` as a percentage; a multi-antenna receiver exposes each
--- antenna as an ordinary source. Sources are named by the layout and either
--- may be absent. The optional ELRS 4.x profile decodes RFMD and nominal
--- sensitivity; generic protocols retain their own units and raw mode values.
---
--- Freshness is the hard part, and it is the reason this panel exists
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
--- whether any source ever contradicted the indicator. This panel reads
--- its published link view rather than guessing again.

---@class AeroGridLinkSettings
---@field rssiSource? string
---@field qualitySource? string
---@field reading? "auto"|"rssi"|"quality"
---@field label? string
---@field barMin? number Reading treated as empty by the bar.
---@field barMax? number Reading treated as full by the bar.
---@field rssiWarning? number
---@field rssiCritical? number
---@field extrema? "source"|"flight"|"none"
---@field extremaSource? string Explicit EdgeTX minimum source.
---@field visual? "bar"|"none"
---@field accent? string
---@field protocol? "generic"|"elrs4"
---@field modeSource? string
---@field snrSource? string
---@field powerSource? string
---@field qualityWarning? number
---@field qualityCritical? number
---@field marginWarning? number
---@field marginCritical? number

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
        "1x1",
        "2x1",
        "3x1",
        "4x1",
        "1x2",
        "2x2",
        "3x2",
        "4x2",
        "2x3",
        "3x3",
        "4x3",
    },
    -- Link quality is the one reading a pilot glances at during a fade, but it
    -- is still a number on a screen: five hertz is indistinguishable from fifty
    -- and costs a tenth as much of the shared instruction budget.
    refreshInterval = 20,
    settings = {
        { key = "rssiSource", label = "RSSI source", type = "string", default = "RSSI" },
        -- Never defaulted: link quality is not universal, and inferring it from
        -- RSSI would invent a number the radio never reported.
        { key = "qualitySource", label = "Link quality source", type = "string", default = "" },
        {
            key = "protocol",
            label = "Protocol mapping",
            type = "string",
            default = "generic",
            choices = { "generic", "elrs4" },
        },
        { key = "modeSource", label = "RF mode source", type = "string", default = "" },
        { key = "snrSource", label = "SNR source", type = "string", default = "" },
        { key = "powerSource", label = "Transmit power source", type = "string", default = "" },
        { key = "qualityWarning", label = "Warning link quality percent", type = "number" },
        { key = "qualityCritical", label = "Critical link quality percent", type = "number" },
        { key = "marginWarning", label = "Warning RSSI margin dB", type = "number" },
        { key = "marginCritical", label = "Critical RSSI margin dB", type = "number" },
        -- Which of the two sources leads the panel. Named `reading` like every
        -- other panel that chooses between its own values.
        {
            key = "reading",
            label = "Primary reading",
            type = "string",
            default = "auto",
            choices = { "auto", "rssi", "quality" },
        },
        { key = "label", label = "Label", type = "string", default = "LINK" },
        -- The bar's range, in the primary reading's own unit. The defaults suit a
        -- percentage; a dBm source needs its own, which is why they are settings.
        { key = "barMin", label = "Bar minimum", type = "number", default = 0 },
        { key = "barMax", label = "Bar maximum", type = "number", default = 100 },
        { key = "rssiWarning", label = "Warning RSSI", type = "number" },
        { key = "rssiCritical", label = "Critical RSSI", type = "number" },
        -- A link only ever gets worse downward.
        -- No `direction`. RSSI and link quality both only alarm downward.
        {
            key = "extrema",
            label = "Minimum tracked",
            type = "string",
            default = "none",
            choices = { "none", "source", "flight" },
        },
        { key = "extremaSource", label = "Minimum source", type = "string", default = "" },
        { key = "visual", label = "Visualization", type = "string", default = "bar", choices = { "bar", "none" } },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "green",
            choices = { "cyan", "green", "amber", "orange" },
        },
    },
}

-- RFMD is enum_rate, NOT the hardware-specific air-rate table index.
-- Verified against ExpressLRS 4.0.0 and 4.1.0 src/include/common.h,
-- src/src/common.cpp and rx_main.cpp / tx_main.cpp.
-- Sensitivity is firmware's nominal RXsensitivity, not a measured failsafe limit.
local elrs4Modes = {
    [0] = { "25Hz", -123 },
    [1] = { "50Hz", -120 },
    [2] = { "100Hz", -117 },
    [3] = { "100Hz 8ch", -112 },
    [5] = { "200Hz", -112 },
    [6] = { "200Hz 8ch", -111 },
    [7] = { "250Hz", -111 },
    [10] = { "D50Hz", -112 },
    [11] = { "FSK1000Hz 8ch", -101 },
    [21] = { "50Hz", -115 },
    [23] = { "100Hz 8ch", -112 },
    [24] = { "150Hz", -112 },
    [27] = { "250Hz", -108 },
    [28] = { "333Hz 8ch", -105 },
    [29] = { "500Hz", -105 },
    [30] = { "D250Hz", -104 },
    [31] = { "D500Hz", -104 },
    [32] = { "F500Hz", -104 },
    [33] = { "F1000Hz", -104 },
    [34] = { "FSK D250Hz", -103 },
    [35] = { "FSK D500Hz", -103 },
    [36] = { "FSK1000Hz", -103 },
    -- Mixed-band RSSI cannot be paired with a band-specific sensitivity from
    -- RFMD alone. Display the rate but do not invent a dual-band margin.
    [100] = { "DUAL100Hz 8ch" },
    [101] = { "DUAL150Hz" },
}

function linkStatus.modeFor(value)
    if type(value) ~= "number" or value % 1 ~= 0 then
        return nil
    end
    return elrs4Modes[value]
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function thresholdRank(value, warning, critical)
    if not finite(value) then
        return 0
    end
    if type(critical) == "number" and value <= critical then
        return 2
    end
    if type(warning) == "number" and value <= warning then
        return 1
    end
    return 0
end

--- Describe how the panel presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
function linkStatus.presentationFor(colSpan, rowSpan)
    local cells = (colSpan or 1) * (rowSpan or 1)
    return { showVisual = cells >= 2, showDetail = cells >= 2 }
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
    if type(feed) ~= "table" then
        return "none"
    end
    if feed.name == nil or feed.name == "" then
        return "none"
    end
    if not feed.known then
        return "absent"
    end
    if feed.available ~= true then
        return "waiting"
    end
    if feed.stale == true then
        return "stale"
    end
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

    if wanted == "rssi" then
        return "rssi"
    end
    if wanted == "quality" then
        return "quality"
    end

    -- Auto: whichever source the radio actually has, quality first.
    if qualityState == "live" or qualityState == "stale" then
        return "quality"
    end
    if rssiState == "live" or rssiState == "stale" then
        return "rssi"
    end
    if qualityState ~= "none" and qualityState ~= "absent" then
        return "quality"
    end
    if rssiState ~= "none" and rssiState ~= "absent" then
        return "rssi"
    end
    return qualityState ~= "none" and "quality" or "rssi"
end

--- Resolve the panel state.
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
    reading.cause = nil
    if reading.linkDown then
        -- Never seen a reading and no link either: the model has not been powered
        -- up yet, which is not a fault and must not shout about one.
        if not reading.available then
            return "unavailable"
        end
        return "critical"
    end

    local rank = reading.rssiState == "live"
            and thresholdRank(reading.rssiValue, settings.rssiWarning, settings.rssiCritical)
        or 0
    if rank > 0 then
        reading.cause = "LOW RSSI"
    end
    local qualityRank = reading.qualityState == "live"
            and thresholdRank(reading.qualityValue, settings.qualityWarning, settings.qualityCritical)
        or 0
    if qualityRank > rank then
        rank, reading.cause = qualityRank, "LOW LQ"
    end
    local marginRank = thresholdRank(reading.margin, settings.marginWarning, settings.marginCritical)
    if marginRank > rank then
        rank, reading.cause = marginRank, "LOW MARGIN"
    end
    if rank > 0 then
        return rank == 2 and "critical" or "warning"
    end
    if reading.sourceState == "none" or reading.sourceState == "absent" or reading.sourceState == "waiting" then
        return "unavailable"
    end
    if reading.sourceState == "stale" then
        return "stale"
    end
    if not finite(reading.value) then
        return "unavailable"
    end

    return "normal"
end

--- Validate source-specific thresholds and their required sources.
---@param settings AeroGridLinkSettings
---@return string[] messages
function linkStatus.validateSettings(settings)
    local messages = {}
    if
        (settings.rssiWarning ~= nil or settings.rssiCritical ~= nil)
        and (not settings.rssiSource or settings.rssiSource == "")
    then
        messages[#messages + 1] = "RSSI thresholds require rssiSource"
    end
    for _, pair in ipairs({
        { "rssiWarning", "rssiCritical" },
        { "qualityWarning", "qualityCritical" },
        { "marginWarning", "marginCritical" },
    }) do
        local warning, critical = settings[pair[1]], settings[pair[2]]
        if type(warning) == "number" and type(critical) == "number" and critical > warning then
            messages[#messages + 1] = pair[2] .. " must be less than or equal to " .. pair[1]
        end
    end
    if settings.qualityWarning ~= nil or settings.qualityCritical ~= nil then
        if not settings.qualitySource or settings.qualitySource == "" then
            messages[#messages + 1] = "quality thresholds require qualitySource"
        end
        for _, key in ipairs({ "qualityWarning", "qualityCritical" }) do
            if type(settings[key]) == "number" and (settings[key] < 0 or settings[key] > 100) then
                messages[#messages + 1] = key .. " must be between 0 and 100 percent"
            end
        end
    end
    if settings.marginWarning ~= nil or settings.marginCritical ~= nil then
        if
            settings.protocol ~= "elrs4"
            or not settings.modeSource
            or settings.modeSource == ""
            or not settings.rssiSource
            or settings.rssiSource == ""
        then
            messages[#messages + 1] = "margin thresholds require protocol: elrs4, modeSource and receiver rssiSource"
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
    out.rssiValue = type(rssi) == "table" and rssi.available and rssi.value or nil
    out.primary = linkStatus.primaryFor(context.settings, out.rssiState, out.qualityState)

    local feed = out.primary == "quality" and quality or rssi
    out.sourceState = out.primary == "quality" and out.qualityState or out.rssiState
    out.value = nil
    out.unitText = ""
    out.precision = 0
    out.available = false

    if type(feed) == "table" then
        out.available = feed.available == true
        if out.available and finite(feed.value) then
            out.value = feed.value
        end
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
    out.qualityValue = type(quality) == "table" and quality.unitText == "%" and quality.value or nil
    out.margin, out.mode = nil, nil
    if context.settings.protocol == "elrs4" then
        local modeFeed = context.modeFeed
        out.modeState = linkStatus.classify(modeFeed)
        if out.modeState == "live" and modeFeed.unitText == "" and not out.linkDown then
            out.mode = linkStatus.modeFor(modeFeed.value)
            if
                out.mode
                and out.mode[2]
                and out.rssiState == "live"
                and rssi ~= nil
                and finite(rssi.value)
                and rssi.value <= 0
                and (rssi.unitText == "dB" or rssi.unitText == "dBm")
            then
                out.margin = rssi.value - out.mode[2]
            end
        end
        if out.primary == "rssi" and (out.unitText == "dB" or out.unitText == "dBm") then
            out.unitText = "dBm"
        end
    end

    return out
end

--- Format one reading for a supporting row.
---@param feed any
---@param state string Result of linkStatus.classify.
---@return string
function linkStatus.sourceText(feed, state)
    if state == "none" then
        return "--"
    end
    -- A source the radio has never heard of is not a zero reading; saying so is
    -- the difference between "this protocol has no RSSI" and "your link died".
    if state == "absent" then
        return "N/A"
    end
    if state == "waiting" then
        return "--"
    end

    local value = type(feed) == "table" and feed.value or nil
    if not finite(value) then
        return "--"
    end

    local digits = type(feed.precision) == "number" and feed.precision or 0
    if digits < 0 then
        digits = 0
    end
    if digits > 3 then
        digits = 3
    end

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
        if type(feed) ~= "table" or not feed.available then
            return nil
        end
        return type(feed.value) == "number" and feed.value or nil
    end

    if mode == "flight" then
        local track = context.sessionExtrema
        if type(track) ~= "table" or not track.available then
            return nil
        end
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
            variants = { "MIN --", "--" }
        else
            local text = string.format("%." .. math.max(0, reading.precision) .. "f", value)
            variants = { "MIN " .. text, text }
        end
    elseif reading.primary == "quality" then
        -- With no minimum configured, the row names the secondary source, which is
        -- whichever of the two is not leading the panel.
        local text = linkStatus.sourceText(context.rssiFeed, reading.rssiState)
        if context.settings.protocol == "elrs4" and context.rssiFeed and context.rssiFeed.unitText == "dB" then
            text = text
                .. (
                    finite(context.rssiFeed.value)
                        and reading.rssiState ~= "waiting"
                        and reading.rssiState ~= "absent"
                        and "m"
                    or ""
                )
        end
        if context.settings.protocol == "elrs4" and reading.rssiState == "stale" then
            text = text .. "*"
        end
        variants = { "RSSI " .. text, text }
    else
        local text = linkStatus.sourceText(context.qualityFeed, reading.qualityState)
        variants = { "LQ " .. text, text }
    end

    return context.themeBuilder.fitLabel(variants, context.fonts.label, context.detailWidth)
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
        variants = { "LINK DOWN", "NO LINK", "DOWN" }
    elseif reading.cause then
        if reading.cause == "LOW MARGIN" then
            variants = { "LOW MARGIN", "MARGIN" }
        elseif reading.cause == "LOW LQ" then
            variants = { "LOW LQ", "LQ" }
        else
            variants = { "LOW RSSI", "RSSI", "RSS" }
        end
    elseif context.settings.protocol == "elrs4" and context.modeFeed then
        if reading.margin ~= nil then
            local text = string.format("%.0fdB", reading.margin)
            variants = { "MARGIN " .. text, text }
        elseif reading.modeState == "stale" then
            variants = { "MODE STALE", "RF STALE" }
        elseif reading.modeState == "live" and not reading.mode then
            variants = { "UNKNOWN MODE", "RFMD ?" }
        elseif reading.modeState == "absent" then
            variants = { "NO RFMD SENSOR", "NO RFMD" }
        elseif reading.modeState == "waiting" then
            variants = { "WAIT RFMD", "RF WAIT" }
        elseif reading.mode and reading.mode[2] and reading.rssiState == "live" then
            variants = { "BAD RSSI", "RSSI ERR" }
        else
            variants = { "MARGIN N/A", "N/A" }
        end
    elseif not reading.indicator or reading.rssiState == "absent" then
        variants = { "NO RSSI SENSOR", "NO RSSI SENSE", "NO RSSI", "NO RSS" }
    elseif reading.primary == "quality" then
        local text = linkStatus.sourceText(context.rssiFeed, reading.rssiState)
        variants = { "RSSI " .. text, text }
    else
        local text = linkStatus.sourceText(context.qualityFeed, reading.qualityState)
        variants = { "LQ " .. text, text }
    end

    if context.pairedRow and reading.margin ~= nil then
        local signal = string.format("%.0fdBm", context.rssiFeed.value)
        local margin = string.format("(%+.0fdB)", reading.margin)
        local pair = signal .. " " .. margin
        if reading.cause then
            variants = { reading.cause .. ": " .. pair, reading.cause .. " " .. margin, reading.cause }
        else
            variants = { pair, signal }
        end
    end

    return context.themeBuilder.fitLabel(variants, context.fonts.label, context.rowRightWidth)
end

function linkStatus.extraText(context, reading)
    local parts = {}
    if context.modeFeed then
        local text = linkStatus.sourceText(context.modeFeed, linkStatus.classify(context.modeFeed))
        if context.settings.protocol == "elrs4" then
            text = reading.mode and reading.mode[1] or "RFMD " .. text .. (reading.modeState == "live" and " ?" or "")
        else
            text = "RFMD " .. text
        end
        if linkStatus.classify(context.modeFeed) == "stale" then
            text = text .. "*"
        end
        parts[#parts + 1] = text
    end
    for _, item in ipairs({ { "snrFeed", "SNR " }, { "powerFeed", "PWR " } }) do
        local feed = context[item[1]]
        if feed then
            local state = linkStatus.classify(feed)
            local prefix = item[1] == "powerFeed"
                    and feed.unitText ~= ""
                    and (state == "live" or state == "stale")
                    and ""
                or item[2]
            parts[#parts + 1] = prefix .. linkStatus.sourceText(feed, state) .. (state == "stale" and "*" or "")
        end
    end
    -- Shed optional details, never clip them into another metric.
    while
        #parts > 1
        and context.themeBuilder.textWidth(context.fonts.label, table.concat(parts, "  ")) > context.area.content
    do
        parts[#parts] = nil
    end
    return context.themeBuilder.fitLabel(
        { table.concat(parts, "  "), "RF DETAIL" },
        context.fonts.label,
        context.area.content
    )
end

--- Convert the primary reading into a 0..1 fraction of the configured range.
---@param settings AeroGridLinkSettings
---@param value any
---@param primitives table
---@return number
function linkStatus.fraction(settings, value, primitives)
    local low = type(settings.barMin) == "number" and settings.barMin or 0
    local high = type(settings.barMax) == "number" and settings.barMax or 100
    if high <= low then
        return 0
    end
    return primitives.fraction(value, low, high)
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@param sample table Widest value text and unit this panel can render.
---@return table
function linkStatus.regionsFor(theme, themeBuilder, rect, layout, fonts, sample, out)
    -- The whole arrangement, from the shared builder. This panel's only
    -- visualization is a bar, which spans the panel by design and is exempt
    -- from the slot rule, so the reading never splits and centres across the
    -- whole content box.
    local area = themeBuilder.panel(theme, rect, fonts, {
        -- Built through this panel's own builder, which the host may have
        -- wrapped to lay the panel out around the menu button's corner.
        frame = themeBuilder.frame(theme, rect, fonts),
        forms = { sample.digits },
        unit = sample.unit,
        draws = {
            rows = layout.showDetail == true,
            visual = layout.showVisual == true and layout.visual ~= "none",
        },
        bar = true,
        -- A bearing-style pair: the secondary source on the left, the link state
        -- on the right.
        rowItems = layout.pairedRow and 1 or 2,
        supporting = layout.side
                and { "", "", width = themeBuilder.textWidth(fonts.label, "-123dBm"), sideOnly = true }
            or nil,
    }, out or {})
    if layout.pairedRow then
        area.rowRightCentre = area.detailCentre
        area.rowRightWidth = area.detailWidth
        area.rowRightX = area.detailX
    end
    area.showExtra = false
    if layout.extra and area.showDetail then
        local height = themeBuilder.fontHeight(fonts.label)
        local bands = themeBuilder.bands(area.frame, rect, true)
        local extraY = area.detailY - height
        if extraY >= bands.tertiary.y then
            area.extraY = area.detailY
            area.detailY = extraY
            area.showExtra = true
        end
    end
    return area
end

--- Build the panel's LVGL objects.
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
    layout.extra = (settings.modeSource or "") ~= ""
        or (settings.snrSource or "") ~= ""
        or (settings.powerSource or "") ~= ""
    layout.pairedRow = settings.protocol == "elrs4" and settings.reading ~= "rssi" and settings.extrema == "none"
    layout.side = span.colSpan == 2
        and span.rowSpan == 1
        and settings.protocol == "elrs4"
        and settings.reading == "quality"
        and (settings.rssiSource or "") ~= ""
        and (settings.modeSource or "") ~= ""
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
        pairedRow = layout.pairedRow,
    }

    local telemetry = services.telemetry
    if telemetry then
        -- Both sources are subscribed even when only one leads the panel: the
        -- other is supporting detail, and a panel that subscribed lazily would
        -- have nothing to show the moment the protocol turned out to differ.
        if type(settings.rssiSource) == "string" and settings.rssiSource ~= "" then
            context.rssiFeed = telemetry:subscribe(settings.rssiSource)
        end
        if type(settings.qualitySource) == "string" and settings.qualitySource ~= "" then
            context.qualityFeed = telemetry:subscribe(settings.qualitySource)
        end
        for _, name in ipairs({ "mode", "snr", "power" }) do
            local source = settings[name .. "Source"]
            if type(source) == "string" and source ~= "" then
                local receiverEvidence = settings.protocol ~= "elrs4" or name == "snr"
                context[name .. "Feed"] = telemetry:subscribe(source, receiverEvidence)
            end
        end
        context.link = telemetry:link()
    end

    local leading = settings.reading == "rssi" and settings.rssiSource or settings.qualitySource
    if type(leading) ~= "string" or leading == "" then
        leading = settings.rssiSource
    end

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
    context.sample = { digits = "-100", unit = "dBm" }
    context.rect = rect

    local area = linkStatus.regionsFor(theme, services.themeBuilder, rect, layout, fonts, context.sample)
    context.detailWidth = area.detailWidth
    context.rowRightWidth = area.rowRightWidth
    context.showDetail = area.showDetail
    context.showExtra = area.showExtra
    context.showSide = area.showSide
    -- Built hidden: the unit is not known yet, so nothing here could decide
    -- whether it fits. `showUnitRoom` records that the panel fitted a `dBm` and
    -- has somewhere to put one; `apply` decides the rest.
    context.showUnitRoom = area.showUnit
    context.showUnit = false
    context.unitText = ""
    context.area = area

    local panel
    context.panel, context.label, context.badge = primitives.panelWithHeader(
        parent,
        rect,
        theme,
        presentation,
        area.frame,
        fonts,
        settings.label,
        services.themeBuilder
    )
    panel = context.panel

    context.value, context.unit = primitives.reading(panel.root, theme, area, presentation, "")

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

    if layout.extra then
        context.extraLabel = primitives.label(panel.root, theme, {
            x = area.pad,
            y = area.extraY or area.detailY,
            w = area.content,
            text = "",
            color = theme.color.textFaint,
            font = fonts.label,
        })
        if not area.showExtra then
            lvgl.hide(context.extraLabel)
        end
    end
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
    if context.pairedRow and area.showDetail then
        lvgl.hide(context.detailLabel)
    end
    if area.showSide then
        lvgl.show(context.detailLabel)
        lvgl.show(context.linkLabel)
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

--- Repaint the panel from its current subscriptions.
---@param context AeroGridLinkContext
--- Collect everything this panel draws.
---@param out table
function linkStatus.render(context, out)
    local settings = context.settings
    local reading = linkStatus.read(context)

    out.state = linkStatus.resolveState(settings, reading)
    local noLink = reading.linkDown and reading.available

    local text = "--"
    if type(reading.value) == "number" then
        local digits = reading.precision
        if type(digits) ~= "number" or digits < 0 then
            digits = 0
        end
        if digits > 3 then
            digits = 3
        end
        text = string.format("%." .. digits .. "f", reading.value)
    elseif reading.sourceState == "absent" then
        -- A source the protocol does not have reads N/A, never zero.
        text = "N/A"
    end
    out.text = noLink and "NO LINK" or text
    -- Declared only where it is drawn, like every other optional element. The
    -- unit is the source's own -- `dBm`, `dB` or `%` -- and it arrives with the
    -- reading rather than being known when the panel is built.
    out.unit = not noLink and reading.unitText or ""
    out.value = reading.value
    out.primary = reading.primary

    -- A reading the panel is not showing must not leave a bar behind that still
    -- looks like a healthy link.
    out.fraction = (noLink or out.state == "unavailable") and 0
        or linkStatus.fraction(settings, reading.value, context.primitives)

    if context.showDetail then
        out.detail = context.pairedRow and "" or linkStatus.detailText(context, reading)
        out.link = linkStatus.linkText(context, reading)
    end
    if context.showExtra then
        out.extra = linkStatus.extraText(context, reading)
    end
    if context.showSide then
        local signal = linkStatus.sourceText(context.rssiFeed, reading.rssiState)
        if finite(context.rssiFeed.value) and (reading.rssiState == "live" or reading.rssiState == "stale") then
            signal = string.format("%.0fdBm", context.rssiFeed.value) .. (reading.rssiState == "stale" and "*" or "")
        end
        out.side = context.themeBuilder.fitLabel({ signal, "RSSI --" }, context.fonts.label, context.area.sideWidth)
        out.margin = reading.margin ~= nil and string.format("(%+.0fdB)", reading.margin) or "(N/A)"
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
    context.extra = drawn.extra
    context.side = drawn.side
    context.margin = drawn.margin

    context.value:set({ text = drawn.text, color = presentation.value })
    -- The unit is the source's own -- `dBm`, `dB` or a percentage -- and it
    -- arrives when the source resolves rather than when the panel is built, so
    -- whether there is room for it is settled here, once, when it turns up.
    local unitText = drawn.unit or ""
    if unitText ~= context.unitText then
        context.unitText = unitText
        local shows = context.showUnitRoom
            and context.primitives.unitFits(
                context.themeBuilder,
                context.area.value,
                context.sample.digits,
                context.area.unitFont,
                unitText,
                context.area.content
            )
        context.unit:set({ text = unitText })
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
    context.primitives.centreReading(context, context.themeBuilder, context.area, context.area.value, drawn.text)
    context.label:set({ color = presentation.label })
    context.primitives.setBadge(
        context,
        context.themeBuilder,
        context.badge,
        context.area.frame,
        context.fonts.badge,
        presentation.badge or "",
        presentation.accent
    )
    context.primitives.stylePanel(context.panel, presentation)

    if context.showDetail then
        context.detailLabel:set({ text = drawn.detail })
        context.linkLabel:set({ text = drawn.link })
        -- Both items of the row take the panel's slot centres, keyed on what
        -- they say so a steady link pays nothing.
        context.primitives.centreLabel(
            context,
            "detailAnchor",
            context.themeBuilder,
            context.detailLabel,
            context.area.detailCentre,
            context.area.detailY,
            context.fonts.label,
            drawn.detail
        )
        context.primitives.centreLabel(
            context,
            "linkAnchor",
            context.themeBuilder,
            context.linkLabel,
            context.area.rowRightCentre,
            context.area.detailY,
            context.fonts.label,
            drawn.link
        )
    end

    if context.showExtra then
        context.extraLabel:set({ text = drawn.extra })
        context.primitives.centreLabel(
            context,
            "extraAnchor",
            context.themeBuilder,
            context.extraLabel,
            context.area.pad + math.floor(context.area.content / 2),
            context.area.extraY,
            context.fonts.label,
            drawn.extra
        )
    end
    if context.showSide then
        context.detailLabel:set({ text = drawn.side })
        context.linkLabel:set({ text = drawn.margin })
        context.primitives.centreLabel(
            context,
            "sideAnchor",
            context.themeBuilder,
            context.detailLabel,
            context.area.sideCentre,
            context.area.sideY,
            context.fonts.label,
            drawn.side
        )
        context.primitives.centreLabel(
            context,
            "marginAnchor",
            context.themeBuilder,
            context.linkLabel,
            context.area.sideCentre,
            context.area.marginY,
            context.fonts.label,
            drawn.margin
        )
    end
    if context.bar then
        context.primitives.setBar(context.bar, drawn.fraction, presentation.accent)
    end
end

--- Advance the panel, repainting only when something drawn changed.
---@param context AeroGridLinkContext
function linkStatus.refresh(context)
    if not context.rssiFeed and not context.qualityFeed then
        return
    end
    local reading = linkStatus.read(context)
    local noLink = reading.linkDown and reading.available
    local digits = noLink and "NO LINK" or "-100"
    if context.sample.digits ~= digits then
        context.sample.digits = digits
        context.sample.unit = noLink and "" or "dBm"
        linkStatus.update(context, context.rect)
        context.rendered = nil
    end
    local changed, drawn = context.primitives.changed(context, linkStatus.render)
    if changed then
        linkStatus.apply(context, drawn)
    end
end

--- Reposition after a zone change.
---@param context AeroGridLinkContext
---@param rect AeroGridRect
function linkStatus.update(context, rect)
    context.rect = rect
    local area =
        linkStatus.regionsFor(context.theme, context.themeBuilder, rect, context.layout, context.fonts, context.sample)

    context.primitives.resizeHeader(context, rect, area.frame, context.settings.label)
    context.primitives.setFont(context.value, area.value)
    context.value:set({
        x = area.pad,
        y = area.valueY,
        w = area.content,
    })

    context.showUnitRoom = area.showUnit
    local shows = area.showUnit
        and context.primitives.unitFits(
            context.themeBuilder,
            area.value,
            context.sample.digits,
            area.unitFont,
            context.unitText,
            area.content
        )
    context.primitives.reflowReading(context, context.themeBuilder, area, area.value, context.text, shows)

    --- Show or hide a supporting row, positioning it only when visible.
    local reconcile = context.primitives.reconcile

    -- Recorded and nothing more, as in `cell-battery`: `render` reads all three
    -- and declares no detail or link key while the row is shed, so the reveal
    -- is a key reappearing rather than something this has to remember to do.
    context.detailWidth = area.detailWidth
    context.rowRightWidth = area.rowRightWidth
    context.showDetail = area.showDetail
    context.showExtra = area.showExtra
    context.showSide = area.showSide

    reconcile(
        context.detailLabel,
        area.showDetail and not context.pairedRow,
        { x = area.detailX, y = area.detailY, w = area.detailWidth }
    )
    reconcile(context.linkLabel, area.showDetail, { x = area.rowRightX, y = area.detailY, w = area.rowRightWidth })
    if context.extraLabel then
        reconcile(
            context.extraLabel,
            area.showExtra,
            { x = area.pad, y = area.extraY or area.detailY, w = area.content }
        )
    end
    if context.layout.side then
        context.sideAnchor = nil
        context.marginAnchor = nil
        reconcile(
            context.detailLabel,
            area.showSide,
            { x = area.pad, y = area.sideY or area.detailY, w = area.sideWidth or area.detailWidth }
        )
        reconcile(
            context.linkLabel,
            area.showSide,
            { x = area.pad, y = area.marginY or area.detailY, w = area.sideWidth or area.rowRightWidth }
        )
    end
    for _, row in ipairs({
        { context.showDetail, context.detailLabel, "detailAnchor", area.detailCentre, area.detailY, context.detail },
        { context.showDetail, context.linkLabel, "linkAnchor", area.rowRightCentre, area.detailY, context.linkDetail },
        {
            context.showExtra,
            context.extraLabel,
            "extraAnchor",
            area.pad + math.floor(area.content / 2),
            area.extraY,
            context.extra,
        },
        { context.showSide, context.detailLabel, "sideAnchor", area.sideCentre, area.sideY, context.side },
        { context.showSide, context.linkLabel, "marginAnchor", area.sideCentre, area.marginY, context.margin },
    }) do
        context[row[3]] = nil
        if row[1] then
            context.primitives.centreLabel(
                context,
                row[3],
                context.themeBuilder,
                row[2],
                row[4],
                row[5],
                context.fonts.label,
                row[6]
            )
        end
    end

    context.primitives.reconcileBar(
        context.bar,
        area.showVisual,
        area.pad,
        area.barY,
        area.content,
        linkStatus.fraction(context.settings, context.reading, context.primitives),
        area.showVisual == context.showVisual
    )
    context.showVisual = area.showVisual
end

return linkStatus
