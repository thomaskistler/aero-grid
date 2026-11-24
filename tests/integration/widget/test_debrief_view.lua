-- SPDX-License-Identifier: GPL-2.0-only

-- The debrief view: built in the background as soon as a debrief exists, it
-- opens only when complete. Tapping the bar opens it over the layout; it
-- scrolls by rows, hides without being destroyed, and is rebuilt only when
-- the debrief, layout or zone changes.

local root = ... or "."
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
fixture.reset()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "review-navigation", Theme = 3 }, nil, definition)
fixture.pump(context, 40)

EVT_TOUCH_FIRST, EVT_TOUCH_SLIDE, EVT_TOUCH_TAP, EVT_TOUCH_BREAK = 9101, 9102, 9103, 9104
EVT_TOUCH_LONG = 9105
EVT_VIRTUAL_EXIT, EVT_ROT_LEFT, EVT_ROT_RIGHT = 9106, 9107, 9108

local worst = 0
local function busy()
    return context.inputQueue or context.openRequest or context.hostKind
end
local function callback(event, touch)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    definition.refresh(context, event, touch)
    debug.sethook()
    worst = math.max(worst, instructions)
    fixture.lvglMock.settle()
end
local function input(event, touch)
    fixture.tick(20)
    callback(event, touch)
    for _ = 1, 200 do
        if not busy() then
            return
        end
        callback()
    end
    error("debrief input did not settle")
end
--- Run callbacks until the view is fully built; returns how many it took.
local function build()
    for count = 1, 2000 do
        local state = context.debrief
        if state and context.debriefModule.ready(state) then
            return count - 1
        end
        fixture.tick(5)
        callback()
    end
    error("debrief view was not built")
end

local H = context.zone.h
local function touch(y, startY, extra)
    local point = { x = 240, y = y, startX = 240, startY = startY }
    for key, value in pairs(extra or {}) do
        point[key] = value
    end
    return point
end
local function drag(from, to, extra)
    input(EVT_TOUCH_FIRST, touch(from, from))
    input(EVT_TOUCH_SLIDE, touch(to, from, extra))
    if extra and extra.swipeUp then
        input(EVT_TOUCH_BREAK, touch(to, from))
    end
end
local function tap(y)
    input(EVT_TOUCH_FIRST, touch(y, y))
    input(EVT_TOUCH_BREAK, touch(0, 0))
end
local function tapBar()
    tap(context.debrief and context.debrief.shown and 5 or H - 5)
end

-- A fake debrief at the 12-tile maximum: two compact tiles, the rest wide,
-- each with two series, one with thresholds.
local chartColumns = context.chartColumns
local function store(width, curve)
    local columns = chartColumns.new(width, 1000, nil, { passive = true })
    for at = 0, 1000, 5 do
        columns:sample(at, curve(at), false, false, 0)
    end
    return columns
end
local function plotWidth(colSpan, rowSpan)
    local rect = context.grid.rect(context.zone, { col = 0, row = 0, colSpan = colSpan, rowSpan = rowSpan }, 4, 4, 4)
    local fonts = context.themeBuilder.typography(colSpan, rowSpan)
    return context.themeBuilder.frame(context.theme, rect, fonts).content
end
local function makeResult(title)
    local tiles = {}
    local sizes = { { 4, 2 }, { 2, 2 }, { 2, 2 }, { 4, 2 }, { 4, 1 } }
    for _ = 6, 12 do
        sizes[#sizes + 1] = { 4, 2 }
    end
    for index, size in ipairs(sizes) do
        local width = plotWidth(size[1], size[2])
        local levels = {}
        for slot = width // 2, width // 2 + 5 do
            levels[slot] = 1
        end
        for slot = width - 3, width do
            levels[slot] = 2
        end
        tiles[index] = {
            config = { title = title .. " " .. index, colSpan = size[1], rowSpan = size[2] },
            series = {
                {
                    config = { source = "RxBt", statistic = "min", label = "Min" },
                    unit = "V",
                    value = 3.48,
                    level = index == 2 and "warning" or index == 3 and "normal" or "critical",
                    thresholds = { warning = 3.6, critical = 3.5, falling = true },
                    columns = store(width, function(at)
                        return 4.2 - at / 1500
                    end),
                    levels = levels,
                },
                {
                    config = {
                        source = "Alt",
                        statistic = "max",
                        label = index == 4 and "Max altitude" or "Altitude",
                        unit = "m",
                        precision = 0,
                    },
                    unit = "ft",
                    value = 1840,
                    level = "normal",
                    columns = store(width, function(at)
                        return at * 2 % 300
                    end),
                    levels = {},
                },
            },
        }
    end
    return {
        duration = 72300,
        tiles = tiles,
        flight = 42,
        model = "Edge 540",
        started = {
            year = 2025,
            mon = 11,
            day = 17,
            hour = 14,
            min = 24,
        },
    }
end

local current
local runtime = context.serviceRuntime
local realDebrief = runtime.byId.debrief
runtime.byId.debrief = {
    result = function()
        return current
    end,
}

-- Pure helpers.
local view = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/debrief_view.lua"))()
local themeBuilder = context.themeBuilder
assert(view.dateText({ year = 2025, mon = 11, day = 17, hour = 14, min = 4 }) == "Nov 17, 14:04")
assert(view.dateText({ year = 2000, mon = 1, day = 1, hour = 0, min = 0 }) == nil, "an unset clock shows no date")
assert(view.valueText(themeBuilder, 1840.4) == "1,840")
assert(view.valueText(themeBuilder, -1234567, 0) == "-1,234,567")
assert(view.valueText(themeBuilder, 3.476) == "3.48")
assert(view.valueText(themeBuilder, 12.34) == "12.3")
assert(view.valueText(themeBuilder, nil) == "--")
assert(view.valueText(themeBuilder, 0 / 0) == "--")
local labels, count =
    view.legendFit({ { label = 20, value = 30, unit = 10 }, { label = 20, value = 30, unit = 10 } }, 200)
assert(labels and count == 2)
labels, count = view.legendFit({ { label = 20, value = 30, unit = 10 }, { label = 20, value = 30, unit = 10 } }, 90)
assert(not labels and count == 2, "labels go before values")
labels, count = view.legendFit({ { label = 20, value = 30, unit = 10 }, { label = 20, value = 30, unit = 10 } }, 60)
assert(not labels and count == 1, "values go from the right")
local layoutTiles = {
    { config = { colSpan = 2, rowSpan = 2 } },
    { config = { colSpan = 4, rowSpan = 1 } },
    { config = { colSpan = 2, rowSpan = 2 } },
    { config = { colSpan = 2, rowSpan = 2 } },
}
local items, headerHeight, total = view.layout(layoutTiles, { w = 480, h = 272 }, context.grid)
local row = (272 + 4) // 4
assert(headerHeight == row - 4)
assert(items[1].x == 0 and items[1].y == view.TOP + row, "compact tiles start at the left")
assert(
    items[2].x == 0 and items[2].y == view.TOP + 3 * row,
    "a wide tile leaves a lone compact tile's right half empty"
)
assert(
    items[3].y == view.TOP + 4 * row and items[4].y == items[3].y and items[4].x > items[3].x,
    "compact tiles pair up"
)
assert(total == view.TOP + 6 * row)

-- Outside fullscreen nothing opens, and without a debrief neither does a drag.
drag(250, 100)
assert(not context.debrief, "normal mode never opens the debrief")
fixture.lvglMock.setFullScreen(true)
fixture.pump(context, 40)
drag(250, 100)
input(EVT_TOUCH_BREAK, touch(100, 250))
assert(not context.debrief, "no debrief, no view")

-- The view builds in the background, even outside fullscreen, and does not
-- open until every tile is built and painted.
current = makeResult("Tile")
fixture.lvglMock.setFullScreen(false)
for _ = 1, 3 do
    fixture.tick(5)
    callback()
end
local state = assert(context.debrief, "a debrief starts building its view")
assert(view.pending(state) and not state.shown)
fixture.lvglMock.setFullScreen(true)
drag(H - 5, H - 60)
input(EVT_TOUCH_BREAK, touch(H - 60, H - 5))
assert(not state.shown, "an unfinished view does not open")
local callbacks = build()
assert(context.debrief == state and not state.shown)
assert(state.ui.overlay.properties.y == state.travel, "only the bar peeks above the bottom when closed")
assert(state.ui.overlay.properties.scrollDir == 0, "native scrolling must not move the sheet's background")
assert(state.ui.content.properties.scrollDir == 0, "Lua alone scrolls the debrief content")
for _, item in ipairs(state.items) do
    assert(item.built and item.complete, "every tile is built before the view opens")
    assert(item.box.properties.scrollDir == 0, "tile containers must not consume drag gestures")
end

-- Every tile size keeps a third of its height for the plot, with each label
-- inside the tile and clear of the plot.
for _, item in ipairs(state.items) do
    local area = item.area
    assert(area.h >= item.h // 3, "a " .. item.w .. "x" .. item.h .. " tile has a " .. area.h .. " px plot")
    for _, child in ipairs(item.box.children) do
        if child.kind == "label" then
            local p = child.properties
            local font = type(p.font) == "function" and p.font() or p.font
            local top, bottom = p.y, p.y + themeBuilder.fontHeight(font)
            assert(
                top >= 0 and bottom <= item.h and p.x >= 0 and p.x + p.w <= item.w,
                "label leaves its tile: " .. p.text
            )
            assert(bottom <= area.y or top >= area.y + area.h, "label overlaps the plot: " .. p.text)
        end
    end
end

-- A tap opens the sheet completely.
tapBar()
assert(state.shown and state.reveal == state.travel and state.offset == 0)
assert(state.ui.overlay.properties.y == 0)
local shield = context.debriefShield
assert(
    shield and not shield.hidden and context.page.children[#context.page.children] == shield,
    "an open sheet lies under a touch shield, so LVGL never scrolls its boxes natively"
)
assert(state.ui.overlay.properties.h == state.height, "the overlay never extends past the page")

local function labelsOf(object, found)
    found = found or {}
    for _, child in ipairs(object.children or {}) do
        if child.kind == "label" then
            found[#found + 1] = child.properties.text
        end
        labelsOf(child, found)
    end
    return found
end
local function has(list, text)
    for _, value in ipairs(list) do
        if value == text then
            return true
        end
    end
    return false
end
local texts = labelsOf(state.ui.overlay)
assert(has(texts, "FLIGHT DEBRIEF") and has(texts, "FLIGHT 42"), "header makes the flight the focal text")
assert(has(texts, "NOV 17, 14:24 - Edge 540"), "header shows date and model as supporting text")
assert(has(texts, "12:03"), "header shows the flight time")
assert(has(texts, "TILE 1") and has(texts, "3.48") and has(texts, "1,840"), "tiles show uppercase title and statistics")
assert(current.tiles[1].config.title == "Tile 1", "display casing must not change saved titles")
assert(has(labelsOf(state.items[1].box), "MAX ALTITUDE"), "a custom series name must not hide its statistic")
assert(has(labelsOf(state.items[4].box), "MAX ALTITUDE"), "a label that already names its statistic is not doubled")
local compactLabels = labelsOf(state.items[2].box)
assert(
    has(compactLabels, "MIN") and has(compactLabels, "MAX"),
    "compact legends retain the statistics when the full names do not fit"
)
assert(has(texts, "V") and has(texts, "m") and not has(texts, "ft"), "recorded units fill in absent overrides")
assert(has(texts, "CRIT") and has(texts, "WARN"), "tiles badge their highest recorded severity")
for index, expected in ipairs({ context.theme.color.critical, context.theme.color.amber, context.theme.color.cyan }) do
    local card = state.items[index].box
    local accent
    for _, child in ipairs(card.children) do
        if child.kind == "box" and child.properties.w == context.theme.spacing.accentWidth then
            accent = child.children[1].properties.color
        elseif child.kind == "label" then
            local p = child.properties
            if p.text == "3.48" or p.text == "1,840" then
                assert(p.color == context.theme.color.text, "statistic numbers use the primary text color")
            elseif p.text == "V" or p.text == "m" or p.text == "MIN" or p.text == "MAX" then
                assert(p.color == context.theme.color.textMuted, "units and statistic labels stay muted")
            end
        end
    end
    assert(accent == expected, "the worst series determines the tile accent")
end
local overlayChildren = state.ui.overlay.children
assert(
    #overlayChildren == 2 and overlayChildren[1] == state.ui.viewport,
    "the open debrief holds one scrolling canvas and a scroll bar floating above it"
)

input(EVT_TOUCH_FIRST, touch(200, 200))
fixture.requeue(context)
local sharedTurns = 0
local sharedTask = {
    name = "debrief shared work",
    cost = 2,
    due = 0,
    onError = function(_, message)
        error(message)
    end,
    step = function()
        sharedTurns = sharedTurns + 1
        assert(state.offset == 0, "shared work runs before the queued drag")
    end,
}
context.scheduler.add(sharedTask)
fixture.tick(5)
callback(EVT_TOUCH_SLIDE, touch(192, 200, { slideY = -8 }))
context.scheduler.remove(sharedTask)
assert(sharedTurns == 1 and not context.inputQueue, "a debrief drag shares a callback with charged work")
assert(
    state.offset == state.stops[2] and state.ui.viewport.properties.y == -state.stops[2],
    "shared work must not defer scrolling"
)
input(EVT_TOUCH_BREAK, touch(200, 200))
input(EVT_ROT_LEFT)
assert(state.offset == 0)

local first = state.items[1]
assert(first.built and first.complete)
for _, item in ipairs(state.items) do
    for _, child in ipairs(item.box.children) do
        local p = child.properties
        assert(
            not (child.kind == "rectangle" and p.w == 4 and p.h == 4),
            "statistic legends must not include colored dots"
        )
    end
end
local amber, critical, shades, dashes = context.theme.color.amber, context.theme.color.critical, 0, 0
for _, child in ipairs(first.box.children) do
    local properties = child.properties
    if child.kind == "rectangle" and properties.opacity == 64 then
        shades = shades + 1
        assert(properties.color == amber or properties.color == critical)
    elseif child.kind == "hline" and properties.dashGap then
        dashes = dashes + 1
    end
end
assert(shades == 2, "warning and critical periods are shaded: " .. shades)
assert(dashes == 2, "warning and critical thresholds are dashed lines: " .. dashes)
assert(has(labelsOf(first.box), "MIN"), "wide tiles label their statistics in uppercase")

local stops = state.stops
assert(
    stops[1] == 0 and stops[2] == state.barHeight + state.items[1].y - view.TOP and stops[#stops] == state.maxOffset,
    "the sheet rests with its summary or a row of tiles at the top"
)
-- One short movement advances once, regardless of later slide events.
input(EVT_TOUCH_FIRST, touch(120, 120))
input(EVT_TOUCH_SLIDE, touch(119, 120, { slideY = -1 }))
assert(state.offset == stops[2], "even a short upward drag advances one row")
input(EVT_TOUCH_SLIDE, touch(120, 120, { slideY = 0 }))
input(EVT_TOUCH_SLIDE, touch(110, 120, { slideY = 20 }))
assert(state.offset == stops[2], "multiple slide events cannot advance or reverse a single drag")
input(EVT_TOUCH_BREAK, touch(110, 120))
assert(state.ui.viewport.properties.y == -stops[2], "the chart body scrolls")
assert(
    context.pillLayer.parent == state.ui.viewport and state.ui.viewport.properties.y == -stops[2],
    "the bar scrolls away with the debrief body"
)
assert(
    state.ui.content.properties.y + state.ui.viewport.properties.y + state.items[1].y == view.TOP,
    "the first chart row reaches the top after the bar scrolls away"
)
tap(5)
assert(state.shown, "tapping the top while the bar is offscreen does not close")
drag(100, 101, { slideY = 1 })
input(EVT_TOUCH_BREAK, touch(101, 100))
assert(state.offset == 0 and state.shown, "a short downward drag returns one row without closing")
drag(100, 101, { slideY = 1 })
input(EVT_TOUCH_BREAK, touch(101, 100))
assert(not state.shown, "scrolling up from the top closes the debrief")
tapBar()
assert(state.shown and state.offset == 0, "the debrief reopens at the top")
input(EVT_ROT_RIGHT)
assert(state.offset == stops[2], "the rotary steps to the next row")
input(EVT_ROT_LEFT)
assert(state.offset == 0 and state.shown, "the rotary returns to the top row")
input(EVT_ROT_LEFT)
assert(not state.shown, "the rotary scrolling up from the top closes the debrief")
tapBar()
for _ = 1, 20 do
    input(EVT_ROT_RIGHT)
end
assert(state.offset == state.maxOffset and state.maxOffset > 0, "the rotary stops at the bottom")
-- The scroll bar has a segment per stop, shows on each step and fades away
-- two seconds after the last, taking two seconds to do so.
local bar = context.debriefScrollBar
local segments = bar and bar.segments
assert(
    bar and bar.box.parent == state.ui.overlay and #segments == #state.stops,
    "a segment per scroll stop floats over the sheet"
)
local function lit()
    local found
    for index, segment in ipairs(segments) do
        if segment.properties.opacity == 215 then
            assert(not found, "one segment is current")
            found = index
        else
            assert(segment.properties.opacity == 77, "other segments are dim")
        end
    end
    return found
end
assert(not bar.box.hidden and lit() == #segments, "stepping shows the last stop as current")
assert(
    segments[1].properties.x == state.width - 10 and segments[1].properties.x > state.width // 2,
    "the bar sits on the right"
)
assert(
    segments[1].properties.y >= H // 5
        and segments[#segments].properties.y + segments[#segments].properties.h <= H - H // 5,
    "the segments leave a fifth of the screen empty at the top and bottom"
)
input(EVT_ROT_LEFT)
assert(lit() == #segments - 1, "the current segment follows the sheet")
fixture.tick(150)
callback()
assert(not bar.box.hidden and lit() == #segments - 1, "the bar holds for two seconds")
local previous = 215
for _ = 1, 60 do
    fixture.tick(5)
    callback()
    local opacity = bar.box.hidden and 0 or segments[#segments - 1].properties.opacity
    assert(opacity <= previous, "the bar only fades")
    previous = opacity
end
assert(bar.box.hidden and not state.bar, "the bar is hidden once faded")
input(EVT_ROT_LEFT)
assert(not bar.box.hidden and lit() == #segments - 2, "stepping brings it back at full strength")
for _ = 1, 20 do
    input(EVT_ROT_RIGHT)
end

local background = state.ui.content.children[1].properties
local backgroundY = state.ui.overlay.properties.y + state.ui.viewport.properties.y + state.ui.content.properties.y
assert(
    background.filled and background.opacity == 255 and background.color == context.theme.color.canvas,
    "the scrolling body has an opaque debrief background"
)
assert(
    background.w == state.width and backgroundY <= 0 and backgroundY + background.h >= state.height,
    "the background covers the screen at the last row"
)

-- A downward swipe moves exactly one row.
input(EVT_TOUCH_FIRST, touch(50, 50))
input(EVT_TOUCH_SLIDE, touch(120, 50, { swipeDown = true }))
assert(state.shown and state.offset == stops[#stops - 1])
input(EVT_TOUCH_BREAK, touch(120, 50))
input(EVT_ROT_LEFT)
local offset = state.offset

-- RTN hides without destroying; reopening keeps the position.
local overlay = state.ui.overlay
input(EVT_VIRTUAL_EXIT)
assert(
    context.debrief == state and not state.shown and overlay.properties.y == state.travel,
    "RTN lowers the sheet to its bar"
)
assert(state.ui.viewport.properties.y == 0, "closing restores the discoverable header even after scrolling")
assert(shield.hidden and overlay.properties.h == state.barHeight, "a closed sheet leaves the dashboard touchable")
tapBar()
assert(context.debrief == state and state.shown and state.reveal == state.travel, "a tap opens fully")
assert(state.ui.overlay == overlay and state.offset == offset, "the hidden view is reused as it was")

-- Scrolling back to the top shows the bar, which closes the debrief; taps
-- elsewhere do nothing.
for _ = 1, 20 do
    if state.offset == 0 then
        break
    end
    input(EVT_ROT_LEFT)
end
assert(state.shown and state.offset == 0, "scrolling back reaches the top")
tapBar()
assert(not state.shown, "the bar closes the debrief after scrolling back to the top")
tapBar()
drag(100, 50)
input(EVT_TOUCH_BREAK, touch(50, 100))
assert(state.shown and state.offset == stops[2], "dragging up steps to the next row")
tap(100)
assert(state.shown, "a tap outside the bar does not close")
input(EVT_VIRTUAL_EXIT)
assert(not state.shown, "RTN still closes")
fixture.pump(context, 10)

-- Leaving fullscreen hides the view without destroying it.
tapBar()
for _ = 1, 3 do
    input(EVT_ROT_RIGHT)
end
offset = state.offset
fixture.lvglMock.setFullScreen(false)
fixture.pump(context, 40)
assert(context.debrief == state and not state.shown, "leaving fullscreen closes the debrief")
assert(not state.ui or state.ui.overlay.properties.y == state.travel)
fixture.lvglMock.setFullScreen(true)
fixture.pump(context, 40)
tapBar()
assert(context.debrief == state and state.ui and state.offset == offset, "the view opens where it was")
assert(not state.ui.overlay.hidden)
input(EVT_VIRTUAL_EXIT)

-- The next flight's debrief and a session reset destroy the view.
current = makeResult("Next")
fixture.pump(context, 5)
assert(context.debrief ~= state, "a new debrief replaces the view")
build()
tapBar()
assert(context.debrief and context.debrief.result == current and context.debrief.offset == 0)
assert(has(labelsOf(context.debrief.ui.overlay), "NEXT 1"))
local pageChildren = #context.page.children
input(EVT_VIRTUAL_EXIT)
current = nil
fixture.pump(context, 5)
assert(context.debrief == nil, "a session reset destroys the view")
tap(H - 5)
assert(context.debrief == nil, "no debrief, no view")

-- Warning and critical alternating every column on three series, and a
-- threshold whose integer pixel product would overflow int32, still build
-- within the callback budget, in the overlay the earlier debriefs used.
local dense = makeResult("Dense")
for _, tile in ipairs(dense.tiles) do
    local width = tile.series[1].columns.width
    tile.series[3] = {
        config = { source = "Curr", statistic = "max", unit = "A" },
        value = 12,
        level = "warning",
        columns = store(width, function(at)
            return at % 50
        end),
        levels = {},
    }
    for _, entry in ipairs(tile.series) do
        for slot = 1, width do
            entry.levels[slot] = slot % 2 + 1
        end
    end
end
local large = dense.tiles[1].series[1]
large.config.rangeMin, large.config.rangeMax = 0, 100000000
large.thresholds = { warning = 50000000 }
local earlier = worst
worst = 0
current = dense
build()
assert(worst < 17500, "dense shading exceeded budget: " .. worst)
worst = math.max(worst, earlier)
assert(#context.page.children == pageChildren, "replacements and resets reuse one overlay")
first = context.debrief.items[1]
local covered, line = 0, nil
for _, child in ipairs(first.box.children) do
    local properties = child.properties
    if child.kind == "rectangle" and properties.opacity == 64 then
        covered = covered + properties.w
    elseif child.kind == "hline" and properties.dashGap then
        line = properties.y
    end
end
assert(covered == 3 * first.area.w, "every column of every series is shaded: " .. covered)
local middle = first.area.y + first.area.h / 2
assert(line and math.abs(line - middle) <= 1, "a large threshold sits mid-plot: " .. tostring(line))
current = nil
fixture.pump(context, 5)

-- A shorter color screen still fits all header rows, and tiles start below them.
local small = fixture.createLoaded(
    { x = 0, y = 0, w = 320, h = 240 },
    { Layout = "review-navigation", Theme = 3 },
    nil,
    definition
)
fixture.pump(small, 40)
local rect = small.grid.rect(small.zone, { col = 0, row = 0, colSpan = 2, rowSpan = 2 }, 4, 4, 4)
local width = small.themeBuilder.frame(small.theme, rect, small.themeBuilder.typography(2, 2)).content
local smallResult = {
    duration = 72300,
    flight = 42,
    model = "Edge 540",
    started = { year = 2025, mon = 11, day = 17, hour = 14, min = 24 },
    tiles = {
        {
            config = { title = "Altitude", colSpan = 2, rowSpan = 2 },
            series = {
                {
                    config = { source = "Alt", statistic = "max" },
                    value = 100,
                    columns = store(width, function(at)
                        return at / 10
                    end),
                    levels = {},
                },
            },
        },
    },
}
small.serviceRuntime.byId.debrief.result = function()
    return smallResult
end
assert(
    fixture.pumpUntil(small, function(host)
        return host.debrief and host.debriefModule.ready(host.debrief)
    end, 1000),
    "the shorter screen's debrief did not build"
)
local smallState = small.debrief
local header = smallState.ui.content.children[2]
assert(header.kind == "box" and header.properties.h == smallState.headerHeight)
local headerLabels = 0
for _, child in ipairs(header.children) do
    if child.kind == "label" and child.properties.text ~= "" then
        local p = child.properties
        local font = type(p.font) == "function" and p.font() or p.font
        assert(
            p.y >= 0 and p.y + small.themeBuilder.fontHeight(font) <= header.properties.h,
            "header text is clipped at 320x240"
        )
        assert(p.x >= 0 and p.x + p.w <= header.properties.w, "header text exceeds the shorter screen's width")
        headerLabels = headerLabels + 1
    end
end
assert(headerLabels >= 4, "the header's flight, date/model and duration rows are present")
assert(has(labelsOf(header), "NOV 17, 14:24 - Edge 540"), "the shorter screen keeps the date/model row")
assert(
    smallState.items[1].y == view.TOP + smallState.headerHeight + view.GUTTER,
    "the taller header cannot overlap the first tile"
)

assert(worst < 17500, "debrief callback exceeded budget: " .. worst)
runtime.byId.debrief = realDebrief
print(
    "Debrief view integration passed; 12 tiles built in "
        .. callbacks
        .. " callbacks; worst callback: "
        .. worst
        .. " instructions"
)
