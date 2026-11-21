-- SPDX-License-Identifier: GPL-2.0-only

--- The debrief view: a sheet below the dashboard layout. Dragging up reveals
--- it and then scrolls its content; dragging down at its top slides it away
--- again. Hiding keeps the built view; the host destroys it when the debrief,
--- the layout or the zone changes.
-- Instruction costs the build charges: a painted column, a shading
-- rectangle, a scanned shading column, and a tile's lines and renderer.
local view = {
    RUNTIME_API = 1,
    TOP = 4,
    GUTTER = 4,
    PAINT_COST = 250,
    SHADE_COST = 300,
    SCAN_COST = 15,
    LINES_COST = 4000,
}

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

--- "Flight 42 - Nov 17, 14:24", either part alone, or nil.
function view.flightText(result)
    local flight = type(result.flight) == "number" and string.format("Flight %d", result.flight) or nil
    local date = view.dateText(result.started)
    if flight and date then
        return flight .. " - " .. date
    end
    return flight or date
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
function view.layout(tiles, zone, grid)
    local gutter, top = view.GUTTER, view.TOP
    local function rowY(row)
        return top + row * (zone.h + gutter) // 4
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
    return items, rowY(1) - gutter - top, rowY(row)
end

local function apply(state)
    local ui = state.ui
    if not ui then
        return
    end
    local y, offset = state.travel - state.reveal, state.shown and -state.offset or 0
    if ui.y ~= y then
        ui.overlay:set({ y = y })
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
        step = math.max(1, (zone.h + view.GUTTER) // 4),
    }
    state.items, state.headerHeight, state.total = view.layout(result.tiles, zone, host.grid)
    state.maxOffset = math.max(0, state.total - state.travel)
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

local function buildOverlay(host, state)
    local theme, width, height = host.theme, state.width, state.height
    -- One overlay per page, reused by every debrief: EdgeTX frees a page's
    -- children only with the page.
    local overlay, viewport = host.debriefOverlay, host.debriefViewport
    overlay:set({ x = 0, y = state.travel - state.reveal, w = width, h = height })
    viewport:set({
        y = state.shown and -state.offset or 0,
        w = width,
        h = math.max(height, state.total + state.barHeight),
    })
    local content = host.debriefContent
    local rect = { x = 0, y = state.barHeight, w = width, h = math.max(state.travel, state.total), scrollDir = 0 }
    if content then
        content:set(rect)
    else
        content = lvgl.box(viewport, rect)
        host.debriefContent = content
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
        local value = view.valueText(host.themeBuilder, entry.value, config.precision)
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

--- Show the view, revealed by `reveal` pixels.
function view.show(host, reveal)
    local state = host.debrief
    -- The opening drag must not resume a dashboard edit hold after closing.
    host.editorPress = nil
    state.shown, state.closing = true, nil
    state.reveal = math.max(0, math.min(state.travel, reveal))
    if state.ui then
        lvgl.show(state.ui.overlay)
        apply(state)
    end
end

--- Slide the view away, keeping it and its scroll position.
function view.hide(host)
    local state = host.debrief
    state.shown, state.closing, state.dragY, state.reveal = false, nil, nil, 0
    state.follow, state.flick = nil, nil
    if state.ui then
        apply(state)
    end
    host.touchTapHandled = true
end

--- Forget the view's objects before the page holding them is cleared; the
--- scroll position stays, and the objects are rebuilt in the background.
function view.detach(state)
    if state.ui then
        lvgl.hide(state.ui.overlay)
    end
    state.ui, state.shown, state.closing, state.dragY, state.reveal = nil, false, nil, nil, 0
    state.follow, state.flick = nil, nil
    for _, item in ipairs(state.items) do
        item.built, item.complete, item.box, item.renderer, item.shade = nil, nil, nil, nil, nil
    end
end

--- Release the view and its objects.
function view.destroy(host)
    local state = host.debrief
    local overlay = host.debriefOverlay
    if state and state.ui and overlay then
        state.ui.content:clear()
        host.pillLayer:clear()
        lvgl.hide(overlay)
        host.debriefPill = nil
        host.debriefCleared = true
    end
    host.debrief = nil
end

--- Move by `delta` pixels, positive up: the sheet rises until it covers the
--- layout, then its content scrolls; down, the content returns to its top,
--- then the sheet slides away.
function view.move(state, delta)
    if delta > 0 then
        local rise = math.min(delta, state.travel - state.reveal)
        state.reveal = state.reveal + rise
        state.offset = math.min(state.maxOffset, state.offset + delta - rise)
    elseif delta < 0 then
        if state.reveal < state.travel then
            state.reveal = math.max(0, state.reveal + delta)
        else
            local scroll = math.max(delta, -state.offset)
            state.offset = state.offset + scroll
            state.reveal = math.max(0, state.reveal + delta - scroll)
        end
    end
end

--- Snap a partly revealed sheet open or closed when the touch ends.
---@return boolean open
function view.release(state)
    if state.flick == "up" then
        state.reveal = state.travel
    elseif state.flick == "down" and state.offset == 0 then
        state.reveal = 0
    end
    state.flick = nil
    if state.reveal < state.travel then
        state.reveal = state.reveal * 2 >= state.travel and state.travel or 0
    end
    return state.reveal > 0
end

local function settle(host, state)
    if state.reveal <= 0 then
        view.hide(host)
        return
    end
    apply(state)
end

--- Apply one input the host has already granted a scheduler turn.
function view.handle(host, event, touch)
    local state = host.debrief
    if not state or not state.shown then
        return false
    end
    if matches(event, "EVT_VIRTUAL_EXIT") or matches(event, "EVT_EXIT_BREAK") then
        view.hide(host)
    elseif host.gesture.touch(event) then
        local point = type(touch) == "table" and type(touch.y) == "number"
        if matches(event, "EVT_TOUCH_FIRST") then
            state.dragY = point and touch.y or nil
            state.follow, state.flick = true, nil
        elseif matches(event, "EVT_TOUCH_SLIDE") then
            local top = state.offset == 0
            if state.dragY and point then
                -- EdgeTX reports y relative to the touched object, which
                -- moves while scrolling; slideY is the finger's movement.
                local delta = type(touch.slideY) == "number" and -touch.slideY or state.dragY - touch.y
                view.move(state, delta)
                state.dragY = touch.y
            end
            if state.follow and touch and touch.swipeUp then
                state.flick = "up"
            elseif state.follow and touch and touch.swipeDown and top then
                state.flick = "down"
            elseif touch and touch.swipeUp and state.reveal < state.travel then
                state.reveal, state.dragY = state.travel, nil
            elseif touch and touch.swipeDown and top then
                state.reveal, state.dragY = 0, nil
            end
            settle(host, state)
        elseif matches(event, "EVT_TOUCH_BREAK") or matches(event, "EVT_TOUCH_TAP") then
            state.dragY = nil
            state.follow = nil
            view.release(state)
            settle(host, state)
            host.touchTapHandled = true
        end
    elseif matches(event, "EVT_ROT_LEFT") or matches(event, "EVT_VIRTUAL_PREV") then
        state.offset = math.max(0, state.offset - state.step)
        settle(host, state)
    elseif matches(event, "EVT_ROT_RIGHT") or matches(event, "EVT_VIRTUAL_NEXT") then
        state.offset = math.min(state.maxOffset, state.offset + state.step)
        settle(host, state)
    end
    return true
end

local PILL_TEXTS = {
    [true] = { "DEBRIEF READY (SCROLL UP)", "DEBRIEF READY" },
    [false] = { "DEBRIEF READY (LONG-PRESS, THEN SCROLL UP)", "DEBRIEF READY" },
}
local PILL_PAD = 4

--- Fit the bottom bar to the zone. Outside fullscreen, opening needs a long press.
function view.pillFit(host, fullscreen, width, height)
    local themeBuilder = host.themeBuilder
    local h = themeBuilder.fontHeight(SMLSIZE) + 4
    if h > height then
        return nil
    end
    for _, text in ipairs(PILL_TEXTS[fullscreen == true]) do
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
    pill.fullscreen, pill.w, pill.h = fullscreen, zone.w, zone.h
    local text, w, h
    if fullscreen ~= nil and layer then
        text, w, h = view.pillFit(host, fullscreen, zone.w, zone.h)
    end
    if not text then
        if layer then
            lvgl.hide(layer)
            lvgl.hide(host.debriefOverlay)
        end
        return
    end
    local ui = pill.ui
    if ui and ui.builtFullscreen ~= fullscreen then
        -- EdgeTX keeps objects built in fullscreen touchable, so outside it they
        -- would take the widget's long press. EdgeTX sweeps whatever is made
        -- under a cleared object in the same callback, so rebuild in the next.
        lvgl.hide(layer)
        layer:clear()
        pill.ui, pill.fullscreen = nil, nil
        return
    end
    local x, y = 0, 0
    if not ui then
        local color = host.theme.color
        local textColor = host.theme.light and color.text or color.canvas
        layer:set({ x = x, y = y, w = w, h = h, scrollDir = 0 })
        -- Fullscreen-created boxes otherwise consume the widget's gestures.
        lvgl.disable(layer)
        lvgl.disable(host.debriefOverlay)
        lvgl.disable(host.debriefViewport)
        ui = { builtFullscreen = fullscreen, text = text, x = x, y = y, w = w }
        local radius = math.min(host.theme.spacing.radius, h // 2)
        ui.fill = lvgl.rectangle(layer, {
            x = 0,
            y = 0,
            w = w,
            h = h,
            color = color.green,
            filled = true,
            rounded = radius,
        })
        lvgl.disable(ui.fill)
        -- Fill the bottom corners, leaving only the top corners rounded.
        ui.bottom = lvgl.hline(layer, {
            x = 0,
            y = radius + (h - radius) // 2,
            w = w,
            h = h - radius,
            color = color.green,
        })
        local textWidth = host.themeBuilder.measureText(SMLSIZE, text)
        local labelX = (w - textWidth - 10) // 2 + 10
        ui.arrow = lvgl.triangle(layer, {
            pts = { { labelX - 10, h // 2 + 2 }, { labelX - 6, h // 2 - 2 }, { labelX - 2, h // 2 + 2 } },
            color = textColor,
        })
        ui.label = host.primitives.label(layer, host.theme, {
            x = labelX,
            y = (h - host.themeBuilder.fontHeight(SMLSIZE)) // 2,
            w = textWidth,
            text = text,
            font = SMLSIZE,
            color = textColor,
        })
        pill.ui = ui
    elseif ui.text ~= text or ui.x ~= x or ui.y ~= y or ui.w ~= w then
        layer:set({ x = x, y = y, w = w, h = h })
        ui.fill:set({ w = w })
        ui.bottom:set({ w = w })
        local textWidth = host.themeBuilder.measureText(SMLSIZE, text)
        local labelX = (w - textWidth - 10) // 2 + 10
        ui.arrow:set({
            pts = { { labelX - 10, h // 2 + 2 }, { labelX - 6, h // 2 - 2 }, { labelX - 2, h // 2 + 2 } },
        })
        ui.label:set({ x = labelX, w = textWidth, text = text })
        ui.text, ui.x, ui.y, ui.w = text, x, y, w
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
        and not state.stale
        and type(touch.x) == "number"
        and type(touch.y) == "number"
        and touch.x >= ui.x
        and touch.x < ui.x + ui.w
        and touch.y >= y
        and touch.y < y + state.barHeight
end

--- Open the fully built view of `result` from an upward drag `request`,
--- where it was last scrolled.
function view.open(host, result, request)
    local state = host.debrief
    if not view.ready(state) or state.result ~= result then
        return
    end
    local reveal = state.travel
    if request and request.follow and type(request.startY) == "number" and type(request.y) == "number" then
        reveal = request.startY - request.y
    end
    view.show(host, reveal)
    state.follow = request and request.follow or nil
    state.flick = state.follow and request.swipe and "up" or nil
    state.dragY = state.follow and not request.released and request.y or nil
    if not state.dragY then
        view.release(state)
    end
    settle(host, state)
end

return view
