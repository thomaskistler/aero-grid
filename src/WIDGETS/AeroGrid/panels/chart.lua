-- SPDX-License-Identifier: GPL-2.0-only

local chart = {
    id = "chart",
    apiVersion = 1,
    supportedSpans = { "2x1", "3x1", "4x1", "2x2", "3x2", "4x2", "3x3", "4x3", "4x4" },
    refreshInterval = 20,
    refreshCost = 6,
    settings = {
        { key = "label", label = "Label", type = "string", default = "" },
        { key = "armSwitch", label = "Armed switch position", type = "string", default = "" },
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
                { key = "rangeMin", label = "Range min", type = "number", step = 0.1, empty = "Auto" },
                { key = "rangeMax", label = "Range max", type = "number", step = 0.1, empty = "Auto" },
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
            label = "Window duration",
            type = "string",
            default = "1m",
            choices = { "30s", "1m", "2m", "5m", "10m" },
            choiceLabels = { "30 seconds", "1 minute", "2 minutes", "5 minutes", "10 minutes" },
            visibleWhen = { key = "timeRange", value = "rolling" },
        },
        {
            key = "scaling",
            label = "Series scales",
            type = "string",
            default = "shared",
            choices = { "shared", "independent" },
        },
        {
            -- Accept earlier preview layouts without keeping the obsolete selector.
            key = "range",
            label = "Value range",
            type = "string",
            default = "auto",
            choices = { "auto", "fixed" },
            visibleWhen = function()
                return false
            end,
        },
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
local COLORS = { "cyan", "orange", "green" }
local LEGEND_FONTS = { MIDSIZE, 0, SMLSIZE }
local PROJECTION_CAP = 7
local textCache = setmetatable({}, { __mode = "k" })

local function timeWindow(settings, elapsed)
    if settings.timeRange == "rolling" then
        return (DURATIONS[settings.duration] or 60) * 100
    end
    return math.max(6000, math.ceil(elapsed / 6000) * 6000)
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function chart.validateSettings(settings)
    local warnings = {}
    local arm = settings.armSwitch
    if arm ~= nil and arm ~= "" then
        if type(arm) ~= "string" or not (string.match(arm, "^S[A-Z][%^v%-]$") or string.match(arm, "^L%d%d$")) then
            warnings[#warnings + 1] =
                "armSwitch must be blank, a position such as SF^, SA-, SFv, or a logical switch such as L01"
        end
    end
    if type(settings.metrics) ~= "table" then
        return { "metrics must contain a contiguous list of up to 3 sources" }
    end
    local count, sharedMin, sharedMax = 0, nil, nil
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
            if finite(entry.rangeMin) and finite(entry.rangeMax) and entry.rangeMin >= entry.rangeMax then
                warnings[#warnings + 1] = prefix .. ".rangeMax must be greater than rangeMin"
            end
            if finite(entry.rangeMin) then
                sharedMin = sharedMin and math.min(sharedMin, entry.rangeMin) or entry.rangeMin
            end
            if finite(entry.rangeMax) then
                sharedMax = sharedMax and math.max(sharedMax, entry.rangeMax) or entry.rangeMax
            end
        end
    end
    if count > 3 or #settings.metrics ~= count then
        warnings[#warnings + 1] = "metrics must contain a contiguous list of up to 3 sources"
    end
    if settings.scaling ~= "independent" and sharedMin and sharedMax and sharedMin >= sharedMax then
        warnings[#warnings + 1] = "shared rangeMax must be greater than shared rangeMin"
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
    return context.settings.label or ""
end

function chart.format(value, precision)
    return finite(value) and string.format("%." .. math.min(3, math.max(0, precision or 0)) .. "f", value) or "--"
end

function chart.durationText(ticks)
    local seconds = math.floor(ticks / 100)
    if seconds < 60 then
        return string.format("%ds", seconds)
    end
    if seconds % 60 == 0 then
        return string.format("%dm", seconds / 60)
    end
    return string.format("%dm%ds", math.floor(seconds / 60), seconds % 60)
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

local function label(context, color, font)
    return context.primitives.label(context.panel.root, context.theme, {
        x = 0,
        y = 0,
        w = 1,
        text = "",
        color = color,
        font = font or TINSIZE,
    })
end

local GRID_CAP = 12

function chart.gridInterval(window, pixels)
    local target = math.max(6000, window / math.max(1, math.min(GRID_CAP, math.floor(pixels / 24))))
    local scale = 6000
    while target > scale * 5 do
        scale = scale * 10
    end
    for _, multiple in ipairs({ 1, 2, 5 }) do
        if scale * multiple >= target then
            return scale * multiple
        end
    end
end

local function updateGrid(context)
    local area, start, window = context.area, context.start, context.window
    if context.gridLayoutVersion ~= context.version then
        context.gridStep = chart.gridInterval(window, area.w)
        context.gridFirst = (math.floor(start / context.gridStep) + 1) * context.gridStep
        context.gridLayoutVersion = context.version
    end
    -- Fill a fixed pool gradually, behind the traces, and limit native changes.
    for _ = 1, #context.grid < GRID_CAP and 1 or 3 do
        local index = context.gridCursor
        local line = context.grid[index]
        if not line then
            line = {
                object = lvgl.vline(context.gridRoot, {
                    x = 0,
                    y = 0,
                    w = 1,
                    h = 1,
                    color = context.theme.chartColor.grid,
                }),
                visible = false,
            }
            lvgl.hide(line.object)
            context.grid[index] = line
        end
        if line.version ~= context.version then
            local at = context.gridFirst + (index - 1) * context.gridStep
            local x = area.x + math.floor((at - start) / window * area.w + 0.5)
            local visible = at < start + window and x > area.x and x < area.x + area.w
            if visible then
                if line.x ~= x or line.geometryVersion ~= context.geometryVersion then
                    line.object:set({ x = x, y = area.y, w = 1, h = area.h })
                end
                if not line.visible then
                    lvgl.show(line.object)
                end
            elseif line.visible then
                lvgl.hide(line.object)
            end
            line.at, line.x, line.visible = at, x, visible
            line.version, line.geometryVersion = context.version, context.geometryVersion
        end
        if index == GRID_CAP and context.grid[1].version == context.version then
            context.gridVersion = context.version
        end
        context.gridCursor = index % GRID_CAP + 1
    end
end

local function updateHeader(context)
    local builder, area = context.themeBuilder, context.area
    local duration = chart.durationText(context.window or timeWindow(context.settings, 0))
    if context.headerGeometry == context.geometryVersion and context.durationText == duration then
        return
    end
    local frame = area.frame
    local title = heading(context)
    if title ~= "" then
        frame.labelWidth = math.max(0, area.x + area.w - frame.labelX)
        context.primitives.setHeading(
            context.title,
            builder,
            frame,
            { label = SMLSIZE, badge = TINSIZE },
            title,
            context.theme.color.text,
            { x = frame.labelX, y = frame.labelY }
        )
    else
        lvgl.hide(context.title)
    end
    local width = math.min(builder.measureText(TINSIZE, duration), area.w)
    local x = area.x + area.w - width
    local baseline = math.max(context.rect.h - 2, context.legendBaseline or 0)
    local y = math.max(0, baseline - builder.fontAscent(TINSIZE))
    local left, top = math.max(area.x, x - 2), math.max(0, y - 1)
    context.durationBackground:set({
        x = left,
        y = top,
        w = area.x + area.w - left,
        h = context.rect.h - top,
    })
    lvgl.show(context.durationBackground)
    context.duration:set({ x = x, y = y, w = width })
    context.status:set({ w = area.w })
    text(context.duration, duration, context.theme.color.textFaint)
    context.headerGeometry, context.durationText = context.geometryVersion, duration
end

local function updatePauseMarker(context)
    local session = context.session
    local paused = session and session.available and not session.recording and (session.segment or 0) > 0
    if not paused then
        if context.pauseVisible then
            lvgl.hide(context.pauseMarker)
            context.pauseVisible = false
        end
        return
    end
    if context.pauseVisible and context.pauseVersion == context.version and context.pauseAt == session.elapsed then
        return
    end
    local available = false
    for _, item in ipairs(context.series) do
        available = available or item.feed and item.feed.available
    end
    if not available then
        return
    end
    if not context.pauseMarker then
        context.pauseMarker = lvgl.vline(context.plotRoot, {
            x = 0,
            y = 0,
            w = 1,
            h = 1,
            color = context.theme.color.textFaint,
            dashGap = 3,
            dashWidth = 2,
        })
    end
    local area = context.area
    context.pauseMarker:set({
        x = area.x + math.floor((session.elapsed - context.start) / context.window * area.w + 0.5),
        y = area.y,
        h = area.h,
    })
    lvgl.show(context.pauseMarker)
    context.pauseVisible, context.pauseVersion, context.pauseAt = true, context.version, session.elapsed
end

local function extremaFont(font)
    if font == MIDSIZE then
        return 0
    end
    return font == 0 and SMLSIZE or TINSIZE
end

local function symbolSize(builder, font)
    return math.max(4, math.floor(builder.fontHeight(font) / 3))
end

local function extremaWidth(context, item, font)
    local builder = context.themeBuilder
    return 2
            * math.max(
                builder.measureText(font, item.minimumText or "--"),
                builder.measureText(font, item.maximumText or "--")
            )
        + 2 * symbolSize(builder, font)
        + 14
end

local function positionExtrema(context, item, y)
    local builder, area, font = context.themeBuilder, context.area, context.extremaFont
    local size = symbolSize(builder, font)
    local available = math.max(0, area.legendW - 2 * size - 14)
    local budget = math.floor(available / 2)
    local minimumWidth = math.min(budget, builder.measureText(font, item.minimumText or "--"))
    local maximumWidth = math.min(available - budget, builder.measureText(font, item.maximumText or "--"))
    local groupWidth = minimumWidth + maximumWidth + 2 * size + 14
    local left = area.legendX + area.legendW - groupWidth
    local minimumX = left + size + 3
    local maximumX = minimumX + minimumWidth + 8 + size + 3
    local height = math.max(3, math.floor(size * 2 / 3))
    local top = y + math.floor((builder.fontAscent(font) - height) / 2)
    item.extrema:set({ x = minimumX, y = y, w = minimumWidth })
    item.maximum:set({ x = maximumX, y = y, w = maximumWidth })
    item.minSymbol:set({
        pts = {
            { left, top },
            { left + size, top },
            { left + math.floor(size / 2), top + height },
        },
    })
    local x = maximumX - size - 3
    item.maxSymbol:set({
        pts = {
            { x, top + height },
            { x + size, top + height },
            { x + math.floor(size / 2), top },
        },
    })
    item.extremaY, item.extremaDirty = y, false
end

local function readingWidths(context, font)
    local builder = context.themeBuilder
    local nameLimit = math.floor(builder.fontHeight(font) * 2.5)
    local value, unit, name = 0, 0, 0
    for _, item in ipairs(context.series) do
        value = math.max(value, builder.measureText(font, item.valueText or "--"))
        unit = math.max(unit, builder.measureText(font, item.unitText or ""))
        name = math.max(name, math.min(nameLimit, builder.measureText(font, item.caption)))
    end
    return value, unit, name
end

local function positionReading(context, item, y)
    local area, builder, font = context.area, context.themeBuilder, context.legendFont
    local unitWidth = math.min(context.unitWidth, builder.measureText(font, item.unitText or ""))
    local finish = area.legendX + area.legendW - unitWidth
    local width = math.min(context.valueWidth, builder.measureText(font, item.valueText or "--"))
    local x = finish - width
    local nameWidth = math.min(math.max(0, x - area.legendX - 4), builder.measureText(font, item.nameText or ""))
    local nameX = x - 4 - nameWidth
    if item.valueX ~= x or item.valueY ~= y or item.valueWidth ~= width then
        item.value:set({ x = x, y = y, w = width })
        item.valueX, item.valueY, item.valueWidth = x, y, width
    end
    if item.unitX ~= finish or item.unitY ~= y or item.unitWidth ~= unitWidth then
        item.unit:set({ x = finish, y = y, w = unitWidth })
        item.unitX, item.unitY, item.unitWidth = finish, y, unitWidth
    end
    if item.nameX ~= nameX or item.nameY ~= y or item.nameWidth ~= nameWidth then
        item.name:set({ x = nameX, y = y, w = nameWidth })
        item.nameX, item.nameY, item.nameWidth = nameX, y, nameWidth
    end
end

local function legendWidth(context, font, showExtrema)
    local value, unit, name = readingWidths(context, font)
    local width = math.max(64, value + unit + name + 4)
    for _, item in ipairs(context.series) do
        width = math.max(width, showExtrema and extremaWidth(context, item, extremaFont(font)) or 0)
    end
    return width
end

function chart.geometry(context, rect)
    local builder = context.themeBuilder
    local fonts = { label = SMLSIZE, badge = TINSIZE }
    local frame = builder.frame(context.theme, rect, fonts)
    local content = frame.content
    local count = #context.series
    local first = frame.labelY
    local available = math.max(1, rect.h - first)
    -- Preserve extrema whenever they fit at the readability floor.
    local showExtrema = available >= count * (builder.fontHeight(SMLSIZE) + builder.fontAscent(TINSIZE))
    local fontLimit = math.max(builder.fontHeight(SMLSIZE), math.floor(rect.h / math.max(6, count * 3)))
    local font, required
    -- Readout growth can step down the font; resizing restarts the ladder.
    for index = count == 0 and #LEGEND_FONTS or context.legendIndex or 1, #LEGEND_FONTS do
        local candidate = LEGEND_FONTS[index]
        local rowHeight = builder.fontHeight(candidate)
            + (showExtrema and builder.fontAscent(extremaFont(candidate)) or 0)
        if builder.fontHeight(candidate) <= fontLimit and count * rowHeight <= available or candidate == SMLSIZE then
            local width = legendWidth(context, candidate, showExtrema)
            if candidate == context.legendFont then
                width = math.max(width, context.legendWidth or 0)
            end
            if width <= math.floor(content / 2) or candidate == SMLSIZE then
                font, required, context.legendIndex = candidate, width, index
                break
            end
        end
    end
    context.legendFont, context.legendWidth = font, required
    context.extremaFont = extremaFont(font)
    local legend = math.min(required, math.max(24, content - 28))
    local valueWidth, unitWidth = readingWidths(context, font)
    context.requiredValueWidth, context.requiredUnitWidth = valueWidth, unitWidth
    context.unitWidth = math.min(unitWidth, math.max(0, legend - 27))
    context.valueWidth = math.min(valueWidth, math.max(0, legend - context.unitWidth - 4))
    local nameWidth = math.max(0, legend - context.valueWidth - context.unitWidth - 4)
    local gap = 6
    local width = math.max(1, content - legend - gap)
    local top = frame.labelY + (heading(context) ~= "" and builder.fontHeight(SMLSIZE) + 2 or 0)
    if frame.reserved and not frame.reserved.side then
        top = math.max(top, frame.reserved.h)
    end
    local bottom = math.max(top + 1, rect.h - 3)
    local area = {
        frame = frame,
        x = frame.pad,
        y = top,
        w = width,
        h = math.max(1, bottom - top),
        legendX = frame.pad + width + gap,
        legendW = legend,
    }
    context.area = area
    context.plotRoot:set({ w = rect.w, h = rect.h })
    context.gridRoot:set({ w = rect.w, h = rect.h })
    context.baseline:set({ x = area.x, y = area.y + area.h, w = area.w, h = 1 })
    context.status:set({ x = area.x, y = area.y, w = area.w })
    local lineHeight = builder.fontHeight(font)
    local pairHeight = lineHeight + builder.fontAscent(context.extremaFont)
    context.showExtrema = showExtrema
    local rowHeight = showExtrema and pairHeight or lineHeight
    local spare = available - 2 - count * rowHeight
    local preferredGap = builder.fontHeight(context.extremaFont) * 2 // 3
    local groupGap = count > 1 and math.max(0, math.min(preferredGap, math.floor(spare / (count - 1)))) or 0
    local step = rowHeight + groupGap
    if count * rowHeight > available then
        step = math.floor(available / math.max(1, count))
    end
    context.legendBaseline = count > 0
            and first + (count - 1) * step + (showExtrema and lineHeight + builder.fontAscent(context.extremaFont) or builder.fontAscent(
                font
            ))
        or 0
    for index, item in ipairs(context.series) do
        local y = first + (index - 1) * step
        local name = builder.fitHeading(item.caption, nameWidth, font, font)
        context.primitives.setFont(item.name, font)
        context.primitives.setFont(item.value, font)
        context.primitives.setFont(item.unit, font)
        context.primitives.setFont(item.extrema, context.extremaFont)
        context.primitives.setFont(item.maximum, context.extremaFont)
        item.nameText = name
        item.name:set({ text = name })
        positionReading(context, item, y)
        positionExtrema(context, item, y + lineHeight)
        if showExtrema then
            lvgl.show(item.extrema)
            lvgl.show(item.maximum)
            lvgl.show(item.minSymbol)
            lvgl.show(item.maxSymbol)
        else
            lvgl.hide(item.extrema)
            lvgl.hide(item.maximum)
            lvgl.hide(item.minSymbol)
            lvgl.hide(item.maxSymbol)
        end
        if nameWidth < 8 then
            lvgl.hide(item.name)
        else
            lvgl.show(item.name)
        end
    end
    context.version = context.version + 1
    context.geometryVersion = (context.geometryVersion or 0) + 1
    updateHeader(context)
end

local function normalRange(low, high)
    if not finite(low) or not finite(high) then
        return 0, 1
    end
    local span = math.max(high - low, math.abs(high) * 0.02, 0.1)
    local step = 10 ^ math.floor(math.log(span) / math.log(10) - 1)
    return math.floor((low - span * 0.08) / step) * step, math.ceil((high + span * 0.08) / step) * step
end

local function valueRange(low, high, minimum, maximum)
    local autoLow, autoHigh = normalRange(low, high)
    low, high = minimum or autoLow, maximum or autoHigh
    if high <= low then
        if minimum ~= nil and maximum == nil then
            high = low + math.max(math.abs(low) * 0.02, 0.1)
        elseif maximum ~= nil and minimum == nil then
            low = high - math.max(math.abs(high) * 0.02, 0.1)
        end
    end
    return low, high
end

function chart.ranges(context)
    local sharedLow, sharedHigh, minimum, maximum
    local independent = context.settings.scaling == "independent"
    for _, item in ipairs(context.series) do
        local feed, settings = item.feed, item.settings
        if independent then
            item.low, item.high = valueRange(feed and feed.min, feed and feed.max, settings.rangeMin, settings.rangeMax)
        else
            if feed and feed.available then
                sharedLow = sharedLow and math.min(sharedLow, feed.min) or feed.min
                sharedHigh = sharedHigh and math.max(sharedHigh, feed.max) or feed.max
            end
            if settings.rangeMin ~= nil then
                minimum = minimum and math.min(minimum, settings.rangeMin) or settings.rangeMin
            end
            if settings.rangeMax ~= nil then
                maximum = maximum and math.max(maximum, settings.rangeMax) or settings.rangeMax
            end
        end
    end
    if not independent then
        local low, high = valueRange(sharedLow, sharedHigh, minimum, maximum)
        for _, item in ipairs(context.series) do
            item.low, item.high = low, high
        end
    end
end

local function runFor(item, index)
    local run = item.runs[index]
    if not run then
        run = { pts = {}, pool = {}, size = 0, changes = {} }
        item.runs[index] = run
    end
    run.size, run.column = 0, nil
    return run
end

local function pixel(job, at, value, x)
    local area = job.area
    x = x or area.x + math.floor((at - job.start) / job.window * area.w + 0.5)
    local fraction = math.max(0, math.min(1, (value - job.low) / (job.high - job.low)))
    local y = area.y + math.floor((1 - fraction) * area.h + 0.5)
    return x, y
end

local function appendPixel(run, x, y)
    local last = run.pts[run.size]
    if last and last[1] == x and last[2] == y then
        return
    end
    run.size = run.size + 1
    local point = run.pool[run.size] or {}
    run.pool[run.size], run.pts[run.size] = point, point
    point[1], point[2] = x, y
end

local function flushColumn(run)
    local column = run.column
    if column then
        appendPixel(run, column.x, column.first)
        if column.lowAt < column.highAt then
            appendPixel(run, column.x, column.low)
            appendPixel(run, column.x, column.high)
        else
            appendPixel(run, column.x, column.high)
            appendPixel(run, column.x, column.low)
        end
        appendPixel(run, column.x, column.last)
        run.column = nil
    end
end

local function addPoint(job, run, at, value, x, y)
    if at < job.start or at > job.finish then
        return
    end
    if not x then
        x, y = pixel(job, at, value)
    end
    local column = run.column
    if not column or column.x ~= x then
        flushColumn(run)
        column = run.columnPool or {}
        run.columnPool, run.column = column, column
        column.x, column.first, column.last = x, y, y
        column.low, column.high, column.lowAt, column.highAt = y, y, at, at
    else
        if y < column.low then
            column.low, column.lowAt = y, at
        end
        if y > column.high then
            column.high, column.highAt = y, at
        end
        column.last = y
    end
end

local function finishRun(run)
    flushColumn(run)
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
    local run = runFor(item, 1)
    run.boundary = nil
    local feed = item.feed
    local job = item.job or {}
    item.job = job
    job.index, job.last = feed.first, feed.last
    job.tailAt, job.tailValue, job.tailBroken = context.history:point(feed, feed.last)
    job.runIndex, job.previousAt, job.previousValue = 1, nil, nil
    job.start, job.window, job.area = context.start, context.window, context.area
    job.finish = job.start + job.window
    job.version, job.geometryVersion = context.version, context.geometryVersion
    job.low, job.high, job.revision = item.low, item.high, feed.plotRevision
    job.marked, job.markerColumns = {}, {}
    job.projecting = true
end

local function projectPoint(job, item, at, value, broken, x, y)
    if not y then
        x, y = pixel(job, at, value, x)
    end
    local run = item.runs[job.runIndex]
    if broken and job.previousAt then
        local coincident = x == job.previousX and y == job.previousY and job.previousAt >= job.start
        if at >= job.start and at <= job.finish then
            local column = x - job.area.x + 1
            if not job.marked[column] then
                job.marked[column] = true
                job.markerColumns[#job.markerColumns + 1] = column
            end
        end
        -- Coincident endpoints add no connector pixels. Sharing their native
        -- line avoids an object per arm cycle, while retaining every gap marker.
        if not coincident and (run.size > 0 or run.column) then
            finishRun(run)
            job.runIndex = job.runIndex + 1
            run = runFor(item, job.runIndex)
        end
        run.boundary = at
        job.previousAt, job.previousValue = nil, nil
    end
    if job.previousAt and job.previousAt < job.start and at >= job.start then
        local fraction = (job.start - job.previousAt) / (at - job.previousAt)
        addPoint(job, run, job.start, job.previousValue * (1 - fraction) + value * fraction)
    end
    local finish = job.finish
    if job.previousAt and job.previousAt <= finish and at > finish then
        local fraction = (finish - job.previousAt) / (at - job.previousAt)
        addPoint(job, run, finish, job.previousValue * (1 - fraction) + value * fraction)
    end
    addPoint(job, run, at, value, x, y)
    job.previousAt, job.previousValue = at, value
    job.previousX, job.previousY = x, y
end

local function project(context, item, limit)
    local job, feed = item.job, item.feed
    if job.geometryVersion ~= context.geometryVersion or job.index < feed.first then
        prepare(context, item)
    end
    for _ = 1, limit do
        if job.index > job.last then
            finishRun(item.runs[job.runIndex])
            item.runCount, item.applyIndex = job.runIndex, 1
            item.markerIndex, item.markerPhase = 1, "hide"
            item.drawnRevision, item.drawnVersion = job.revision, job.version
            item.drawnLow, item.drawnHigh = job.low, job.high
            job.projecting = false
            return true
        end
        local index = job.index
        local at, value, broken
        if index == job.last then
            at, value, broken = job.tailAt, job.tailValue, job.tailBroken
        else
            at, value, broken = context.history:point(feed, index)
        end
        local column = math.floor((at - job.start) / job.window * job.area.w + 0.5)
        local before = job.start + (column + 0.5) * job.window / job.area.w
        local last, firstExtreme, lastExtreme, interrupted = context.history:block(feed, index, job.last - 1, before)
        projectPoint(job, item, at, value, broken, job.area.x + column)
        if last and at >= job.start then
            local firstAt, firstValue = context.history:point(feed, firstExtreme)
            local lastAt, lastValue = context.history:point(feed, lastExtreme)
            local firstX, firstY = pixel(job, firstAt, firstValue)
            local lastX, lastY = pixel(job, lastAt, lastValue)
            if not interrupted or firstY == lastY then
                if firstY ~= lastY or interrupted and job.previousY ~= firstY then
                    projectPoint(job, item, firstAt, firstValue, false, firstX, firstY)
                    projectPoint(job, item, lastAt, lastValue, false, lastX, lastY)
                end
                local endAt, endValue = context.history:point(feed, last)
                projectPoint(job, item, endAt, endValue, interrupted)
                job.index = last + 1
            else
                job.index = index + 1
            end
        else
            job.index = index + 1
        end
    end
    return false
end

local function applyMarkers(context, item)
    local job = item.job
    local changes = 0
    for _ = 1, 16 do
        local keys = item.markerPhase == "hide" and item.markerKeys or job.markerColumns
        local column = keys[item.markerIndex]
        if not column then
            if item.markerPhase == "show" then
                return true
            end
            item.markerPhase, item.markerIndex = "show", 1
        else
            local marker = item.markers[column]
            if item.markerPhase == "hide" then
                if marker.active and not job.marked[column] then
                    lvgl.hide(marker.object)
                    marker.active = false
                    changes = changes + 1
                end
            elseif not marker or marker.geometryVersion ~= job.geometryVersion then
                local options = {
                    x = job.area.x + column - 1,
                    y = job.area.y,
                    w = 1,
                    h = job.area.h,
                    color = context.theme.color.textFaint,
                    dashGap = 3,
                    dashWidth = 2,
                }
                if marker then
                    marker.object:set(options)
                    lvgl.show(marker.object)
                else
                    marker = { object = lvgl.vline(context.plotRoot, options) }
                    item.markers[column] = marker
                    item.markerKeys[#item.markerKeys + 1] = column
                end
                marker.active, marker.geometryVersion = true, job.geometryVersion
                changes = changes + 1
            elseif not marker.active then
                lvgl.show(marker.object)
                marker.active = true
                changes = changes + 1
            end
            item.markerIndex = item.markerIndex + 1
        end
        if changes == 4 then
            break
        end
    end
    return false
end

local function applyRuns(context, item)
    local limit = math.max(item.runCount, #item.runs)
    local changes = 0
    for _ = 1, 16 do
        local index = item.applyIndex
        if index > limit then
            return applyMarkers(context, item)
        end
        local run = item.runs[index]
        if index <= item.runCount and run.size >= 2 then
            if run.line then
                run.changes.pts, run.changes.color = run.pts, item.color
                run.line:set(run.changes)
                if not run.visible then
                    lvgl.show(run.line)
                end
            else
                run.line = lvgl.line(context.plotRoot, { pts = run.pts, color = item.color, thickness = 1 })
            end
            run.visible = true
            changes = changes + 1
        else
            if run.line and run.visible then
                lvgl.hide(run.line)
                run.visible = false
                changes = changes + 1
            end
        end
        item.applyIndex = index + 1
        if changes == 4 then
            break
        end
    end
    if item.applyIndex > limit then
        return applyMarkers(context, item)
    end
    return false
end

function chart.intervalFor(window, pixels, sources)
    local perPixel = math.max(20, math.min(100, math.floor(window / math.max(1, pixels))))
    return math.max(5, math.floor(perPixel / math.max(1, sources)))
end

function chart.render(context)
    local changed = context.readingGeometry ~= context.geometryVersion
    for _, item in ipairs(context.series) do
        local feed = item.feed
        if
            not feed
            or feed.revision == nil
            or item.readingRevision ~= feed.revision
            or item.readingUnit ~= item.settings.unit
            or item.readingPrecision ~= item.settings.precision
        then
            changed = true
            break
        end
    end
    if not changed then
        return false
    end
    local builder = context.themeBuilder
    local font = context.legendFont
    local width = 64
    for _, item in ipairs(context.series) do
        local feed = item.feed
        item.readingRevision = feed and feed.revision
        item.readingUnit, item.readingPrecision = item.settings.unit, item.settings.precision
        local precision = item.settings.precision or feed and feed.precision or 0
        local unit = item.settings.unit
        if unit == nil then
            unit = feed and feed.unitText or ""
        end
        local value = chart.format(feed and feed.value, precision)
        item.valueText, item.unitText = value, value ~= "--" and unit or ""
        item.readout = value .. item.unitText
        local minimumText = chart.format(feed and feed.min, precision)
        local maximumText = chart.format(feed and feed.max, precision)
        if item.minimumText ~= minimumText or item.maximumText ~= maximumText then
            item.extremaDirty = true
        end
        item.minimumText, item.maximumText = minimumText, maximumText
        width = math.max(width, context.showExtrema and extremaWidth(context, item, context.extremaFont) or 0)
        local color = feed and feed.stale and context.theme.color.textFaint or context.theme.color.text
        text(item.value, value, color)
        text(item.unit, item.unitText, color)
        if context.showExtrema then
            text(item.extrema, minimumText, context.theme.color.textFaint)
            text(item.maximum, maximumText, context.theme.color.textFaint)
        end
    end
    local valueWidth, unitWidth, nameWidth = readingWidths(context, font)
    width = math.max(width, valueWidth + unitWidth + nameWidth + 4)
    if
        width > (context.legendWidth or 0)
        or valueWidth > context.requiredValueWidth
        or unitWidth > context.requiredUnitWidth
    then
        context.legendWidth = math.max(width, context.legendWidth or 0)
        chart.geometry(context, context.rect)
    end
    for _, item in ipairs(context.series) do
        positionReading(context, item, item.valueY)
        if context.showExtrema and item.extremaDirty then
            positionExtrema(context, item, item.extremaY)
        end
    end
    context.readingGeometry = context.geometryVersion
    return true
end

function chart.refresh(context, creating)
    local session = context.session
    local elapsed = session and session.elapsed or 0
    local window = timeWindow(context.settings, elapsed)
    local start = context.settings.timeRange == "rolling" and math.max(0, elapsed - window) or 0
    local pixelStart = math.floor(start / window * context.area.w)
    if context.window ~= window or context.pixelStart ~= pixelStart then
        context.window, context.start, context.pixelStart = window, start, pixelStart
        context.version = context.version + 1
    end
    local version = context.version
    -- Stable readings also keep their ranges, leaving room for more projection.
    local readingsChanged = chart.render(context)
    local projectionCap = readingsChanged and PROJECTION_CAP or 13
    local reflowed = version ~= context.version
    if readingsChanged then
        chart.ranges(context)
    end
    updateHeader(context)
    if not creating then
        updateGrid(context)
    end
    if session and session.available and not session.recording or context.pauseVisible then
        updatePauseMarker(context)
    end
    local status = ""
    local full = false
    for _, item in ipairs(context.series) do
        full = full or item.feed and item.feed.full
    end
    if not context.history or context.history.failed then
        status = "HISTORY N/A"
    elseif not session.configured then
        status = "SET ARM SOURCE"
    elseif #context.series == 0 then
        status = "ADD METRICS"
    elseif full then
        status = "HISTORY FULL"
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
    if status ~= "" and status ~= "HISTORY FULL" then
        return 20
    end
    if reflowed then
        return 5
    end
    if context.pending then
        local item = context.pending
        if item.job.geometryVersion ~= context.geometryVersion then
            prepare(context, item)
        end
        if item.job.projecting and not project(context, item, projectionCap) then
            return 5
        end
        if applyRuns(context, item) then
            context.pending = nil
        end
        return 5
    end
    for offset = 0, #context.series - 1 do
        local index = (context.cursor + offset - 1) % #context.series + 1
        local item = context.series[index]
        if
            item.drawnVersion ~= context.version
            or item.drawnRevision ~= item.feed.plotRevision
            or item.drawnLow ~= item.low
            or item.drawnHigh ~= item.high
        then
            prepare(context, item)
            if not project(context, item, projectionCap) or not applyRuns(context, item) then
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
        grid = {},
        gridCursor = 1,
    }
    local presentation = services.state("normal", settings.accent or "cyan")
    context.panel = context.primitives.panel(parent, rect, context.theme, presentation)
    context.plotRoot = lvgl.box(context.panel.root, { x = 0, y = 0, w = rect.w, h = rect.h })
    context.gridRoot = lvgl.box(context.plotRoot, { x = 0, y = 0, w = rect.w, h = rect.h })
    context.session = context.history and context.history:session(settings.armSwitch)
    for index, entry in ipairs(settings.metrics) do
        local color = context.theme.chartColor[entry.accent or COLORS[index]]
        local item = {
            settings = entry,
            color = color,
            runs = {},
            markers = {},
            markerKeys = {},
            caption = string.upper(caption(entry)),
        }
        if context.history then
            item.feed = context.history:subscribe(entry.source, {
                armSwitch = settings.armSwitch,
                windowSeconds = timeWindow(settings, 0) / 100,
                timeRange = settings.timeRange or "growing",
                smoothing = settings.smoothing or "off",
                precision = entry.precision,
            })
        end
        item.name, item.value, item.unit, item.extrema, item.maximum =
            label(context, color, SMLSIZE),
            label(context, context.theme.color.text, SMLSIZE),
            label(context, context.theme.color.text, SMLSIZE),
            label(context, context.theme.color.textFaint, TINSIZE),
            label(context, context.theme.color.textFaint, TINSIZE)
        item.minSymbol = lvgl.triangle(context.panel.root, {
            pts = { { 0, 0 }, { 1, 0 }, { 0, 1 } },
            color = context.theme.color.textFaint,
        })
        item.maxSymbol = lvgl.triangle(context.panel.root, {
            pts = { { 0, 0 }, { 1, 0 }, { 0, 1 } },
            color = context.theme.color.textFaint,
        })
        context.series[index] = item
    end
    context.durationBackground = lvgl.rectangle(context.panel.root, {
        x = 0,
        y = 0,
        w = 1,
        h = 1,
        color = context.theme.color.surface,
        filled = true,
    })
    context.title, context.duration, context.status = label(context), label(context), label(context)
    context.baseline =
        lvgl.hline(context.plotRoot, { x = 0, y = 0, w = 1, h = 1, color = context.theme.chartColor.grid })
    chart.geometry(context, rect)
    chart.refresh(context, true)
    return context
end

function chart.update(context, rect)
    context.rect = rect
    context.legendFont, context.legendIndex, context.legendWidth = nil, nil, nil
    context.primitives.resizePanel(context.panel, rect)
    chart.geometry(context, rect)
    chart.refresh(context)
end

return chart
