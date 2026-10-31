-- SPDX-License-Identifier: GPL-2.0-only

local chart = {
    id = "chart",
    apiVersion = 1,
    supportedSpans = { "2x1", "3x1", "4x1", "2x2", "3x2", "4x2", "3x3", "4x3", "4x4" },
    refreshInterval = 20,
    refreshCost = 6,
    settings = {
        { key = "label", label = "Label", type = "string", default = "" },
        { key = "armSwitch", label = "Arm switch position", type = "string", default = "", legacyArm = true },
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
local BREAK_WIDTH = 24
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

function chart.validateSettings(settings, _, _, modelArmed)
    local warnings = {}
    local arm = settings.armSwitch
    if
        modelArmed == nil
        and arm ~= nil
        and arm ~= ""
        and (type(arm) ~= "string" or not (string.match(arm, "^S[A-Z][%^v%-]$") or string.match(arm, "^L%d%d$")))
    then
        warnings[#warnings + 1] = "armSwitch must be blank, a physical switch position, or a logical switch"
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

local function axisPosition(axis, at, before)
    local low, high = 1, #axis.breaks
    while low <= high do
        local middle = (low + high) // 2
        local stamp = axis.breaks[middle]
        if stamp < at or stamp == at and not before then
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return axis.x + (at - axis.start) * axis.scale + high * axis.gap, axis.breaks[low]
end

local function timeX(context, at, before)
    if context.axis and #context.axis.breaks > 0 then
        return math.floor(axisPosition(context.axis, at, before) + 0.5)
    end
    return context.area.x + math.floor((at - context.start) / context.window * context.area.w + 0.5)
end

local function prepareAxis(context)
    local session, area = context.session, context.area
    local window = timeWindow(context.settings, session.elapsed)
    local start = context.settings.timeRange == "rolling" and math.max(0, session.elapsed - window) or 0
    local axis = context.axis
    if
        axis
        and axis.revision == session.resumeRevision
        and axis.baseStart == start
        and axis.window == window
        and axis.geometryVersion == context.geometryVersion
    then
        return true
    end
    local work = context.axisWork
    if not work then
        work = { index = session.resumeLast or 0, reverse = {}, start = start }
        context.axisWork = work
    end
    -- Keep room for recorded data when fixed-width breaks crowd the axis.
    local capacity = math.max(1, area.w // (BREAK_WIDTH * 2))
    for _ = 1, 32 do
        if work.index < (session.resumeFirst or 1) or not context.history.recordingBreak then
            work.done = true
            break
        end
        local at = context.history:recordingBreak(context.liveSession or session, work.index)
        work.index = work.index - 1
        if at and at < start then
            work.done = true
            break
        end
        if at and at <= start + window and at ~= work.reverse[#work.reverse] then
            if #work.reverse == capacity then
                work.start, work.done = work.reverse[#work.reverse], true
                break
            end
            work.reverse[#work.reverse + 1] = at
        end
    end
    if not work.done then
        return false
    end
    local breaks = {}
    for index = #work.reverse, 1, -1 do
        breaks[#breaks + 1] = work.reverse[index]
    end
    local gap = math.min(BREAK_WIDTH, area.w // 2)
    if gap == 0 then
        breaks = {}
    end
    context.axis = {
        breaks = breaks,
        start = work.start,
        baseStart = start,
        window = window,
        x = area.x,
        gap = gap,
        revision = session.resumeRevision,
        geometryVersion = context.geometryVersion,
    }
    axis = context.axis
    axis.scale = (area.w - #breaks * axis.gap) / math.max(1, start + window - axis.start)
    context.axisWork = nil
    context.version = context.version + 1
    return true
end

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
        context.gridFirst = (math.floor((context.axis and context.axis.start or start) / context.gridStep) + 1)
            * context.gridStep
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
            local x = timeX(context, at)
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
    context.durationLeft, context.durationTop = left, top
    lvgl.show(context.durationBackground)
    context.duration:set({ x = x, y = y, w = width })
    context.status:set({ w = area.w })
    text(context.duration, duration, context.theme.color.textFaint)
    context.headerGeometry, context.durationText = context.geometryVersion, duration
end

local function updateFlights(context)
    local session, historyService = context.session, context.history
    if
        not session
        or not historyService
        or not historyService.flight
        or (session.flightLast or 0) == 0 and not context.flightBands
    then
        return false
    end
    local elapsed = session.flightActive and (context.frameThrough or session.elapsed) or 0
    if
        context.flightDrawnRevision == session.flightRevision
        and context.flightDrawnVersion == context.version
        and context.flightDrawnElapsed == elapsed
    then
        return false
    end
    context.flightBands = context.flightBands or {}
    local first, last = session.flightFirst, session.flightLast
    if context.flightPassRevision ~= session.flightRevision or context.flightPassVersion ~= context.version then
        context.flightCursor = 1
        context.flightPassRevision, context.flightPassVersion = session.flightRevision, context.version
    end
    local slot = context.flightCursor or 1
    local index = first + (slot - 1 - (first - 1) % historyService.FLIGHT_CAPACITY) % historyService.FLIGHT_CAPACITY
    local band = context.flightBands[slot]
    local at, finish = historyService:flight(context.liveSession or session, index)
    finish = math.min(finish or session.elapsed, context.frameThrough or session.elapsed)
    local area, start, window = context.area, context.start, context.window
    local visible = at
        and finish > at
        and finish > (context.axis and context.axis.start or start)
        and at < start + window
    if visible then
        local left = math.max(area.x, math.min(area.x + area.w - 1, timeX(context, at)))
        local right = math.max(area.x, math.min(area.x + area.w, timeX(context, finish, true)))
        if not band then
            band = lvgl.rectangle(context.flightRoot, {
                x = left,
                y = area.y,
                w = 1,
                h = area.h,
                color = context.theme.chartColor.flightBand,
                opacity = 48,
                filled = true,
                thickness = 0,
            })
            context.flightBands[slot] = band
            context.flightSlots = math.max(context.flightSlots or 0, slot)
        end
        local key = table.concat({ left, right, area.y, area.h }, ":")
        if context.flightKeys[slot] ~= key then
            band:set({ x = left, y = area.y, w = math.max(1, right - left), h = area.h })
            context.flightKeys[slot] = key
        end
        lvgl.show(band)
    elseif band then
        lvgl.hide(band)
    end
    local slots = math.max(context.flightSlots or 0, math.min(historyService.FLIGHT_CAPACITY, last))
    context.flightCursor = slot < slots and slot + 1 or 1
    if context.flightCursor == 1 then
        context.flightDrawnRevision = session.flightRevision
        context.flightDrawnVersion = context.version
        context.flightDrawnElapsed = elapsed
    end
    return true
end

local applyMarkers

local function markerPool(style)
    return { markers = {}, markerKeys = {}, style = style }
end

local function markBoundary(context, item, pass, at, armed)
    if item.style == "resume" and context.axis.gap == 0 then
        return
    end
    if not at or at < (context.axis and context.axis.start or context.start) or at > context.start + context.window then
        return
    end
    local x = timeX(context, at, item.style == "resume" or item.style == "arm" and not armed)
    local column = x - context.area.x + 1
    local key = item.style == "arm" and not armed and -column or column
    if not pass.marked[key] then
        pass.marked[key] = true
        pass.markerColumns[#pass.markerColumns + 1] = key
    end
end

local function updateSessionMarkers(context, item, first, last, revision, readBoundary)
    local session, service = context.session, context.history
    if not service or not readBoundary then
        return true
    end
    if
        item.drawnRevision == revision
        and item.drawnVersion == context.version
        and item.drawnResumeRevision == session.resumeRevision
    then
        return true
    end
    if not item.job then
        item.job = {
            index = first or 1,
            marked = {},
            markerColumns = {},
            geometryVersion = context.geometryVersion,
            area = context.area,
        }
        item.markerIndex, item.markerPhase = 1, "hide"
    end
    local pass = item.job
    for _ = 1, 64 do
        if pass.index > (last or 0) then
            if applyMarkers(context, item) then
                item.drawnRevision, item.drawnVersion = revision, context.version
                item.drawnResumeRevision = session.resumeRevision
                item.marked = pass.marked
                return true
            end
            return false
        end
        local at, armed = readBoundary(service, context.liveSession or session, pass.index)
        markBoundary(context, item, pass, at, armed)
        pass.index = pass.index + 1
    end
    return false
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
    local legendX, legendW = item.legendX or area.legendX, item.legendW or area.legendW
    local size = symbolSize(builder, font)
    local available = math.max(0, legendW - 2 * size - 14)
    local budget = math.floor(available / 2)
    local minimumWidth = math.min(budget, builder.measureText(font, item.minimumText or "--"))
    local maximumWidth = math.min(available - budget, builder.measureText(font, item.maximumText or "--"))
    local groupWidth = minimumWidth + maximumWidth + 2 * size + 14
    local left = legendX + math.floor((legendW - groupWidth) * (item.legendAlignment or 1))
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
    local value, unit, name, row = 0, 0, 0, 0
    for _, item in ipairs(context.series) do
        local valueWidth = builder.measureText(font, item.valueText or "--")
        local unitWidth = builder.measureText(font, item.unitText or "")
        local nameWidth = math.min(nameLimit, builder.measureText(font, item.caption))
        value = math.max(value, valueWidth)
        unit = math.max(unit, unitWidth)
        name = math.max(name, nameWidth)
        row = math.max(row, valueWidth + unitWidth + nameWidth + 4)
    end
    return value, unit, name, row
end

local function positionReading(context, item, y)
    local area, builder, font = context.area, context.themeBuilder, context.legendFont
    local legendX, legendW = item.legendX or area.legendX, item.legendW or area.legendW
    local width = builder.measureText(font, item.valueText or "--")
    local unitWidth = math.min(
        context.topLegend and math.max(0, legendW - math.min(width, legendW)) or context.unitWidth,
        builder.measureText(font, item.unitText or "")
    )
    width = math.min(context.topLegend and legendW - unitWidth or context.valueWidth, width)
    local alignment = item.legendAlignment or 1
    local x = legendX + math.floor((legendW - width - unitWidth) * alignment)
    local nameBudget = math.max(0, context.topLegend and legendW - width - unitWidth - 4 or x - legendX - 4)
    if context.topLegend and item.nameBudget ~= nameBudget then
        local name = builder.fitHeading(item.caption, nameBudget, font, font)
        if name ~= item.nameText then
            item.nameText = name
            item.name:set({ text = name })
        end
        item.nameBudget = nameBudget
        if nameBudget < 8 then
            lvgl.hide(item.name)
        else
            lvgl.show(item.name)
        end
    end
    local nameWidth = math.min(nameBudget, builder.measureText(font, item.nameText or ""))
    local nameX = x - 4 - nameWidth
    if context.topLegend then
        local gap = nameWidth > 0 and 4 or 0
        nameX = legendX + math.floor((legendW - nameWidth - gap - width - unitWidth) * alignment)
        x = nameX + nameWidth + gap
    end
    local finish = x + width
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
    local value, unit, name, row = readingWidths(context, font)
    local width = math.max(64, context.topLegend and row or value + unit + name + 4)
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
    local span = context.span
    -- Square grid spans are still physically wide on a landscape radio.
    context.topLegend = span and span.rowSpan >= span.colSpan or not span and rect.w <= 2 * rect.h
    local gap = 6
    local first = frame.labelY
    local top = first + (heading(context) ~= "" and builder.fontHeight(SMLSIZE) + 2 or 0)
    if context.topLegend then
        first = top
    end
    local legendX = frame.pad
    if context.topLegend and frame.reserved and first < frame.reserved.h then
        legendX = math.max(legendX, frame.reserved.w + 4)
    end
    local legendContent = math.max(1, content - (legendX - frame.pad))
    local cellWidth = math.max(1, math.floor((legendContent - gap * math.max(0, count - 1)) / math.max(1, count)))
    local available = math.max(1, rect.h - first)
    local rows = context.topLegend and 1 or count
    -- Preserve extrema whenever they fit at the readability floor.
    local showExtrema = available
        >= rows * builder.fontHeight(SMLSIZE)
            + (context.topLegend and 1 or count) * builder.fontAscent(TINSIZE)
            + (context.topLegend and 12 or 0)
    if context.topLegend and cellWidth < extremaWidth(context, { minimumText = "--", maximumText = "--" }, TINSIZE) then
        showExtrema = false
    end
    local fontLimit =
        math.max(builder.fontHeight(SMLSIZE), math.floor(rect.h / (context.topLegend and 6 or math.max(6, count * 3))))
    local font, required
    -- Readout growth can step down the font; resizing restarts the ladder.
    for index = count == 0 and #LEGEND_FONTS or context.legendIndex or 1, #LEGEND_FONTS do
        local candidate = LEGEND_FONTS[index]
        local rowHeight = builder.fontHeight(candidate)
            + (showExtrema and builder.fontAscent(extremaFont(candidate)) or 0)
        local groups = context.topLegend and 1 or count
        if
            builder.fontHeight(candidate) <= fontLimit
                and groups * rowHeight + (context.topLegend and 12 or 0) <= available
            or candidate == SMLSIZE
        then
            local width = legendWidth(context, candidate, showExtrema)
            if candidate == context.legendFont then
                width = math.max(width, context.legendWidth or 0)
            end
            if width <= (context.topLegend and cellWidth or math.floor(content / 2)) or candidate == SMLSIZE then
                font, required, context.legendIndex = candidate, width, index
                break
            end
        end
    end
    context.legendFont, context.legendWidth = font, required
    context.extremaFont = extremaFont(font)
    local legend = math.min(required, context.topLegend and cellWidth or math.max(24, content - 28))
    local valueWidth, unitWidth = readingWidths(context, font)
    context.requiredValueWidth, context.requiredUnitWidth = valueWidth, unitWidth
    context.unitWidth = math.min(unitWidth, math.max(0, legend - 27))
    context.valueWidth = math.min(valueWidth, math.max(0, legend - context.unitWidth - 4))
    local nameWidth = math.max(0, legend - context.valueWidth - context.unitWidth - 4)
    local width = context.topLegend and content or math.max(1, content - legend - gap)
    local lineHeight = builder.fontHeight(font)
    if context.topLegend and count > 0 then
        top = first + lineHeight + (showExtrema and builder.fontAscent(context.extremaFont) or 0) + gap
    end
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
        legendX = context.topLegend and legendX or frame.pad + width + gap,
        legendW = legend,
    }
    context.area = area
    context.baseline:set({ x = area.x, y = area.y + area.h, w = area.w, h = 1 })
    context.status:set({ x = area.x, y = area.y, w = area.w })
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
    if context.topLegend then
        context.legendBaseline = count > 0 and top - gap or 0
    end
    for index, item in ipairs(context.series) do
        item.legendX, item.legendW, item.legendAlignment = nil, nil, nil
        local y = first + (index - 1) * step
        local itemNameWidth = nameWidth
        if context.topLegend then
            local alignment = count == 1 and 1 or (index - 1) / (count - 1)
            item.legendAlignment = alignment
            item.legendW = legend
            item.legendX = legendX + math.floor((legendContent - legend) * alignment)
            y = first
            local value = math.min(builder.measureText(font, item.valueText or "--"), legend)
            local unit = math.min(builder.measureText(font, item.unitText or ""), math.max(0, legend - value))
            itemNameWidth = math.max(0, legend - value - unit - 4)
        end
        local name = builder.fitHeading(item.caption, itemNameWidth, font, font)
        context.primitives.setFont(item.name, font)
        context.primitives.setFont(item.value, font)
        context.primitives.setFont(item.unit, font)
        context.primitives.setFont(item.extrema, context.extremaFont)
        context.primitives.setFont(item.maximum, context.extremaFont)
        item.nameText, item.nameBudget = name, itemNameWidth
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
        if itemNameWidth < 8 then
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
    run.size, run.column, run.dotted = 0, nil, false
    run.dotIndex, run.dotCount = 1, nil
    return run
end

local function pixel(job, at, value, x)
    local area = job.area
    x = x
        or (
            job.axis and math.floor(axisPosition(job.axis, at, job.resumeAt ~= at) + 0.5)
            or area.x + math.floor((at - job.start) / job.window * area.w + 0.5)
        )
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
    if item.snapshot then
        job.tailAt, job.tailValue, job.tailBroken, job.tailResumed =
            item.tailAt, item.tailValue, item.tailBroken, item.tailResumed
    else
        job.tailAt, job.tailValue, job.tailBroken, job.tailResumed = context.history:point(feed, feed.last)
    end
    job.runIndex, job.previousAt, job.previousValue, job.resumeAt = 1, nil, nil, nil
    job.start, job.window, job.area = context.start, context.window, context.area
    job.finish = job.start + job.window
    job.axis = context.axis and #context.axis.breaks > 0 and context.axis or nil
    if job.axis then
        job.start = job.axis.start
        job.window = job.finish - job.start
    end
    job.seekLow, job.seekHigh = nil, nil
    if job.start > 0 and feed.last - feed.first > 16 then
        job.seekLow, job.seekHigh = feed.first, feed.last
    end
    job.version, job.geometryVersion = context.version, context.geometryVersion
    job.low, job.high, job.revision = item.low, item.high, feed.plotRevision
    job.marked, job.markerColumns = {}, {}
    job.projecting = true
end

local function projectPoint(job, item, at, value, broken, resumed, x, y)
    if resumed then
        job.resumeAt = at
    end
    if not y then
        x, y = pixel(job, at, value, x)
    end
    local run = item.runs[job.runIndex]
    if broken and job.previousAt then
        local coincident = x == job.previousX and y == job.previousY and job.previousAt >= job.start
        if at >= job.start and at <= job.finish and not resumed then
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
            if resumed and job.previousAt >= job.start and at <= job.finish then
                run.dotted = true
                appendPixel(run, job.previousX, job.previousY)
                appendPixel(run, x, y)
                finishRun(run)
                job.runIndex = job.runIndex + 1
                run = runFor(item, job.runIndex)
            end
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
    if job.seekLow then
        for _ = 1, limit do
            if job.seekLow > job.seekHigh then
                job.index = math.max(feed.first, job.seekLow - 1)
                job.seekLow, job.seekHigh = nil, nil
                break
            end
            local middle = (job.seekLow + job.seekHigh) // 2
            local at = context.history:point(item.liveFeed or feed, middle, feed.first)
            if not at then
                context.frameExpired = true
                return false
            elseif at < job.start then
                job.seekLow = middle + 1
            else
                job.seekHigh = middle - 1
            end
        end
        return false
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
        local at, value, broken, resumed
        if index == job.last then
            at, value, broken, resumed = job.tailAt, job.tailValue, job.tailBroken, job.tailResumed
        else
            at, value, broken, resumed = context.history:point(item.liveFeed or feed, index, feed.first)
        end
        if not at then
            context.frameExpired = true
            return false
        end
        local column = math.floor((at - job.start) / job.window * job.area.w + 0.5)
        local before = job.start + (column + 0.5) * job.window / job.area.w
        if job.axis then
            if resumed then
                job.resumeAt = at
            end
            local raw, nextBreak = axisPosition(job.axis, at, job.resumeAt ~= at)
            column = math.floor(raw + 0.5) - job.area.x
            before = at + (job.area.x + column + 0.5 - raw) / job.axis.scale
            if nextBreak and before >= nextBreak then
                before = nextBreak - 0.001
            end
        end
        local last, firstExtreme, lastExtreme, interrupted, resumesOnly =
            context.history:block(item.liveFeed or feed, index, job.last - 1, before)
        projectPoint(job, item, at, value, broken, resumed, job.area.x + column)
        if last and at >= job.start then
            local firstAt, firstValue = context.history:point(item.liveFeed or feed, firstExtreme, feed.first)
            local lastAt, lastValue = context.history:point(item.liveFeed or feed, lastExtreme, feed.first)
            local firstX, firstY = pixel(job, firstAt, firstValue)
            local lastX, lastY = pixel(job, lastAt, lastValue)
            if not interrupted or firstY == lastY then
                if firstY ~= lastY or interrupted and job.previousY ~= firstY then
                    projectPoint(job, item, firstAt, firstValue, false, false, firstX, firstY)
                    projectPoint(job, item, lastAt, lastValue, false, false, lastX, lastY)
                end
                local endAt, endValue = context.history:point(item.liveFeed or feed, last, feed.first)
                projectPoint(job, item, endAt, endValue, interrupted, resumesOnly)
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

local function positionBreak(context, marker, job, column)
    local area = job.area
    local width = context.axis.gap
    local x = math.max(area.x, math.min(area.x + area.w - width, area.x + column - 1))
    local options = { x = x, y = area.y, w = width, h = area.h }
    if marker then
        marker.object:set(options)
    else
        options.color, options.filled, options.thickness = context.theme.color.surface, true, 0
        marker = { object = lvgl.rectangle(context.gapRoot, options) }
    end
    return marker
end

local function showMarker(marker)
    lvgl.show(marker.object)
    marker.active = true
end

applyMarkers = function(context, item)
    local job = item.job
    local changes = 0
    for _ = 1, 16 do
        local keys = item.markerPhase == "hide" and item.markerKeys or job.markerColumns
        local key = keys[item.markerIndex]
        if not key then
            if item.markerPhase == "show" then
                return true
            end
            item.markerPhase, item.markerIndex = "show", 1
        else
            local column = math.abs(key)
            local marker = item.markers[key]
            if item.markerPhase == "hide" then
                if marker.active and not job.marked[key] then
                    lvgl.hide(marker.object)
                    marker.active = false
                    changes = changes + 1
                end
            elseif
                not marker
                or marker.geometryVersion ~= job.geometryVersion
                or item.style == "arm" and marker.footerLeft ~= context.durationLeft
            then
                if item.style == "resume" then
                    local existing = marker ~= nil
                    marker = positionBreak(context, marker, job, column)
                    if not existing then
                        item.markers[key] = marker
                        item.markerKeys[#item.markerKeys + 1] = key
                    end
                elseif item.style == "arm" then
                    local half = math.min(3, job.area.w // 2)
                    local x =
                        math.max(job.area.x + half, math.min(job.area.x + job.area.w - half, job.area.x + column - 1))
                    local bottom = job.area.y + job.area.h
                    local height = math.min(5, job.area.h)
                    if x + half > context.durationLeft then
                        bottom = math.max(job.area.y + height, math.min(bottom, context.durationTop - 1))
                    end
                    local base, tip = bottom, bottom - height
                    if key < 0 then
                        base, tip = tip, base
                    end
                    local options = {
                        pts = { { x - half, base }, { x + half, base }, { x, tip } },
                        color = context.theme.color.textFaint,
                    }
                    if marker then
                        marker.object:set(options)
                    else
                        marker = { object = lvgl.triangle(context.plotRoot, options) }
                        item.markers[key] = marker
                        item.markerKeys[#item.markerKeys + 1] = key
                    end
                else
                    local options = {
                        x = job.area.x + column - 1,
                        y = job.area.y,
                        w = 1,
                        h = job.area.h,
                        color = context.theme.color.textFaint,
                    }
                    options.dashGap, options.dashWidth = 3, 2
                    if marker then
                        marker.object:set(options)
                    else
                        marker = { object = lvgl.vline(context.plotRoot, options) }
                        item.markers[key] = marker
                        item.markerKeys[#item.markerKeys + 1] = key
                    end
                end
                showMarker(marker)
                marker.geometryVersion = job.geometryVersion
                marker.footerLeft = context.durationLeft
                changes = changes + 1
            elseif not marker.active then
                showMarker(marker)
                changes = changes + 1
            end
            item.markerIndex = item.markerIndex + 1
        end
        if changes == (item.style == "resume" and 2 or 4) then
            break
        end
    end
    return false
end

local function applyConnector(context, item, run)
    if run.line and run.visible then
        lvgl.hide(run.line)
        run.visible = false
    end
    if not run.connector then
        run.connector = lvgl.box(context.plotRoot, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
        run.dots = {}
    elseif run.dotIndex == 1 then
        run.connector:set({ w = context.rect.w, h = context.rect.h })
    end
    local first, last = run.pts[1], run.pts[run.size]
    if not run.dotCount then
        run.dotCount = math.max(1, math.ceil(math.sqrt((last[1] - first[1]) ^ 2 + (last[2] - first[2]) ^ 2) / 3)) + 1
    end
    for _ = 1, 3 do
        local index = run.dotIndex
        if index > math.max(run.dotCount, #run.dots) then
            lvgl.show(run.connector)
            return true
        end
        local dot = run.dots[index]
        if index <= run.dotCount then
            local fraction = (index - 1) / (run.dotCount - 1)
            local options = {
                x = math.floor(first[1] + (last[1] - first[1]) * fraction + 0.5),
                y = math.floor(first[2] + (last[2] - first[2]) * fraction + 0.5),
                w = 1,
                h = 1,
                color = item.color,
            }
            if dot then
                dot:set(options)
                lvgl.show(dot)
            else
                options.filled, options.thickness = true, 0
                run.dots[index] = lvgl.rectangle(run.connector, options)
            end
        else
            lvgl.hide(dot)
        end
        run.dotIndex = index + 1
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
        if index <= item.runCount and run.size >= 2 and run.dotted then
            if not applyConnector(context, item, run) then
                return false
            end
            changes = changes + 1
        elseif index <= item.runCount and run.size >= 2 then
            if run.connector then
                lvgl.hide(run.connector)
            end
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
            if run.connector then
                lvgl.hide(run.connector)
            end
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
    local valueWidth, unitWidth, nameWidth, rowWidth = readingWidths(context, font)
    width = math.max(width, context.topLegend and rowWidth or valueWidth + unitWidth + nameWidth + 4)
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

local function refreshPlot(context, creating)
    local session = context.session
    local hasFlights = not creating and (session.flightLast or 0) > 0
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
    -- Reserve the next non-overlay callback for projection after updating live
    -- readings, so a continuous telemetry stream cannot starve the traces.
    local readingsChanged = not context.projectionTurn and chart.render(context)
    context.projectionTurn = false
    local projectionCap = readingsChanged and PROJECTION_CAP or 8
    if
        hasFlights
        and (context.history.sampledAt == context.clock() or context.history.boundaryAt == context.clock())
    then
        projectionCap = math.min(projectionCap, 9)
    end
    local reflowed = version ~= context.version
    if context.axis and context.axis.geometryVersion ~= context.geometryVersion then
        context.framePhase, context.pending = "axis", nil
        return 5
    end
    updateHeader(context)
    if not creating then
        updateGrid(context)
    end
    local status = ""
    local full = false
    for _, item in ipairs(context.series) do
        full = full or item.feed and item.feed.full
    end
    if not context.history or context.history.failed then
        status = "HISTORY N/A"
    elseif context.preview then
        status = context.previewMissing and "PREVIEW: NO DATA" or "PREVIEW"
    elseif not session.configured then
        status = "SET ARM SOURCE"
    elseif #context.series == 0 then
        status = "ADD METRICS"
    elseif full then
        status = "HISTORY FULL"
    elseif not session.available and not session.recording then
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
    if status ~= "" and status ~= "HISTORY FULL" and status ~= "PREVIEW" and status ~= "PREVIEW: NO DATA" then
        if readingsChanged then
            context.rangesReady = false
        end
        return 20
    end
    if readingsChanged or not context.rangesReady then
        chart.ranges(context)
        context.rangesReady = true
    end
    if reflowed or readingsChanged and hasFlights then
        context.projectionTurn = true
        return 5
    end
    if context.pending then
        local item = context.pending
        if item.job.geometryVersion ~= context.geometryVersion then
            prepare(context, item)
        end
        if item.job.projecting then
            project(context, item, projectionCap)
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
            item.feed
            and (
                item.drawnVersion ~= context.version
                or item.drawnRevision ~= item.feed.plotRevision
                or item.drawnLow ~= item.low
                or item.drawnHigh ~= item.high
            )
        then
            prepare(context, item)
            project(context, item, projectionCap)
            context.pending = item

            context.cursor = index % #context.series + 1
            break
        end
    end
    return context.pending and 5 or chart.intervalFor(window, context.area.w, #context.series)
end

local PLOT_FIELDS = {
    "axis",
    "plotRoot",
    "flightRoot",
    "gapRoot",
    "gridRoot",
    "baseline",
    "grid",
    "gridCursor",
    "gridVersion",
    "gridLayoutVersion",
    "flightBands",
    "flightKeys",
    "flightSlots",
    "flightCursor",
    "flightPassRevision",
    "flightPassVersion",
    "flightDrawnRevision",
    "flightDrawnVersion",
    "flightDrawnElapsed",
    "armMarkers",
    "resumeMarkers",
}
local SERIES_FIELDS = {
    "runs",
    "markers",
    "markerKeys",
    "job",
    "runCount",
    "applyIndex",
    "markerIndex",
    "markerPhase",
    "drawnRevision",
    "drawnVersion",
    "drawnLow",
    "drawnHigh",
}
local FEED_FIELDS = {
    "available",
    "stale",
    "value",
    "min",
    "max",
    "precision",
    "unitText",
    "revision",
    "plotRevision",
    "first",
    "last",
    "full",
}
local SESSION_FIELDS = {
    "configured",
    "available",
    "recording",
    "stoppedAt",
    "elapsed",
    "segment",
    "revision",
    "flightFirst",
    "flightLast",
    "flightRevision",
    "flightActive",
    "armFirst",
    "armLast",
    "armRevision",
    "resumeFirst",
    "resumeLast",
    "resumeRevision",
}

local function exchange(target, buffer, fields)
    for _, key in ipairs(fields) do
        target[key], buffer[key] = buffer[key], target[key]
    end
end

local function copyFields(source, target, fields)
    for _, key in ipairs(fields) do
        target[key] = source[key]
    end
end

local function newPlot(context)
    local rect = context.rect
    local plot = {
        grid = {},
        gridCursor = 1,
        flightKeys = {},
        armMarkers = markerPool("arm"),
        resumeMarkers = markerPool("resume"),
        series = {},
    }
    plot.plotRoot = lvgl.box(context.plotHost, { x = 0, y = 0, w = rect.w, h = rect.h })
    lvgl.hide(plot.plotRoot)
    plot.flightRoot = lvgl.box(plot.plotRoot, { x = 0, y = 0, w = rect.w, h = rect.h })
    plot.gapRoot = lvgl.box(plot.plotRoot, { x = 0, y = 0, w = rect.w, h = rect.h })
    plot.gridRoot = lvgl.box(plot.plotRoot, { x = 0, y = 0, w = rect.w, h = rect.h })
    plot.baseline = lvgl.hline(plot.plotRoot, { x = 0, y = 0, w = 1, h = 1, color = context.theme.chartColor.grid })
    for index = 1, #context.series do
        plot.series[index] = { runs = {}, markers = {}, markerKeys = {} }
    end
    return plot
end

local function needsFrame(context)
    local session, drawn = context.session, context.frameSession
    local window = timeWindow(context.settings, session.elapsed)
    local start = context.settings.timeRange == "rolling" and math.max(0, session.elapsed - window) or 0
    if window ~= context.window or math.floor(start / window * context.area.w) ~= context.pixelStart then
        return true
    end
    if not drawn or context.frameGeometry ~= context.geometryVersion then
        return true
    end
    for _, key in ipairs(SESSION_FIELDS) do
        if drawn[key] ~= session[key] then
            return true
        end
    end
    for _, item in ipairs(context.series) do
        if
            item.feed
            and (
                not item.snapshot
                or item.snapshot.revision ~= item.feed.revision
                or item.readingRevision ~= item.feed.revision
                or item.snapshot.plotRevision ~= item.feed.plotRevision
            )
        then
            return true
        end
    end
    return false
end

--- Retain both plot buffers and retire old traces in bounded batches.
function chart.resetSession(context)
    local reset = context.resetWork
    if not reset then
        if context.framePhase then
            exchange(context, context.backPlot, PLOT_FIELDS)
            for index, item in ipairs(context.series) do
                exchange(item, context.backPlot.series[index], SERIES_FIELDS)
            end
        end
        context.framePhase, context.frameSession, context.frameExpired = nil, nil, nil
        context.pending, context.axisWork, context.projectionTurn, context.rangesReady = nil, nil, nil, false
        reset = { groups = {}, group = 1, index = 1 }
        context.resetWork = reset
        local function markers(pool)
            if pool then
                pool.job, pool.drawnRevision, pool.drawnVersion = nil, nil, nil
                reset.groups[#reset.groups + 1] = { pool = pool, kind = "markers", keys = pool.markerKeys }
            end
        end
        local function plot(buffer, series)
            if not buffer then
                return
            end
            buffer.axis = nil
            buffer.flightPassRevision, buffer.flightDrawnRevision = nil, nil
            reset.groups[#reset.groups + 1] = { kind = "flights", keys = buffer.flightBands or {} }
            markers(buffer.armMarkers)
            markers(buffer.resumeMarkers)
            for _, item in ipairs(series) do
                item.job, item.drawnRevision, item.drawnVersion = nil, nil, nil
                reset.groups[#reset.groups + 1] = { kind = "runs", keys = item.runs }
                markers(item)
            end
        end
        plot(context, context.series)
        plot(context.backPlot, context.backPlot and context.backPlot.series)
    end
    for _ = 1, 8 do
        local group = reset.groups[reset.group]
        if not group then
            context.resetWork = nil
            return
        end
        local value = group.keys[reset.index]
        if value then
            if group.kind == "runs" then
                if value.line and value.visible then
                    lvgl.hide(value.line)
                    value.visible = false
                end
                if value.connector then
                    lvgl.hide(value.connector)
                end
            elseif group.kind == "markers" then
                local marker = group.pool.markers[value]
                if marker.active then
                    lvgl.hide(marker.object)
                    marker.active = false
                end
            else
                lvgl.hide(value)
            end
            reset.index = reset.index + 1
        else
            reset.group, reset.index = reset.group + 1, 1
        end
    end
    return nil, true
end

function chart.refresh(context, creating)
    if creating or not context.history or context.history.failed then
        return refreshPlot(context, true)
    end
    if not context.framePhase then
        if not needsFrame(context) then
            return chart.intervalFor(context.window, context.area.w, #context.series)
        end
        context.backPlot = context.backPlot or newPlot(context)
        context.displayRoot = context.plotRoot
        exchange(context, context.backPlot, PLOT_FIELDS)
        context.armMarkers = context.armMarkers or markerPool("arm")
        context.resumeMarkers = context.resumeMarkers or markerPool("resume")
        for index, item in ipairs(context.series) do
            exchange(item, context.backPlot.series[index], SERIES_FIELDS)
            item.liveFeed = item.feed
            if item.feed then
                item.snapshot = item.snapshot or {}
                copyFields(item.feed, item.snapshot, FEED_FIELDS)
                if item.feed.available then
                    item.tailAt, item.tailValue, item.tailBroken, item.tailResumed =
                        context.history:point(item.feed, item.feed.last)
                end
            end
        end
        context.liveSession = context.session
        context.frameSession = context.frameSession or {}
        copyFields(context.session, context.frameSession, SESSION_FIELDS)
        context.frameThrough = context.frameSession.elapsed
        for _, item in ipairs(context.series) do
            if item.snapshot and item.snapshot.available and not item.snapshot.stale then
                context.frameThrough = math.min(context.frameThrough, item.tailAt)
            end
        end
        context.framePhase = "axis"
        context.axisWork = nil
        context.armMarkers.job, context.resumeMarkers.job = nil, nil
        context.frameGeometry = context.geometryVersion
        context.plotRoot:set({ w = context.rect.w, h = context.rect.h })
        context.flightRoot:set({ w = context.rect.w, h = context.rect.h })
        context.gapRoot:set({ w = context.rect.w, h = context.rect.h })
        context.gridRoot:set({ w = context.rect.w, h = context.rect.h })
        local area = context.area
        context.baseline:set({ x = area.x, y = area.y + area.h, w = area.w, h = 1 })
        return 1, true
    end

    context.session = context.frameSession
    for _, item in ipairs(context.series) do
        item.feed = item.snapshot
    end
    local done = false
    if context.framePhase == "axis" then
        if prepareAxis(context) then
            context.framePhase = "traces"
        end
    elseif context.framePhase == "traces" then
        refreshPlot(context)
        done = not context.pending and context.gridVersion == context.version
        for _, item in ipairs(context.series) do
            if item.feed and item.feed.available then
                done = done
                    and item.drawnVersion == context.version
                    and item.drawnRevision == item.feed.plotRevision
                    and item.drawnLow == item.low
                    and item.drawnHigh == item.high
            end
        end
        if done then
            context.framePhase = "flights"
        end
        done = false
    elseif context.framePhase == "flights" then
        if not updateFlights(context) then
            context.framePhase = "resumes"
        end
    elseif context.framePhase == "arms" then
        done = updateSessionMarkers(
            context,
            context.armMarkers,
            context.session.armFirst,
            context.session.armLast,
            context.session.armRevision,
            context.history.armBoundary
        )
    else
        if
            updateSessionMarkers(
                context,
                context.resumeMarkers,
                context.session.resumeFirst,
                context.session.resumeLast,
                context.session.resumeRevision,
                context.history.recordingBreak
            )
        then
            context.framePhase = "arms"
        end
    end
    context.session = context.liveSession
    for _, item in ipairs(context.series) do
        item.feed = item.liveFeed
    end
    if context.frameExpired then
        exchange(context, context.backPlot, PLOT_FIELDS)
        for index, item in ipairs(context.series) do
            exchange(item, context.backPlot.series[index], SERIES_FIELDS)
        end
        context.frameExpired, context.framePhase, context.frameSession, context.pending = nil, nil, nil, nil
        return 1, true
    end
    if done then
        lvgl.hide(context.displayRoot)
        lvgl.show(context.plotRoot)
        context.framePhase = nil
        context.frameGeometry = context.geometryVersion
        return chart.intervalFor(context.window, context.area.w, #context.series)
    end
    return 1, true
end

function chart.create(parent, rect, settings, services)
    local warnings = chart.validateSettings(settings, nil, nil, services.host and services.host.modelArmed)
    assert(#warnings == 0, table.concat(warnings, "; "))
    local context = {
        theme = services.theme,
        themeBuilder = services.themeBuilder,
        primitives = services.primitives,
        settings = settings,
        history = services.history and (services.preview and services.history:preview() or services.history),
        preview = services.preview == true,
        clock = services.clock or getTime,
        series = {},
        version = 0,
        cursor = 1,
        rect = rect,
        span = services.span,
        area = {},
        grid = {},
        gridCursor = 1,
        flightKeys = {},
    }
    local presentation = services.state("normal", settings.accent or "cyan")
    context.panel = context.primitives.panel(parent, rect, context.theme, presentation)
    context.plotHost = lvgl.box(context.panel.root, { x = 0, y = 0, w = rect.w, h = rect.h })
    context.plotRoot = lvgl.box(context.plotHost, { x = 0, y = 0, w = rect.w, h = rect.h })
    context.flightRoot = lvgl.box(context.plotRoot, { x = 0, y = 0, w = rect.w, h = rect.h })
    context.gapRoot = lvgl.box(context.plotRoot, { x = 0, y = 0, w = rect.w, h = rect.h })
    context.gridRoot = lvgl.box(context.plotRoot, { x = 0, y = 0, w = rect.w, h = rect.h })
    context.session = context.history and context.history:session(settings.armSwitch)
        or { elapsed = 0, configured = false, available = false, recording = false }
    if context.preview then
        context.previewMissing = context.session.previewMissing
    end
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
            if context.preview then
                context.previewMissing = context.previewMissing or item.feed.previewMissing
            end
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
    context.window, context.start, context.pixelStart = timeWindow(settings, 0), 0, 0
    chart.geometry(context, rect)
    text(
        context.status,
        not context.history and "HISTORY N/A"
            or context.preview and (context.previewMissing and "PREVIEW: NO DATA" or "PREVIEW")
            or not context.session.configured and "SET ARM SOURCE"
            or "",
        context.theme.color.textFaint
    )
    return context
end

function chart.update(context, rect)
    context.rect = rect
    context.legendFont, context.legendIndex, context.legendWidth = nil, nil, nil
    context.primitives.resizePanel(context.panel, rect)
    context.plotHost:set({ w = rect.w, h = rect.h })
    context.plotRoot:set({ w = rect.w, h = rect.h })
    context.flightRoot:set({ w = rect.w, h = rect.h })
    context.gapRoot:set({ w = rect.w, h = rect.h })
    context.gridRoot:set({ w = rect.w, h = rect.h })
    chart.geometry(context, rect)
    if context.framePhase then
        context.framePhase, context.pending, context.axisWork = "axis", nil, nil
        context.armMarkers.job, context.resumeMarkers.job = nil, nil
    end
    chart.refresh(context)
end

return chart
