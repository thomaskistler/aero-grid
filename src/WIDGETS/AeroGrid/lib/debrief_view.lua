-- SPDX-License-Identifier: GPL-2.0-only

--- The debrief view: tap its bar to open or close, and drag to step through
--- chart rows. Hiding keeps the built view until the debrief or layout changes.
-- Instruction costs the build charges: a painted column, a shading
-- rectangle, a scanned shading column, and a tile's lines and renderer.
local view = {
    TOP = 4,
    GUTTER = 4,
    PAINT_COST = 250,
    SHADE_COST = 300,
    SCAN_COST = 15,
    LINES_COST = 4000,
}

-- The scroll bar floats over the right edge as one segment per scroll stop,
-- the current one bright. It shows on opening and on each step, holds for
-- BAR_HOLD ticks (10 ms), then fades in BAR_FADE_STEPS steps.
local BAR_WIDTH, BAR_INSET, BAR_GAP, BAR_SPAN = 4, 6, 5, 20
local BAR_ACTIVE_OPACITY, BAR_IDLE_OPACITY = 215, 77
local BAR_HOLD, BAR_FADE_TICKS, BAR_FADE_STEPS = 200, 200, 12

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local LEGEND_GAP, ITEM_GAP = 3, 10
-- EdgeTX's standard font is no size flag at all.
local STD_FONT = 0
local SHADE_OPACITY, LINE_OPACITY = 64, 192

local function matches(event, name)
    return _G[name] ~= nil and event == _G[name]
end

local function durationText(host, ticks)
    return host.servicesModule.clockText(math.max(0, (ticks or 0) // 100))
end

--- "Nov 17, 14:24", or nil when the radio clock looks unset.
function view.dateText(started)
    if type(started) ~= "table" or type(started.year) ~= "number" or started.year < 2024 then
        return nil
    end
    local month = MONTHS[started.mon]
    if not month then
        return nil
    end
    return string.format("%s %d, %02d:%02d", month, started.day or 1, started.hour or 0, started.min or 0)
end

--- A statistic with its precision, thousands grouped: "1,840", "3.48".
function view.valueText(themeBuilder, value, precision)
    if precision == nil and type(value) == "number" then
        local size = math.abs(value)
        precision = size >= 100 and 0 or size >= 10 and 1 or 2
    end
    local text = themeBuilder.numberText(value, precision)
    local sign, whole, rest = string.match(text, "^(-?)(%d+)(.*)$")
    if not whole or #whole <= 3 then
        return text
    end
    local grouped = string.sub(whole, 1, (#whole - 1) % 3 + 1)
    for index = (#whole - 1) % 3 + 2, #whole, 3 do
        grouped = grouped .. "," .. string.sub(whole, index, index + 2)
    end
    return sign .. grouped .. rest
end

--- How much of a legend fits `width`: labels go first, then values from the
--- right. `items[i]` carries measured `label`, `value` and `unit` widths.
---@return boolean labels Whether labels are shown.
---@return integer count Series values shown, from the left.
function view.legendFit(items, width)
    local function measure(labels, count)
        local total = 0
        for index = 1, count do
            local item = items[index]
            total = total + (index > 1 and ITEM_GAP or 0) + item.value + item.unit
            if labels and item.label > 0 then
                total = total + item.label + LEGEND_GAP
            end
        end
        return total
    end
    if measure(true, #items) <= width then
        return true, #items
    end
    for count = #items, 1, -1 do
        if measure(false, count) <= width then
            return false, count
        end
    end
    return false, 0
end

--- Vertical bounds of one series: its configured range, or the drawn extremes
--- with a little headroom.
function view.range(config, store)
    -- Floats throughout: int32 radio Lua would overflow integer products.
    local low, high = config.rangeMin, config.rangeMax
    low, high = low and low + 0.0, high and high + 0.0
    local minimum, maximum = store.minimum, store.maximum
    if low == nil or high == nil then
        if minimum == nil then
            low, high = low or 0.0, high or (low or 0.0) + 1
        else
            minimum, maximum = minimum + 0.0, maximum + 0.0
            local pad = math.max((maximum - minimum) * 0.1, math.abs(maximum) * 0.02, 0.01)
            low, high = low or minimum - pad, high or maximum + pad
        end
    end
    if high <= low then
        high = low + 1
    end
    return low, high
end

--- Tile positions in content coordinates. Compact tiles pair up side by
--- side in order; a wide tile starts a new row.
function view.layout(tiles, zone, grid, minimumHeaderHeight)
    local gutter, top = view.GUTTER, view.TOP
    local rowHeaderHeight = (zone.h + gutter) // 4 - gutter
    local headerHeight = math.max(rowHeaderHeight, minimumHeaderHeight or 0)
    local extra = headerHeight - rowHeaderHeight
    local function rowY(row)
        return top + row * (zone.h + gutter) // 4 + extra
    end
    -- `row` is the next free full row; `pending` the row of a compact tile
    -- whose right half is still free.
    local items, row, pending = {}, 1, nil
    for _, tile in ipairs(tiles) do
        local config = tile.config
        if config then
            local col, at = 0, row
            if config.colSpan == 2 and pending then
                col, at, pending = 2, pending, nil
            elseif config.colSpan == 2 then
                pending, row = row, row + config.rowSpan
            else
                pending, row = nil, row + config.rowSpan
            end
            local span = { col = col, row = 0, colSpan = config.colSpan, rowSpan = config.rowSpan }
            local rect = grid.rect(zone, span, 4, 4, gutter)
            items[#items + 1] = { tile = tile, x = rect.x, y = rowY(at), w = rect.w, h = rect.h }
        end
    end
    return items, headerHeight, rowY(row)
end

--- Scroll offsets for the summary and each row of tiles.
function view.stops(items, barHeight)
    local stops = { 0 }
    for _, item in ipairs(items) do
        local stop = barHeight + item.y - view.TOP
        if stop > stops[#stops] then
            stops[#stops + 1] = stop
        end
    end
    return stops
end

--- The stop nearest `offset`, or the next one in `direction` (1 down, -1 up).
function view.stop(stops, offset, direction)
    if direction == 1 then
        for _, stop in ipairs(stops) do
            if stop > offset then
                return stop
            end
        end
        return stops[#stops]
    elseif direction == -1 then
        for index = #stops, 1, -1 do
            if stops[index] < offset then
                return stops[index]
            end
        end
        return stops[1]
    end
    local best = stops[1]
    for _, stop in ipairs(stops) do
        if math.abs(stop - offset) < math.abs(best - offset) then
            best = stop
        end
    end
    return best
end

local function apply(state)
    local ui = state.ui
    if not ui then
        return
    end
    local y, offset = state.travel - state.reveal, state.shown and -state.offset or 0
    if ui.y ~= y then
        -- Ending at the zone's bottom keeps the page from scrolling natively.
        ui.overlay:set({ y = y, h = state.height - y })
        ui.y = y
    end
    if ui.offset ~= offset then
        ui.viewport:set({ y = offset })
        ui.offset = offset
    end
end

--- Whether `advance` has work left: the overlay, a tile or a curve.
function view.pending(state)
    if not state.ui then
        return true
    end
    for _, item in ipairs(state.items) do
        if not item.complete then
            return true
        end
    end
    return false
end

--- Whether the view is fully built and may open.
function view.ready(state)
    return state ~= nil and not state.stale and not view.pending(state)
end

--- Percent of the view built while it is still preparing, nil once it may open.
function view.progress(state)
    if view.ready(state) then
        return nil
    end
    local done = state.ui and 1 or 0
    for _, item in ipairs(state.items) do
        done = done + (item.complete and 1 or 0)
    end
    return math.min(99, done * 100 // (#state.items + 1))
end

function view.new(host, result)
    local zone = host.zone
    local barHeight = host.themeBuilder.fontHeight(SMLSIZE) + 4
    local state = {
        result = result,
        document = host.document,
        width = zone.w,
        height = zone.h,
        barHeight = barHeight,
        travel = math.max(0, zone.h - barHeight),
        reveal = 0,
        offset = 0,
        shown = false,
    }
    local textHeight = host.themeBuilder.fontHeight(SMLSIZE)
        + host.themeBuilder.fontHeight(MIDSIZE)
        + host.themeBuilder.fontHeight(TINSIZE)
    local headerHeight = (zone.h + view.GUTTER) // 4 - view.GUTTER
    for _ = 1, 2 do
        local frame = host.themeBuilder.frame(
            host.theme,
            { w = zone.w, h = headerHeight },
            { label = SMLSIZE, badge = SMLSIZE }
        )
        local required = frame.labelY + textHeight + frame.bottom
        if required <= headerHeight then
            break
        end
        headerHeight = required
    end
    state.items, state.headerHeight, state.total = view.layout(result.tiles, zone, host.grid, headerHeight)
    state.stops = view.stops(state.items, barHeight)
    state.maxOffset = state.stops[#state.stops]
    return state
end

local function panel(host, parent, rect, level)
    local presentation = host.themeBuilder.state(host.theme, level, "cyan")
    presentation.opacity = 255
    local card = host.primitives.panel(parent, rect, host.theme, presentation)
    card.root:set({ scrollDir = 0 })
    card.column:set({ scrollDir = 0 })
    return card.root, presentation
end

local function buildHeader(host, state, parent)
    local theme, measure = host.theme, host.themeBuilder.measureText
    local fontHeight = host.themeBuilder.fontHeight
    local color = theme.color
    local x, y, w, h = 0, view.TOP, state.width, state.headerHeight
    local box = panel(host, parent, { x = x, y = y, w = w, h = h }, "normal")
    local frame = host.themeBuilder.frame(theme, { w = w, h = h }, { label = SMLSIZE, badge = SMLSIZE })
    x, y = frame.pad, frame.labelY
    local result = state.result
    local time = durationText(host, result.duration)
    local timeFont = MIDSIZE
    local timeWidth = measure(timeFont, time)
    local timeX = w - frame.padRight - timeWidth
    host.primitives.label(box, theme, {
        x = timeX,
        y = y + fontHeight(SMLSIZE),
        w = timeWidth + 2,
        text = time,
        font = timeFont,
        color = color.text,
    })
    local caption = "FLIGHT TIME"
    local captionWidth = measure(SMLSIZE, caption)
    local rightWidth = math.max(timeWidth, captionWidth)
    local textWidth = math.max(1, w - frame.padRight - rightWidth - x - 8)
    local heading, headingFont = host.themeBuilder.fitHeading("FLIGHT DEBRIEF", textWidth, SMLSIZE, TINSIZE)
    if captionWidth < w // 2 then
        host.primitives.label(box, theme, {
            x = w - frame.padRight - captionWidth,
            y = y,
            w = captionWidth + 2,
            text = caption,
            font = SMLSIZE,
            color = color.textMuted,
        })
    end
    host.primitives.label(box, theme, {
        x = x,
        y = y,
        w = textWidth,
        text = heading,
        font = headingFont,
        color = color.textMuted,
    })
    local flight = type(result.flight) == "number" and string.format("FLIGHT %d", result.flight) or "FLIGHT"
    local flightText, flightFont = host.themeBuilder.fitHeading(flight, textWidth, MIDSIZE, SMLSIZE)
    host.primitives.label(box, theme, {
        x = x,
        y = y + fontHeight(SMLSIZE),
        w = textWidth,
        text = flightText,
        font = flightFont,
        color = color.text,
    })
    local metadata = view.dateText(result.started)
    if type(result.model) == "string" and result.model ~= "" then
        metadata = metadata and (string.upper(metadata) .. " - " .. result.model) or result.model
    elseif metadata then
        metadata = string.upper(metadata)
    end
    host.primitives.label(box, theme, {
        x = x,
        y = y + fontHeight(SMLSIZE) + fontHeight(MIDSIZE),
        w = w - frame.padRight - x,
        text = host.themeBuilder.fitLabel(
            { metadata or "", string.upper(view.dateText(result.started) or ""), "" },
            TINSIZE,
            w - frame.padRight - x
        ),
        font = TINSIZE,
        color = color.textMuted,
    })
end

--- One segment per scroll stop, in a box above the scrolling sheet. They stay
--- hidden until `wake` and never take touches.
function view.buildScrollBar(host, state)
    local bar = host.debriefScrollBar
    if not bar then
        local box = lvgl.box(host.debriefOverlay, { x = 0, y = 0, w = state.width, h = state.height, scrollDir = 0 })
        lvgl.disable(box)
        lvgl.hide(box)
        bar = { box = box }
        host.debriefScrollBar = bar
    else
        -- `destroy` already cleared the previous segments; EdgeTX sweeps
        -- whatever is made under a box cleared in the same callback.
        bar.box:set({ w = state.width, h = state.height })
    end
    local count = #state.stops
    local top = math.max(state.barHeight, state.height * BAR_SPAN // 100)
    local height = state.height - 2 * top
    local x = state.width - BAR_WIDTH - BAR_INSET
    bar.segments, bar.active = {}, nil
    if count < 2 then
        return
    end
    local segment = (height - (count - 1) * BAR_GAP) // count
    for index = 1, count do
        local object = lvgl.rectangle(bar.box, {
            x = x,
            y = top + (index - 1) * (segment + BAR_GAP),
            w = BAR_WIDTH,
            h = segment,
            filled = true,
            thickness = 0,
            rounded = BAR_WIDTH // 2,
            color = host.theme.color.cyan,
            opacity = BAR_IDLE_OPACITY,
        })
        lvgl.disable(object)
        bar.segments[index] = object
    end
end

local function buildOverlay(host, state)
    local theme, width, height = host.theme, state.width, state.height
    -- One overlay per page, reused by every debrief: EdgeTX frees a page's
    -- children only with the page.
    local overlay, viewport = host.debriefOverlay, host.debriefViewport
    overlay:set({ x = 0, y = state.travel - state.reveal, w = width, h = height - state.travel + state.reveal })
    viewport:set({
        y = state.shown and -state.offset or 0,
        w = width,
        h = math.max(height, state.total + state.barHeight, state.maxOffset + height),
    })
    local content = host.debriefContent
    local rect = {
        x = 0,
        y = state.barHeight,
        w = width,
        h = math.max(state.height + state.maxOffset - state.barHeight, state.total),
        scrollDir = 0,
    }
    if content then
        content:set(rect)
    else
        content = lvgl.box(viewport, rect)
        host.debriefContent = content
    end
    if not host.pillLayer then
        host.pillLayer = lvgl.box(viewport, { x = 0, y = 0, w = 1, h = 1, scrollDir = 0 })
    end
    lvgl.rectangle(content, {
        x = 0,
        y = 0,
        w = width,
        h = rect.h,
        filled = true,
        color = theme.color.canvas,
        opacity = 255,
    })
    view.buildScrollBar(host, state)
    state.ui = {
        overlay = overlay,
        viewport = viewport,
        content = content,
        y = state.travel - state.reveal,
        offset = state.shown and -state.offset or 0,
    }
    buildHeader(host, state, content)
end

local function legendItems(host, series, font)
    local measure = host.themeBuilder.measureText
    local items = {}
    for index, entry in ipairs(series) do
        local config = entry.config
        local label = string.upper(config.label and config.label ~= "" and config.label or config.statistic)
        local statistic = string.upper(config.statistic)
        if
            (statistic == "MIN" or statistic == "MAX")
            and label ~= statistic
            and string.sub(label, 1, #statistic + 1) ~= statistic .. " "
        then
            label = statistic .. " " .. label
        end
        local value = view.valueText(host.themeBuilder, entry.value, config.precision or entry.precision)
        local unit = config.unit or entry.unit or ""
        items[index] = {
            labelText = label,
            statisticText = statistic,
            valueText = value,
            unitText = unit,
            label = measure(SMLSIZE, label),
            value = measure(font, value),
            unit = unit ~= "" and measure(SMLSIZE, unit) + 1 or 0,
        }
    end
    return items
end

--- The tile's box, title, legend and axis. Short tiles put the title and a
--- smaller legend on one line and drop the axis labels, keeping a third of
--- their height for the plot.
local function buildBase(host, state, item)
    local theme, color = host.theme, host.theme.color
    local themeBuilder, primitives = host.themeBuilder, host.primitives
    local fontHeight, measure = themeBuilder.fontHeight, themeBuilder.measureText
    local tile = item.tile
    local config = tile.config
    local level = "normal"
    for _, entry in ipairs(tile.series) do
        if entry.level == "critical" then
            level = "critical"
            break
        elseif entry.level == "warning" then
            level = "warning"
        end
    end
    local box, presentation = panel(host, state.ui.content, item, level)
    item.box = box
    local fonts = themeBuilder.typography(config.colSpan, config.rowSpan)
    local frame = themeBuilder.frame(theme, { x = 0, y = 0, w = item.w, h = item.h }, fonts)
    local pad, right = frame.pad, item.w - frame.padRight
    local titleHeight = fontHeight(SMLSIZE)
    local fullTop = frame.labelY + titleHeight + fontHeight(MIDSIZE) + 4
    local compact = item.h - frame.bottom - titleHeight - 1 - fullTop < item.h // 3
    local valueFont = compact and STD_FONT or MIDSIZE
    local valueHeight = fontHeight(valueFont)
    local smallOffset = valueHeight - titleHeight - 2
    local title = string.upper(config.title or "")
    local badgeWidth = presentation.badge and measure(SMLSIZE, presentation.badge) or 0
    local headerRight = right - (badgeWidth > 0 and badgeWidth + 4 or 0)
    local legendX, legendY, titleWidth = pad, frame.labelY + titleHeight, headerRight - pad
    if compact then
        legendY = frame.labelY
        titleWidth = title ~= "" and math.min(measure(SMLSIZE, title) + 1, (headerRight - pad) // 2) or 0
        legendX = titleWidth > 0 and pad + titleWidth + ITEM_GAP or pad
    end
    if titleWidth > 0 then
        primitives.label(box, theme, {
            x = pad,
            y = compact and legendY + smallOffset or frame.labelY,
            w = math.max(1, titleWidth),
            text = themeBuilder.fitHeading(title, titleWidth, SMLSIZE, SMLSIZE),
            font = SMLSIZE,
            color = color.textMuted,
        })
    end
    if presentation.badge then
        primitives.label(box, theme, {
            x = right - badgeWidth,
            y = frame.labelY,
            w = badgeWidth + 1,
            text = presentation.badge,
            font = SMLSIZE,
            color = presentation.accent,
        })
    end

    local items = legendItems(host, tile.series, valueFont)
    local legendWidth = (compact and headerRight or right) - legendX
    local labels, count = view.legendFit(items, legendWidth)
    if not labels then
        for _, legend in ipairs(items) do
            local statistic = legend.statisticText
            if statistic == "MIN" or statistic == "MAX" then
                legend.labelText, legend.label = statistic, measure(SMLSIZE, statistic)
            end
        end
        labels, count = view.legendFit(items, legendWidth)
    end
    local x = legendX
    for index = 1, count do
        local legend = items[index]
        if index > 1 then
            x = x + ITEM_GAP
        end
        if labels and legend.label > 0 then
            primitives.label(box, theme, {
                x = x,
                y = legendY + smallOffset,
                w = legend.label + 1,
                text = legend.labelText,
                font = SMLSIZE,
                color = color.textMuted,
            })
            x = x + legend.label + LEGEND_GAP
        end
        primitives.label(box, theme, {
            x = x,
            y = legendY,
            w = legend.value + 1,
            text = legend.valueText,
            font = valueFont,
            color = color.text,
        })
        x = x + legend.value
        if legend.unit > 0 then
            primitives.label(box, theme, {
                x = x + 1,
                y = legendY + smallOffset,
                w = legend.unit,
                text = legend.unitText,
                font = SMLSIZE,
                color = color.textMuted,
            })
            x = x + legend.unit
        end
    end

    local first = tile.series[1]
    local axisY = item.h - frame.bottom - (compact and 1 or titleHeight)
    local area = { x = pad, y = legendY + valueHeight + (compact and 2 or 4), w = first and first.columns.width or 1 }
    area.h = math.max(1, axisY - 1 - area.y)
    item.area, item.shade = area, { 1, 1 }
    lvgl.hline(box, { x = area.x, y = axisY, w = area.w, h = 1, color = color.border })
    if compact then
        return
    end
    local duration = durationText(host, state.result.duration)
    local durationWidth = measure(SMLSIZE, duration)
    primitives.label(box, theme, {
        x = area.x,
        y = axisY + 1,
        w = measure(SMLSIZE, "0:00") + 1,
        text = "0:00",
        font = SMLSIZE,
    })
    primitives.label(box, theme, {
        x = area.x + area.w - durationWidth,
        y = axisY + 1,
        w = durationWidth + 1,
        text = duration,
        font = SMLSIZE,
    })
end

--- Shade warning and critical periods within `allowance`, resuming where the
--- last call stopped. Returns the allowance left once done, or nil.
local function shade(host, item, allowance)
    local cursor, series, area = item.shade, item.tile.series, item.area
    local color, width = host.theme.color, area.w
    local cost, scan = view.SHADE_COST, view.SCAN_COST
    while cursor[1] <= #series do
        local levels = series[cursor[1]].levels
        local slot = next(levels) ~= nil and cursor[2] or width + 1
        while slot <= width do
            if allowance < cost + scan then
                cursor[2] = slot
                return nil
            end
            allowance = allowance - scan
            local level, last = levels[slot], slot
            if level then
                while last < width and levels[last + 1] == level and allowance >= cost + scan do
                    last = last + 1
                    allowance = allowance - scan
                end
                lvgl.rectangle(item.box, {
                    x = area.x + slot - 1,
                    y = area.y,
                    w = last - slot + 1,
                    h = area.h,
                    filled = true,
                    thickness = 0,
                    opacity = SHADE_OPACITY,
                    color = level >= 2 and color.critical or color.amber,
                })
                allowance = allowance - cost
            end
            slot = last + 1
        end
        cursor[1], cursor[2] = cursor[1] + 1, 1
    end
    return allowance
end

--- Threshold lines over the shading, and the renderer for the curves.
local function buildLines(host, item)
    local theme, color = host.theme, host.theme.color
    local tile, area, box = item.tile, item.area, item.box
    local series, consumers = {}, {}
    for index, entry in ipairs(tile.series) do
        local low, high = view.range(entry.config, entry.columns)
        local spec = entry.thresholds
        if spec then
            for _, mark in ipairs({ { spec.warning, color.amber }, { spec.critical, color.critical } }) do
                local value = mark[1]
                if type(value) == "number" and value > low and value < high then
                    local fraction = (value - low) / (high - low)
                    lvgl.hline(box, {
                        x = area.x,
                        y = area.y + area.h - (fraction * area.h + 0.5) // 1,
                        w = area.w,
                        h = 1,
                        color = mark[2],
                        opacity = LINE_OPACITY,
                        dashGap = 3,
                        dashWidth = 2,
                    })
                end
            end
        end
        series[index] = {
            low = low,
            high = high,
            color = host.themeBuilder.seriesColor(theme, index, entry.config.accent),
        }
        consumers[index] = { map = entry.columns }
    end
    item.renderer = host.chartColumnsRenderer.new({
        area = area,
        rect = { w = item.w, h = item.h },
        plotRoot = box,
        series = series,
        columnConsumers = consumers,
    })
    item.shade, item.built = nil, true
end

--- Build the hidden overlay, then each tile: its base, its shading and its
--- lines, then paint the curves. Shading and curves keep within `allowance`
--- Lua instructions; the overlay and a tile's base are one step each.
function view.advance(host, allowance)
    local state = host.debrief
    if not state.ui then
        buildOverlay(host, state)
        apply(state)
        return
    end
    for _, item in ipairs(state.items) do
        if not item.built then
            if not item.box then
                buildBase(host, state, item)
                return
            end
            local left = shade(host, item, allowance)
            if left and left >= view.LINES_COST then
                buildLines(host, item)
            end
            return
        end
    end
    for _, item in ipairs(state.items) do
        if allowance < view.PAINT_COST then
            return
        end
        if not item.complete then
            local painted, complete = item.renderer:paintSlots(allowance // view.PAINT_COST, 1, true)
            allowance = allowance - painted * view.PAINT_COST
            item.complete = complete
        end
    end
end

--- While the sheet is open, a clickable box over it stays the touch target.
--- Otherwise LVGL targets a tile and natively scrolls one of the sheet's
--- boxes: EdgeTX honours `scrollDir` only for boxes built in fullscreen.
local function shield(host, visible)
    local box = host.debriefShield
    if visible and not box and host.page and type(lvgl.isFullScreen) == "function" and lvgl.isFullScreen() then
        local zone = host.zone
        box = lvgl.box(host.page, { x = 0, y = 0, w = zone.w, h = zone.h, scrollDir = 0 })
        host.debriefShield = box
    end
    if box then
        if visible then
            lvgl.show(box)
        else
            lvgl.hide(box)
        end
    end
end

local function hideScrollBar(host, state)
    local bar = host.debriefScrollBar
    if bar then
        lvgl.hide(bar.box)
    end
    state.bar = nil
end

--- The segment of the stop the sheet rests on.
local function currentStop(state)
    local current = 1
    for index, stop in ipairs(state.stops) do
        if stop <= state.offset then
            current = index
        end
    end
    return current
end

--- Show the scroll bar at the current stop and restart its hold.
local function wake(host, state)
    local bar = host.debriefScrollBar
    if not (bar and state.ui) or not bar.segments or #bar.segments == 0 then
        return
    end
    local active, shown = currentStop(state), state.bar
    if not shown or shown.step > 0 then
        lvgl.show(bar.box)
        for index, segment in ipairs(bar.segments) do
            segment:set({ opacity = index == active and BAR_ACTIVE_OPACITY or BAR_IDLE_OPACITY })
        end
    elseif bar.active ~= active then
        bar.segments[bar.active]:set({ opacity = BAR_IDLE_OPACITY })
        bar.segments[active]:set({ opacity = BAR_ACTIVE_OPACITY })
    end
    bar.active = active
    state.bar = { at = getTime(), step = 0 }
end

--- The fade step reached at `now`, once the hold is over.
local function fadeStep(state, now)
    local bar = state.bar
    local elapsed = bar and now - bar.at - BAR_HOLD
    if not elapsed or elapsed < 0 then
        return nil
    end
    return elapsed * BAR_FADE_STEPS // BAR_FADE_TICKS + 1
end

--- Whether the scroll bar has a fade step to take at `now`.
function view.fadeDue(state, now)
    local step = fadeStep(state, now)
    return step ~= nil and step > state.bar.step
end

--- Take the next fade step, or hide the bar when it has faded.
function view.fade(host)
    local state = host.debrief
    local step = state and fadeStep(state, getTime())
    if not step or step <= state.bar.step then
        return
    end
    local bar = host.debriefScrollBar
    if step >= BAR_FADE_STEPS or not bar then
        hideScrollBar(host, state)
        return
    end
    local left = BAR_FADE_STEPS - step
    for index, segment in ipairs(bar.segments) do
        local opacity = index == bar.active and BAR_ACTIVE_OPACITY or BAR_IDLE_OPACITY
        segment:set({ opacity = opacity * left // BAR_FADE_STEPS })
    end
    state.bar.step = step
end

--- Show the view, revealed by `reveal` pixels.
function view.show(host, reveal)
    local state = host.debrief
    host.editorPress = nil
    state.shown, state.closing = true, nil
    state.reveal = math.max(0, math.min(state.travel, reveal))
    if state.ui then
        lvgl.show(state.ui.overlay)
        apply(state)
        wake(host, state)
    end
    shield(host, true)
end

--- Slide the view away, keeping it and its scroll position.
function view.hide(host)
    local state = host.debrief
    state.shown, state.closing, state.press, state.reveal = false, nil, nil, 0
    state.dragY, state.dragged = nil, nil
    if state.ui then
        apply(state)
    end
    hideScrollBar(host, state)
    shield(host, false)
    host.touchTapHandled = true
end

--- Forget the view's objects before the page holding them is cleared; the
--- scroll position stays, and the objects are rebuilt in the background.
function view.detach(state)
    if state.ui then
        lvgl.hide(state.ui.overlay)
    end
    state.ui, state.shown, state.closing, state.press, state.reveal = nil, false, nil, nil, 0
    state.bar = nil
    state.dragY, state.dragged = nil, nil
    for _, item in ipairs(state.items) do
        item.built, item.complete, item.box, item.renderer, item.shade = nil, nil, nil, nil, nil
    end
end

--- Release the view and its objects.
function view.destroy(host)
    local state = host.debrief
    local overlay = host.debriefOverlay
    if state and state.ui and overlay then
        host.debriefViewport:clear()
        host.debriefContent, host.pillLayer, host.debriefPill = nil, nil, nil
        host.debriefCleared = true
        -- Hidden ancestors stop EdgeTX's reference cleanup. Keep the empty
        -- sheet visible but below the zone until its viewport acknowledges it.
        overlay:set({ y = host.zone.h, h = host.zone.h })
        lvgl.show(overlay)
    end
    if state then
        hideScrollBar(host, state)
        if host.debriefScrollBar then
            host.debriefScrollBar.box:clear()
        end
    end
    shield(host, false)
    host.debrief = nil
end

--- Apply one input the host has already granted a scheduler turn.
--- Move one stop; scrolling up from the top closes the debrief.
local function step(host, state, direction)
    if direction < 0 and state.offset <= state.stops[1] then
        view.hide(host)
        return
    end
    state.offset = view.stop(state.stops, state.offset, direction)
    apply(state)
    wake(host, state)
end

function view.handle(host, event, touch)
    local state = host.debrief
    if not state or not state.shown then
        return false
    end
    if matches(event, "EVT_VIRTUAL_EXIT") or matches(event, "EVT_EXIT_BREAK") then
        view.hide(host)
    elseif host.gesture.touch(event) then
        if matches(event, "EVT_TOUCH_FIRST") then
            state.press = host.gesture.track(nil, event, touch)
            state.dragY = type(touch) == "table" and touch.y or nil
            state.dragged = false
        elseif matches(event, "EVT_TOUCH_SLIDE") then
            state.press = host.gesture.track(state.press, event, touch)
            if not state.dragged and type(touch) == "table" then
                local delta = type(touch.slideY) == "number" and touch.slideY
                    or type(state.dragY) == "number" and type(touch.y) == "number" and touch.y - state.dragY
                    or 0
                local direction = delta < 0 and 1 or delta > 0 and -1 or touch.swipeUp and 1 or touch.swipeDown and -1
                if direction then
                    state.dragged = true
                    state.press = host.gesture.cancel(state.press)
                    step(host, state, direction)
                end
            end
        else
            local tap
            state.press, tap = host.gesture.track(state.press, event, touch)
            if tap and view.barHit(host, tap) then
                view.hide(host)
            end
            if matches(event, "EVT_TOUCH_BREAK") or matches(event, "EVT_TOUCH_TAP") then
                state.dragY, state.dragged = nil, nil
                host.touchTapHandled = true
            end
        end
    elseif matches(event, "EVT_ROT_LEFT") or matches(event, "EVT_VIRTUAL_PREV") then
        step(host, state, -1)
    elseif matches(event, "EVT_ROT_RIGHT") or matches(event, "EVT_VIRTUAL_NEXT") then
        step(host, state, 1)
    end
    return true
end

local PILL_TEXTS = {
    open = { "DEBRIEF READY (TAP TO CLOSE)", "TAP TO CLOSE" },
    closed = { "DEBRIEF READY (TAP TO OPEN)", "TAP TO OPEN" },
    outside = { "DEBRIEF READY (LONG-PRESS, THEN TAP)", "DEBRIEF READY" },
}
local PILL_PAD = 4
local PILL_TRACK_MIX = 55

--- Fit the bottom bar to the zone. Outside fullscreen, opening needs a long press.
function view.pillFit(host, fullscreen, width, height, shown, progress)
    local themeBuilder = host.themeBuilder
    local h = themeBuilder.fontHeight(SMLSIZE) + 4
    if h > height then
        return nil
    end
    local texts = fullscreen and (shown and PILL_TEXTS.open or PILL_TEXTS.closed) or PILL_TEXTS.outside
    if progress then
        texts = { "PREPARING DEBRIEF " .. progress .. "%", "PREPARING" }
    end
    for _, text in ipairs(texts) do
        local w = themeBuilder.measureText(SMLSIZE, text) + 10 + 2 * PILL_PAD
        if w <= width then
            return text, width, h
        end
    end
    return nil
end

--- Keep the latest debrief discoverable in a full-width bottom bar.
function view.pill(host, fullscreen)
    local zone, layer, pill = host.zone, host.pillLayer, host.debriefPill
    if not pill then
        pill = {}
        host.debriefPill = pill
    end
    local shown = host.debrief and host.debrief.shown or false
    local progress = host.debrief and view.progress(host.debrief)
    pill.fullscreen, pill.w, pill.h, pill.shown, pill.progress = fullscreen, zone.w, zone.h, shown, progress
    local text, w, h
    if fullscreen ~= nil and layer then
        text, w, h = view.pillFit(host, fullscreen, zone.w, zone.h, shown, progress)
    end
    if not text then
        if layer then
            lvgl.hide(layer)
            lvgl.hide(host.debriefOverlay)
        end
        return
    end
    local ui = pill.ui
    if ui and ui.builtFullscreen and not fullscreen then
        -- EdgeTX keeps objects built in fullscreen touchable, so outside it they
        -- would take the widget's long press. EdgeTX sweeps whatever is made
        -- under a cleared object in the same callback, so rebuild in the next.
        lvgl.hide(layer)
        layer:clear()
        pill.ui, pill.fullscreen = nil, nil
        return
    end
    local x, y = 0, 0
    local radius = math.min(host.theme.spacing.radius, h // 2)
    -- While preparing, a muted track fills with solid green as the view builds.
    local function paint()
        local textWidth = host.themeBuilder.measureText(SMLSIZE, text)
        local labelX = progress and (w - textWidth) // 2 or (w - textWidth - 10) // 2 + 10
        local muted = progress ~= nil
        if ui.muted ~= muted then
            local fillColor = muted and ui.track or host.theme.color.green
            ui.fill:set({ color = fillColor })
            ui.bottom:set({ color = fillColor })
            ui.muted = muted
        end
        -- A rounded left cap and a square body keep the leading edge straight.
        local meterWidth = progress and w * progress // 100 or 0
        local cap = math.min(2 * radius, meterWidth)
        local body = meterWidth - radius
        local function place(object, width)
            if width > 0 then
                object:set({ w = width })
                lvgl.show(object)
            else
                lvgl.hide(object)
            end
        end
        place(ui.meter, cap)
        place(ui.meterBottom, cap)
        place(ui.meterBody, body)
        if progress then
            lvgl.hide(ui.arrow)
        else
            ui.arrow:set({
                pts = { { labelX - 10, h // 2 + 2 }, { labelX - 6, h // 2 - 2 }, { labelX - 2, h // 2 + 2 } },
            })
            lvgl.show(ui.arrow)
        end
        ui.label:set({ x = labelX, w = textWidth, text = text })
        ui.text, ui.progress = text, progress
    end
    if not ui then
        local color = host.theme.color
        local textColor = host.theme.light and color.text or color.canvas
        layer:set({ x = x, y = y, w = w, h = h, scrollDir = 0 })
        -- Fullscreen-created boxes otherwise consume the widget's gestures.
        lvgl.disable(layer)
        lvgl.disable(host.debriefOverlay)
        lvgl.disable(host.debriefViewport)
        ui = { builtFullscreen = fullscreen, text = text, x = x, y = y, w = w }
        -- A bar is a rounded rectangle with its bottom corners filled square.
        local function bar(paintColor, width)
            local top = lvgl.rectangle(layer, {
                x = 0,
                y = 0,
                w = width,
                h = h,
                color = paintColor,
                filled = true,
                rounded = radius,
            })
            lvgl.disable(top)
            local bottom = lvgl.hline(layer, {
                x = 0,
                y = radius + (h - radius) // 2,
                w = width,
                h = h - radius,
                color = paintColor,
            })
            return top, bottom
        end
        -- One opaque muted green, so the two bar pieces cannot blend differently.
        local rgb = host.theme.rgb
        local muted = 0
        for _, shift in ipairs({ 16, 8, 0 }) do
            local canvas, green = rgb.canvas >> shift & 255, rgb.green >> shift & 255
            muted = muted * 256 + (canvas * (100 - PILL_TRACK_MIX) + green * PILL_TRACK_MIX) // 100
        end
        ui.track = lcd.RGB(muted)
        ui.fill, ui.bottom = bar(ui.track, w)
        ui.meter, ui.meterBottom = bar(color.green, w)
        ui.meterBody = lvgl.hline(layer, {
            x = radius,
            y = h // 2,
            w = w,
            h = h,
            color = color.green,
        })
        ui.arrow = lvgl.triangle(layer, {
            pts = { { 0, 0 }, { 0, 0 }, { 0, 0 } },
            color = textColor,
        })
        ui.label = host.primitives.label(layer, host.theme, {
            x = 0,
            y = (h - host.themeBuilder.fontHeight(SMLSIZE)) // 2,
            w = host.themeBuilder.measureText(SMLSIZE, text),
            text = text,
            font = SMLSIZE,
            color = textColor,
        })
        pill.ui = ui
        paint()
    elseif ui.text ~= text or ui.progress ~= progress or ui.x ~= x or ui.y ~= y or ui.w ~= w then
        if ui.x ~= x or ui.y ~= y or ui.w ~= w then
            layer:set({ x = x, y = y, w = w, h = h })
            ui.fill:set({ w = w })
            ui.bottom:set({ w = w })
        end
        ui.x, ui.y, ui.w = x, y, w
        paint()
    end
    lvgl.show(layer)
    lvgl.show(host.debriefOverlay)
end

function view.barHit(host, touch)
    local bar, state = host.debriefPill, host.debrief
    local ui = bar and bar.fullscreen == true and bar.ui
    local y = state and state.travel - state.reveal - (state.shown and state.offset or 0) or 0
    return ui
        and state
        and view.ready(state)
        and type(touch.x) == "number"
        and type(touch.y) == "number"
        and touch.x >= ui.x
        and touch.x < ui.x + ui.w
        and touch.y >= y
        and touch.y < y + state.barHeight
end

--- Open the fully built view where it was last scrolled.
function view.open(host, result)
    local state = host.debrief
    if not view.ready(state) or state.result ~= result then
        return
    end
    view.show(host, state.travel)
end

return view
