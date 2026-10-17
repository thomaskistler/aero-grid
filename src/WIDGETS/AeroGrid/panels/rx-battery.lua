-- SPDX-License-Identifier: GPL-2.0-only

--- Aircraft battery voltage from an EdgeTX cells monitor or pack sensor.
---
--- The bar is scaled over the configured usable range, from the empty
--- voltage to full, not from zero. A bar that started at zero would sit above
--- three quarters full on a pack that is nearly empty.
---
--- A cells source returns the monitored cells table. A pack source such as
--- "RxBt" supplies only total voltage; alarms therefore judge its average,
--- never a guessed lowest cell. When its series count is automatic, the first
--- fresh voltage is divided by the configured full-cell voltage and rounded
--- once. That estimate is held until telemetry disconnects.
---
--- Count estimation assumes the first received pack voltage is near full.
--- It is an estimate, not a capacity or cell-health measurement; configuring
--- the known series count is more reliable.

---@class AeroGridRxBatterySettings
---@field source? string EdgeTX cells or pack-voltage source.
---@field label? string
---@field reading? "cell"|"pack" Which value is dominant.
---@field cellEmpty? number Volts per cell treated as empty by the bar.
---@field cellFull? number Volts per cell treated as full by the bar.
---@field cellWarning? number Volts per cell.
---@field cellCritical? number Volts per cell.
---@field cells? number Pack series count; zero estimates it from initial voltage.
---@field showPack? boolean Show pack voltage, or average voltage when pack leads.
---@field showCount? boolean Show the measured or configured cell count.
---@field showDelta? boolean Show highest minus lowest measured cell voltage.
---@field visual? "battery"|"bar"|"none" `none` is shown as "details".
---@field accent? string

---@class AeroGridRxBatteryContext
---@field panel table
---@field feed? AeroGridReading Battery voltage subscription.
---@field estimatedCells? integer
---@field summary table Reused result of the last shape validation.
---@field stateName string

local rxBattery = {
    id = "rx-battery",
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
    },
    -- A pack voltage moves over a flight, not over a frame, and every refresh
    -- walks the cells table. Five hertz is already far more than a pilot reads.
    refreshInterval = 20,
    settings = {
        { key = "label", label = "Label", type = "string", default = "PACK" },
        { key = "source", label = "Voltage source", type = "string", default = "Cels" },
        {
            key = "cells",
            label = "Cell count (0 = auto)",
            type = "number",
            default = 0,
            min = 0,
            max = 16,
            step = 1,
        },
        {
            key = "reading",
            label = "Primary reading",
            type = "string",
            default = "cell",
            choices = { "cell", "pack" },
        },
        {
            key = "cellFull",
            label = "Full (V/cell)",
            type = "number",
            default = 4.2,
            min = 0,
            max = 10,
            step = 0.01,
            section = "Voltage levels",
            visibleWhen = { key = "visual", value = "none", invert = true },
        },
        {
            key = "cellWarning",
            label = "Warning (V/cell)",
            type = "number",
            default = 3.6,
            min = 0,
            max = 10,
            step = 0.01,
        },
        {
            key = "cellCritical",
            label = "Critical (V/cell)",
            type = "number",
            default = 3.4,
            min = 0,
            max = 10,
            step = 0.01,
        },
        {
            key = "cellEmpty",
            label = "Empty (V/cell)",
            type = "number",
            default = 3.2,
            min = 0,
            max = 10,
            step = 0.01,
            visibleWhen = { key = "visual", value = "none", invert = true },
        },
        -- Preferences, not demands: the panel sheds either where it does not
        -- fit, and the battery visualization never draws them.
        {
            key = "visual",
            label = "Visualization",
            type = "string",
            default = "battery",
            choices = { "battery", "bar", "none" },
            choiceLabels = { "battery", "bar", "details" },
        },
        {
            key = "showPack",
            label = "Show alt reading",
            type = "boolean",
            default = true,
            visibleWhen = { key = "visual", value = "battery", invert = true },
        },
        {
            key = "showCount",
            label = "Show cell count",
            type = "boolean",
            default = true,
            visibleWhen = { key = "visual", value = "battery", invert = true },
        },
        {
            key = "showDelta",
            label = "Show cell delta",
            type = "boolean",
            default = false,
            visibleWhen = { key = "visual", value = "battery", invert = true },
        },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "cyan",
            choices = { "cyan", "green", "amber", "orange" },
        },
    },
}

--- Most cells any supported protocol reports, and the ceiling on the walk.
--- The loop is bounded because it runs inside the host's instruction budget
--- and the table comes from the firmware rather than from this dashboard.
rxBattery.CELL_LIMIT = 16

--- Voltages outside this range are not cells.
--- A chemistry this dashboard has never heard of still cannot put 30 V across
--- one cell, so an entry above it is a pack voltage, a raw count, or a sensor
--- reporting something else entirely, and folding it in would hide a real low
--- cell behind a nonsense average.
rxBattery.CELL_MAX = 30

--- Validate a cells value and summarize it.
---
--- The result is written into a caller-owned table so a refresh allocates
--- nothing. `shape` is the honest description of what EdgeTX returned:
---
--- - `none`: nothing has been received, or the source is not configured.
--- - `number`: a plain number; gather summarizes it as pack voltage instead.
--- - `empty`: a table with no entries, which is what a pack that has not been
---   detected yet looks like.
--- - `invalid`: a table whose entries are not plausible cell voltages.
--- - `cells`: a usable table, with at least one valid cell.
---
--- Numeric values never infer individual cells from their magnitude.
---@param raw any Value from a telemetry subscription.
---@param out table Table to write the summary into.
---@return table out
function rxBattery.summarize(raw, out)
    out.shape = "none"
    out.count = 0
    out.entries = 0
    out.rejected = 0
    out.lowest = nil
    out.highest = nil
    out.pack = nil
    out.spread = nil
    out.estimated = nil
    out.numeric = nil

    if raw == nil then
        return out
    end

    if type(raw) ~= "table" then
        out.shape = type(raw) == "number" and "number" or "invalid"
        return out
    end

    local limit = rxBattery.CELL_LIMIT
    local maximum = rxBattery.CELL_MAX
    local sum = 0

    for index = 1, limit do
        local value = raw[index]
        if value == nil then
            break
        end

        out.entries = index
        -- A NaN compares false against everything, so it is excluded by the
        -- bounds test rather than needing its own branch.
        if type(value) == "number" and value > 0 and value < maximum then
            out.count = out.count + 1
            sum = sum + value
            if out.lowest == nil or value < out.lowest then
                out.lowest = value
            end
            if out.highest == nil or value > out.highest then
                out.highest = value
            end
        else
            out.rejected = out.rejected + 1
        end
    end

    if out.entries == 0 then
        out.shape = "empty"
        return out
    end

    if out.count == 0 then
        out.shape = "invalid"
        return out
    end

    out.shape = "cells"
    out.pack = sum
    out.spread = out.highest - out.lowest
    return out
end

--- Pack voltage supplies no information about imbalance or the lowest cell.
---@param raw any
---@param cells number? Configured or estimated count; unavailable estimates are rejected.
---@param out table
---@return table
function rxBattery.summarizePack(raw, cells, out)
    rxBattery.summarize(nil, out)
    if raw == nil then
        return out
    end
    if
        type(raw) ~= "number"
        or raw <= 0
        or raw >= rxBattery.CELL_MAX * rxBattery.CELL_LIMIT
        or raw ~= raw
        or type(cells) ~= "number"
        or cells < 1
        or cells > rxBattery.CELL_LIMIT
    then
        out.shape = "invalid"
        return out
    end
    out.shape = "pack"
    out.count = cells
    out.pack = raw
    return out
end

--- Choose the dominant reading from a validated summary.
---@param settings AeroGridRxBatterySettings
---@param summary table
---@return number? value
function rxBattery.primaryValue(settings, summary)
    if settings.reading == "pack" then
        return summary.pack
    end
    if summary.count == 0 or summary.pack == nil then
        return nil
    end
    if summary.shape == "pack" then
        return summary.pack / summary.count
    end
    return summary.lowest
end

--- Report whether the primary reading is a per-cell voltage.
--- A pack reading is not, so per-cell thresholds and the per-cell bar must not
--- be applied to it.
---@param settings AeroGridRxBatterySettings
---@return boolean
function rxBattery.isPerCell(settings)
    return settings.reading ~= "pack"
end

--- Estimate the series count from the initial voltage of a near-full pack.
---@param voltage number
---@param cellFull number
---@return integer? count
function rxBattery.estimateCount(voltage, cellFull)
    if type(voltage) ~= "number" or voltage <= 0 or voltage ~= voltage then
        return nil
    end
    if type(cellFull) ~= "number" or cellFull <= 0 or cellFull ~= cellFull then
        return nil
    end
    local count = math.floor(voltage / cellFull + 0.5)
    if count < 1 or count > rxBattery.CELL_LIMIT then
        return nil
    end
    return count
end

--- Resolve the panel state. Cell voltages always count downward.
---@param settings AeroGridRxBatterySettings
---@param value any Primary reading.
---@param perCell any Lowest measured cell, or average for a pack source.
---@param stale boolean
---@return string
function rxBattery.resolveState(settings, value, perCell, stale)
    if type(value) ~= "number" or value ~= value then
        return "unavailable"
    end
    if stale then
        return "stale"
    end

    -- A cells monitor judges the worst cell; a pack source can only supply
    -- an average and cannot detect a single sagging cell.
    local judged = type(perCell) == "number" and perCell or nil
    if judged == nil then
        return "normal"
    end

    local critical = settings.cellCritical
    local warning = settings.cellWarning
    if type(critical) == "number" and judged <= critical then
        return "critical"
    end
    if type(warning) == "number" and judged <= warning then
        return "warning"
    end
    return "normal"
end

--- Convert a per-cell voltage into a fraction of the usable range.
--- The range runs from the configured empty voltage to full, never from zero.
---@param settings AeroGridRxBatterySettings
---@param value any
---@param cells integer Divisor for a pack reading.
---@param primitives table
---@return number
function rxBattery.fraction(settings, value, cells, primitives)
    local low = type(settings.cellEmpty) == "number" and settings.cellEmpty or 3.2
    local high = type(settings.cellFull) == "number" and settings.cellFull or 4.2
    if high <= low then
        return 0
    end

    local perCell = value
    if not rxBattery.isPerCell(settings) then
        if type(cells) ~= "number" or cells < 1 then
            return 0
        end
        perCell = value / cells
    end

    return primitives.fraction(perCell, low, high)
end

--- Wordings for the cell-count row, which is where a shape problem is named.
---
--- "N/A" is the right badge for a source that answered with something this
--- panel cannot read, and it is not enough on its own. What the row adds
--- is **what the pilot should do about it**:
---
--- - `NO CELLS` -- nothing has arrived and may yet. The source answered with
---   an empty table, which is what a pack that has not been detected looks
---   like. Wait.
--- - `CELLS ERR` -- unusable cells or a malformed source. Fix configuration.
--- - `VOLT ERR` -- a numeric source supplied unusable pack voltage/count.
---@param summary table
---@param settings AeroGridRxBatterySettings
---@return string[]
function rxBattery.countVariants(summary, settings)
    local shape = summary.shape

    -- One wording, not a ladder. A form that fits the narrowest row fits every
    -- row, so a longer one would only ever be drawn where the short one was
    -- also correct.
    if shape == "number" or shape == "invalid" then
        if summary.numeric then
            return { "VOLT ERR" }
        end
        return { "CELLS ERR" }
    end
    if shape == "empty" then
        return { "NO CELLS" }
    end
    if (shape ~= "cells" and shape ~= "pack") or summary.count == 0 then
        return { "" }
    end
    if not settings.showCount then
        return { "" }
    end

    local count = tostring(summary.count) .. "S"
    if summary.estimated then
        return { count .. " EST", count .. "~", count }
    end
    return { count }
end

function rxBattery.deltaVariants(summary, settings)
    if
        not settings.showDelta
        or summary.shape ~= "cells"
        or summary.rejected ~= 0
        or type(summary.spread) ~= "number"
    then
        return { "" }
    end
    -- EdgeTX's fonts map delta to U+0088, not the Unicode Greek block.
    return { string.format(CHAR_DELTA .. " %.2fv", summary.spread) }
end

--- Wordings for the pack-voltage row.
---@param summary table
---@param settings AeroGridRxBatterySettings
---@return string[]
function rxBattery.packVariants(summary, settings)
    if not settings.showPack or type(summary.pack) ~= "number" then
        return { "" }
    end

    if settings.reading == "pack" then
        if summary.count == nil or summary.count < 1 then
            return { "" }
        end
        local volts = string.format("%.2fV", summary.pack / summary.count)
        return { volts .. " AVG", volts }
    end

    local volts = string.format("%.1fV", summary.pack)
    return { volts .. " PACK", volts }
end

--- Check the configuration itself.
---
--- Span never makes a setting invalid here. Supporting details
--- are preferences: the panel draws them where they fit and quietly
--- drops them where they do not, and the battery visualization never draws
--- them at all.
---@param settings AeroGridRxBatterySettings
---@return string[] messages
function rxBattery.validateSettings(settings)
    local messages = {}
    local cells = settings.cells == nil and 0 or settings.cells
    if type(cells) ~= "number" or cells < 0 or cells > rxBattery.CELL_LIMIT or cells ~= math.floor(cells) then
        messages[#messages + 1] = "Pack series count must be 0 (auto) or an integer from 1 to 16."
    end
    local full = settings.cellFull == nil and 4.2 or settings.cellFull
    local warning = settings.cellWarning == nil and 3.6 or settings.cellWarning
    local critical = settings.cellCritical == nil and 3.4 or settings.cellCritical
    local empty = settings.cellEmpty == nil and 3.2 or settings.cellEmpty
    local levels = { full, warning, critical, empty }
    local finiteLevels = true
    for index = 1, 4 do
        local value = levels[index]
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
            finiteLevels = false
            break
        end
    end
    if not finiteLevels then
        messages[#messages + 1] = "Voltage levels must be finite numbers."
    elseif not (full > warning and warning >= critical and critical >= empty) then
        messages[#messages + 1] = "Voltage levels must be ordered Full > Warning >= Critical >= Empty."
    end
    return messages
end

--- Describe how the panel presents itself at a given span.
---@return table
function rxBattery.presentationFor()
    -- Measured geometry decides what fits, including after an editor resize.
    return { showVisual = true, showDetail = true }
end

--- The form a supporting wording is fitted by: its shortest variant, with
--- every digit widened to `8`.
---
--- Measuring digits as the widest one keeps the arrangement steady while the
--- voltage moves; it is only revisited when the wording's shape changes, such
--- as a pack crossing ten volts or a count turning into an error.
---@param variants string[]
---@return string
function rxBattery.measureForm(variants)
    return (string.gsub(variants[#variants] or "", "%d", "8"))
end

--- Compute the content regions for the current rectangle.
---
--- **Supporting details are preferences, shed quietly.** The battery glyph
--- never carries them. A bar or text-only panel prioritizes count, delta,
--- then secondary reading. Try footer and side placements before shedding
--- each priority tier; unavailable details reserve no slot. The measured
--- forms describe what the panel currently has to say.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@param sample table Widest digits this panel prints, and its unit.
---@return table
function rxBattery.regionsFor(theme, themeBuilder, rect, layout, fonts, sample, out, primitives)
    local frame = themeBuilder.frame(theme, rect, fonts)
    local glyphHeight
    local compact
    if layout.visual == "battery" then
        compact = function(_, half, ladder)
            local width
            width, glyphHeight = primitives.batterySize(half, ladder.room)
            return width or 0
        end
    end
    local spec = {
        -- Built through this panel's own builder, which the host may have
        -- wrapped to lay the panel out around the menu button's corner.
        frame = frame,
        forms = { sample.digits },
        unit = sample.unit,
        draws = {
            rows = false,
            visual = layout.showVisual == true and layout.visual ~= "none",
        },
        bar = layout.visual == "bar",
        compact = compact,
        equalGaps = layout.visual == "battery",
        minimumGapFraction = 0.3,
        rowItems = 1,
    }
    out = out or {}

    local forms = { layout.countForm or "", layout.deltaForm or "", layout.packForm or "" }
    local keys = { "count", "delta", "pack" }
    local requested = {}
    for index, form in ipairs(forms) do
        if form ~= "" then
            requested[#requested + 1] = { key = keys[index], form = form }
        end
    end
    local area
    local shown = 0
    local selected = {}
    if layout.visual ~= "battery" and layout.showDetail == true and #requested > 0 then
        local supporting = {}
        spec.draws.rows = true
        spec.supporting = supporting
        -- Highest-priority presence wins. If delta cannot fit at all, a
        -- shorter secondary may still share the count's remaining space.
        for mask = 2 ^ #requested - 1, 1, -1 do
            selected = {}
            for index, item in ipairs(requested) do
                if math.floor(mask / 2 ^ (#requested - index)) % 2 == 1 then
                    selected[#selected + 1] = item
                end
            end
            local items = #selected
            for index = 1, 3 do
                supporting[index] = index <= items and selected[index].form or nil
            end
            spec.rowItems = items
            area = themeBuilder.panel(theme, rect, fonts, spec, out)
            if area.supportingPlacement ~= "hidden" then
                shown = items
            end
            if shown > 0 then
                break
            end
        end
        if shown == 0 then
            spec.draws.rows, spec.supporting, spec.rowItems = false, nil, 1
            area = nil
        end
    end
    area = area or themeBuilder.panel(theme, rect, fonts, spec, out)
    local prefixes = { "detail", "rowRight", "rowThird" }
    for _, key in ipairs(keys) do
        area[key .. "Shown"] = false
        area[key .. "Slot"] = nil
    end
    for index = 1, shown do
        local key = selected[index].key
        local prefix = prefixes[index]
        area[key .. "Shown"] = true
        area[key .. "Slot"] = {
            x = area[prefix .. "X"],
            y = area[prefix .. "Y"],
            w = area[prefix .. "Width"],
            centre = area[prefix .. "Centre"],
        }
    end
    if area.packShown then
        local slot = area.packSlot
        area.rowRightCentre, area.rowRightWidth = slot.centre, slot.w
        area.rowRightX, area.rowRightY = slot.x, slot.y
    end
    if area.visualSize then
        area.glyphWidth = area.visualSize
        area.glyphHeight = glyphHeight
        area.glyphX = themeBuilder.slotX(area.visualCentreX, area.glyphWidth)
        area.glyphY = area.valueY
            + math.floor(themeBuilder.numberInkCentre(area.value, sample.digits) - glyphHeight / 2 + 0.5)
    end
    return area
end

--- Record the measured forms of what the supporting row has to say.
---@param context AeroGridRxBatteryContext
---@return boolean changed Whether the arrangement must be recomputed.
function rxBattery.measureSupporting(context)
    local layout = context.layout
    if not layout.adaptive then
        return false
    end
    rxBattery.gather(context)
    context.gathered = true
    local count = rxBattery.measureForm(rxBattery.countVariants(context.summary, context.settings))
    local pack = rxBattery.measureForm(rxBattery.packVariants(context.summary, context.settings))
    local delta = rxBattery.measureForm(rxBattery.deltaVariants(context.summary, context.settings))
    if layout.countForm == count and layout.packForm == pack and layout.deltaForm == delta then
        return false
    end
    layout.countForm, layout.packForm, layout.deltaForm = count, pack, delta
    return true
end

--- The longest wording that fits, or nothing where none does.
local function fitOrDrop(context, variants, width)
    local themeBuilder = context.themeBuilder
    local font = context.fonts.label
    local text = themeBuilder.fitLabel(variants, font, width)
    if type(width) ~= "number" or themeBuilder.measureText(font, text) > width then
        return ""
    end
    return text
end

--- Build the panel's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridRxBatterySettings
---@param services table
---@return AeroGridRxBatteryContext
function rxBattery.create(parent, rect, settings, services)
    local theme = services.theme
    local primitives = services.primitives
    local fonts = services.fonts
    local layout = rxBattery.presentationFor()
    layout.visual = settings.visual
    -- The glyph alone: it never carries the count or alternate reading.
    layout.adaptive = settings.visual ~= "battery" and layout.showDetail
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
        countText = "",
        packText = "",
        deltaText = "",
        -- Reused so a refresh allocates nothing; the host pays this per frame.
        summary = {},
        rect = rect,
    }

    -- Subscribing in create is the mechanism: a source nothing references is
    -- never read.
    local telemetry = services.telemetry
    if telemetry then
        context.feed = telemetry:subscribe(settings.source)
    end

    -- The widest number this panel can print, taken from what it reads
    -- rather than from whatever is showing now, so the reading does not resize
    -- as the pack drains. The two decimals are not negotiable: cells are
    -- compared against each other, and 3.8 V hides a difference that matters
    -- where 3.82 V does not. The unit rides beside the number rather than
    -- being part of it.
    local sample = {
        digits = rxBattery.isPerCell(settings) and "4.44" or "88.88",
        unit = "V",
    }
    context.sample = sample

    rxBattery.measureSupporting(context)
    local area = rxBattery.regionsFor(theme, services.themeBuilder, rect, layout, fonts, sample, nil, primitives)
    context.showDetail = area.countShown or area.deltaShown or area.packShown
    context.detailWidth = area.detailWidth

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

    -- LVGL userdata cannot report its text; keep it for reading/unit placement.
    context.unitText = sample.unit
    context.value, context.unit = primitives.reading(panel.root, theme, area, presentation, sample.unit)

    context.countLabel = primitives.label(panel.root, theme, {
        x = area.detailX,
        y = area.detailY,
        w = area.detailWidth,
        text = "",
        color = theme.color.textFaint,
        font = fonts.label,
    })

    context.packLabel = primitives.label(panel.root, theme, {
        x = area.rowRightX or area.detailX,
        y = area.rowRightY or area.detailY,
        w = area.rowRightWidth or area.detailWidth,
        text = "",
        color = theme.color.textFaint,
        font = fonts.label,
    })
    context.deltaLabel = primitives.label(panel.root, theme, {
        x = area.deltaSlot and area.deltaSlot.x or area.detailX,
        y = area.deltaSlot and area.deltaSlot.y or area.detailY,
        w = area.deltaSlot and area.deltaSlot.w or area.detailWidth,
        text = "",
        color = theme.color.textFaint,
        font = fonts.label,
    })

    if layout.showVisual and settings.visual == "bar" then
        context.bar = primitives.bar(panel.root, theme, {
            x = area.pad,
            y = area.barY,
            w = area.content,
            fraction = 0,
            color = presentation.accent,
        })
    end
    if settings.visual == "battery" and area.visualSize then
        context.glyph = primitives.batteryGlyph(panel.root, theme, {
            x = area.glyphX,
            y = area.glyphY,
            w = area.glyphWidth,
            h = area.glyphHeight,
            fraction = 0,
            color = presentation.accent,
            border = primitives.batteryStroke(services.themeBuilder, area.value, area.glyphWidth),
        })
    end

    if not area.countShown then
        lvgl.hide(context.countLabel)
    end
    if not area.packShown then
        lvgl.hide(context.packLabel)
    end
    if not area.deltaShown then
        lvgl.hide(context.deltaLabel)
    end
    if not area.showUnit then
        lvgl.hide(context.unit)
    end
    context.showUnit = area.showUnit
    context.area = area
    -- What the panel currently shows, so a reflow that changes nothing about
    -- visibility does not tell every object again what it already is.
    context.showVisual = area.showVisual
    if context.bar and not area.showVisual then
        lvgl.hide(context.bar.track)
        lvgl.hide(context.bar.fill)
    end

    local _, drawn = primitives.changed(context, rxBattery.render)
    rxBattery.apply(context, drawn)
    return context
end

--- Read both subscriptions into the context, allocating nothing.
--- Kept separate from `apply` so a refresh can decide whether anything is
--- worth repainting without summarizing the cells table twice.
---@param context AeroGridRxBatteryContext
function rxBattery.gather(context)
    local settings = context.settings
    local feed = context.feed
    local raw = type(feed) == "table" and feed.available and feed.raw or nil
    local summary
    local stale = type(feed) == "table" and feed.stale == true
    if stale or raw == nil then
        context.reestimateOnFresh = true
    end
    if type(raw) == "number" then
        local cells = settings.cells or 0
        if cells == 0 then
            if not stale and (context.reestimateOnFresh or context.estimatedCells == nil) then
                context.estimatedCells = rxBattery.estimateCount(raw, settings.cellFull)
                context.reestimateOnFresh = nil
            end
            cells = context.estimatedCells
        end
        summary = rxBattery.summarizePack(raw, cells, context.summary)
        summary.numeric = true
        summary.estimated = (settings.cells or 0) == 0 and summary.shape == "pack"
    else
        summary = rxBattery.summarize(raw, context.summary)
        if type(raw) == "table" then
            context.estimatedCells = nil
            context.reestimateOnFresh = true
        end
    end
    context.primary = rxBattery.primaryValue(settings, summary)
    context.perCell = summary.lowest
    if summary.shape == "pack" then
        context.perCell = summary.pack / summary.count
    end

    context.stale = stale
end

--- Collect everything this panel draws.
---@param context AeroGridRxBatteryContext
---@param out table
function rxBattery.render(context, out)
    if context.gathered then
        context.gathered = nil
    else
        rxBattery.gather(context)
    end

    local settings = context.settings
    local summary = context.summary
    local value = context.primary
    local stale = context.stale == true

    out.state = rxBattery.resolveState(settings, value, context.perCell, stale)
    -- Two decimals: cells are compared against each other, and 3.8 V hides a
    -- difference that matters where 3.82 V does not.
    -- Digits alone. The `V` is its own label beside them, so there is no
    -- longer a shorter form of this string to measure and then not draw.
    out.text = type(value) == "number" and string.format("%.2f", value) or "--"
    out.fraction = rxBattery.fraction(settings, value, summary.count, context.primitives)
    out.value = value

    if context.showDetail then
        local area = context.area
        out.count = area.countShown and fitOrDrop(context, rxBattery.countVariants(summary, settings), area.countSlot.w)
            or ""
        out.pack = area.packShown and fitOrDrop(context, rxBattery.packVariants(summary, settings), area.rowRightWidth)
            or ""
        out.delta = area.deltaShown and fitOrDrop(context, rxBattery.deltaVariants(summary, settings), area.deltaSlot.w)
            or ""
    end
end

--- Centre the supporting labels that are shown.
local function centreSupporting(context, area)
    for _, key in ipairs({ "count", "delta", "pack" }) do
        local slot = area[key .. "Slot"]
        if slot then
            context.primitives.centreLabel(
                context,
                key .. "Anchor",
                context.themeBuilder,
                context[key .. "Label"],
                slot.centre,
                slot.y,
                context.fonts.label,
                context[key .. "Text"]
            )
        end
    end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridRxBatteryContext
---@param drawn table
function rxBattery.apply(context, drawn)
    local presentation = context.state(drawn.state, context.settings.accent)

    context.stateName = drawn.state
    context.reading = drawn.value
    context.fraction = drawn.fraction
    context.text = drawn.text
    context.countText = drawn.count or ""
    context.packText = drawn.pack or ""
    context.deltaText = drawn.delta or ""

    context.value:set({ text = drawn.text, color = presentation.value })
    -- The unit follows what the number says, so it stays attached to a short
    -- reading instead of holding station at the widest one's edge.
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
        context.countLabel:set({ text = context.countText })
        context.packLabel:set({ text = context.packText })
        context.deltaLabel:set({ text = context.deltaText })
        -- Keyed on what they say so a steady pack pays nothing.
        centreSupporting(context, context.area)
    end

    if context.bar then
        context.primitives.setBar(context.bar, drawn.fraction, presentation.accent)
    end
    if context.glyph then
        local shown = context.showVisual and type(drawn.value) == "number"
        local area = context.area
        local previousY = area.glyphY
        if shown then
            area.glyphY = area.valueY
                + math.floor(context.themeBuilder.numberInkCentre(area.value, drawn.text) - area.glyphHeight / 2 + 0.5)
            context.primitives.setBatteryGlyph(context.glyph, drawn.fraction, presentation.accent)
        end
        if shown ~= context.glyphShown or previousY ~= area.glyphY then
            context.primitives.reconcileBatteryGlyph(
                context.glyph,
                shown,
                area.glyphX,
                area.glyphY,
                area.glyphWidth,
                area.glyphHeight,
                drawn.fraction
            )
            context.glyphShown = shown
        end
    end
end

--- Advance the panel, repainting only when something drawn changed.
---@param context AeroGridRxBatteryContext
function rxBattery.refresh(context)
    if not context.feed and not context.lowestFeed then
        return
    end
    -- What the row has to say decides what fits, so a change in its shape
    -- rearranges the panel before it is painted.
    local reflowed = rxBattery.measureSupporting(context)
    if reflowed then
        rxBattery.update(context, context.rect, nil, true)
    end
    local changed, drawn = context.primitives.changed(context, rxBattery.render)
    if changed or reflowed then
        rxBattery.apply(context, drawn)
    end
end

--- Reposition after a zone change.
---@param context AeroGridRxBatteryContext
---@param rect AeroGridRect
function rxBattery.update(context, rect, _, detailsOnly)
    context.rect = rect
    local area = rxBattery.regionsFor(
        context.theme,
        context.themeBuilder,
        rect,
        context.layout,
        context.fonts,
        context.sample,
        nil,
        context.primitives
    )

    -- A telemetry wording change moves only the content. Rebuilding the
    -- unchanged header wastes the radio's shared callback budget.
    if not detailsOnly then
        context.primitives.resizeHeader(context, rect, area.frame, context.settings.label)
    end
    context.primitives.setFont(context.value, area.value)
    context.value:set({
        x = area.valueX,
        y = area.valueY,
        w = area.valueWidth,
    })

    context.primitives.reflowReading(context, context.themeBuilder, area, area.value, context.text, area.showUnit)
    -- Every anchor is about a slot and a font that have just moved.
    context.unitAnchor = nil
    context.countAnchor, context.packAnchor, context.deltaAnchor = nil, nil, nil
    context.area = area
    -- Nothing drawn is discarded: `render` refits the details against these
    -- slots, so a wording or visibility that must change is a changed value.
    context.showDetail = area.countShown or area.deltaShown or area.packShown
    context.detailWidth = area.detailWidth

    local reconcile = context.primitives.reconcile
    for _, key in ipairs({ "count", "delta", "pack" }) do
        local slot = area[key .. "Slot"]
        reconcile(context[key .. "Label"], area[key .. "Shown"], slot and { x = slot.x, y = slot.y, w = slot.w } or {})
    end
    if not detailsOnly then
        centreSupporting(context, area)
    end

    if not context.bar and context.settings.visual == "bar" and area.showVisual then
        context.bar = context.primitives.bar(context.panel.root, context.theme, {
            x = area.pad,
            y = area.barY,
            w = area.content,
            fraction = context.fraction,
            color = context.state(context.stateName, context.settings.accent).accent,
        })
    end
    if context.bar then
        context.primitives.reconcileBar(
            context.bar,
            area.showVisual,
            area.pad,
            area.barY,
            area.content,
            context.fraction,
            area.showVisual == context.showVisual
        )
    end
    context.showVisual = area.showVisual
    if context.settings.visual == "battery" then
        local fraction = context.fraction
        if area.visualSize and type(context.reading) == "number" then
            area.glyphY = area.valueY
                + math.floor(
                    context.themeBuilder.numberInkCentre(area.value, context.text) - area.glyphHeight / 2 + 0.5
                )
        end
        if not context.glyph and area.visualSize then
            context.glyph = context.primitives.batteryGlyph(context.panel.root, context.theme, {
                x = area.glyphX,
                y = area.glyphY,
                w = area.glyphWidth,
                h = area.glyphHeight,
                fraction = fraction,
                color = context.state(context.stateName, context.settings.accent).accent,
                border = context.primitives.batteryStroke(context.themeBuilder, area.value, area.glyphWidth),
            })
            context.glyphShown = nil
        end
        local shown = area.visualSize ~= nil and type(context.reading) == "number"
        context.primitives.reconcileBatteryGlyph(
            context.glyph,
            shown,
            area.glyphX,
            area.glyphY,
            area.glyphWidth,
            area.glyphHeight,
            fraction,
            shown == context.glyphShown
        )
        context.glyphShown = shown
    end
end

return rxBattery
