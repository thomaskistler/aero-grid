-- SPDX-License-Identifier: GPL-2.0-only

local chart = {
    id = "chart",
    apiVersion = 1,
    supportedSpans = { "2x1", "3x1", "4x1", "2x2", "3x2", "4x2", "3x3", "4x3", "4x4" },
    refreshInterval = 20,
    refreshCost = "variable",
    independentRefresh = true,
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
            default = "fixed",
            visibleWhen = function()
                return false
            end,
        },
        {
            -- Whole minutes; unset grows automatically (see layout.normalizePanel).
            key = "duration",
            label = "Window minutes",
            type = "number",
            min = 1,
            max = 60,
            step = 1,
            empty = "Auto",
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

local COLORS = { "cyan", "orange", "green" }
local LEGEND_FONTS = { MIDSIZE, 0, SMLSIZE }
local textCache = setmetatable({}, { __mode = "k" })

local function timeWindow(settings)
    return (type(settings.duration) == "number" and settings.duration or 1) * 6000
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
    local duration = settings.duration
    if duration ~= nil and not (finite(duration) and duration % 1 == 0 and duration >= 1 and duration <= 60) then
        warnings[#warnings + 1] = "duration must be whole minutes from 1 to 60, or unset for automatic"
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
local SLOT_INSTRUCTIONS = 1600
local CALLBACK_RESERVE = 900

local function instructionAllowance(slots)
    return math.max(0, slots * SLOT_INSTRUCTIONS - CALLBACK_RESERVE)
end

local function consumedSlots(instructions)
    return math.max(1, math.ceil((instructions + CALLBACK_RESERVE) / SLOT_INSTRUCTIONS))
end

-- Plot state owned by one layer. Auto windows prepare the next window in a
-- hidden layer with the same staged pipeline, then swap the layers.
local LAYER_KEYS = {
    "layerHost",
    "plotRoot",
    "flightRoot",
    "gapRoot",
    "gridRoot",
    "columnConsumers",
    "columnRenderer",
    "axis",
    "axisWork",
    "window",
    "start",
    "pixelStart",
    "version",
    "frameThrough",
    "columnsDecorating",
    "connectorWork",
    "grid",
    "gridCursor",
    "gridVersion",
    "gridLayoutVersion",
    "gridStep",
    "gridFirst",
    "flightBands",
    "flightKeys",
    "flightCursor",
    "flightSlots",
    "flightPassRevision",
    "flightPassVersion",
    "flightDrawnRevision",
    "flightDrawnVersion",
    "flightDrawnElapsed",
    "armMarkers",
    "resumeMarkers",
    "paintedVersion",
    "paintedArmRevision",
    "paintedResumeRevision",
    "paintedFlightRevision",
}
local ITEM_KEYS = {
    "connectors",
    "markers",
    "markerKeys",
    "job",
    "markerIndex",
    "markerPhase",
    "marked",
    "drawnBreakMap",
    "drawnBreak",
    "drawnBreakVersion",
    "paintedBreakMap",
    "paintedBreak",
    "drawnRevision",
    "drawnVersion",
    "drawnResumeRevision",
    "low",
    "high",
}
local LAYER_KEY, ITEM_KEY = {}, {}
for _, key in ipairs(LAYER_KEYS) do
    LAYER_KEY[key] = true
end
for _, key in ipairs(ITEM_KEYS) do
    ITEM_KEY[key] = true
end

--- A hidden layer reads shared chart state through `context` but keeps its own
--- plot state; writes always stay on the view.
local function layerView(context, view)
    setmetatable(view, {
        __index = function(_, key)
            if LAYER_KEY[key] then
                return nil
            end
            return context[key]
        end,
    })
    local series = rawget(view, "series") or {}
    rawset(view, "series", series)
    for index, item in ipairs(context.series) do
        series[index] = setmetatable(series[index] or { connectors = {}, markers = {}, markerKeys = {} }, {
            __index = function(_, key)
                if ITEM_KEY[key] then
                    return nil
                end
                return item[key]
            end,
        })
    end
    return view
end

local function axisPosition(axis, at, before)
    if axis.map then
        return axis.x + axis.map:pixel(at, before)
    end
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
    if context.axis and (context.axis.map or #context.axis.breaks > 0) then
        return math.floor(axisPosition(context.axis, at, before) + 0.5)
    end
    return context.area.x + math.floor((at - context.start) / context.window * context.area.w + 0.5)
end

local function prepareAxis(context, allowance)
    local session, area = context.session, context.area
    local window, start = context.window, context.start
    local axis = context.axis
    local owner = context.columnConsumers and context.columnConsumers[1]
    if owner and owner.map.recording then
        local map = owner.map
        if not axis or axis.map ~= map or axis.geometryVersion ~= context.geometryVersion then
            context.axis = {
                map = map,
                x = area.x,
                gap = area.w >= map.breakWidth and map.breakWidth or 0,
                scale = area.w / window,
                start = start,
                baseStart = start,
                window = window,
                breaks = {},
                revision = session.resumeRevision,
                geometryVersion = context.geometryVersion,
            }
        else
            if axis.revision ~= session.resumeRevision then
                context.gridVersion, context.gridLayoutVersion = nil, nil
                for _, line in ipairs(context.grid) do
                    line.version = nil
                end
            end
            axis.revision = session.resumeRevision
        end
        return true, 0
    end
    return true, 0
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
        local index = first + (slot - 1 - (first - 1) % historyService.FLIGHT_CAPACITY) % historyService.FLIGHT_CAPACITY
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
            cost = cost + (band and context.flightKeys[slot] == key and 100 or 500)
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
    local fixed = context.axis and context.axis.map
    if
        not at
        or not fixed
            and (at < (context.axis and context.axis.start or context.start) or at > context.start + context.window)
    then
        return
    end
    local x = timeX(context, at, item.style == "resume" or item.style == "arm" and not armed)
    if
        fixed
        and (
            x >= context.area.x + context.area.w
            or x + (item.style == "resume" and context.axis.gap or 0) < context.area.x
            or item.style == "resume" and x + context.axis.gap == context.area.x
        )
    then
        return
    end
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

local function measuredText(context, item, key, font, value)
    local cache = item.textMeasurements
    if not cache then
        cache = {}
        item.textMeasurements = cache
    end
    local saved = cache[key]
    if not saved or saved.font ~= font or saved.text ~= value then
        saved = { font = font, text = value, width = context.themeBuilder.measureText(font, value) }
        cache[key] = saved
    end
    return saved.width
end

local function extremaWidth(context, item, font)
    local builder = context.themeBuilder
    return 2
            * math.max(
                measuredText(context, item, "minimum", font, item.minimumText or "--"),
                measuredText(context, item, "maximum", font, item.maximumText or "--")
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
    local measuredMinimum = measuredText(context, item, "minimum", font, item.minimumText or "--")
    local measuredMaximum = measuredText(context, item, "maximum", font, item.maximumText or "--")
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
        local valueWidth = measuredText(context, item, "value", font, item.valueText or "--")
        local unitWidth = measuredText(context, item, "unit", font, item.unitText or "")
        local nameWidth = math.min(nameLimit, measuredText(context, item, "caption", font, item.caption))
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
    local width = measuredText(context, item, "value", font, item.valueText or "--")
    local measuredValue, measuredUnit = width, measuredText(context, item, "unit", font, item.unitText or "")
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
    local nameWidth = math.min(nameBudget, measuredText(context, item, "name", font, item.nameText or ""))
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
            local value = math.min(measuredText(context, item, "value", font, item.valueText or "--"), legend)
            local unit =
                math.min(measuredText(context, item, "unit", font, item.unitText or ""), math.max(0, legend - value))
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

local function valueRange(minimum, maximum)
    local low, high = minimum or -1000, maximum or 1000
    if high <= low then
        if minimum ~= nil and maximum == nil then
            high = low + 100
        elseif maximum ~= nil and minimum == nil then
            low = high - 100
        end
    end
    return low, high
end

function chart.ranges(context)
    local minimum, maximum
    local independent = context.settings.scaling == "independent"
    for _, item in ipairs(context.series) do
        local settings = item.settings
        if independent then
            item.fixedLow, item.fixedHigh = settings.rangeMin, settings.rangeMax
        else
            if settings.rangeMin ~= nil then
                minimum = minimum and math.min(minimum, settings.rangeMin) or settings.rangeMin
            end
            if settings.rangeMax ~= nil then
                maximum = maximum and math.max(maximum, settings.rangeMax) or settings.rangeMax
            end
        end
    end
    for _, item in ipairs(context.series) do
        if not independent then
            item.fixedLow, item.fixedHigh = minimum, maximum
        end
        if not item.rangeSeeded or not item.low then
            -- Provisional until the first reading seeds automatic bounds.
            item.low, item.high = valueRange(item.fixedLow, item.fixedHigh)
        else
            item.low, item.high = item.fixedLow or item.low, item.fixedHigh or item.high
        end
    end
end

--- Grow automatic bounds to fit `dataLow`..`dataHigh` with headroom: the span at
--- least doubles and covers the data with 25% to spare. Configured sides stay.
function chart.growRange(low, high, dataLow, dataHigh, fixedLow, fixedHigh)
    if fixedLow and fixedHigh then
        return fixedLow, fixedHigh
    end
    local needLow = fixedLow or math.min(low or dataLow, dataLow)
    local needHigh = fixedHigh or math.max(high or dataHigh, dataHigh)
    local need = math.max(0, needHigh - needLow)
    local span =
        math.max(2 * (low and high - low or 0), 1.25 * need, math.abs(needLow) * 0.1, math.abs(needHigh) * 0.1, 0.1)
    local extra = span - need
    if fixedLow then
        needHigh = needHigh + extra
    elseif fixedHigh then
        needLow = needLow - extra
    else
        needLow, needHigh = needLow - extra / 2, needHigh + extra / 2
    end
    local step = 10 ^ (math.floor(math.log(span, 10)) - 1)
    return fixedLow or math.floor(needLow / step) * step, fixedHigh or math.ceil(needHigh / step) * step
end

local function outside(item, low, high, map)
    return map.minimum ~= nil and (not item.fixedLow and map.minimum < low or not item.fixedHigh and map.maximum > high)
end

--- Seed automatic bounds from the first readings, before anything is drawn, and
--- request a background rescale once drawn data leaves the current bounds.
local function checkRange(context, series, map)
    local consumers, auto = context.columnConsumers, context.auto
    local resets = 0
    for _, owner in ipairs(consumers) do
        resets = resets + (owner.resets or 0)
    end
    if context.rangeResets ~= resets then
        -- A session reset or resize clears the plot, so bounds are seeded again.
        context.rangeResets = resets
        for _, item in ipairs(context.series) do
            item.rangeSeeded = nil
        end
    end
    local item = context.series[series]
    if map.minimum == nil or item.fixedLow and item.fixedHigh then
        return
    end
    if not item.rangeSeeded then
        local independent = context.settings.scaling == "independent"
        for index, other in ipairs(context.series) do
            if independent and index == series or not independent and not other.rangeSeeded then
                other.low, other.high =
                    chart.growRange(nil, nil, map.minimum, map.maximum, other.fixedLow, other.fixedHigh)
                other.rangeSeeded = true
            end
        end
    elseif auto and not (auto.job and auto.job.kind == "range") and outside(item, item.low, item.high, map) then
        -- A rebuild in progress checks its own targets against new data.
        auto.rangeRequest = true
    end
end

--- Bounds the hidden layer is drawn at for a range rescale.
local function rangeTargets(context, consumers)
    local targets, independent = {}, context.settings.scaling == "independent"
    local low, high
    for index, item in ipairs(context.series) do
        local map = consumers[index].map
        if independent then
            local from, to = item.low, item.high
            if outside(item, from, to, map) then
                from, to = chart.growRange(from, to, map.minimum, map.maximum, item.fixedLow, item.fixedHigh)
            end
            targets[index] = { from, to }
        elseif map.minimum then
            low = low and math.min(low, map.minimum) or map.minimum
            high = high and math.max(high, map.maximum) or map.maximum
        end
    end
    if not independent then
        local item = context.series[1]
        local from, to = item.low, item.high
        if low then
            from, to = chart.growRange(from, to, low, high, item.fixedLow, item.fixedHigh)
        end
        for index in ipairs(context.series) do
            targets[index] = { from, to }
        end
    end
    return targets
end

local function positionBreak(context, marker, job, column)
    local area = job.area
    local width = context.axis.gap
    local x = math.max(area.x, math.min(area.x + area.w - width, area.x + column - 1))
    if context.axis.map then
        x = math.max(area.x, area.x + column - 1)
        width = math.min(area.x + area.w, area.x + column - 1 + width) - x
    end
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
            local column = item.style == "arm" and math.abs(key) or key
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

-- Pause connectors are one faint solid line in the series color.
local CONNECTOR_OPACITY = 128

local function applyConnector(context, item, run, allowance)
    local cost = run.connector and 200 or 300
    if allowance < cost then
        return false, 0
    end
    local options = { pts = { run.pts[1], run.pts[run.size] }, color = item.color, opacity = CONNECTOR_OPACITY }
    if run.connector then
        run.connector:set(options)
        lvgl.show(run.connector)
    else
        options.thickness = 1
        run.connector = lvgl.line(context.plotRoot, options)
    end
    return true, cost
end

function chart.intervalFor(window, pixels, sources)
    local perPixel = math.max(20, math.min(100, math.floor(window / math.max(1, pixels))))
    return math.max(5, math.floor(perPixel / math.max(1, sources)))
end

function chart.render(context)
    local geometryChanged = context.readingGeometry ~= context.geometryVersion
    local changed = geometryChanged
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
    local visibleChanged = geometryChanged
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
        local unitText = value ~= "--" and unit or ""
        local color = feed and feed.stale and context.theme.color.textFaint or context.theme.color.text
        visibleChanged = visibleChanged
            or item.valueText ~= value
            or item.unitText ~= unitText
            or item.readingColor ~= color
            or item.rangeMinimum ~= (feed and feed.min)
            or item.rangeMaximum ~= (feed and feed.max)
        item.rangeMinimum, item.rangeMaximum = feed and feed.min, feed and feed.max
        item.valueText, item.unitText = value, unitText
        item.readout = value .. item.unitText
        local minimumText = chart.format(feed and feed.min, precision)
        local maximumText = chart.format(feed and feed.max, precision)
        if item.minimumText ~= minimumText or item.maximumText ~= maximumText then
            item.extremaDirty = true
            visibleChanged = true
        end
        item.minimumText, item.maximumText = minimumText, maximumText
        item.readingColor = color
    end
    if not visibleChanged then
        return false
    end
    local textOnly = not geometryChanged
    for _, item in ipairs(context.series) do
        local measurements = item.textMeasurements
        local previousValue = measurements and measurements.value
        local previousUnit = measurements and measurements.unit
        local valueWidth = previousValue and previousValue.width
        local unitWidth = previousUnit and previousUnit.width
        textOnly = textOnly
            and not item.extremaDirty
            and valueWidth == measuredText(context, item, "value", font, item.valueText or "--")
            and unitWidth == measuredText(context, item, "unit", font, item.unitText or "")
            and item.valueText ~= "--"
            and valueWidth <= item.valueWidth
            and unitWidth <= item.unitWidth
    end
    if textOnly then
        for _, item in ipairs(context.series) do
            text(item.value, item.valueText, item.readingColor)
            text(item.unit, item.unitText, item.readingColor)
        end
        return true, true
    end
    for _, item in ipairs(context.series) do
        width = math.max(width, context.showExtrema and extremaWidth(context, item, context.extremaFont) or 0)
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
    context.metadataReady = nil
    if context.auto then
        context.auto.wakeAt = nil
    end
    local reset = context.resetWork
    if not reset then
        if context.columnRenderer then
            context.columnRenderer:reset()
        end
        context.columnsDecorating, context.frameThrough = nil, nil
        context.connectorWork, context.axis, context.axisWork = nil, nil, nil
        context.rangesReady = false
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

local function publishColumns(context)
    context.metadataReady = nil
    -- Native dashed lines shift their phase under partial invalidation.
    -- Only changed overlays need a complete invalidation, not ordinary appends.
    local session = context.session
    local invalidate = context.paintedVersion ~= context.version
        or not (context.axis and context.axis.map) and (context.paintedArmRevision ~= session.armRevision or context.paintedResumeRevision ~= session.resumeRevision)
        or context.paintedFlightRevision ~= session.flightRevision
    for _, item in ipairs(context.series) do
        invalidate = invalidate or item.paintedBreakMap ~= item.drawnBreakMap or item.paintedBreak ~= item.drawnBreak
        item.paintedBreakMap, item.paintedBreak = item.drawnBreakMap, item.drawnBreak
    end
    if invalidate then
        lvgl.hide(context.plotRoot)
        lvgl.show(context.plotRoot)
    end
    context.paintedVersion = context.version
    context.paintedArmRevision, context.paintedResumeRevision, context.paintedFlightRevision =
        session.armRevision, session.resumeRevision, session.flightRevision
    context.columnsDecorating, context.frameThrough = nil, nil
    return chart.intervalFor(context.window, context.area.w, #context.series)
end

local function finishColumns(context, allowance)
    local remaining, used = allowance, 0
    for series = 1, #context.series do
        if not context.columnRenderer.published[series] then
            context.columnsDecorating, context.frameThrough = nil, nil
            return 1, true, 0
        end
    end
    if not context.frameThrough then
        context.frameThrough = context.session.elapsed
        for series, job in ipairs(context.columnRenderer.published) do
            local feed = context.series[series].feed
            if feed.available and not feed.stale and job.at then
                context.frameThrough =
                    math.min(context.frameThrough, job.at + context.columnConsumers[series].startedAt)
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
        local map = context.columnRenderer.published[series].map
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
                item.drawnBreakMap, item.drawnBreak, item.drawnBreakVersion = map, map.breakLast, context.version
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
        return publishColumns(context), false, used + 250
    end
    local work = context.connectorWork
    if not work then
        work = { series = 1, index = 1 }
        context.connectorWork = work
    end
    while work.series <= #context.series do
        local item = context.series[work.series]
        local published = context.columnRenderer.published[work.series]
        local source = published and (published.connectors or published.map.connectors) or {}
        local saved = item.connectors[work.index]
        local values = source[work.index]
        if values then
            local key = table.concat(
                { values[1], values[2], values[3], values[4], published.low, published.high, context.geometryVersion },
                ":"
            )
            if saved and saved.key == key then
                work.index, work.prepared = work.index + 1, nil
            else
                if not work.prepared then
                    if remaining < 150 then
                        return 1, true, used
                    end
                    saved = saved or {}
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
                    saved.size = 2
                    saved.key = nil
                    work.prepared = true
                    remaining, used = remaining - 150, used + 150
                end
                complete, stageUsed = applyConnector(context, item, saved, remaining)
                remaining, used = remaining - stageUsed, used + stageUsed
                if not complete then
                    return 1, true, used
                end
                saved.key = key
                work.index, work.prepared = work.index + 1, nil
            end
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
    if remaining < 250 then
        return 1, true, used
    end
    context.connectorWork = nil
    return publishColumns(context), false, used + 250
end

-- Measured cost of painting one hidden column through the layer view.
local PAINT_COST = 120
-- Estimated work per extra slot; per-call overhead brings the measured cost to about one slot.
local BACKGROUND_ALLOWANCE = 1100

local function newLayer(context)
    local rect = context.rect
    local layerHost = lvgl.box(context.plotHost, { x = 0, y = 0, w = rect.w, h = rect.h })
    lvgl.hide(layerHost)
    local root = lvgl.box(layerHost, { x = 0, y = 0, w = rect.w, h = rect.h })
    return layerView(context, {
        layerHost = layerHost,
        plotRoot = root,
        flightRoot = lvgl.box(root, { x = 0, y = 0, w = rect.w, h = rect.h }),
        gapRoot = lvgl.box(root, { x = 0, y = 0, w = rect.w, h = rect.h }),
        gridRoot = lvgl.box(root, { x = 0, y = 0, w = rect.w, h = rect.h }),
        grid = {},
        gridCursor = 1,
        flightKeys = {},
        armMarkers = markerPool("arm"),
        resumeMarkers = markerPool("resume"),
        version = 0,
    })
end

local function overflowed(consumers)
    for _, owner in ipairs(consumers) do
        if owner.map.overflowed then
            return true
        end
    end
    return false
end

--- Whether the hidden layer's overlays still match the session's pauses, arms
--- and flights and the pause connectors of its columns.
local function decorationCurrent(auto, session)
    local job, hidden = auto.job, auto.hidden
    local seen = job and job.decorated
    if not seen then
        return false
    end
    local seams = 0
    for _, owner in ipairs(rawget(hidden, "columnConsumers") or {}) do
        seams = seams + #owner.map.seams
    end
    return seen.resume == session.resumeRevision
        and seen.arm == session.armRevision
        and seen.flight == session.flightRevision
        and seen.seams == seams
end

local function decorationStamp(auto, session)
    local seams = 0
    for _, owner in ipairs(rawget(auto.hidden, "columnConsumers") or {}) do
        seams = seams + #owner.map.seams
    end
    return {
        resume = session.resumeRevision,
        arm = session.armRevision,
        flight = session.flightRevision,
        seams = seams,
    }
end

--- Whether the next auto window needs background turns now rather than only
--- alongside ordinary refreshes.
--- Completed columns a hidden layer has yet to take: fine columns merged for the
--- next window, or the visible plot's own columns repainted at new bounds.
local function behind(job, owner, consumer)
    if job.kind == "range" then
        return (owner.map.last or -1) - (owner.next or 1) + 1
    end
    return (consumer.fine.last or 0) - (owner.map.cursor or 0)
end

local function hiddenLagging(auto)
    local owners = auto.job and auto.hidden and rawget(auto.hidden, "columnConsumers")
    for index, owner in ipairs(owners or {}) do
        if
            behind(auto.job, owner, auto.consumers[index]) > 2
            or #owner.map.dirtyList > 2 and auto.job.kind ~= "range"
        then
            return true
        end
    end
    return false
end

local function autoPending(auto, session)
    local consumers = auto and auto.consumers
    if not consumers then
        return false
    end
    local job = auto.job
    if not job then
        return auto.rangeRequest == true or auto.window and not auto.stopped and consumers[1].step < auto.limit
    end
    return not job.ready
        or job.kind == "range"
        or overflowed(consumers)
        or not decorationCurrent(auto, session)
        or hiddenLagging(auto)
end

local function forgetMarkers(markers)
    for _, marker in pairs(markers or {}) do
        marker.geometryVersion = nil
    end
end

--- Show the prepared layer. Plot state moves once; nothing is redrawn.
local function swapLayers(context, auto, job)
    local hidden = auto.hidden
    local previous = { series = {} }
    for _, key in ipairs(LAYER_KEYS) do
        previous[key] = context[key]
        context[key] = rawget(hidden, key)
    end
    for index, item in ipairs(context.series) do
        local saved, loaded = {}, rawget(hidden, "series")[index]
        for _, key in ipairs(ITEM_KEYS) do
            saved[key] = item[key]
            item[key] = rawget(loaded, key)
        end
        previous.series[index] = saved
    end
    for index, owner in ipairs(auto.consumers) do
        owner:adopt(context.columnConsumers[index].map, job.target or owner.step)
    end
    context.columnConsumers = auto.consumers
    context.columnRenderer.context = context
    lvgl.show(context.layerHost)
    lvgl.hide(previous.layerHost)
    previous.columnConsumers, previous.recycle = nil, true
    auto.hidden, auto.job = layerView(context, previous), nil
    previous.columnRenderer.context = auto.hidden
    context.metadataReady, context.columnsDecorating, context.frameThrough = nil, nil, nil
end

--- Prepare the next auto window within `allowance` estimated instructions:
--- coarsen fine stores when needed, build the hidden layer from them, decorate
--- it with the ordinary staged pipeline, and swap once the visible plot is full.
local function background(context, allowance)
    local auto = context.auto
    local consumers = auto and auto.consumers
    if not consumers or context.columnSetup or not context.columnRenderer then
        return 0
    end
    local Columns, remaining, used = context.columnModule, allowance, 0
    local resets = 0
    for _, owner in ipairs(consumers) do
        resets = resets + owner.resets
    end
    if auto.resets ~= resets or auto.geometry ~= context.geometryVersion then
        auto.resets, auto.geometry, auto.job, auto.stopped = resets, context.geometryVersion, nil, nil
        if auto.hidden then
            auto.hidden.recycle = true
        end
    end
    if auto.window and not auto.stopped then
        for _, owner in ipairs(consumers) do
            if owner.fine.overflowed then
                -- Too many pauses for the fine store: keep the plot fixed at its edge.
                auto.stopped = true
                if auto.job and auto.job.kind ~= "range" then
                    auto.job = nil
                end
            end
        end
    end
    local job = auto.job
    if auto.rangeRequest and (not job or job.kind ~= "range") then
        -- New bounds take priority; the next window is prepared again afterwards.
        job = { kind = "range", phase = "layer" }
        auto.job, auto.rangeRequest = job, nil
        if auto.hidden then
            auto.hidden.recycle = true
        end
    elseif job and job.kind == "range" and job.targets then
        for index, item in ipairs(context.series) do
            local bounds = job.targets[index]
            if outside(item, bounds[1], bounds[2], consumers[index].map) then
                -- Data left the bounds being prepared; prepare wider ones.
                job = { kind = "range", phase = "layer" }
                auto.job = job
                auto.hidden.recycle = true
                break
            end
        end
    end
    if not job then
        if not auto.window or auto.stopped or consumers[1].step >= Columns.AUTO_STEPS then
            -- Fixed windows and the longest auto window stop at the right edge.
            return used
        end
        job = { target = consumers[1].step + 1, phase = "halve" }
        auto.job = job
    end
    local target = job.target
    if job.phase == "halve" then
        local level = Columns.autoLevel(target)
        if consumers[1].fine.level >= level then
            job.phase = "layer"
        else
            job.fines = job.fines or {}
            local complete = true
            for index, owner in ipairs(consumers) do
                local fine = owner.fine
                job.fines[index] = job.fines[index] or Columns.fine(owner.width, level, owner.recording)
                local done, stage = job.fines[index]:absorb(fine, 2, (fine.last or 0) - 1, remaining)
                remaining, used = remaining - stage, used + stage
                complete = complete and done
                if not done then
                    break
                end
            end
            -- The newest fine column can still grow, so it moves with the switch.
            if complete and remaining >= 150 * #consumers then
                for index, owner in ipairs(consumers) do
                    local _, stage = job.fines[index]:absorb(owner.fine, 2, owner.fine.last or -1, remaining)
                    used = used + stage
                    owner.fine = job.fines[index]
                end
                job.phase, job.fines = "layer", nil
            end
            return used
        end
    end
    local hidden = auto.hidden
    if job.phase == "layer" then
        if not hidden then
            auto.hidden = newLayer(context)
            return used + 1500
        end
        if not hidden.columnRenderer then
            hidden.columnRenderer = context.columnRendererModule.new(hidden)
            return used + 800
        end
        if hidden.recycle then
            if hidden.recycle == true then
                forgetMarkers(hidden.armMarkers and hidden.armMarkers.markers)
                forgetMarkers(hidden.resumeMarkers and hidden.resumeMarkers.markers)
                for _, item in ipairs(hidden.series) do
                    forgetMarkers(item.markers)
                end
                hidden.recycle = "sweep"
            end
            local visited, complete = hidden.columnRenderer:sweep(math.max(1, remaining // 20))
            used = used + visited * 20
            if not complete then
                return used
            end
            hidden.recycle = nil
        end
        local owners, window, gap = {}, nil, nil
        if job.kind == "range" then
            job.targets, job.factor = rangeTargets(context, consumers), 1
            window, gap = consumers[1].map.window, consumers[1].map.breakWidth
        else
            local minutes, level = Columns.autoMinutes(target), Columns.autoLevel(target)
            window, gap, job.factor = minutes * 6000, Columns.autoGap(target), minutes >> level
        end
        for index, owner in ipairs(consumers) do
            -- New bounds repaint the visible columns themselves; a new window merges fine ones.
            owners[index] = {
                map = job.kind == "range" and owner.map
                    or Columns.new(owner.width, window, owner.recording, { breakWidth = gap }),
                startedAt = 0,
            }
            local item, bounds = hidden.series[index], job.targets and job.targets[index]
            item.low = bounds and bounds[1] or context.series[index].low
            item.high = bounds and bounds[2] or context.series[index].high
        end
        hidden.columnConsumers, hidden.window, hidden.start = owners, window, context.start or 0
        hidden.version, hidden.axis = (hidden.version or 0) + 1, nil
        hidden.gridVersion, hidden.gridLayoutVersion = nil, nil
        hidden.connectorWork, hidden.columnsDecorating, hidden.frameThrough = nil, nil, nil
        job.phase = "build"
        return used + 100 * #consumers
    end
    local swapCost
    -- New bounds show as soon as they are ready; a new window waits for a full plot.
    if job.ready and (job.kind == "range" or overflowed(consumers)) then
        swapCost = 800
        for index, owner in ipairs(hidden.columnConsumers) do
            local pending = math.max(0, behind(job, owner, consumers[index]) + 1)
            if job.kind == "range" then
                swapCost = swapCost + pending * PAINT_COST
            else
                swapCost = swapCost + pending * 100 + (#owner.map.dirtyList > 2 and math.huge or 0)
            end
        end
    end
    -- The newest fine column can still grow, so the final catch-up and the swap
    -- happen in one turn of at most one slot. A few unpainted columns are left to
    -- the next ordinary append; otherwise keep catching up first.
    -- Swap only with overlays drawn for every pause, arm and flight so far.
    local current = job.ready and decorationCurrent(auto, context.session)
    if swapCost and current and swapCost <= math.max(remaining, SLOT_INSTRUCTIONS) and used == 0 then
        if job.kind == "range" then
            local painted = hidden.columnRenderer:paintSlots(math.huge, 1, true)
            used = used + painted * PAINT_COST
            -- Every column is now drawn at the new bounds; later changes mark again.
            for _, owner in ipairs(hidden.columnConsumers) do
                owner.map.dirtyColumns, owner.map.dirtyList = {}, {}
            end
        else
            for index, owner in ipairs(hidden.columnConsumers) do
                local fine = consumers[index].fine
                local _, stage = owner.map:absorb(fine, job.factor, fine.last or -1, math.huge)
                used = used + stage
            end
        end
        swapLayers(context, auto, job)
        return used + 800
    end
    -- Catch up when the hidden columns lag; otherwise spend the turn on overlays,
    -- which resume across turns, so one-slot grants still finish decorating.
    local lagging = hiddenLagging(auto)
    local decorating = rawget(hidden, "columnsDecorating")
    -- Long overlay passes alternate with catch-up so neither starves.
    job.alternate = lagging and decorating and not job.alternate
    if lagging and (not decorating or job.alternate) or not decorating and current then
        -- Paint absorbed columns before absorbing more, so no backlog reaches the swap.
        local owners = hidden.columnConsumers
        job.rotation = (job.rotation or 0) % #owners + 1
        if job.kind == "range" then
            local painted = hidden.columnRenderer:paintSlots(remaining // PAINT_COST, job.rotation)
            return used + painted * PAINT_COST
        end
        local painted = hidden.columnRenderer:paint(remaining // PAINT_COST, job.rotation)
        remaining, used = remaining - painted * PAINT_COST, used + painted * PAINT_COST
        for offset = 0, #owners - 1 do
            if remaining < 120 then
                break
            end
            local index = (job.rotation + offset - 1) % #owners + 1
            local fine = consumers[index].fine
            local _, stage = owners[index].map:absorb(fine, job.factor, (fine.last or 0) - 1, remaining)
            remaining, used = remaining - stage, used + stage
        end
        painted = hidden.columnRenderer:paint(math.max(0, remaining // PAINT_COST), job.rotation)
        return used + painted * PAINT_COST
    end
    if remaining < 300 then
        return used
    end
    prepareAxis(hidden, remaining)
    if hidden.gridVersion ~= hidden.version then
        local gridDone, stage = updateGrid(hidden, remaining)
        remaining, used = remaining - stage, used + stage
        if not gridDone or remaining < 300 then
            return used
        end
    end
    if not rawget(hidden, "columnsDecorating") then
        -- Changes during a multi-turn pass leave the result stale.
        job.stamp = decorationStamp(auto, context.session)
    end
    hidden.columnsDecorating = true
    -- A pass that made no progress gets up to one slot, so the largest overlay
    -- item always fits without inflating ordinary turns.
    local allowed = job.stalled and used == 0 and math.max(remaining, SLOT_INSTRUCTIONS) or remaining
    local _, unfinished, stage = finishColumns(hidden, allowed)
    job.stalled = unfinished and stage == 0
    if not unfinished then
        job.phase, job.ready, job.decorated = "ready", true, job.stamp
    end
    return used + stage
end

local function refreshColumns(context, slots)
    local remaining, used = instructionAllowance(slots), 0
    if not context.columnRenderer then
        context.columnRenderer = context.columnRendererModule.new(context)
        return 1, true, 1
    end
    if context.columnsDecorating then
        local interval, unfinished, stageUsed = finishColumns(context, remaining)
        return interval, unfinished, consumedSlots(used + stageUsed)
    end
    if not context.metadataReady then
        chart.render(context)
        if not context.rangesReady then
            chart.ranges(context)
            context.rangesReady = true
        end
        updateHeader(context)
        text(context.status, plotStatus(context), context.theme.color.textFaint)
        context.metadataReady = true
        return 1, true, 1
    end
    if remaining < 1 then
        return 1, true, consumedSlots(used)
    end
    remaining, used = remaining - 1, used + 1
    local owner = context.columnConsumers[1]
    local window, start = owner.map.window, owner.startedAt
    if context.window ~= window or context.start ~= start then
        context.window, context.start = window, start
        context.axis = nil
        context.version = context.version + 1
    end
    if owner.map.recording or (context.session.resumeLast or 0) > 0 then
        local axisReady, stageUsed = prepareAxis(context, remaining)
        remaining, used = remaining - stageUsed, used + stageUsed
        if not axisReady then
            return 1, true, consumedSlots(used)
        end
    end
    if context.gridVersion ~= context.version then
        local complete, stageUsed = updateGrid(context, remaining)
        remaining, used = remaining - stageUsed, used + stageUsed
        if not complete then
            return 1, true, consumedSlots(used)
        end
    end
    if used > 1 then
        return 1, true, consumedSlots(used)
    end
    context.columnRenderer:append()
    context.metadataReady = nil
    context.columnsDecorating, context.frameThrough = true, nil
    return 1, false, 1
end

local function refreshChart(context, creating, slots)
    if
        context.columnsReadonly
        and not context.preview
        and context.history.observeSamples
        and context.columnConsumers
        and context.columnConsumers[1].history ~= context.history
    then
        for _, owner in ipairs(context.columnConsumers) do
            owner:destroy()
        end
        context.columnConsumers, context.columnsReadonly, context.columnSetupIndex = nil, nil, nil
        context.columnSetup = context.columnModule
        if context.columnRenderer then
            context.columnRenderer:reset()
            context.columnsDecorating = nil
        end
    end
    if context.columnSetup then
        local used = 0
        if not context.columnSetupIndex then
            chart.geometry(context, context.rect)
            context.columnConsumers, context.columnSetupIndex = {}, 1
            used = 1
        end
        while context.columnSetupIndex <= #context.series and used < slots do
            local index = context.columnSetupIndex
            local item = context.series[index]
            context.columnConsumers[index] =
                context.columnSetup.attach(context.history, item.feed, context.area.w // 1, {
                    window = timeWindow(context.settings),
                    preview = context.preview,
                    recording = { history = context.history, session = context.session },
                    auto = context.autoWanted,
                    elapsed = context.session.elapsed,
                })
            context.columnsReadonly = context.columnsReadonly or context.columnConsumers[index].readonly
            context.columnSetupIndex, used = index + 1, used + 1
        end
        if context.columnSetupIndex > #context.series then
            context.columnSetup, context.columnSetupIndex = nil, nil
            -- Live charts prepare rescaled layers: the next auto window, or new bounds.
            context.auto = not context.columnConsumers[1].readonly
                    and {
                        consumers = context.columnConsumers,
                        hidden = context.auto and context.auto.hidden,
                        limit = context.columnModule.AUTO_STEPS,
                        window = context.columnConsumers[1].auto,
                    }
                or nil
        end
        return 1, true, used
    end
    if creating or not context.history or context.history.failed or #context.series == 0 then
        chart.render(context)
        updateHeader(context)
        text(context.status, plotStatus(context), context.theme.color.textFaint)
        return 20
    end
    return refreshColumns(context, slots)
end

function chart.refresh(context, creating, slots)
    slots = slots or 8
    local auto = context.auto
    local ready = auto and auto.consumers and not creating and context.columnRenderer and not context.columnSetup
    local rescaling = auto and (auto.rangeRequest or auto.job and auto.job.kind == "range")
    local full = ready and auto.window and overflowed(auto.consumers)
    if ready and (rescaling or full and autoPending(auto, context.session)) then
        -- A full or wrongly scaled plot gains little from readout, overlay or column
        -- refreshes: samples are appended and the rest of the ordinary slot, plus
        -- the extra slot when granted, finishes the rescaled layer. Columns left
        -- unpainted are drawn by the layer that replaces this one.
        local appended = 0
        for _, owner in ipairs(auto.consumers) do
            appended = appended + #owner.pending * 150
        end
        context.columnRenderer:append(true)
        local extra = slots >= 2 and BACKGROUND_ALLOWANCE or 0
        background(context, math.max(0, BACKGROUND_ALLOWANCE - appended) + extra)
        return 1, true, extra > 0 and 2 or 1
    end
    if auto and auto.wakeAt and ready then
        local now = context.clock()
        -- A bounded run of preparation turns never starves ordinary refreshes.
        if now < auto.wakeAt and (auto.backgroundTurns or 0) < 4 then
            auto.backgroundTurns = (auto.backgroundTurns or 0) + 1
            -- Between ordinary refreshes only the rescaled layer is prepared.
            background(context, BACKGROUND_ALLOWANCE)
            local interval = autoPending(auto, context.session) and 1 or auto.wakeAt - now
            -- The visible plot still owes its next refresh.
            return math.max(1, math.min(6000, interval)), true, 1
        end
    end
    local interval, unfinished, consumed = refreshChart(context, creating, slots)
    consumed = consumed or 1
    if auto then
        auto.backgroundTurns = 0
    end
    if auto and auto.consumers and context.auto == auto and not creating then
        -- A cycle ends when decorations publish, not when the append returns.
        local idle = not unfinished and not context.columnsDecorating and not context.metadataReady
        local pending = autoPending(auto, context.session)
        -- At most one extra slot per refresh goes to a rescaled layer.
        if slots > consumed and not context.columnsDecorating and (pending or idle and auto.job ~= nil) then
            background(context, BACKGROUND_ALLOWANCE)
            consumed = consumed + 1
            pending = autoPending(auto, context.session)
        end
        auto.wakeAt = idle and pending and context.clock() + interval or nil
        if pending then
            interval = 1
        end
    end
    return interval, unfinished, consumed
end

--- While the dashboard is hidden, keep columns current so returning to it
--- draws only overlays; a rescale in progress continues with what is left.
function chart.background(context)
    local renderer = context.columnRenderer
    if not renderer or context.columnSetup or not context.columnConsumers then
        return
    end
    local auto = context.auto
    local appended = 0
    for _, owner in ipairs(context.columnConsumers) do
        appended = appended + #(owner.pending or {}) * 250
    end
    local rescaling = auto and (auto.rangeRequest or auto.job and auto.job.kind == "range")
    renderer:append(rescaling or auto and auto.window and overflowed(auto.consumers))
    if auto then
        background(context, math.max(0, BACKGROUND_ALLOWANCE - appended))
    end
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
        columnModule = services.chartColumns,
        columnRendererModule = services.chartColumnsRenderer,
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
    context.baseline =
        lvgl.hline(context.plotHost, { x = 0, y = 0, w = 1, h = 1, color = context.theme.chartColor.grid })
    context.layerHost = lvgl.box(context.plotHost, { x = 0, y = 0, w = rect.w, h = rect.h })
    context.plotRoot = lvgl.box(context.layerHost, { x = 0, y = 0, w = rect.w, h = rect.h })
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
                timeRange = "growing",
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
    context.window, context.start, context.pixelStart = timeWindow(settings, 0), 0, 0
    if context.history and #context.series > 0 then
        context.autoWanted = settings.duration == nil and not context.preview
        context.checkRange = checkRange
        context.columnSetup = assert(services.chartColumns, "chart column runtime unavailable")
        assert(context.columnRendererModule, "chart column renderer runtime unavailable")
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
    context.metadataReady = nil
    if context.auto then
        context.auto.wakeAt = nil
    end
    context.rangesReady = false
    if context.columnSetup then
        if context.columnSetupIndex then
            for _, owner in ipairs(context.columnConsumers) do
                owner:destroy()
            end
            context.columnConsumers, context.columnSetupIndex, context.columnsReadonly = nil, nil, nil
        end
    end
    local resized = rect.w ~= context.rect.w or rect.h ~= context.rect.h
    if resized then
        context.plotWidth = nil
    end
    context.rect = rect
    context.legendFont, context.legendIndex, context.legendWidth = nil, nil, nil
    context.primitives.resizePanel(context.panel, rect)
    context.plotHost:set({ w = rect.w, h = rect.h })
    context.layerHost:set({ w = rect.w, h = rect.h })
    context.plotRoot:set({ w = rect.w, h = rect.h })
    context.flightRoot:set({ w = rect.w, h = rect.h })
    context.gapRoot:set({ w = rect.w, h = rect.h })
    context.gridRoot:set({ w = rect.w, h = rect.h })
    chart.geometry(context, rect)
    local hidden = context.auto and context.auto.hidden
    if resized and hidden then
        -- Resizing clears the chart; the next auto window is prepared again.
        for _, key in ipairs({ "layerHost", "plotRoot", "flightRoot", "gapRoot", "gridRoot" }) do
            hidden[key]:set({ w = rect.w, h = rect.h })
        end
        if hidden.columnRenderer then
            hidden.columnRenderer:destroy()
            hidden.columnRenderer = nil
        end
        hidden.recycle, context.auto.job = true, nil
    end
    if resized and context.columnConsumers then
        if context.columnRenderer then
            context.columnRenderer:destroy()
            context.columnRenderer = nil
        end
        context.columnsDecorating, context.frameThrough = nil, nil
        for _, consumer in ipairs(context.columnConsumers) do
            consumer:resize(context.area.w // 1)
        end
    end
    context.connectorWork = nil
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
    context.columnsDecorating, context.frameThrough = nil, nil
    if context.columnRenderer then
        context.columnRenderer:destroy()
        context.columnRenderer = nil
    end
    if context.columnConsumers then
        for _, consumer in ipairs(context.columnConsumers) do
            consumer:destroy()
        end
        context.columnConsumers = nil
    end
end

return chart
