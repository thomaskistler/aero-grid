-- SPDX-License-Identifier: GPL-2.0-only

local text = {
    id = "text",
    apiVersion = 1,
    supportedSpans = { "1x1", "2x1", "3x1", "4x1", "1x2", "2x2", "3x2", "4x2" },
    refreshInterval = 20,
    settings = {
        {
            key = "texts",
            label = "Texts",
            type = "table",
            minItems = 1,
            maxItems = 3,
            default = {
                {
                    label = "SW1",
                    source = "sa",
                    positions = { up = "UP", middle = "MID", down = "DOWN" },
                },
            },
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

local POSITIONS = { [-1024] = "up", [0] = "middle", [1024] = "down" }

local function singleLine(value)
    return type(value) == "string" and value ~= "" and not string.find(value, "[\r\n]")
end

function text.validateSettings(settings)
    local warnings = {}
    local entries = settings.texts
    if type(entries) ~= "table" then
        return { "texts must contain a contiguous list of 1 to 3 entries" }
    end
    local count = 0
    for key, entry in pairs(entries) do
        count = count + 1
        local prefix = "texts[" .. tostring(key) .. "]"
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 3 then
            warnings[#warnings + 1] = prefix .. " must be an index from 1 to 3"
        elseif type(entry) ~= "table" then
            warnings[#warnings + 1] = prefix .. " must be a mapping"
        else
            if not singleLine(entry.label) then
                warnings[#warnings + 1] = prefix .. ".label must be a nonempty single-line string"
            end
            if type(entry.source) ~= "string" or not string.match(entry.source, "^s[a-z]$") then
                warnings[#warnings + 1] = prefix .. ".source must name a physical switch, such as sa or sb"
            end
            for field in pairs(entry) do
                if field ~= "label" and field ~= "source" and field ~= "positions" then
                    warnings[#warnings + 1] = prefix .. "." .. tostring(field) .. " is not a text setting"
                end
            end
            local positions = entry.positions
            if type(positions) ~= "table" then
                warnings[#warnings + 1] = prefix .. ".positions must map up and down, with optional middle"
            else
                for _, position in ipairs({ "up", "down" }) do
                    if not singleLine(positions[position]) then
                        warnings[#warnings + 1] = prefix
                            .. ".positions."
                            .. position
                            .. " must be a nonempty single-line string"
                    end
                end
                for position, value in pairs(positions) do
                    if position ~= "up" and position ~= "middle" and position ~= "down" then
                        warnings[#warnings + 1] = prefix .. ".positions." .. tostring(position) .. " is unknown"
                    elseif not singleLine(value) then
                        warnings[#warnings + 1] = prefix
                            .. ".positions."
                            .. position
                            .. " must be a nonempty single-line string"
                    end
                end
            end
        end
    end
    if count < 1 or count > 3 or #entries ~= count then
        warnings[#warnings + 1] = "texts must contain a contiguous list of 1 to 3 entries"
    end
    return warnings
end

function text.reading(entry, feed)
    -- Switches are radio-local: a zero is a real middle position even with no
    -- receiver. Never turn an absent, stale, or telemetry reading into a mode.
    if not feed or not feed.known or not feed.available or not feed.fresh or feed.telemetry then
        return "--", "unavailable"
    end
    local position = POSITIONS[feed.value]
    local value = position and entry.positions[position]
    if value == nil then
        return "UNMAPPED", "unavailable"
    end
    return value, "normal"
end

local function widest(builder, font, entry, supporting)
    local prefix = supporting and (entry.label .. " ") or ""
    local sample = prefix .. "--"
    local width = builder.measureText(font, sample)
    for _, value in pairs(entry.positions) do
        local candidate = prefix .. value
        local measured = builder.measureText(font, candidate)
        if measured > width then
            sample, width = candidate, measured
        end
    end
    return sample
end

function text.regionsFor(context, rect)
    local builder, fonts = context.themeBuilder, context.fonts
    local entries = context.settings.texts
    local supporting = entries[2] and { widest(builder, fonts.label, entries[2], true) } or nil
    if entries[3] then
        supporting[2] = widest(builder, fonts.label, entries[3], true)
    end
    local sample = widest(builder, fonts.primary, entries[1])
    local spec = {
        frame = builder.frame(context.theme, rect, fonts),
        forms = { sample },
        draws = { rows = supporting ~= nil, visual = false },
        rowItems = entries[3] and 2 or 1,
        supporting = supporting,
    }
    local area
    -- Proportional glyph widths can change order between fonts. Re-measure at
    -- the chosen font rather than treating character count as a width.
    for _ = 1, #builder.READING_FONTS + 1 do
        area = builder.panel(context.theme, rect, fonts, spec, {})
        sample = widest(builder, area.value, entries[1])
        if builder.measureText(area.value, sample) <= builder.measureText(area.value, spec.forms[1]) then
            break
        end
        spec.forms[1] = sample
    end
    area.primaryFits = builder.measureText(area.value, sample) <= area.valueBudget
    if not area.primaryFits then
        -- At the smallest font an arbitrarily long string may still not fit.
        -- Refuse it visibly; drawing a clipped mode could assert a different one.
        spec.forms[1] = "NO FIT"
        area = builder.panel(context.theme, rect, fonts, spec, {})
        area.primaryFits = false
    end
    return area
end

function text.render(context, out)
    out.text, out.state = text.reading(context.settings.texts[1], context.feeds[1])
    if
        out.state == "unavailable"
        and out.text == "UNMAPPED"
        and context.themeBuilder.measureText(context.area.value, out.text) > context.area.valueBudget
    then
        out.text = "?"
    end
    if not context.area.primaryFits then
        out.text, out.state = "NO FIT", "unavailable"
    end
    if context.showSupporting then
        for index = 2, #context.settings.texts do
            local entry = context.settings.texts[index]
            local value, state = text.reading(entry, context.feeds[index])
            if state == "unavailable" and value == "UNMAPPED" then
                value = "?"
            end
            out["text" .. index] = entry.label .. " " .. value
            out["state" .. index] = state
        end
    end
end

function text.apply(context, drawn)
    local primitives, builder, area = context.primitives, context.themeBuilder, context.area
    local presentation = context.state(drawn.state, context.settings.accent)
    context.text, context.stateName = drawn.text, drawn.state
    context.value:set({ text = drawn.text, color = presentation.value })
    primitives.centreReading(context, builder, area, area.value, drawn.text)
    context.label:set({ color = presentation.label })
    primitives.setBadge(
        context,
        builder,
        context.badge,
        area.frame,
        context.fonts.badge,
        presentation.badge or "",
        presentation.accent
    )
    primitives.stylePanel(context.panel, presentation)
    for index = 2, #context.settings.texts do
        local label = context.supporting[index]
        local value = drawn["text" .. index]
        if value then
            label:set({
                text = value,
                color = context.state(drawn["state" .. index], context.settings.accent).label,
            })
            primitives.centreLabel(
                context,
                "anchor" .. index,
                builder,
                label,
                index == 2 and area.detailCentre or area.rowRightCentre,
                index == 2 and area.detailY or area.rowRightY,
                context.fonts.label,
                value
            )
        end
    end
end

function text.create(parent, rect, settings, services)
    local warnings = text.validateSettings(settings)
    if #warnings > 0 then
        error(table.concat(warnings, "; "))
    end
    local context = {
        settings = settings,
        theme = services.theme,
        themeBuilder = services.themeBuilder,
        primitives = services.primitives,
        fonts = services.fonts,
        state = services.state,
        feeds = {},
        supporting = {},
    }
    for index, entry in ipairs(settings.texts) do
        if services.telemetry then
            context.feeds[index] = services.telemetry:subscribe(entry.source, false)
        end
    end
    local area = text.regionsFor(context, rect)
    context.area = area
    context.showSupporting = area.showDetail or area.showSide
    local presentation = services.state("unavailable", settings.accent)
    local primitives = services.primitives
    context.panel = primitives.panel(parent, rect, services.theme, presentation)
    context.label, context.badge = primitives.header(
        context.panel.root,
        services.theme,
        area.frame,
        services.fonts,
        settings.texts[1].label,
        presentation,
        services.themeBuilder
    )
    context.value = primitives.value(context.panel.root, services.theme, {
        x = area.valueX,
        y = area.valueY,
        w = area.valueWidth,
        text = "--",
        color = presentation.value,
        font = area.value,
    })
    for index = 2, #settings.texts do
        context.supporting[index] = primitives.label(context.panel.root, services.theme, {
            x = area.pad,
            y = area.detailY,
            w = area.content,
            text = "",
            color = services.theme.color.textMuted,
            font = services.fonts.label,
        })
        if not (area.showDetail or area.showSide) then
            lvgl.hide(context.supporting[index])
        end
    end
    local _, drawn = primitives.changed(context, text.render)
    text.apply(context, drawn)
    return context
end

function text.refresh(context)
    local changed, drawn = context.primitives.changed(context, text.render)
    if changed then
        text.apply(context, drawn)
    end
end

function text.update(context, rect)
    local primitives = context.primitives
    local area = text.regionsFor(context, rect)
    local previous = context.area
    context.area = area
    primitives.resizePanel(context.panel, rect)
    primitives.placeHeader(
        context.label,
        context.badge,
        area.frame,
        context.themeBuilder,
        context.fonts,
        context.settings.texts[1].label,
        context.badgeText
    )
    primitives.setFont(context.value, area.value)
    context.value:set({ x = area.valueX, y = area.valueY, w = area.valueWidth })
    context.readingAnchor, context.readingUnitAnchor = nil, nil
    local visible = area.showDetail or area.showSide
    context.showSupporting = visible
    local settled = visible == (previous.showDetail or previous.showSide)
    for index = 2, #context.settings.texts do
        primitives.reconcile(context.supporting[index], visible, {}, settled)
        context["anchor" .. index] = nil
    end
    context.rendered = nil
    text.refresh(context)
end

return text
