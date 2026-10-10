-- SPDX-License-Identifier: GPL-2.0-only

local statePanel = {
    id = "state",
    apiVersion = 1,
    supportedSpans = { "1x1", "2x1", "3x1", "4x1", "1x2", "2x2", "3x2", "4x2" },
    refreshInterval = 20,
    settings = {
        {
            key = "entries",
            label = "Entries",
            type = "table",
            minItems = 1,
            maxItems = 3,
            fields = {
                { key = "label", label = "Label", type = "string", required = true },
                {
                    key = "states",
                    label = "States",
                    type = "table",
                    minItems = 1,
                    maxItems = 3,
                    fields = {
                        { key = "switch", label = "When", type = "string", required = true },
                        { key = "text", label = "Text", type = "string", required = true },
                        {
                            key = "background",
                            label = "Background",
                            type = "string",
                            default = "normal",
                            choices = { "normal", "active", "warning", "critical" },
                        },
                    },
                    itemDefault = { switch = "SA^", text = "UP" },
                },
            },
            default = {
                {
                    label = "SW1",
                    states = {
                        { switch = "SA^", text = "UP" },
                        { switch = "SA-", text = "MID" },
                        { switch = "SAv", text = "DOWN" },
                    },
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

local function singleLine(value)
    return type(value) == "string" and value ~= "" and not string.find(value, "[\r\n]")
end

local function list(value)
    if type(value) ~= "table" then
        return false
    end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 3 then
            return false
        end
        count = count + 1
    end
    return count >= 1 and count <= 3 and #value == count
end

function statePanel.validateSettings(settings)
    local warnings = {}
    local entries = settings.entries
    if not list(entries) then
        return { "entries must contain a contiguous list of 1 to 3 entries" }
    end
    for key, entry in ipairs(entries) do
        local prefix = "entries[" .. key .. "]"
        if type(entry) ~= "table" then
            warnings[#warnings + 1] = prefix .. " must be a mapping"
        else
            if not singleLine(entry.label) then
                warnings[#warnings + 1] = prefix .. ".label must be a nonempty single-line string"
            end
            for field in pairs(entry) do
                if field ~= "label" and field ~= "states" then
                    warnings[#warnings + 1] = prefix .. "." .. tostring(field) .. " is not a state setting"
                end
            end
            if not list(entry.states) then
                warnings[#warnings + 1] = prefix .. ".states must contain a contiguous list of 1 to 3 conditions"
            else
                for index, condition in ipairs(entry.states) do
                    local path = prefix .. ".states[" .. index .. "]"
                    if type(condition) ~= "table" then
                        warnings[#warnings + 1] = path .. " must be a mapping"
                    else
                        if not singleLine(condition.text) then
                            warnings[#warnings + 1] = path .. ".text must be a nonempty single-line string"
                        end
                        local switch = condition.switch
                        if
                            type(switch) ~= "string"
                            or not (string.match(switch, "^S[A-Z][%^v%-]$") or string.match(switch, "^L%d%d$"))
                        then
                            warnings[#warnings + 1] = path
                                .. ".switch must name a position such as SF^ or a logical switch such as L01"
                        end
                        local bg = condition.background
                        if bg ~= nil and bg ~= "normal" and bg ~= "active" and bg ~= "warning" and bg ~= "critical" then
                            warnings[#warnings + 1] = path .. ".background must be normal, active, warning, or critical"
                        end
                        for field in pairs(condition) do
                            if field ~= "switch" and field ~= "text" and field ~= "background" then
                                warnings[#warnings + 1] = path .. "." .. tostring(field) .. " is not a state setting"
                            end
                        end
                    end
                end
            end
        end
    end
    return warnings
end

function statePanel.reading(entry, feeds)
    for index, condition in ipairs(entry.states) do
        local feed = feeds and feeds[index]
        if not feed or not feed.known or not feed.available or not feed.fresh then
            return "--", "unavailable", "normal"
        end
        if feed.value then
            return condition.text, "normal", condition.background or "normal"
        end
    end
    return "UNMAPPED", "unavailable", "normal"
end

local function widest(builder, font, entry, supporting)
    local prefix = supporting and (entry.label .. " ") or ""
    local sample = prefix .. "--"
    local width = builder.measureText(font, sample)
    for _, condition in ipairs(entry.states) do
        local candidate = prefix .. condition.text
        local measured = builder.measureText(font, candidate)
        if measured > width then
            sample, width = candidate, measured
        end
    end
    return sample
end

function statePanel.regionsFor(context, rect)
    local builder, fonts = context.themeBuilder, context.fonts
    local entries = context.settings.entries
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

function statePanel.render(context, out)
    out.text, out.state, out.background = statePanel.reading(context.settings.entries[1], context.feeds[1])
    if
        out.state == "unavailable"
        and out.text == "UNMAPPED"
        and context.themeBuilder.measureText(context.area.value, out.text) > context.area.valueBudget
    then
        out.text = "?"
    end
    if not context.area.primaryFits then
        out.text, out.state, out.background = "NO FIT", "unavailable", "normal"
    end
    if out.state == "normal" then
        out.state = out.background
    end
    if context.showSupporting then
        for index = 2, #context.settings.entries do
            local entry = context.settings.entries[index]
            local value, state = statePanel.reading(entry, context.feeds[index])
            if state == "unavailable" and value == "UNMAPPED" then
                value = "?"
            end
            out["text" .. index] = entry.label .. " " .. value
            out["state" .. index] = state
        end
    end
end

function statePanel.apply(context, drawn)
    local primitives, builder, area = context.primitives, context.themeBuilder, context.area
    local presentation = context.state(drawn.state, context.settings.accent)
    if drawn.state == "warning" or drawn.state == "critical" then
        presentation.badge = nil
    end
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
    for index = 2, #context.settings.entries do
        local label = context.supporting[index]
        local value = drawn["text" .. index]
        if value then
            label:set({
                text = value,
                color = (drawn.state == "active" or drawn.state == "warning" or drawn.state == "critical")
                        and context.theme.color.text
                    or context.state(drawn["state" .. index], context.settings.accent).label,
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

function statePanel.create(parent, rect, settings, services)
    local warnings = statePanel.validateSettings(settings)
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
    for index, entry in ipairs(settings.entries) do
        context.feeds[index] = {}
        if services.control then
            for conditionIndex, condition in ipairs(entry.states) do
                context.feeds[index][conditionIndex] = services.control:switch(condition.switch)
            end
        end
    end
    local area = statePanel.regionsFor(context, rect)
    context.area = area
    context.showSupporting = area.showDetail or area.showSide
    local presentation = services.state("unavailable", settings.accent)
    local primitives = services.primitives
    context.panel, context.label, context.badge = primitives.panelWithHeader(
        parent,
        rect,
        services.theme,
        presentation,
        area.frame,
        services.fonts,
        settings.entries[1].label,
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
    for index = 2, #settings.entries do
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
    local _, drawn = primitives.changed(context, statePanel.render)
    statePanel.apply(context, drawn)
    return context
end

function statePanel.refresh(context)
    local changed, drawn = context.primitives.changed(context, statePanel.render)
    if changed then
        statePanel.apply(context, drawn)
    end
end

function statePanel.update(context, rect)
    local primitives = context.primitives
    local area = statePanel.regionsFor(context, rect)
    local previous = context.area
    context.area = area
    primitives.resizeHeader(context, rect, area.frame, context.settings.entries[1].label)
    primitives.setFont(context.value, area.value)
    context.value:set({ x = area.valueX, y = area.valueY, w = area.valueWidth })
    context.readingAnchor, context.readingUnitAnchor = nil, nil
    local visible = area.showDetail or area.showSide
    context.showSupporting = visible
    local settled = visible == (previous.showDetail or previous.showSide)
    for index = 2, #context.settings.entries do
        primitives.reconcile(context.supporting[index], visible, {}, settled)
        context["anchor" .. index] = nil
    end
    context.rendered = nil
    statePanel.refresh(context)
end

return statePanel
