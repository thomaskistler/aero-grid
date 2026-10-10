-- SPDX-License-Identifier: GPL-2.0-only

--- Fixed samples of the live host theme; never subscribes to telemetry.
local showcase = {
    id = "theme-showcase",
    apiVersion = 1,
    supportedSpans = { "4x4" },
    settings = {},
}

local TOKENS = {
    "canvas",
    "surface",
    "surfaceRaised",
    "border",
    "track",
    "text",
    "textMuted",
    "textFaint",
    "cyan",
    "blue",
    "green",
    "amber",
    "orange",
    "critical",
}
local STATES = { "normal", "active", "warning", "critical", "stale", "unavailable" }
local ACCENTS = { "cyan", "green", "amber", "orange" }

function showcase.create(parent, rect, settings, services)
    local theme, p, builder = services.theme, services.primitives, services.themeBuilder
    local context = {
        root = lvgl.box(parent, { x = rect.x, y = rect.y, w = rect.w, h = rect.h }),
        theme = theme,
        primitives = p,
        builder = builder,
        swatches = {},
        cards = {},
        bars = {},
        labels = {},
    }
    local function label(parentObject, text, color, font)
        return p.label(parentObject, theme, { x = 0, y = 0, w = 1, text = text, color = color, font = font })
    end
    local name = theme.mode == "modern" and "Modern Dark"
        or (theme.mode == "modern-light" and "Modern Light" or "Custom")
    context.title = label(context.root, "THEME: " .. name .. " / SAMPLE DATA", theme.color.text, SMLSIZE)
    context.palette = p.panel(context.root, { x = 0, y = 0, w = 1, h = 1 }, theme, services.state("normal"))
    for _, token in ipairs(TOKENS) do
        context.swatches[#context.swatches + 1] = {
            box = lvgl.rectangle(context.palette.root, {
                x = 0,
                y = 0,
                w = 1,
                h = 1,
                filled = true,
                color = theme.color[token],
            }),
            label = label(context.palette.root, token, theme.color.text, TINSIZE),
        }
    end
    context.typePanel = p.panel(context.root, { x = 0, y = 0, w = 1, h = 1 }, theme, services.state("normal"))
    for _, token in ipairs({ "text", "textMuted", "textFaint" }) do
        context.labels[#context.labels + 1] =
            label(context.typePanel.root, token .. "  123.4", theme.color[token], SMLSIZE)
    end
    context.raised = lvgl.rectangle(context.typePanel.root, {
        x = 0,
        y = 0,
        w = 1,
        h = 1,
        filled = true,
        rounded = theme.spacing.radius,
        color = theme.color.surfaceRaised,
    })
    context.raisedLabel = label(context.typePanel.root, "Raised", theme.color.text, TINSIZE)
    for _, accent in ipairs(ACCENTS) do
        context.bars[#context.bars + 1] = {
            label = label(context.typePanel.root, accent, theme.color[accent], TINSIZE),
            bar = p.bar(context.typePanel.root, theme, {
                x = 0,
                y = 0,
                w = 1,
                fraction = 0.65,
                color = theme.color[accent],
                marker = 0.8,
            }),
        }
    end
    context.dial = p.radial(context.typePanel.root, theme, {
        x = 0,
        y = 0,
        radius = 1,
        fraction = 0.72,
        color = theme.color.cyan,
    })
    for _, state in ipairs(STATES) do
        local presentation = services.state(state)
        local panel = p.panel(context.root, { x = 0, y = 0, w = 1, h = 1 }, theme, presentation)
        context.cards[#context.cards + 1] = {
            state = state,
            presentation = presentation,
            panel = panel,
            label = label(panel.root, string.upper(state), presentation.label, TINSIZE),
            value = p.value(panel.root, theme, {
                x = 0,
                y = 0,
                w = 1,
                text = state == "unavailable" and "--" or "72.4",
                color = presentation.value,
                font = MIDSIZE,
            }),
            badge = p.badge(panel.root, theme, {
                x = 0,
                y = 0,
                w = 1,
                text = presentation.badge or "",
                color = presentation.accent,
                font = TINSIZE,
            }),
            bar = p.bar(panel.root, theme, {
                x = 0,
                y = 0,
                w = 1,
                fraction = state == "unavailable" and 0 or 0.72,
                color = presentation.accent,
            }),
        }
    end
    showcase.update(context, rect)
    return context
end

function showcase.update(context, rect)
    local p, builder, theme = context.primitives, context.builder, context.theme
    local gap, pad = theme.spacing.gutter, theme.spacing.padding
    context.root:set({ x = rect.x, y = rect.y, w = rect.w, h = rect.h })
    local frame = builder.frame(theme, rect, { label = SMLSIZE, badge = SMLSIZE })
    local titleX = math.max(40, frame.labelX)
    context.title:set({ x = titleX, y = 0, w = rect.w - titleX })
    local top = math.max(builder.fontHeight(SMLSIZE) + gap, frame.reserved and frame.reserved.h or 0)
    local rowHeight = math.floor((rect.h - top - gap * 2) / 4)
    local upperHeight = math.max(rowHeight * 2, builder.fontHeight(TINSIZE) * 7 + pad)
    local leftWidth = math.floor((rect.w - gap) / 2)
    local rightWidth = rect.w - leftWidth - gap
    p.resizePanel(context.palette, { x = 0, y = top, w = leftWidth, h = upperHeight })
    p.resizePanel(context.typePanel, { x = leftWidth + gap, y = top, w = rightWidth, h = upperHeight })
    local swatchWidth = math.floor((leftWidth - pad * 2 - gap) / 2)
    local swatchHeight = math.floor((upperHeight - pad) / 7)
    for index, item in ipairs(context.swatches) do
        local x = pad + math.floor((index - 1) / 7) * (swatchWidth + gap)
        local y = math.floor(pad / 2) + ((index - 1) % 7) * swatchHeight
        item.box:set({ x = x, y = y + 2, w = 10, h = math.max(1, swatchHeight - 4) })
        item.label:set({ x = x + 14, y = y, w = swatchWidth - 14 })
    end
    local lineHeight = builder.fontHeight(SMLSIZE)
    for index, item in ipairs(context.labels) do
        item:set({ x = pad, y = 2 + (index - 1) * lineHeight, w = rightWidth - pad * 2 })
    end
    local visualTop = 2 + lineHeight * 3
    local radius = math.max(1, math.floor((upperHeight - visualTop - pad) / 2))
    local dialX = rightWidth - pad - radius
    p.placeRadial(context.dial, dialX, visualTop + radius, radius)
    local barWidth = math.max(1, dialX - radius - pad * 2)
    local visualStep = math.floor((upperHeight - visualTop - 2) / 4)
    for index, item in ipairs(context.bars) do
        local y = visualTop + (index - 1) * visualStep
        item.label:set({ x = pad, y = y - 2, w = 42 })
        p.placeBar(item.bar, pad + 44, y + 4, math.max(1, barWidth - 44), 0.65)
    end
    context.raised:set({ x = dialX - radius, y = 3, w = radius * 2, h = lineHeight })
    context.raisedLabel:set({ x = dialX - radius + 4, y = 3, w = radius * 2 - 8 })
    -- The raised sample sits on the text row only when there is room beside it.
    local raisedFits = builder.measureText(SMLSIZE, "text  123.4") + pad * 2 < dialX - radius
    p.reconcile(context.raised, raisedFits)
    p.reconcile(context.raisedLabel, raisedFits)
    local cardsTop = top + upperHeight + gap
    local cardHeight = math.floor((rect.h - cardsTop - gap) / 2)
    for index, card in ipairs(context.cards) do
        local col, row = (index - 1) % 3, math.floor((index - 1) / 3)
        local available = rect.w - gap * 2
        local x = math.floor(col * available / 3) + col * gap
        local width = math.floor((col + 1) * available / 3) - math.floor(col * available / 3)
        p.resizePanel(card.panel, { x = x, y = cardsTop + row * (cardHeight + gap), w = width, h = cardHeight })
        local content = width - pad - theme.spacing.paddingRight
        local readingFont = cardHeight >= builder.fontHeight(TINSIZE) * 2 + builder.fontHeight(MIDSIZE) + 4 and MIDSIZE
            or SMLSIZE
        card.label:set({ x = pad, y = 0, w = content })
        p.setFont(card.value, readingFont)
        card.value:set({ x = pad, y = builder.fontHeight(TINSIZE) - 2, w = content })
        card.badge:set({ x = pad, y = cardHeight - builder.fontHeight(TINSIZE) - 6, w = content })
        p.placeBar(card.bar, pad, cardHeight - 6, content, card.state == "unavailable" and 0 or 0.72)
    end
end

return showcase
