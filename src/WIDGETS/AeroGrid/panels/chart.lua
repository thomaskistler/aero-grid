-- SPDX-License-Identifier: GPL-2.0-only

local chart = {
    id = "chart",
    apiVersion = 1,
    supportedSpans = { "2x1", "3x1", "4x1", "2x2", "3x2", "4x2", "3x3", "4x3", "4x4" },
    refreshInterval = 20,
    refreshCost = 6,
    settings = {
        { key = "label", label = "Label", type = "string", default = "" },
        {
            key = "metrics",
            label = "Metrics",
            itemLabel = "Metric",
            type = "table",
            minItems = 0,
            maxItems = 3,
            default = {},
            fields = {
                { key = "source", label = "Source", type = "string", required = true },
                { key = "label", label = "Label", type = "string" },
                { key = "unit", label = "Unit", type = "string" },
                {
                    key = "precision",
                    label = "Precision",
                    type = "number",
                    min = 0,
                    max = 3,
                    step = 1,
                    empty = "Sensor",
                },
                { key = "accent", label = "Color", type = "string", choices = { "cyan", "green", "orange", "amber" } },
                { key = "rangeMin", label = "Range min", type = "number", step = 0.1, default = 0 },
                { key = "rangeMax", label = "Range max", type = "number", step = 0.1, default = 100 },
            },
        },
        {
            key = "timeRange",
            label = "Time range",
            type = "string",
            default = "growing",
            choices = { "growing", "rolling" },
        },
        {
            key = "duration",
            label = "Initial / window duration",
            type = "string",
            default = "30s",
            choices = { "30s", "1m", "2m", "5m", "10m" },
            choiceLabels = { "30 seconds", "1 minute", "2 minutes", "5 minutes", "10 minutes" },
        },
        {
            key = "scaling",
            label = "Series scales",
            type = "string",
            default = "shared",
            choices = { "shared", "independent" },
        },
        { key = "range", label = "Value range", type = "string", default = "auto", choices = { "auto", "fixed" } },
        {
            key = "smoothing",
            label = "Line smoothing",
            type = "string",
            default = "off",
            choices = { "off", "light", "medium", "strong" },
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

local DURATIONS = { ["30s"] = 30, ["1m"] = 60, ["2m"] = 120, ["5m"] = 300, ["10m"] = 600 }
local COLORS = { "cyan", "green", "orange" }
local textCache = setmetatable({}, { __mode = "k" })

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function chart.validateSettings(settings)
    local warnings = {}
    if type(settings.metrics) ~= "table" then
        return { "metrics must contain a contiguous list of up to 3 sources" }
    end
    local count = 0
    for key, entry in pairs(settings.metrics) do
        count = count + 1
        local prefix = "metrics[" .. tostring(key) .. "]"
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 3 or type(entry) ~= "table" then
            warnings[#warnings + 1] = prefix .. " must be a source mapping at an index from 1 to 3"
        else
            for field, value in pairs(entry) do
                local valid
                if field == "source" or field == "label" or field == "unit" then
                    valid = type(value) == "string"
                elseif field == "precision" then
                    valid = finite(value) and value >= 0 and value <= 3 and value % 1 == 0
                elseif field == "rangeMin" or field == "rangeMax" then
                    valid = finite(value)
                elseif field == "accent" then
                    valid = value == "cyan" or value == "green" or value == "orange" or value == "amber"
                end
                if not valid then
                    warnings[#warnings + 1] = prefix .. "." .. tostring(field) .. " is invalid"
                end
            end
            if
                finite(entry.rangeMin or 0)
                and finite(entry.rangeMax or 100)
                and (entry.rangeMin or 0) >= (entry.rangeMax or 100)
            then
                warnings[#warnings + 1] = prefix .. ".rangeMax must be greater than rangeMin"
            end
        end
    end
    if count > 3 or #settings.metrics ~= count then
        warnings[#warnings + 1] = "metrics must contain a contiguous list of up to 3 sources"
    end
    return warnings
end

local function caption(entry)
    if entry.label and entry.label ~= "" then
        return entry.label
    end
    return entry.source and entry.source ~= "" and entry.source or "Metric"
end

local function heading(context)
    local label = context.settings.label
    if label and label ~= "" then
        return label
    end
    return #context.series == 1 and caption(context.series[1].settings) or "CHART"
end

function chart.format(value, precision)
    return finite(value) and string.format("%." .. math.min(3, math.max(0, precision or 0)) .. "f", value) or "--"
end

local function timeText(ticks)
    local seconds = math.floor(ticks / 100)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function text(object, value, color)
    local previous = textCache[object]
    if not previous or previous.value ~= value or previous.color ~= color then
        object:set({ text = value, color = color })
        previous = previous or {}
        previous.value, previous.color = value, color
        textCache[object] = previous
    end
end

local function label(context, color)
    return context.primitives.label(context.panel.root, context.theme, {
        x = 0,
        y = 0,
        w = 1,
        text = "",
        color = color,
        font = TINSIZE,
    })
end

function chart.geometry(context, rect)
    local builder = context.themeBuilder
    local fonts = { label = SMLSIZE, badge = TINSIZE }
    local frame = builder.frame(context.theme, rect, fonts)
    local content = frame.content
    local legend = math.min(context.legendWidth or 68, math.max(24, content - 28))
    local gap = 6
    local width = math.max(1, content - legend - gap)
    local top = frame.labelY + builder.fontHeight(SMLSIZE) + 2
    if frame.reserved and not frame.reserved.side then
        top = math.max(top, frame.reserved.h)
    end
    local bottom = math.max(top + 1, rect.h - builder.fontHeight(TINSIZE) - 3)
    local area = {
        frame = frame,
        x = frame.pad,
        y = top,
        w = width,
        h = math.max(1, bottom - top),
        legendX = frame.pad + width + gap,
        legendW = legend,
        axisY = math.max(0, rect.h - builder.fontHeight(TINSIZE)),
    }
    context.area = area
    local titleWidth = math.max(0, area.x + area.w - frame.labelX - 7)
    frame.labelWidth = titleWidth
    context.primitives.setHeading(
        context.title,
        builder,
        frame,
        fonts,
        heading(context),
        context.theme.color.text,
        { x = frame.labelX, y = frame.labelY }
    )
    context.axisStart:set({ x = area.x, y = area.axisY, w = math.floor(area.w / 2) })
    context.axisEnd:set({ x = area.x + math.floor(area.w / 2), y = area.axisY, w = math.ceil(area.w / 2) })
    context.endLabel = nil
    context.baseline:set({ x = area.x, y = area.y + area.h, w = area.w, h = 1 })
    context.status:set({ x = area.x, y = area.y, w = area.w })
    context.indicator:set({ x = area.x + area.w - 3, y = frame.labelY + 3, w = 3, h = 3 })
    local count = #context.series
    local lineHeight = builder.fontHeight(TINSIZE)
    local pairHeight = lineHeight + builder.fontAscent(TINSIZE)
    local showExtrema = rect.h >= count * pairHeight + 2
    context.showExtrema = showExtrema
    local step = math.min(
        showExtrema and pairHeight + 1 or lineHeight + 1,
        math.floor(math.max(1, rect.h - 2) / math.max(1, count))
    )
    local first = math.max(0, math.floor((rect.h - count * step) / 2))
    for index, item in ipairs(context.series) do
        local y = first + (index - 1) * step
        local valueWidth = math.min(legend, math.max(24, item.readoutWidth or 0))
        local nameWidth = math.max(0, legend - valueWidth - 3)
        local name = builder.fitHeading(caption(item.settings), nameWidth, TINSIZE, TINSIZE)
        item.name:set({ x = area.legendX, y = y, w = nameWidth, text = name })
        item.value:set({ x = area.legendX + legend - valueWidth, y = y, w = valueWidth })
        item.extrema:set({ x = area.legendX, y = y + lineHeight, w = legend })
        if showExtrema then
            lvgl.show(item.extrema)
        else
            lvgl.hide(item.extrema)
        end
        if nameWidth < 8 then
            lvgl.hide(item.name)
        else
            lvgl.show(item.name)
        end
    end
    context.version = context.version + 1
end

local function normalRange(low, high)
    if not finite(low) or not finite(high) then
        return 0, 1
    end
    local span = math.max(high - low, math.abs(high) * 0.02, 0.1)
    local step = 10 ^ math.floor(math.log(span) / math.log(10))
    return math.floor((low - span * 0.08) / step) * step, math.ceil((high + span * 0.08) / step) * step
end

function chart.ranges(context)
    local sharedLow, sharedHigh
    for _, item in ipairs(context.series) do
        local low, high
        if context.settings.range == "fixed" then
            low, high = item.settings.rangeMin or 0, item.settings.rangeMax or 100
        else
            low, high = normalRange(item.feed and item.feed.min, item.feed and item.feed.max)
        end
        item.low, item.high = low, high
        if context.settings.range == "fixed" or item.feed and item.feed.available then
            sharedLow = sharedLow and math.min(sharedLow, low) or low
            sharedHigh = sharedHigh and math.max(sharedHigh, high) or high
        end
    end
    if context.settings.scaling ~= "independent" then
        if context.settings.range == "fixed" and context.series[1] then
            sharedLow, sharedHigh = context.series[1].low, context.series[1].high
        end
        for _, item in ipairs(context.series) do
            item.low, item.high = sharedLow or 0, sharedHigh or 1
        end
    end
end

local function runFor(item, index)
    local run = item.runs[index]
    if not run then
        run = { pts = {}, pool = {}, size = 0, changes = {} }
        item.runs[index] = run
    end
    run.size, run.rawAt, run.rawValue = 0, nil, nil
    return run
end

local function addPoint(context, item, run, at, value)
    if run.rawAt == at and run.rawValue == value then
        return
    end
    run.rawAt, run.rawValue = at, value
    local area = context.area
    local finish = context.start + context.window
    if at < context.start or at > finish then
        return
    end
    local x = area.x + math.floor((at - context.start) / context.window * area.w + 0.5)
    local fraction = math.max(0, math.min(1, (value - item.low) / (item.high - item.low)))
    local y = area.y + math.floor((1 - fraction) * area.h + 0.5)
    local last = run.pts[run.size]
    if last and last[1] == x and last[2] == y then
        return
    end
    run.size = run.size + 1
    local point = run.pool[run.size] or {}
    run.pool[run.size], run.pts[run.size] = point, point
    point[1], point[2] = x, y
end

local function finishRun(run)
    if run.size == 1 then
        local first = run.pts[1]
        local second = run.pool[2] or {}
        second[1], second[2] = first[1], first[2]
        run.pool[2], run.pts[2], run.size = second, second, 2
    end
    for index = #run.pts, run.size + 1, -1 do
        run.pts[index] = nil
    end
end

local function prepare(context, item)
    local runIndex = 1
    local run = runFor(item, runIndex)
    run.boundary = nil
    local segment
    local feed = item.feed
    for index = 1, feed and feed.count or 0 do
        local point = context.history:point(feed, index)
        if point and point.lastAt >= context.start then
            if run.size > 0 and (point.breakBefore or point.segment ~= segment) then
                finishRun(run)
                runIndex = runIndex + 1
                run = runFor(item, runIndex)
                run.boundary = point.firstAt
            end
            segment = point.segment
            addPoint(context, item, run, point.firstAt, point.first)
            if point.lowAt <= point.highAt then
                addPoint(context, item, run, point.lowAt, point.low)
                addPoint(context, item, run, point.highAt, point.high)
            else
                addPoint(context, item, run, point.highAt, point.high)
                addPoint(context, item, run, point.lowAt, point.low)
            end
            addPoint(context, item, run, point.lastAt, point.last)
        end
    end
    finishRun(run)
    item.runCount, item.applyIndex = runIndex, 1
    item.drawnRevision = feed and feed.revision or 0
    item.drawnVersion, item.drawnLow, item.drawnHigh = context.version, item.low, item.high
end

local function applyRuns(context, item)
    local limit = math.min(math.max(item.runCount, #item.runs), item.applyIndex + 1)
    for index = item.applyIndex, limit do
        local run = item.runs[index]
        if index <= item.runCount and run.size >= 2 then
            if run.line then
                run.changes.pts, run.changes.color = run.pts, item.color
                run.line:set(run.changes)
                lvgl.show(run.line)
            else
                run.line = lvgl.line(context.panel.root, { pts = run.pts, color = item.color, thickness = 1 })
            end
            if run.boundary and run.boundary >= context.start then
                local x = context.area.x + math.floor((run.boundary - context.start) / context.window * context.area.w)
                local options = {
                    x = x,
                    y = context.area.y,
                    w = 1,
                    h = context.area.h,
                    color = context.theme.color.textFaint,
                    dashGap = 3,
                    dashWidth = 2,
                }
                if run.marker then
                    run.marker:set(options)
                else
                    run.marker = lvgl.vline(context.panel.root, options)
                end
                lvgl.show(run.marker)
            elseif run.marker then
                lvgl.hide(run.marker)
            end
        else
            if run.line then
                lvgl.hide(run.line)
            end
            if run.marker then
                lvgl.hide(run.marker)
            end
        end
    end
    item.applyIndex = limit + 1
    return item.applyIndex > math.max(item.runCount, #item.runs)
end

function chart.intervalFor(window, pixels, sources)
    local perPixel = math.max(20, math.min(100, math.floor(window / math.max(1, pixels))))
    return math.max(5, math.floor(perPixel / math.max(1, sources)))
end

function chart.render(context)
    local builder = context.themeBuilder
    local width = 64
    local reflow = false
    for _, item in ipairs(context.series) do
        local feed = item.feed
        local precision = item.settings.precision or feed and feed.precision or 0
        local unit = item.settings.unit
        if unit == nil then
            unit = feed and feed.unitText or ""
        end
        local value = chart.format(feed and feed.value, precision)
        item.readout = value .. (value ~= "--" and unit ~= "" and (" " .. unit) or "")
        local measured = builder.measureText(TINSIZE, item.readout)
        if measured > (item.readoutWidth or 0) then
            item.readoutWidth, reflow = measured, true
        end
        local extrema = context.showExtrema
                and ((CHAR_DOWN or string.char(193)) .. chart.format(feed and feed.min, precision) .. "  " .. (CHAR_UP or string.char(
                    192
                )) .. chart.format(feed and feed.max, precision))
            or ""
        width = math.max(
            width,
            builder.measureText(TINSIZE, extrema),
            builder.measureText(TINSIZE, item.readout)
                + math.min(30, builder.measureText(TINSIZE, caption(item.settings)))
                + 3
        )
        local color = feed and feed.stale and context.theme.color.textFaint or context.theme.color.text
        text(item.value, item.readout, color)
        if context.showExtrema then
            text(item.extrema, extrema, context.theme.color.textFaint)
        end
    end
    if width > (context.legendWidth or 0) or reflow then
        context.legendWidth = math.max(width, context.legendWidth or 0)
        chart.geometry(context, context.rect)
    end
end

function chart.refresh(context)
    local session = context.session
    local elapsed = session and session.elapsed or 0
    local window = (DURATIONS[context.settings.duration] or 30) * 100
    if context.settings.timeRange ~= "rolling" then
        while elapsed > window do
            window = window * 2
        end
    end
    local start = context.settings.timeRange == "rolling" and math.max(0, elapsed - window) or 0
    local pixelStart = math.floor(start / window * context.area.w)
    if context.window ~= window or context.pixelStart ~= pixelStart then
        context.window, context.start, context.pixelStart = window, start, pixelStart
        context.version = context.version + 1
    end
    local version = context.version
    chart.render(context)
    local reflowed = version ~= context.version
    chart.ranges(context)
    text(context.axisStart, timeText(context.start), context.theme.color.textFaint)
    local endLabel = timeText(context.start + window)
    if context.endLabel ~= endLabel then
        local width = math.min(context.area.w, context.themeBuilder.measureText(TINSIZE, endLabel))
        context.axisEnd:set({ x = context.area.x + context.area.w - width, w = width })
        context.endLabel = endLabel
    end
    text(context.axisEnd, endLabel, context.theme.color.textFaint)
    local status = ""
    if not context.history or context.history.failed then
        status = "HISTORY N/A"
    elseif not session.configured then
        status = "SET ARM SOURCE"
    elseif #context.series == 0 then
        status = "ADD METRICS"
    elseif not session.available then
        status = "ARM N/A"
    else
        local available = false
        for _, item in ipairs(context.series) do
            available = available or item.feed.available
        end
        if not available then
            status = session.recording and "NO DATA" or "WAITING FOR ARM"
        end
    end
    text(context.status, status, context.theme.color.textFaint)
    if session and session.recording then
        context.indicator:set({ color = context.theme.color.green })
    else
        context.indicator:set({ color = context.theme.color.track })
    end
    if status ~= "" then
        return 20
    end
    if reflowed then
        return 5
    end
    if context.pending then
        if applyRuns(context, context.pending) then
            context.pending = nil
        end
        return 5
    end
    for offset = 0, #context.series - 1 do
        local index = (context.cursor + offset - 1) % #context.series + 1
        local item = context.series[index]
        if
            item.drawnVersion ~= context.version
            or item.drawnRevision ~= item.feed.revision
            or item.drawnLow ~= item.low
            or item.drawnHigh ~= item.high
        then
            prepare(context, item)
            if not applyRuns(context, item) then
                context.pending = item
            end
            context.cursor = index % #context.series + 1
            break
        end
    end
    return context.pending and 5 or chart.intervalFor(window, context.area.w, #context.series)
end

function chart.create(parent, rect, settings, services)
    local warnings = chart.validateSettings(settings)
    assert(#warnings == 0, table.concat(warnings, "; "))
    local context = {
        theme = services.theme,
        themeBuilder = services.themeBuilder,
        primitives = services.primitives,
        settings = settings,
        history = services.history,
        series = {},
        version = 0,
        cursor = 1,
        rect = rect,
        area = {},
    }
    local presentation = services.state("normal", settings.accent or "cyan")
    context.panel = context.primitives.panel(parent, rect, context.theme, presentation)
    context.session = context.history and context.history:session(services.session and services.session.armSource)
    for index, entry in ipairs(settings.metrics) do
        local color = context.theme.color[entry.accent or COLORS[index]]
        local item = { settings = entry, color = color, runs = {} }
        if context.history then
            item.feed = context.history:subscribe(entry.source, {
                windowSeconds = DURATIONS[settings.duration] or 30,
                timeRange = settings.timeRange or "growing",
                smoothing = settings.smoothing or "off",
            })
        end
        item.name, item.value, item.extrema =
            label(context, color),
            label(context, context.theme.color.text),
            label(context, context.theme.color.textFaint)
        context.series[index] = item
    end
    context.title, context.axisStart, context.axisEnd, context.status =
        label(context), label(context), label(context), label(context)
    context.baseline =
        lvgl.hline(context.panel.root, { x = 0, y = 0, w = 1, h = 1, color = context.theme.color.border })
    context.indicator = lvgl.rectangle(
        context.panel.root,
        { x = 0, y = 0, w = 3, h = 3, color = context.theme.color.track, filled = true }
    )
    chart.geometry(context, rect)
    chart.refresh(context)
    return context
end

function chart.update(context, rect)
    context.rect = rect
    context.primitives.resizePanel(context.panel, rect)
    chart.geometry(context, rect)
    chart.refresh(context)
end

return chart
