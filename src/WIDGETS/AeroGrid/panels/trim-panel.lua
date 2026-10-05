-- SPDX-License-Identifier: GPL-2.0-only

--- Effective trim positions, inside a normal grid panel.
---
--- EdgeTX draws trims along the screen edges. This panel puts them where
--- the pilot is already looking, and reads them through selectable trim
--- sources so EdgeTX resolves flight-mode trim inheritance rather than
--- AeroGrid guessing at it. It is read-only: changing a trim remains the job
--- of the radio's own trim controls.
---
--- Two firmware behaviours shape everything here, and both are handled by
--- `controlService` rather than repeated in the presentation:
---
--- * A trim source returns eight times the stored trim, and EdgeTX clamps the
---   stored value to TRIM_MAX (128) or TRIM_EXTENDED_MAX (512). The real
---   spans are therefore 1024 and 4096, not 1000 and 4000, and the model's
---   extended-trim flag is not exposed to Lua at all. `auto` starts standard
---   and widens permanently once a value outside the standard range appears.
---
--- * A trim configured as a three-position toggle returns full deflection or
---   nothing, which is exactly what a standard trim parked at its end stop
---   returns. One sample can never distinguish them, so the service claims a
---   toggle only after seeing a centre and a full deflection with nothing in
---   between, and this panel labels that state rather than printing a
---   percentage that would be meaningless.
---
--- EdgeTX exposes no axis metadata for a trim source. The panel assigns the
--- configured trim1, trim2, and trim4 sources to aileron, elevator, and rudder.

---@class AeroGridTrimSettings
---@field trim1? string
---@field trim2? string
---@field trim4? string
---@field scale? "standard"|"extended"|"auto"
---@field readout? "percent"|"raw"|"none"
---@field label? string
---@field accent? string

---@class AeroGridTrimIndicator
---@field feed? AeroGridTrim
---@field name string
---@field vertical boolean
---@field bar table
---@field caption any
---@field value any

local trimPanel = {
    id = "trim-panel",
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
        "2x4",
        "3x4",
        "4x4",
    },
    -- A trim moves under the pilot's thumb, so it is refreshed at the same rate
    -- as a telemetry readout rather than at a status-panel rate.
    refreshInterval = 20,
    settings = {
        -- Source names are configurable; their positions are fixed by axis.
        { key = "trim1", label = "Trim 1", type = "string", default = "trim-ail" },
        { key = "trim2", label = "Trim 2", type = "string", default = "trim-ele" },
        { key = "trim4", label = "Trim 4", type = "string", default = "trim-rud" },
        {
            key = "scale",
            label = "Scale",
            type = "string",
            default = "auto",
            choices = { "auto", "standard", "extended" },
        },
        {
            key = "readout",
            label = "Readout",
            type = "string",
            default = "percent",
            choices = { "percent", "raw", "none" },
        },
        { key = "label", label = "Label", type = "string", default = "TRIM" },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "cyan",
            choices = { "cyan", "green", "amber", "orange" },
        },
    },
}

--- Thickness of a trim bar.
local BAR_THICKNESS = 6

--- Short caption for one indicator.
--- A trim source is named "trim-ail" and the panel has no room for that, so
--- the stem after the dash is used and the full name stays in the layout.
---@param name any
---@return string
function trimPanel.captionFor(name)
    if type(name) ~= "string" or name == "" then
        return "--"
    end

    local stem = string.match(name, "^trim%-(.+)$")
    return string.upper(stem or name)
end

--- Format one indicator's readout.
--- A three-position trim reports full deflection or nothing, so a percentage
--- would imply a precision it does not have; its position is named instead.
---@param settings AeroGridTrimSettings
---@param feed? AeroGridTrim
---@return string
function trimPanel.valueText(settings, feed)
    if settings.readout == "none" then
        return ""
    end
    if type(feed) ~= "table" or not feed.available then
        return "--"
    end

    if feed.threePosition then
        if feed.centered then
            return "3P MID"
        end
        return feed.raw > 0 and "3P HI" or "3P LO"
    end

    if feed.centered then
        return settings.readout == "raw" and "0" or "0%"
    end

    if settings.readout == "raw" then
        return (feed.value > 0 and "+" or "") .. tostring(feed.value)
    end

    local percent = feed.fraction * 100
    -- Round half away from zero. Adding a negative half and flooring rounds
    -- -23.4 to -24, which reads as more deflection than the trim actually has.
    if percent < 0 then
        percent = -math.floor(-percent + 0.5)
    else
        percent = math.floor(percent + 0.5)
    end
    return (percent > 0 and "+" or "") .. tostring(percent) .. "%"
end

--- Compute the fixed three-axis square and its readout geometry.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param fonts table
---@return table
function trimPanel.regionsFor(theme, themeBuilder, rect, fonts, settings)
    local frame = themeBuilder.frame(theme, rect, fonts)
    local labelHeight = frame.labelHeight
    local top = frame.top

    local available = math.max(1, rect.h - top - frame.bottom)
    local readoutFont = fonts.label
    if available < themeBuilder.fontHeight(readoutFont) * 3 then
        readoutFont = TINSIZE
    end
    local readoutHeight = themeBuilder.fontHeight(readoutFont)
    local readoutWidth = math.max(
        themeBuilder.measureText(readoutFont, "-100%"),
        themeBuilder.measureText(readoutFont, "3P MID"),
        themeBuilder.measureText(readoutFont, "-512")
    ) + math.max(
        themeBuilder.measureText(readoutFont, "A "),
        themeBuilder.measureText(readoutFont, "E "),
        themeBuilder.measureText(readoutFont, "R ")
    ) + 2
    local showValue = settings.readout ~= "none"
        and available >= readoutHeight * 3
        and frame.content >= readoutWidth + 8 + BAR_THICKNESS
    local reserved = showValue and readoutWidth + 4 or 0
    local verticalInset = showValue and math.max(0, math.ceil((readoutHeight - BAR_THICKNESS) / 2)) or 0
    local side = math.max(BAR_THICKNESS, math.min(frame.content - reserved, available - 2 * verticalInset))
    local left = frame.pad + math.floor((frame.content - reserved - side) / 2)
    top = top + math.floor((available - side) / 2)
    local width, height = side, side
    local cornerGap = math.min(BAR_THICKNESS + 2, math.floor((side - 2) / 2))
    local barLength = side - 2 * cornerGap
    local bottom = top + side - BAR_THICKNESS
    local textX = left + side - cornerGap + 4
    local textFits = math.floor(width / 3) >= themeBuilder.measureText(fonts.label, "3P MID") + 2
    return {
        frame = frame,
        squareLeft = left,
        squareSide = side,
        readoutGap = 4 - cornerGap,
        showCaption = height >= labelHeight * 3 + 8 and textFits,
        showValue = showValue,
        readoutFont = readoutFont,
        centreX = left + math.floor(side / 2),
        centreY = top + math.floor(side / 2),
        cells = {
            {
                x = left,
                y = top,
                textWidth = showValue and readoutWidth or math.floor(width / 2),
                captionY = top + BAR_THICKNESS + 2,
                valueY = top,
                valueX = textX,
                barX = left + cornerGap,
                barY = top,
                barWidth = barLength,
                barHeight = BAR_THICKNESS,
            },
            {
                x = left + BAR_THICKNESS + 2,
                y = top,
                textWidth = showValue and readoutWidth or math.floor(width / 3),
                captionY = top + math.floor(height / 2) - labelHeight - 2,
                valueY = top + math.floor((height - readoutHeight) / 2),
                valueX = textX,
                barX = left,
                barY = top + cornerGap,
                barWidth = BAR_THICKNESS,
                barHeight = barLength,
            },
            {
                x = left,
                y = bottom,
                textWidth = showValue and readoutWidth or math.floor(width / 2),
                captionY = bottom - labelHeight - 2,
                valueY = top + side - readoutHeight,
                valueX = textX,
                barX = left + cornerGap,
                barY = bottom,
                barWidth = barLength,
                barHeight = BAR_THICKNESS,
            },
        },
    }
end

--- Build the panel's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridTrimSettings
---@param services table
---@return table
function trimPanel.create(parent, rect, settings, services)
    local theme = services.theme
    local primitives = services.primitives
    local fonts = services.fonts
    local presentation = services.state("normal", settings.accent)
    local area = trimPanel.regionsFor(theme, services.themeBuilder, rect, fonts, settings)

    local context = {
        theme = theme,
        themeBuilder = services.themeBuilder,
        primitives = primitives,
        state = services.state,
        fonts = fonts,
        settings = settings,
        indicators = {},
        stateName = "normal",
        -- A shed readout is a reading nobody can check, so do not format it.
        showCaption = area.showCaption,
        showValue = area.showValue,
        -- The arrangement this panel was built against. Every other panel
        -- that draws a badge already held it; this one did not, because nothing
        -- it drew outside `create` and `update` needed the frame until the badge
        -- began being placed from its own measured text.
        area = area,
    }

    local panel = primitives.panel(parent, rect, theme, presentation)
    context.panel = panel

    context.label, context.badge =
        primitives.header(panel.root, theme, area.frame, fonts, settings.label, presentation, services.themeBuilder)

    local control = services.control
    local scale = settings.scale
    local names = { settings.trim1, settings.trim2, settings.trim4 }

    for index, name in ipairs(names) do
        local vertical = index == 2
        local cell = area.cells[index]

        local indicator = {
            name = type(name) == "string" and name or "",
            vertical = vertical,
            valueText = "",
        }

        -- Subscribing in create is what makes the control service read this trim
        -- at all; a trim nothing references is never polled.
        if control then
            indicator.feed = control:trim(indicator.name, scale)
        end

        indicator.caption = primitives.label(panel.root, theme, {
            x = cell.x,
            y = cell.captionY,
            w = cell.textWidth,
            text = area.showCaption and trimPanel.captionFor(indicator.name) or "",
            color = theme.color.textFaint,
            font = fonts.label,
        })

        indicator.bar = primitives.bipolarBar(panel.root, theme, {
            x = cell.barX,
            y = cell.barY,
            w = cell.barWidth,
            h = cell.barHeight,
            thickness = BAR_THICKNESS,
            vertical = vertical,
            fraction = 0,
            color = services.state("normal", "green").accent,
        })

        indicator.value = primitives.label(panel.root, theme, {
            x = cell.valueX or cell.x,
            y = cell.valueY,
            w = cell.textWidth,
            text = "",
            color = theme.color.textMuted,
            font = area.readoutFont or fonts.label,
        })

        if not area.showCaption then
            lvgl.hide(indicator.caption)
        end
        if not area.showValue then
            lvgl.hide(indicator.value)
        end

        context.indicators[index] = indicator
    end
    context.dot = lvgl.rectangle(panel.root, {
        x = area.centreX - 3,
        y = area.centreY - 3,
        w = 6,
        h = 6,
        rounded = 3,
        filled = true,
        color = lcd.RGB(0xFFFFFF),
    })

    local _, drawn = primitives.changed(context, trimPanel.render)
    trimPanel.apply(context, drawn)
    return context
end

--- Resolve the panel's state from its three trim sources.
--- An unreadable trim is reported by its own dashes; the panel only calls
--- itself unavailable when none of the axes can be read.
---@param context table
---@return string
function trimPanel.resolveState(context)
    for _, indicator in ipairs(context.indicators) do
        local feed = indicator.feed
        if type(feed) == "table" and feed.available then
            return "normal"
        end
    end
    return "unavailable"
end

--- Repaint every indicator from its current subscription.
---@param context table
--- Collect everything this panel draws.
---
--- One panel with several indicators, so the declaration is flat: each
--- indicator contributes its own keys. A nested table would compare by
--- identity and never differ.
---@param out table
function trimPanel.render(context, out)
    local settings = context.settings
    local showValue = context.showValue
    out.state = trimPanel.resolveState(context)

    for index, indicator in ipairs(context.indicators) do
        local feed = indicator.feed
        local available = type(feed) == "table" and feed.available == true
        -- A cell too narrow for text has no readout, so none is formatted. The
        -- key is absent rather than empty, which `changed` notices by counting.
        if showValue then
            local text = trimPanel.valueText(settings, feed)
            out["text" .. index] = text .. (index == 1 and " A" or (index == 2 and " E" or " R"))
        end
        out["fraction" .. index] = available and feed.fraction or 0
        out["available" .. index] = available
    end
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context table
---@param drawn table
function trimPanel.apply(context, drawn)
    local primitives = context.primitives
    local presentation = context.state(drawn.state, context.settings.accent)

    context.stateName = drawn.state
    context.label:set({ color = presentation.label })
    primitives.setBadge(
        context,
        context.themeBuilder,
        context.badge,
        context.area.frame,
        context.fonts.badge,
        presentation.badge or "",
        presentation.accent
    )
    primitives.stylePanel(context.panel, presentation)

    for index, indicator in ipairs(context.indicators) do
        -- An unreadable trim must not look like a centred one, so its bar is
        -- drawn in the faint token rather than the panel's accent.
        primitives.setBipolarBar(
            indicator.bar,
            drawn["fraction" .. index],
            drawn["available" .. index] and context.state("normal", "green").accent or context.theme.color.textFaint
        )

        if context.showValue then
            local text = drawn["text" .. index]
            indicator.valueText = text
            indicator.value:set({ text = text })
        end
    end
    trimPanel.centreAxes(context)
    trimPanel.placeDot(context, drawn["fraction1"], drawn["fraction2"], drawn["available1"] and drawn["available2"])
end

--- Center the square and fixed readout column without moving as values change.
function trimPanel.centreAxes(context)
    local area = context.area
    local width = context.showValue and area.cells[1].textWidth or 0
    local groupWidth = area.squareSide + (context.showValue and area.readoutGap + width or 0)
    local left = math.floor((context.panel.width - groupWidth) / 2)
    local offset = left - area.squareLeft
    if context.showValue then
        for index, indicator in ipairs(context.indicators) do
            local bar = area.cells[index]
            local centreY = bar.barY + bar.barHeight / 2
            local textWidth = context.themeBuilder.measureText(area.readoutFont, indicator.valueText)
            indicator.value:set({
                x = bar.valueX + offset + width - textWidth,
                y = math.floor(
                    centreY - context.themeBuilder.numberInkCentre(area.readoutFont, indicator.valueText) + 0.5
                ),
                w = math.max(1, textWidth),
            })
        end
    end
    if area.groupOffset == offset then
        return
    end
    area.groupOffset = offset
    area.centreX = left + math.floor(area.squareSide / 2)
    for index, indicator in ipairs(context.indicators) do
        local cell = area.cells[index]
        context.primitives.placeBipolarBar(
            indicator.bar,
            cell.barX + offset,
            cell.barY,
            cell.barWidth,
            cell.barHeight,
            indicator.feed and indicator.feed.fraction or 0
        )
        if context.showCaption then
            indicator.caption:set({ x = cell.x + offset })
        end
    end
end

--- Plot aileron/elevator at the same normalized positions as their bar endpoints.
function trimPanel.placeDot(context, aileron, elevator, available)
    local horizontal = context.indicators[1].bar
    local vertical = context.indicators[2].bar
    context.primitives.reconcile(context.dot, available == true, {
        x = context.area.centreX - 3 + math.floor(aileron * (horizontal.w - 6) / 2 + 0.5),
        y = context.area.centreY - 3 - math.floor(elevator * (vertical.h - 6) / 2 + 0.5),
    })
end

--- Advance the panel, repainting only when something drawn changed.
---@param context table
function trimPanel.refresh(context)
    local changed, drawn = context.primitives.changed(context, trimPanel.render)
    if changed then
        trimPanel.apply(context, drawn)
    end
end

--- Reposition the square and readouts after a zone change.
---@param context table
---@param rect AeroGridRect
function trimPanel.update(context, rect)
    local primitives = context.primitives
    local area = trimPanel.regionsFor(context.theme, context.themeBuilder, rect, context.fonts, context.settings)

    context.area = area
    context.dot:set({ x = area.centreX - 3, y = area.centreY - 3 })
    primitives.resizePanel(context.panel, rect)
    primitives.placeHeader(
        context.label,
        context.badge,
        area.frame,
        context.themeBuilder,
        context.fonts,
        context.settings.label,
        context.badgeText
    )

    local reconcile = primitives.reconcile
    local captionsChanged = area.showCaption ~= context.showCaption
    context.showCaption = area.showCaption

    local valuesChanged = area.showValue ~= context.showValue
    if valuesChanged then
        context.showValue = area.showValue
        if not area.showValue then
            -- Nothing reads a shed readout, and a stale one left behind reads like
            -- a value that is still being kept up to date.
            for _, indicator in ipairs(context.indicators) do
                indicator.valueText = ""
            end
        end
        -- Nothing is discarded here on purpose. Every other panel that sheds
        -- a row drops its last record so the next refresh repaints, because its
        -- row keeps being declared while hidden and the comparison would
        -- otherwise match. This panel stops declaring the readout at all, so the
        -- key count changes and `changed` sees the reveal by construction. The
        -- discard was written first and then removed when no test could be made
        -- to fail without it.
    end

    for index, indicator in ipairs(context.indicators) do
        local cell = area.cells[index]

        -- Eight rows here rather than one or two, so a row whose visibility has
        -- not moved is repositioned without being told again what it already is.
        reconcile(
            indicator.caption,
            area.showCaption,
            { x = cell.x, y = cell.captionY, w = cell.textWidth },
            not captionsChanged
        )
        primitives.setFont(indicator.value, area.readoutFont or context.fonts.label)
        reconcile(indicator.value, area.showValue, {
            x = cell.valueX or cell.x,
            y = cell.valueY,
            w = cell.textWidth,
        }, not valuesChanged)
        primitives.placeBipolarBar(
            indicator.bar,
            cell.barX,
            cell.barY,
            cell.barWidth,
            cell.barHeight,
            type(indicator.feed) == "table" and indicator.feed.fraction or 0
        )

        -- A caption is fixed text, so it is written once when the row appears
        -- rather than on every reflow that keeps it.
        if captionsChanged and area.showCaption then
            indicator.caption:set({ text = trimPanel.captionFor(indicator.name) })
        end
    end
    trimPanel.centreAxes(context)
    local aileron, elevator = context.indicators[1].feed, context.indicators[2].feed
    trimPanel.placeDot(
        context,
        aileron and aileron.fraction or 0,
        elevator and elevator.fraction or 0,
        aileron and elevator and aileron.available and elevator.available
    )
end

return trimPanel
