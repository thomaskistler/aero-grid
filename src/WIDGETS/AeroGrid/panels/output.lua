-- SPDX-License-Identifier: GPL-2.0-only

local output = {
    id = "output",
    apiVersion = 1,
    supportedSpans = { "any" },
    refreshInterval = 10,
    settings = {
        { key = "showNames", label = "Show channel names", type = "boolean", default = true },
        { key = "showTrim", label = "Show trim", type = "boolean", default = true },
        { key = "firstChannel", label = "First channel", type = "number", default = 1, min = 1, max = 32, step = 1 },
        { key = "channelCount", label = "Channel count", type = "number", min = 1, max = 32, step = 1, empty = "Auto" },
        { key = "label", label = "Label", type = "string", default = "CHANNEL OUTPUT" },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "cyan",
            choices = { "cyan", "green", "amber", "orange" },
        },
    },
}

local GUTTER = 8

function output.validateSettings(settings)
    local errors = {}
    for _, key in ipairs({ "firstChannel", "channelCount" }) do
        local value = settings[key]
        if value ~= nil and (value ~= value or value < 1 or value > 32 or value ~= math.floor(value)) then
            errors[#errors + 1] = key .. " must be a whole number from 1 to 32"
            settings[key] = key == "firstChannel" and 1 or nil
        end
    end
    return errors
end

local function percentText(fraction)
    local percent = fraction * 100
    percent = percent < 0 and -math.floor(-percent + 0.5) or math.floor(percent + 0.5)
    return (percent > 0 and "+" or "") .. tostring(percent) .. "%"
end

function output.valueText(feed)
    return feed and feed.available and percentText(feed.fraction) or "--"
end

function output.regionsFor(context, rect)
    local builder = context.themeBuilder
    local settings = context.settings or {}
    local firstChannel = settings.firstChannel or 1
    local frame = builder.frame(context.theme, rect, context.fonts)
    -- This is a list, not a dominant reading: keep rows compact even on tall spans.
    local font = frame.content >= 190 and SMLSIZE or TINSIZE
    local height = builder.fontHeight(font)
    local showValues = frame.content >= 190
    local valueWidth = showValues
            and math.max(
                builder.measureText(font, "-100%"),
                builder.measureText(font, "+100%"),
                builder.measureText(font, "-150%"),
                builder.measureText(font, "+150%")
            )
        or 0
    local gutters = GUTTER + (showValues and GUTTER or 0)
    local stacked = frame.content < builder.measureText(font, "CH32") + valueWidth + 24 + gutters
    local pitch = stacked and height + 16 or math.max(20, height + 3)
    local top = math.max(frame.labelY + frame.labelHeight + 2, frame.reserved and frame.reserved.h or 0)
    local count = math.max(
        0,
        math.min(33 - firstChannel, settings.channelCount or 32, math.floor((rect.h - frame.bottom - top) / pitch))
    )
    local prefix = "CH" .. (firstChannel + math.max(1, count) - 1)
    local namedWidth = builder.measureText(font, prefix .. ": WWW")
    local showNames = settings.showNames ~= false
        and (stacked or frame.content - namedWidth - valueWidth - gutters >= 64)
    local captionWidth = stacked and frame.content - valueWidth - 4
        or (showNames and namedWidth or builder.measureText(font, prefix))
    local barX = stacked and frame.pad or frame.pad + captionWidth + GUTTER
    local barWidth = stacked and frame.content or frame.content - captionWidth - valueWidth - gutters
    return {
        frame = frame,
        font = font,
        top = top,
        pitch = pitch,
        count = barWidth >= 24 and captionWidth >= builder.measureText(font, "CH1") and count or 0,
        firstChannel = firstChannel,
        stacked = stacked,
        showNames = showNames,
        showValues = showValues,
        gutters = gutters,
        captionWidth = captionWidth,
        valueWidth = valueWidth,
        barX = barX,
        barWidth = barWidth,
    }
end

local function layoutCaptions(context)
    local area, builder = context.area, context.themeBuilder
    local names = context.layoutNames
    local changed = names == nil
    for index = 1, area.count do
        local feed = context.rows[index].feed
        if context.settings.showNames ~= false and feed and not feed.nameReady then
            return false
        end
        if names and names[index] ~= (context.settings.showNames ~= false and feed and feed.name or "") then
            changed = true
        end
    end
    if changed then
        names = names or {}
        local prefixWidth, namedWidth = 0, 0
        for index = 1, area.count do
            local feed = context.rows[index].feed
            local name = context.settings.showNames ~= false and feed and feed.name or ""
            names[index] = name
            local prefix = "CH" .. (area.firstChannel + index - 1)
            local caption = name ~= "" and prefix .. ": " .. string.sub(name, 1, 3) or prefix
            prefixWidth = math.max(prefixWidth, builder.measureText(area.font, prefix))
            namedWidth = math.max(namedWidth, builder.measureText(area.font, caption))
        end
        context.layoutNames = names
        if not area.stacked then
            local showNames = context.settings.showNames ~= false
                and area.frame.content - namedWidth - area.valueWidth - area.gutters >= 64
            local captionWidth = showNames and namedWidth or prefixWidth
            if captionWidth ~= area.captionWidth or showNames ~= area.showNames then
                area.showNames, area.captionWidth = showNames, captionWidth
                area.barX = area.frame.pad + captionWidth + GUTTER
                area.barWidth = area.frame.content - captionWidth - area.valueWidth - area.gutters
                context.nextRow = 1
                context.rendered = nil
            end
        end
    end
    return true
end

local function rectangle(parent, color, rounded)
    return lvgl.rectangle(parent, {
        x = 0,
        y = 0,
        w = 1,
        h = 1,
        color = color,
        filled = true,
        rounded = rounded or 0,
    })
end

local function createRow(context, index)
    local theme, primitives = context.theme, context.primitives
    local root = lvgl.box(context.panel.root, { x = 0, y = 0, w = 1, h = 1 })
    lvgl.hide(root)
    local row = { root = root, dots = {} }
    row.caption = primitives.label(root, theme, { x = 0, y = 0, text = "", font = context.area.font })
    row.value = primitives.label(root, theme, { x = 0, y = 0, text = "", font = context.area.font })
    row.track = rectangle(root, context.tapeColors.track)
    row.fill = rectangle(root, context.state("normal", context.settings.accent).accent, 2)
    row.fillOrigin = rectangle(root, context.state("normal", context.settings.accent).accent)
    for _, fraction in ipairs({ -0.5, 0.5 }) do
        row.dots[#row.dots + 1] = { object = rectangle(root, context.tapeColors.dot, 2), fraction = fraction }
    end
    row.zero = rectangle(root, context.tapeColors.zero)
    row.trim = lvgl.triangle(root, { pts = { { 0, 0 }, { 1, 0 }, { 0, 1 } }, color = theme.color.green })
    row.channel = context.area.firstChannel + index - 1
    row.feed = context.control and context.control:output(row.channel - 1)
    context.rows[index] = row
    return row
end

local function position(width, fraction)
    return math.floor((math.max(-1, math.min(1, fraction)) + 1) * (width - 1) / 2 + 0.5)
end

local function placeRow(context, row, index)
    local area, builder, primitives = context.area, context.themeBuilder, context.primitives
    local height = builder.fontHeight(area.font)
    row.root:set({
        x = area.frame.pad,
        y = area.top + (index - 1) * area.pitch,
        w = area.frame.content,
        h = area.pitch,
    })
    local textY = area.stacked and 0 or math.floor((area.pitch - height) / 2)
    primitives.setFont(row.caption, area.font)
    primitives.setFont(row.value, area.font)
    row.caption:set({ x = 0, y = textY, w = area.captionWidth })
    row.value:set({ x = area.frame.content - area.valueWidth, y = textY, w = area.valueWidth })
    primitives.reconcile(row.value, area.showValues)
    local x, y, width = area.barX - area.frame.pad, area.stacked and height + 8 or 8, area.barWidth
    local barHeight = area.stacked and 4 or math.max(4, area.pitch - 12)
    row.track:set({ x = x, y = y, w = width, h = barHeight })
    for _, dot in ipairs(row.dots) do
        dot.object:set({
            x = x + position(width, dot.fraction) - 1,
            y = y + math.floor(barHeight / 2) - 1,
            w = 3,
            h = 3,
        })
    end
    row.zero:set({ x = x + position(width, 0), y = y - 2, w = 2, h = barHeight + 4 })
    row.x, row.y, row.width, row.height = x, y, width, barHeight
    row.text = nil
    lvgl.show(row.root)
end

local function paintRow(context, row, index, drawn)
    local builder = context.themeBuilder
    local available = drawn["available" .. index]
    local name = drawn["name" .. index]
    local fraction = drawn["fraction" .. index]
    local trimFraction = drawn["trim" .. index]
    if row.text == nil or row.name ~= name or row.captionsReady ~= drawn.captionsReady then
        local prefix = "CH" .. row.channel
        local caption = context.area.showNames and name ~= "" and prefix .. ": " .. string.sub(name, 1, 3) or prefix
        if builder.measureText(context.area.font, caption) > context.area.captionWidth then
            caption = prefix
        end
        if not drawn.captionsReady then
            caption = ""
        end
        row.captionsReady, row.captionText = drawn.captionsReady, caption
        if row.drawnCaption ~= caption then
            row.drawnCaption = caption
            row.caption:set({ text = caption })
        end
    end
    if
        row.text ~= nil
        and row.name == name
        and row.available == available
        and row.fraction == fraction
        and row.trimFraction == trimFraction
    then
        return
    end
    row.name, row.available = name, available
    local text = available and percentText(fraction) or "--"
    row.text, row.fraction, row.trimFraction = text, fraction, trimFraction
    if context.area.showValues then
        local textWidth = builder.measureText(context.area.font, text)
        row.value:set({ text = text, x = context.area.frame.content - textWidth, w = textWidth })
    end
    local zero, endpoint = position(row.width, 0), position(row.width, fraction)
    local fillWidth = math.max(1, math.abs(endpoint - zero))
    local accent = context.state("normal", context.settings.accent).accent
    context.primitives.reconcile(row.fill, available, {
        x = row.x + math.min(zero, endpoint),
        y = row.y,
        w = fillWidth,
        h = row.height,
        color = accent,
    })
    -- Cover only the inner corners, keeping the moving tip rounded.
    local originWidth = math.min(2, fillWidth)
    context.primitives.reconcile(row.fillOrigin, available, {
        x = row.x + zero - (endpoint < zero and originWidth or 0),
        y = row.y,
        w = originWidth,
        h = row.height,
        color = accent,
    })
    local pointer = row.x + position(row.width, trimFraction or 0)
    context.primitives.reconcile(row.trim, trimFraction ~= nil, {
        pts = { { pointer - 3, row.y - 5 }, { pointer + 3, row.y - 5 }, { pointer, row.y + 1 } },
    })
end

function output.create(parent, rect, settings, services)
    local context = {
        theme = services.theme,
        themeBuilder = services.themeBuilder,
        primitives = services.primitives,
        state = services.state,
        fonts = services.fonts,
        control = services.control,
        settings = settings,
        rows = {},
    }
    local builder, surface = context.themeBuilder, context.theme.rgb.surface
    local light = builder.contrast(surface, 0x000000) > builder.contrast(surface, 0xFFFFFF)
    context.tapeColors = {
        track = lcd.RGB(builder.shade(surface, light and -0.08 or 0.08)),
        dot = lcd.RGB(builder.shade(surface, light and -0.12 or 0.20)),
        zero = lcd.RGB(builder.shade(surface, light and -0.35 or 0.35)),
    }
    context.area = output.regionsFor(context, rect)
    context.panel, context.label, context.badge = services.primitives.panelWithHeader(
        parent,
        rect,
        context.theme,
        context.state("normal", settings.accent),
        context.area.frame,
        context.fonts,
        settings.label,
        context.themeBuilder
    )
    output.refresh(context)
    return context
end

function output.render(context, out)
    out.state = "unavailable"
    out.captionsReady = context.showRows == context.area.count
    for index = 1, context.showRows do
        local feed = context.rows[index].feed
        local available = feed ~= nil and feed.available == true
        if context.settings.showNames ~= false and feed and not feed.nameReady then
            out.captionsReady = false
        end
        out["available" .. index] = available
        out["name" .. index] = context.settings.showNames ~= false and feed and feed.name or ""
        out["fraction" .. index] = available and feed.fraction or 0
        local trim = context.settings.showTrim ~= false and available and feed.trim
        out["trim" .. index] = trim and trim.available and trim.fraction or nil
        if available then
            out.state = "normal"
        end
    end
end

function output.apply(context, drawn)
    for index = 1, context.showRows do
        paintRow(context, context.rows[index], index, drawn)
    end
    local state = drawn.state
    if context.stateName ~= state then
        context.stateName = state
        local presentation = context.state(state, context.settings.accent)
        context.primitives.stylePanel(context.panel, presentation)
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
    end
end

function output.refresh(context)
    local area = context.area
    context.showRows = context.showRows or 0
    -- Subscribe before measuring captions, so no provisional column reaches the screen.
    if #context.rows < area.count then
        createRow(context, #context.rows + 1)
        return
    end
    for index = 1, area.count do
        local row = context.rows[index]
        local channel = area.firstChannel + index - 1
        if row.channel ~= channel then
            row.channel = channel
            row.feed = context.control and context.control:output(channel - 1)
        end
    end
    if not layoutCaptions(context) then
        return
    end
    -- Mount at most one new row per callback, keeping tall panels within the
    -- firmware instruction budget. Existing rows are reused through reflows.
    local pending = context.nextRow or 1
    if pending <= area.count then
        local row = context.rows[pending] or createRow(context, pending)
        placeRow(context, row, pending)
        context.nextRow = pending + 1
        context.rendered = nil
    end
    context.showRows = math.min((context.nextRow or 1) - 1, area.count)
    local changed, drawn = context.primitives.changed(context, output.render)
    if changed then
        output.apply(context, drawn)
    end
end

function output.update(context, rect, settings)
    context.settings = settings
    context.area = output.regionsFor(context, rect)
    context.primitives.resizeHeader(context, rect, context.area.frame, settings.label)
    for _, row in ipairs(context.rows) do
        context.primitives.reconcile(row.root, false)
    end
    context.nextRow = 1
    context.layoutNames = nil
    context.showRows = 0
    context.stateName = nil
    context.rendered = nil
    output.refresh(context)
end

return output
