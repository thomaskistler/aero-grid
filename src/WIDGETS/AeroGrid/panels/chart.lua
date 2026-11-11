-- SPDX-License-Identifier: GPL-2.0-only

local chart = {
    id = "chart",
    apiVersion = 1,
    supportedSpans = { "2x1", "3x1", "4x1", "2x2", "3x2", "4x2", "3x3", "4x3", "4x4" },
    refreshInterval = 20,
    refreshCost = "variable",
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
local SLOT_INSTRUCTIONS = 1700
local CALLBACK_RESERVE = 500

local function instructionAllowance(slots)
    return math.max(0, slots * SLOT_INSTRUCTIONS - CALLBACK_RESERVE)
end

local function consumedSlots(instructions)
    return math.max(1, math.ceil((instructions + CALLBACK_RESERVE) / SLOT_INSTRUCTIONS))
end

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

local function prepareAxis(context, allowance)
    local session, area = context.session, context.area
    local window, start = context.window, context.start
    local axis = context.axis
    if
        axis
        and axis.revision == session.resumeRevision
        and axis.baseStart == start
        and axis.window == window
        and axis.geometryVersion == context.geometryVersion
    then
        return true, 0
    end
    local work = context.axisWork
    if not work then
        work = { index = session.resumeLast or 0, reverse = {}, start = start, phase = "scan" }
        context.axisWork = work
    end
    -- Keep room for recorded data when fixed-width breaks crowd the axis.
    local capacity = math.max(1, area.w // (BREAK_WIDTH * 2))
    local remaining, used = allowance, 0
    while work.phase == "scan" and remaining >= 200 do
        if work.index < (session.resumeFirst or 1) or not context.history.recordingBreak then
            work.phase = "copy"
            work.copyIndex, work.breaks = #work.reverse, {}
        else
            local at = context.history:recordingBreak(context.liveSession or session, work.index)
            work.index = work.index - 1
            remaining, used = remaining - 200, used + 200
            if at and at < start then
                work.phase = "copy"
                work.copyIndex, work.breaks = #work.reverse, {}
            elseif at and at <= start + window and at ~= work.reverse[#work.reverse] then
                if #work.reverse == capacity then
                    work.start = work.reverse[#work.reverse]
                    work.phase = "copy"
                    work.copyIndex, work.breaks = #work.reverse, {}
                else
                    work.reverse[#work.reverse + 1] = at
                end
            end
        end
    end
    while work.phase == "copy" and work.copyIndex > 0 and remaining >= 100 do
        work.breaks[#work.breaks + 1] = work.reverse[work.copyIndex]
        work.copyIndex = work.copyIndex - 1
        remaining, used = remaining - 100, used + 100
    end
    if work.phase ~= "copy" or work.copyIndex > 0 or remaining < 100 then
        return false, used
    end
    local gap = math.min(BREAK_WIDTH, area.w // 2)
    if gap == 0 then
        work.breaks = {}
    end
    context.axis = {
        breaks = work.breaks,
        start = work.start,
        baseStart = start,
        window = window,
        x = area.x,
        gap = gap,
        revision = session.resumeRevision,
        geometryVersion = context.geometryVersion,
    }
    axis = context.axis
    axis.scale = (area.w - #work.breaks * axis.gap) / math.max(1, start + window - axis.start)
    context.axisWork = nil
    context.version = context.version + 1
    return true, used + 100
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

local function updateGrid(context, allowance)
    local area, start, window = context.area, context.start, context.window
    if context.gridLayoutVersion ~= context.version then
        context.gridStep = chart.gridInterval(window, area.w)
        context.gridFirst = (math.floor((context.axis and context.axis.start or start) / context.gridStep) + 1)
            * context.gridStep
        context.gridLayoutVersion = context.version
    end
    local remaining, used = allowance, 0
    -- Fill the reusable pool behind the traces without exceeding the grant.
    while remaining >= 100 do
        local index = context.gridCursor
        local line = context.grid[index]
        local cost = line and 100 or 600
        if line and line.version ~= context.version then
            local at = context.gridFirst + (index - 1) * context.gridStep
            local x = timeX(context, at)
            local visible = at < start + window and x > area.x and x < area.x + area.w
            if visible and (line.x ~= x or line.geometryVersion ~= context.geometryVersion) then
                cost = cost + 350
            end
            if visible and not line.visible or not visible and line.visible then
                cost = cost + 150
            end
        end
        if remaining < cost then
            break
        end
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
        remaining, used = remaining - cost, used + cost
        if context.gridVersion == context.version then
            return true, used
        end
    end
    return false, used
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

local function updateFlights(context, allowance)
    local session, historyService = context.session, context.history
    if
        not session
        or not historyService
        or not historyService.flight
        or (session.flightLast or 0) == 0 and not context.flightBands
    then
        return true, 0
    end
    local elapsed = session.flightActive and (context.frameThrough or session.elapsed) or 0
    if
        context.flightDrawnRevision == session.flightRevision
        and context.flightDrawnVersion == context.version
        and context.flightDrawnElapsed == elapsed
    then
        return true, 0
    end
    context.flightBands = context.flightBands or {}
    local first, last = session.flightFirst, session.flightLast
    if context.flightPassRevision ~= session.flightRevision or context.flightPassVersion ~= context.version then
        context.flightCursor = 1
        context.flightPassRevision, context.flightPassVersion = session.flightRevision, context.version
    end
    local remaining, used = allowance, 0
    while true do
        local slot = context.flightCursor or 1
        local slots = math.max(context.flightSlots or 0, math.min(historyService.FLIGHT_CAPACITY, last))
        if slot > slots then
            context.flightCursor = 1
            context.flightDrawnRevision = session.flightRevision
            context.flightDrawnVersion = context.version
            context.flightDrawnElapsed = elapsed
            return true, used
        end
        local index = first + (slot - 1 - (first - 1) % historyService.FLIGHT_CAPACITY)
            % historyService.FLIGHT_CAPACITY
        local band = context.flightBands[slot]
        local at, finish = historyService:flight(context.liveSession or session, index)
        finish = math.min(finish or session.elapsed, context.frameThrough or session.elapsed)
        local area, start, window = context.area, context.start, context.window
        local visible = at
            and finish > at
            and finish > (context.axis and context.axis.start or start)
            and at < start + window
        local left, right, key
        local cost = 200
        if visible then
            left = math.max(area.x, math.min(area.x + area.w - 1, timeX(context, at)))
            right = math.max(area.x, math.min(area.x + area.w, timeX(context, finish, true)))
            key = table.concat({ left, right, area.y, area.h }, ":")
            cost = cost
                + (band and context.flightKeys[slot] == key and 100 or 500)
            if not band then
                cost = cost + 500
            end
        elseif band and context.flightKeys[slot] then
            cost = cost + 200
        end
        if remaining < cost then
            return false, used
        end
        if visible then
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
            if context.flightKeys[slot] ~= key then
                band:set({ x = left, y = area.y, w = math.max(1, right - left), h = area.h })
                context.flightKeys[slot] = key
            end
            lvgl.show(band)
            context.flightKeys[slot] = key
        elseif band and context.flightKeys[slot] then
            lvgl.hide(band)
            context.flightKeys[slot] = nil
        end
        context.flightCursor = slot + 1
        remaining, used = remaining - cost, used + cost
    end
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

local function updateSessionMarkers(context, item, first, last, revision, readBoundary, allowance)
    local session, service = context.session, context.history
    if not service or not readBoundary then
        return true, 0
    end
    if
        item.drawnRevision == revision
        and item.drawnVersion == context.version
        and item.drawnResumeRevision == session.resumeRevision
    then
        return true, 0
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
    local remaining, used = allowance, 0
    while pass.index <= (last or 0) and remaining >= 250 do
        local at, armed = readBoundary(service, context.liveSession or session, pass.index)
        markBoundary(context, item, pass, at, armed)
        pass.index = pass.index + 1
        remaining, used = remaining - 250, used + 250
    end
    if pass.index <= (last or 0) then
        return false, used
    end
    local complete, markerUsed = applyMarkers(context, item, remaining)
    used = used + markerUsed
    if complete then
        item.drawnRevision, item.drawnVersion = revision, context.version
        item.drawnResumeRevision = session.resumeRevision
        item.marked = pass.marked
        item.job = nil
    end
    return complete, used
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

local function overflowText(builder, font, width)
    return builder.measureText(font, "...") <= width and "..." or ""
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
    local measuredMinimum = builder.measureText(font, item.minimumText or "--")
    local measuredMaximum = builder.measureText(font, item.maximumText or "--")
    local minimumWidth = math.min(budget, measuredMinimum)
    local maximumWidth = math.min(available - budget, measuredMaximum)
    local groupWidth = minimumWidth + maximumWidth + 2 * size + 14
    local left = legendX + math.floor((legendW - groupWidth) * (item.legendAlignment or 1))
    local minimumX = left + size + 3
    local maximumX = minimumX + minimumWidth + 8 + size + 3
    local height = math.max(3, math.floor(size * 2 / 3))
    local top = y + math.floor((builder.fontAscent(font) - height) / 2)
    item.extrema:set({ x = minimumX, y = y, w = minimumWidth })
    item.maximum:set({ x = maximumX, y = y, w = maximumWidth })
    local minimum, maximum = item.minimumText or "--", item.maximumText or "--"
    if measuredMinimum > minimumWidth then
        minimum = overflowText(builder, font, minimumWidth)
    end
    if measuredMaximum > maximumWidth then
        maximum = overflowText(builder, font, maximumWidth)
    end
    if item.minimumText then
        text(item.extrema, minimum, context.theme.color.textFaint)
        text(item.maximum, maximum, context.theme.color.textFaint)
    end
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
    local measuredValue, measuredUnit = width, builder.measureText(font, item.unitText or "")
    local unitWidth = math.min(
        context.topLegend and math.max(0, legendW - math.min(width, legendW)) or context.unitWidth,
        measuredUnit
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
    local value, unit = item.valueText or "--", item.unitText or ""
    if measuredValue > width then
        value = overflowText(builder, font, width)
    end
    if measuredUnit > unitWidth then
        unit = overflowText(builder, font, unitWidth)
    end
    if item.valueText then
        text(item.value, value, item.readingColor or context.theme.color.text)
        text(item.unit, unit, item.readingColor or context.theme.color.text)
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
    local legendLimit = context.plotWidth and math.max(0, content - context.plotWidth - gap) or math.floor(content / 2)
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
            if width <= (context.topLegend and cellWidth or legendLimit) or candidate == SMLSIZE then
                font, required, context.legendIndex = candidate, width, index
                break
            end
        end
    end
    context.legendFont, context.legendWidth = font, required
    context.extremaFont = extremaFont(font)
    local legend = math.min(
        required,
        context.topLegend and cellWidth or context.plotWidth and legendLimit or math.max(24, content - 28)
    )
    local valueWidth, unitWidth = readingWidths(context, font)
    context.requiredValueWidth, context.requiredUnitWidth = valueWidth, unitWidth
    context.unitWidth = math.min(unitWidth, math.max(0, legend - 27))
    context.valueWidth = math.min(valueWidth, math.max(0, legend - context.unitWidth - 4))
    local nameWidth = math.max(0, legend - context.valueWidth - context.unitWidth - 4)
    local width = context.topLegend and content or context.plotWidth or math.max(1, content - legend - gap)
    context.plotWidth = width
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

applyMarkers = function(context, item, allowance)
    local job = item.job
    local remaining, used = allowance, 0
    while remaining >= 100 do
        local keys = item.markerPhase == "hide" and item.markerKeys or job.markerColumns
        local key = keys[item.markerIndex]
        local cost = 100
        if not key then
            if item.markerPhase == "show" then
                return true, used
            end
            item.markerPhase, item.markerIndex = "show", 1
        else
            local column = math.abs(key)
            local marker = item.markers[key]
            if item.markerPhase == "hide" then
                if marker and marker.active and not job.marked[key] then
                    cost = cost + 200
                end
            elseif
                not marker
                or marker.geometryVersion ~= job.geometryVersion
                or item.style == "arm" and marker.footerLeft ~= context.durationLeft
            then
                cost = cost + 500
            elseif not marker.active then
                cost = cost + 150
            end
            if remaining < cost then
                return false, used
            end
            if item.markerPhase == "hide" then
                if marker and marker.active and not job.marked[key] then
                    lvgl.hide(marker.object)
                    marker.active = false
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
            elseif not marker.active then
                showMarker(marker)
            end
            item.markerIndex = item.markerIndex + 1
        end
        if key then
            remaining, used = remaining - cost, used + cost
        else
            remaining, used = remaining - 100, used + 100
        end
    end
    return false, used
end

local function applyConnector(context, item, run, allowance)
    local remaining, used = allowance, 0
    if not run.connector then
        if remaining < 500 then
            return false, used
        end
        run.connector = lvgl.box(context.plotRoot, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
        run.dots = {}
        remaining, used = remaining - 500, used + 500
    elseif run.dotIndex == 1 then
        if remaining < 250 then
            return false, used
        end
        run.connector:set({ w = context.rect.w, h = context.rect.h })
        remaining, used = remaining - 250, used + 250
    end
    local first, last = run.pts[1], run.pts[run.size]
    if not run.dotCount then
        run.dotCount = math.max(1, math.ceil(math.sqrt((last[1] - first[1]) ^ 2 + (last[2] - first[2]) ^ 2) / 3)) + 1
    end
    while true do
        local index = run.dotIndex
        if index > math.max(run.dotCount, #run.dots) then
            if remaining < 100 then
                return false, used
            end
            lvgl.show(run.connector)
            return true, used + 100
        end
        local dot = run.dots[index]
        local cost = index <= run.dotCount and (dot and 200 or 300) or 100
        if remaining < cost then
            return false, used
        end
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
        remaining, used = remaining - cost, used + cost
    end
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
        item.readingColor = feed and feed.stale and context.theme.color.textFaint or context.theme.color.text
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

local function plotStatus(context)
    if not context.history or context.history.failed then
        return "HISTORY N/A"
    elseif context.preview then
        return context.previewMissing and "PREVIEW: NO DATA" or "PREVIEW"
    elseif not context.session.configured then
        return "SET ARM SOURCE"
    elseif #context.series == 0 then
        return "ADD METRICS"
    end
    local available, full = false, false
    for _, item in ipairs(context.series) do
        available = available or item.feed and item.feed.available
        full = full or item.feed and item.feed.full
    end
    if full then
        return "HISTORY FULL"
    elseif not context.session.available and not context.session.recording then
        return "ARM N/A"
    elseif not available then
        return context.session.recording and "NO DATA" or "WAITING FOR ARM"
    end
    return ""
end

--- Retire the current native presentation in bounded batches.
function chart.resetSession(context, slots)
    local reset = context.resetWork
    if not reset then
        if context.mipmapRenderer then
            context.mipmapRenderer:reset()
        end
        context.mipmapDecorating, context.frameThrough = nil, nil
        context.connectorWork, context.axis, context.axisWork = nil, nil, nil
        context.viewWork, context.viewReady = nil, nil
        context.projectionTurn, context.rangesReady = nil, false
        context.flightPassRevision, context.flightDrawnRevision = nil, nil
        reset = { groups = {}, group = 1, index = 1 }
        context.resetWork = reset
        local function markers(pool)
            if pool then
                pool.job, pool.drawnRevision, pool.drawnVersion = nil, nil, nil
                reset.groups[#reset.groups + 1] = { pool = pool, kind = "markers", keys = pool.markerKeys }
            end
        end
        reset.groups[#reset.groups + 1] = { kind = "flights", keys = context.flightBands or {} }
        markers(context.armMarkers)
        markers(context.resumeMarkers)
        for _, item in ipairs(context.series) do
            reset.groups[#reset.groups + 1] = { kind = "connectors", keys = item.connectors }
        end
    end
    local remaining, used = instructionAllowance(slots or 1), 0
    while remaining >= 100 do
        local group = reset.groups[reset.group]
        if not group then
            context.resetWork = nil
            return nil, nil, consumedSlots(used)
        end
        local value = group.keys[reset.index]
        if value then
            local marker, cost
            if group.kind == "connectors" then
                cost = value.connector and 150 or 50
            elseif group.kind == "markers" then
                marker = group.pool.markers[value]
                cost = marker.active and 150 or 50
            else
                cost = 150
            end
            if remaining < cost then
                break
            end
            if group.kind == "connectors" then
                if value.connector then
                    lvgl.hide(value.connector)
                end
            elseif group.kind == "markers" then
                if marker.active then
                    lvgl.hide(marker.object)
                    marker.active = false
                end
            else
                lvgl.hide(value)
            end
            reset.index = reset.index + 1
            remaining, used = remaining - cost, used + cost
        else
            reset.group, reset.index = reset.group + 1, 1
        end
    end
    return nil, true, consumedSlots(used)
end

local function publishMipmap(context)
    -- Native dashed lines shift their phase under partial invalidation.
    -- Invalidate the complete plot once all envelopes and overlays are ready.
    lvgl.hide(context.plotRoot)
    lvgl.show(context.plotRoot)
    context.mipmapDecorating, context.frameThrough = nil, nil
    return chart.intervalFor(context.window, context.area.w, #context.series)
end

local function finishMipmap(context, allowance)
    local remaining, used = allowance, 0
    for series = 1, #context.series do
        if not context.mipmapRenderer.published[series] then
            context.mipmapDecorating, context.frameThrough = nil, nil
            return 1, true, 0
        end
    end
    if not context.frameThrough then
        context.frameThrough = context.session.elapsed
        for series, job in ipairs(context.mipmapRenderer.published) do
            local feed = context.series[series].feed
            if feed.available and not feed.stale and job.at then
                context.frameThrough =
                    math.min(context.frameThrough, job.at + context.mipmapConsumers[series].startedAt)
            end
        end
    end
    local complete, stageUsed = updateFlights(context, remaining)
    remaining, used = remaining - stageUsed, used + stageUsed
    if not complete then
        return 1, true, used
    end
    context.armMarkers = context.armMarkers or markerPool("arm")
    complete, stageUsed = updateSessionMarkers(
        context,
        context.armMarkers,
        context.session.armFirst,
        context.session.armLast,
        context.session.armRevision,
        context.history.armBoundary,
        remaining
    )
    remaining, used = remaining - stageUsed, used + stageUsed
    if not complete then
        return 1, true, used
    end
    for series, item in ipairs(context.series) do
        local map = context.mipmapRenderer.published[series].map
        if
            item.drawnBreakMap ~= map
            or item.drawnBreak ~= map.breakLast
            or item.drawnBreakVersion ~= context.version
        then
            if not item.job then
                item.job = {
                    index = map.breakFirst,
                    marked = {},
                    markerColumns = {},
                    geometryVersion = context.geometryVersion,
                    area = context.area,
                }
                item.markerIndex, item.markerPhase = 1, "hide"
            end
            local pass = item.job
            while pass.index <= map.breakLast and remaining >= 250 do
                markBoundary(context, item, pass, map.breaks[(pass.index - 1) % map.width + 1])
                pass.index = pass.index + 1
                remaining, used = remaining - 250, used + 250
            end
            if pass.index <= map.breakLast then
                return 1, true, used
            end
            complete, stageUsed = applyMarkers(context, item, remaining)
            remaining, used = remaining - stageUsed, used + stageUsed
            if complete then
                item.drawnBreakMap, item.drawnBreak, item.drawnBreakVersion =
                    map, map.breakLast, context.version
                item.job = nil
            else
                return 1, true, used
            end
        end
    end
    if context.axis then
        context.resumeMarkers = context.resumeMarkers or markerPool("resume")
        complete, stageUsed = updateSessionMarkers(
            context,
            context.resumeMarkers,
            context.session.resumeFirst,
            context.session.resumeLast,
            context.session.resumeRevision,
            context.history.recordingBreak,
            remaining
        )
        remaining, used = remaining - stageUsed, used + stageUsed
        if not complete then
            return 1, true, used
        end
    else
        if remaining < 250 then
            return 1, true, used
        end
        return publishMipmap(context), false, used + 250
    end
    local work = context.connectorWork
    if not work then
        work = { series = 1, index = 1 }
        context.connectorWork = work
    end
    while work.series <= #context.series do
        local item = context.series[work.series]
        local published = context.mipmapRenderer.published[work.series]
        local source = published and published.map.connectors or {}
        local saved = item.connectors[work.index]
        local values = source[work.index]
        if values then
            if not work.prepared then
                if remaining < 150 then
                    return 1, true, used
                end
                saved = saved or { dots = {} }
                item.connectors[work.index] = saved
                local function y(value)
                    local fraction =
                        math.max(0, math.min(1, (value - published.low) / (published.high - published.low)))
                    return context.area.y + math.floor((1 - fraction) * context.area.h + 0.5)
                end
                saved.pts = {
                    { context.area.x + math.floor(values[1] + 0.5), y(values[2]) },
                    { context.area.x + math.floor(values[3] + 0.5), y(values[4]) },
                }
                saved.size, saved.dotIndex, saved.dotCount = 2, 1, nil
                work.prepared = true
                remaining, used = remaining - 150, used + 150
            end
            complete, stageUsed = applyConnector(context, item, saved, remaining)
            remaining, used = remaining - stageUsed, used + stageUsed
            if not complete then
                return 1, true, used
            end
            work.index, work.prepared = work.index + 1, nil
        elseif saved then
            if saved.connector and remaining >= 150 then
                lvgl.hide(saved.connector)
                used, remaining = used + 150, remaining - 150
            elseif saved.connector then
                return 1, true, used
            end
            work.index = work.index + 1
        elseif values == nil and saved == nil then
            work.series, work.index = work.series + 1, 1
        end
    end
    context.connectorWork = nil
    if remaining < 250 then
        return 1, true, used
    end
    return publishMipmap(context), false, used + 250
end

local function refreshMipmap(context, slots)
    local remaining, used = instructionAllowance(slots), 0
    if not context.mipmapRenderer then
        if remaining < 500 then
            return 1, true, consumedSlots(used)
        end
        context.mipmapRenderer = context.mipmapRendererModule.new(context)
        remaining, used = remaining - 500, used + 500
    end
    local renderer = context.mipmapRenderer
    if not context.mipmapPrepared then
        local complete, stageUsed = renderer:prepare(remaining)
        remaining, used = remaining - stageUsed, used + stageUsed
        if not complete then
            return 1, true, consumedSlots(used)
        end
        context.mipmapPrepared = true
    end
    if context.mipmapDecorating then
        local interval, unfinished, stageUsed = finishMipmap(context, remaining)
        return interval, unfinished, consumedSlots(used + stageUsed)
    end
    local readings = not renderer.jobs
        and not context.viewWork
        and not context.viewReady
        and not context.projectionTurn
        and chart.render(context)
    context.projectionTurn = false
    if readings or not context.rangesReady then
        chart.ranges(context)
        context.rangesReady = true
    end
    local owner = context.mipmapConsumers[1]
    local at = math.max(0, context.session.elapsed - owner.startedAt)
    local level, origin = owner.map:select(at)
    local window = owner.map.levels[level].span
    if owner.readonly then
        window = owner.window or 6000
        if not owner.window then
            local selected = 0
            while selected < 10 and at >= window do
                selected, window = selected + 1, window * (4 / 3)
            end
        end
        origin = at >= window and ((((at - window) / (window / 4)) // 1 + 1) * renderer.width / 4) // 1 or 0
    end
    local start = owner.startedAt + origin * window / renderer.width
    if not context.viewWork and not context.viewReady and (context.window ~= window or context.start ~= start) then
        context.window, context.start = window, start
        context.axis = nil
        context.version = context.version + 1
    end
    if (context.session.resumeLast or 0) > 0 then
        local axisReady, stageUsed = prepareAxis(context, remaining)
        remaining, used = remaining - stageUsed, used + stageUsed
        if not axisReady then
            return 1, true, consumedSlots(used)
        end
    end
    if not renderer.jobs and (context.axis or context.mipmapReadonly) and not context.viewReady then
        local work = context.viewWork
        if not work or work.axis ~= context.axis or work.geometry ~= context.geometryVersion then
            work = { index = 1, axis = context.axis, version = context.version, geometry = context.geometryVersion }
            context.viewWork = work
            for _, consumer in ipairs(context.mipmapConsumers) do
                consumer.viewJob = nil
                consumer.viewWindow, consumer.viewOrigin = context.window, origin
                consumer:prepareView(work.axis, work.version)
            end
        end
        while context.mipmapConsumers[work.index] do
            local consumer = context.mipmapConsumers[work.index]
            local complete, stageUsed = consumer:view(work.axis, work.version, remaining)
            remaining, used = remaining - stageUsed, used + stageUsed
            if complete then
                work.index = work.index + 1
            else
                return 1, true, consumedSlots(used)
            end
        end
        context.viewReady, context.viewWork = true, nil
    end
    local geometry = context.geometryVersion
    if renderer.jobs then
        for series, job in ipairs(renderer.jobs) do
            local item, consumer = context.series[series], context.mipmapConsumers[series]
            local map = consumer.output or consumer.map
            local selected, selectedOrigin = map:select(map.pinned and 0 or at)
            if
                job.map ~= map
                or job.level ~= selected
                or job.origin ~= selectedOrigin
                or job.geometry ~= geometry
                or job.low ~= item.low
                or job.high ~= item.high
            then
                renderer.jobs = nil
                context.viewReady = nil
                break
            end
        end
    end
    updateHeader(context)
    text(context.status, plotStatus(context), context.theme.color.textFaint)
    if readings then
        context.projectionTurn = true
        return 1, true, consumedSlots(used + 1)
    end
    if context.gridVersion ~= context.version then
        local complete, stageUsed = updateGrid(context, remaining)
        remaining, used = remaining - stageUsed, used + stageUsed
        if not complete then
            return 1, true, consumedSlots(used)
        end
    end
    local complete, estimated = renderer:step(remaining)
    remaining, used = remaining - estimated, used + estimated
    if not complete then
        return 1, true, consumedSlots(used)
    end
    context.viewReady = nil
    context.mipmapDecorating, context.frameThrough = true, nil
    local interval, unfinished, stageUsed = finishMipmap(context, remaining)
    return interval, unfinished, consumedSlots(used + stageUsed)
end

local function refreshChart(context, creating, slots)
    if
        context.mipmapReadonly
        and not context.preview
        and context.history.observeSamples
        and context.mipmapConsumers
        and context.mipmapConsumers[1].history ~= context.history
    then
        for _, owner in ipairs(context.mipmapConsumers) do
            owner:destroy()
        end
        context.mipmapConsumers, context.mipmapReadonly = nil, nil
        context.mipmapSetup = context.mipmapModule
        context.viewWork, context.viewReady = nil, nil
        if context.mipmapRenderer then
            context.mipmapRenderer.jobs = nil
        end
    end
    if context.mipmapSetup then
        if slots < 3 then
            return 1, true, 0
        end
        chart.geometry(context, context.rect)
        context.mipmapConsumers = {}
        for index, item in ipairs(context.series) do
            context.mipmapConsumers[index] =
                context.mipmapSetup.attach(context.history, item.feed, context.area.w // 1, {
                    window = context.settings.timeRange == "rolling" and timeWindow(context.settings, 0) or nil,
                    preview = context.preview,
                })
            context.mipmapReadonly = context.mipmapReadonly or context.mipmapConsumers[index].readonly
        end
        context.mipmapSetup = nil
        return 1, true, 3
    end
    if creating or not context.history or context.history.failed or #context.series == 0 then
        chart.render(context)
        updateHeader(context)
        text(context.status, plotStatus(context), context.theme.color.textFaint)
        return 20
    end
    for _, owner in ipairs(context.mipmapConsumers) do
        if owner.rebuildJob then
            local _, used = owner:step(instructionAllowance(slots))
            return 1, not context.host, consumedSlots(used)
        end
    end
    return refreshMipmap(context, slots)
end

function chart.refresh(context, creating, slots)
    local interval, unfinished, consumed = refreshChart(context, creating, slots or 8)
    return interval, unfinished, consumed or 1
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
        host = services.host,
        mipmapModule = services.chartMipmap,
        mipmapRendererModule = services.chartMipmapRenderer,
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
        armMarkers = markerPool("arm"),
        resumeMarkers = markerPool("resume"),
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
            connectors = {},
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
    if context.history and #context.series > 0 then
        context.mipmapSetup = assert(services.chartMipmap, "chart mipmap runtime unavailable")
        assert(context.mipmapRendererModule, "chart mipmap renderer runtime unavailable")
    else
        chart.geometry(context, rect)
    end
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
    if context.mipmapSetup then
        context.rect = rect
        chart.refresh(context)
        return
    end
    local resized = rect.w ~= context.rect.w or rect.h ~= context.rect.h
    if resized then
        context.plotWidth = nil
    end
    context.rect = rect
    context.legendFont, context.legendIndex, context.legendWidth = nil, nil, nil
    context.primitives.resizePanel(context.panel, rect)
    context.plotHost:set({ w = rect.w, h = rect.h })
    context.plotRoot:set({ w = rect.w, h = rect.h })
    context.flightRoot:set({ w = rect.w, h = rect.h })
    context.gapRoot:set({ w = rect.w, h = rect.h })
    context.gridRoot:set({ w = rect.w, h = rect.h })
    chart.geometry(context, rect)
    if resized and context.mipmapConsumers then
        if context.mipmapRenderer then
            context.mipmapRenderer:destroy()
            context.mipmapRenderer, context.mipmapPrepared = nil, nil
        end
        context.mipmapDecorating, context.frameThrough = nil, nil
        for _, consumer in ipairs(context.mipmapConsumers) do
            consumer:restart(context.area.w // 1, context.session.elapsed)
        end
    end
    context.axisWork, context.connectorWork, context.viewWork, context.viewReady = nil, nil, nil, nil
    if context.armMarkers then
        context.armMarkers.job = nil
    end
    if context.resumeMarkers then
        context.resumeMarkers.job = nil
    end
    if not resized then
        chart.refresh(context)
    end
end

function chart.destroy(context)
    context.mipmapDecorating, context.frameThrough = nil, nil
    if context.mipmapRenderer then
        context.mipmapRenderer:destroy()
        context.mipmapRenderer = nil
    end
    if context.mipmapConsumers then
        for _, consumer in ipairs(context.mipmapConsumers) do
            consumer:destroy()
        end
        context.mipmapConsumers = nil
    end
end

return chart
