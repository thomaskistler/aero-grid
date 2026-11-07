-- SPDX-License-Identifier: GPL-2.0-only

local output = {
    id = "output",
    apiVersion = 1,
    supportedSpans = { "any" },
    refreshInterval = 10,
    settings = {
        { key = "label", label = "Label", type = "string", default = "CHANNEL OUTPUT" },
        { key = "firstChannel", label = "First channel", type = "number", default = 1, min = 1, max = 32, step = 1 },
        { key = "channelCount", label = "Channel count", type = "number", min = 1, max = 32, step = 1, empty = "Auto" },
        { key = "showNames", label = "Show channel names", type = "boolean", default = true },
        { key = "showTrim", label = "Show trim", type = "boolean", default = true },
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

output.decl = {
    class = "normal",
    first = "prepare",
    kinds = { steady = true },
    stages = {
        prepare = { fixed = 0, perUnit = 1840, maxUnits = 1 },
        render = { fixed = 0, perUnit = 3300, maxUnits = 1 },
        apply = { fixed = 460, perUnit = 430, maxUnits = 2 },
    },
}

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

local function applyCaptionLayout(context, names, prefixWidth, namedWidth)
    local area = context.area
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

local function captionSlice(context, limit)
    local area, builder = context.area, context.themeBuilder
    local work = context.captionWork
    if not work then
        work = { next = 1, names = {}, changed = context.layoutNames == nil, prefixWidth = 0, namedWidth = 0 }
        context.captionWork = work
    end
    local last = math.min(area.count, work.next + limit - 1)
    for index = work.next, last do
        local feed = context.rows[index].feed
        if context.settings.showNames ~= false and feed and not feed.nameReady then
            context.captionWork = nil
            return false
        end
        local name = context.settings.showNames ~= false and feed and feed.name or ""
        work.names[index] = name
        work.changed = work.changed or context.layoutNames[index] ~= name
        local prefix = "CH" .. (area.firstChannel + index - 1)
        local caption = name ~= "" and prefix .. ": " .. string.sub(name, 1, 3) or prefix
        work.prefixWidth = math.max(work.prefixWidth, builder.measureText(area.font, prefix))
        work.namedWidth = math.max(work.namedWidth, builder.measureText(area.font, caption))
    end
    work.next = last + 1
    if last < area.count then
        return false
    end
    context.captionWork = nil
    if work.changed then
        applyCaptionLayout(context, work.names, work.prefixWidth, work.namedWidth)
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
    local root = lvgl.box(context.rowsRoot, { x = 0, y = 0, w = 1, h = 1 })
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
    local placed = row.text == nil
    local text = available and percentText(fraction) or "--"
    if context.area.showValues and (placed or row.text ~= text) then
        local textWidth = builder.measureText(context.area.font, text)
        row.value:set({ text = text, x = context.area.frame.content - textWidth, w = textWidth })
    end
    if placed or row.available ~= available or row.fraction ~= fraction then
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
    end
    if placed or row.trimFraction ~= trimFraction then
        local pointer = row.x + position(row.width, trimFraction or 0)
        context.primitives.reconcile(row.trim, trimFraction ~= nil, {
            pts = { { pointer - 3, row.y - 5 }, { pointer + 3, row.y - 5 }, { pointer, row.y + 1 } },
        })
    end
    row.name, row.available = name, available
    row.text, row.fraction, row.trimFraction = text, fraction, trimFraction
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
        showRows = 0,
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
    context.rowsRoot = lvgl.box(context.panel.root, { x = 0, y = 0, w = rect.w, h = rect.h })
    lvgl.hide(context.rowsRoot)
    return context
end

function output.render(context, out)
    local names = context.captureNames
    out.state = "unavailable"
    out.captionsReady = context.showRows == context.area.count
    for index = 1, context.showRows do
        local feed = context.rows[index].feed
        local available = feed ~= nil and feed.available == true
        if context.settings.showNames ~= false and feed and not feed.nameReady then
            out.captionsReady = false
        end
        out["available" .. index] = available
        out["name" .. index] = names and names[index]
            or (context.settings.showNames ~= false and feed and feed.name or "")
        out["fraction" .. index] = available and feed.fraction or 0
        local trim = context.settings.showTrim ~= false and available and feed.trim
        out["trim" .. index] = trim and trim.available and trim.fraction or nil
        if available then
            out.state = "normal"
        end
    end
end

function output.apply(context, drawn, first, count)
    first = first or 1
    local last = math.min(context.showRows, first + (count or context.showRows) - 1)
    for index = first, last do
        paintRow(context, context.rows[index], index, drawn)
    end
    if last < context.showRows then
        return last + 1
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
    if not context.rowsShown and drawn.captionsReady then
        lvgl.show(context.rowsRoot)
        context.rowsShown = true
    end
end

local function prepare(context)
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
    if not captionSlice(context, 8) then
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
    return context.showRows == area.count
end

local function render(context, names)
    context.captureNames = names
    local changed, drawn = context.primitives.changed(context, output.render)
    context.captureNames = nil
    if changed then
        return drawn
    end
end

function output.cancelRefresh(context)
    if context.reflowWork then
        context.reflowWork = { invalidated = true }
        context.rendered = nil
    end
    if context.pendingDrawn then
        context.rendered = nil
    end
    context.pendingDrawn, context.applyRow, context.renderReady, context.captionWork = nil, nil, nil, nil
end

function output.stageOf(context)
    if context.pendingDrawn then
        return "apply", math.max(1, math.min(2, context.showRows - context.applyRow + 1))
    end
    if context.renderReady then
        return "render", 1
    end
    return "prepare", 1
end

--- Keep the render snapshot stable until every granted row has been painted.
--- Reflow invalidates it; a stale plan does no work and publishes the new stage.
function output.step(context, grant, stage)
    context.used = 0
    if stage ~= output.stageOf(context) then
        return nil, true
    end
    if stage == "prepare" then
        context.renderReady = prepare(context)
        context.used = 1
    elseif stage == "render" then
        context.pendingDrawn = render(context, context.layoutNames)
        context.renderReady = nil
        if context.pendingDrawn then
            context.applyRow = 1
        end
        context.used = 1
    else
        local nextRow = output.apply(context, context.pendingDrawn, context.applyRow, grant)
        context.used = math.min(grant, math.max(1, context.showRows - context.applyRow + 1))
        context.applyRow = nextRow
        if not nextRow then
            context.pendingDrawn = nil
        end
    end
    if context.pendingDrawn or context.renderReady or context.captionWork or context.showRows < context.area.count then
        return nil, true
    end
end

local function beginGeometry(context, rect, settings)
    context.settings = settings
    context.area = output.regionsFor(context, rect)
    context.rowsRoot:set({ w = rect.w, h = rect.h })
    lvgl.hide(context.rowsRoot)
    context.rowsShown = nil
    context.primitives.resizeHeader(context, rect, context.area.frame, settings.label)
    context.nextRow = 1
    context.layoutNames = nil
    context.showRows = 0
    context.stateName = nil
    context.rendered = nil
end

function output.update(context, rect, settings)
    output.cancelRefresh(context)
    beginGeometry(context, rect, settings)
    for _, row in ipairs(context.rows) do
        context.primitives.reconcile(row.root, false)
    end
end

function output.reflow(context, rect, settings, _, _, begin)
    if context.primitives.reflowStart(context, rect, begin) then
        output.cancelRefresh(context)
        beginGeometry(context, rect, settings or context.settings)
        context.reflowWork = { stage = "hide", index = 1 }
        return false
    end
    local work = context.reflowWork
    if not work then
        return true
    end
    if work.stage == "hide" then
        local last = math.min(#context.rows, work.index + 7)
        for index = work.index, last do
            context.primitives.reconcile(context.rows[index].root, false)
        end
        work.index = last + 1
        if last == #context.rows then
            work.stage, work.index = "subscribe", 1
        end
    elseif work.stage == "subscribe" then
        local index = work.index
        if index <= context.area.count then
            local row = context.rows[index] or createRow(context, index)
            local channel = context.area.firstChannel + index - 1
            if row.channel ~= channel then
                row.channel = channel
                row.feed = context.control and context.control:output(channel - 1)
            end
            work.index = index + 1
        else
            work.stage = "captions"
        end
    elseif work.stage == "captions" then
        if captionSlice(context, 8) then
            work.stage, work.index = "place", 1
        elseif not context.captionWork then
            -- Unready service names leave rows hidden, just like update().
            -- The normal prepare task resumes them after services can run.
            context.reflowWork = nil
            return true
        end
    elseif work.stage == "place" then
        if work.index <= context.area.count then
            placeRow(context, context.rows[work.index], work.index)
            context.showRows = work.index
            work.index = work.index + 1
            context.nextRow = work.index
        else
            work.stage = "render"
        end
    elseif work.stage == "render" then
        work.drawn = render(context, context.layoutNames)
        work.stage, work.index = "apply", 1
    else
        work.index = work.drawn and output.apply(context, work.drawn, work.index, 2)
        if not work.index then
            context.reflowWork = nil
            return true
        end
    end
    return false
end

output.reflowDecl = { callback = output.reflow, bound = 2230 }

return output
