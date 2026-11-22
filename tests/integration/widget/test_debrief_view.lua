-- SPDX-License-Identifier: GPL-2.0-only

-- The debrief view: built in the background as soon as a debrief exists, it
-- opens only when complete. An upward drag in fullscreen reveals it over the
-- layout; it scrolls, hides without being destroyed, and is rebuilt only when
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
    return context.inputQueue or context.debriefRequest or context.uiRequest
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

-- A drag past the halfway point snaps the sheet open on release.
drag(H - 5, H - 60)
assert(state.shown and state.reveal == 55, "the sheet follows the finger")
assert(state.ui.overlay.properties.y == state.travel - 55)
input(EVT_TOUCH_SLIDE, touch(20, H - 5))
assert(state.reveal == H - 25)
input(EVT_TOUCH_BREAK, touch(20, H - 5))
assert(state.reveal == state.travel and state.offset == 0, "release past halfway opens fully")
assert(state.ui.overlay.properties.y == 0)

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
assert(#state.ui.overlay.children == 1, "the open debrief contains just one scrolling canvas")

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

-- Dragging further up scrolls; the rotary scrolls and never hides.
drag(200, 120)
assert(state.offset == 80 and state.reveal == state.travel, "an upward drag scrolls the open sheet")
assert(state.ui.viewport.properties.y == -80, "the entire debrief canvas scrolls")
assert(
    context.pillLayer.parent == state.ui.viewport and state.ui.content.parent == state.ui.viewport,
    "the ready header and flight summary share one scrolling canvas"
)
local barY = state.ui.overlay.properties.y + state.ui.viewport.properties.y + context.pillLayer.properties.y
local summaryY = state.ui.overlay.properties.y + state.ui.viewport.properties.y + state.ui.content.properties.y
assert(
    barY == -80 and summaryY == barY + state.barHeight,
    "the header scrolls offscreen without overlapping the summary"
)
input(EVT_TOUCH_BREAK, touch(120, 200))
-- Native coordinates follow the touched tile as it moves, but slideY remains
-- the finger's delta. Holding the finger still must not reverse the scroll.
input(EVT_TOUCH_FIRST, touch(120, 120))
input(EVT_TOUCH_SLIDE, touch(80, 120, { slideY = -40 }))
assert(state.offset == 120, "native finger movement scrolls once")
input(EVT_TOUCH_SLIDE, touch(120, 120, { slideY = 0 }))
assert(state.offset == 120, "a moving tile must not move a stationary finger")
input(EVT_TOUCH_SLIDE, touch(110, 120, { slideY = 20 }))
assert(state.offset == 100, "a downward finger movement scrolls back regardless of tile coordinates")
input(EVT_TOUCH_BREAK, touch(110, 120))
input(EVT_ROT_LEFT)
input(EVT_ROT_LEFT)
input(EVT_ROT_LEFT)
assert(state.offset == 0 and state.shown, "the rotary stops at the top")
for _ = 1, 20 do
    input(EVT_ROT_RIGHT)
end
assert(state.offset == state.maxOffset and state.maxOffset > 0, "the rotary stops at the bottom")
local background = state.ui.content.children[1].properties
local backgroundY = state.ui.overlay.properties.y + state.ui.viewport.properties.y + state.ui.content.properties.y
assert(
    background.filled and background.opacity == 255 and background.color == context.theme.color.canvas,
    "the scrolling body has an opaque debrief background"
)
assert(
    background.w == state.width and backgroundY <= 0 and backgroundY + background.h >= state.height,
    "the background covers the entire screen at the bottom of a long debrief"
)

-- A downward swipe with content scrolled only scrolls back.
input(EVT_TOUCH_FIRST, touch(50, 50))
input(EVT_TOUCH_SLIDE, touch(120, 50, { swipeDown = true }))
assert(state.shown and state.offset == state.maxOffset - 70)
input(EVT_TOUCH_BREAK, touch(120, 50))
input(EVT_ROT_LEFT)
local offset = state.offset

-- RTN hides without destroying; reopening keeps the scroll position.
local overlay = state.ui.overlay
input(EVT_VIRTUAL_EXIT)
assert(
    context.debrief == state and not state.shown and overlay.properties.y == state.travel,
    "RTN lowers the sheet to its bar"
)
assert(state.ui.viewport.properties.y == 0, "closing restores the discoverable header even after scrolling")
drag(H - 5, H - 40, { swipeUp = true })
assert(context.debrief == state and state.shown and state.reveal == state.travel, "a swipe up opens fully")
assert(state.ui.overlay == overlay and state.offset == offset, "the hidden view is reused as it was")

-- At the top, a downward drag slides the sheet away; a swipe hides it.
for _ = 1, 20 do
    input(EVT_ROT_LEFT)
end
drag(50, 100)
assert(state.shown and state.reveal == state.travel - 50, "a downward drag at the top slides the sheet")
input(EVT_TOUCH_BREAK, touch(100, 50))
assert(state.reveal == state.travel, "a short slide snaps back")
input(EVT_TOUCH_FIRST, touch(50, 50))
input(EVT_TOUCH_SLIDE, touch(80, 50, { swipeDown = true }))
assert(state.shown and state.reveal == state.travel - 30, "a downward swipe follows the finger before release")
input(EVT_TOUCH_BREAK, touch(80, 50))
assert(not context.debrief.shown, "release after hiding does not reopen")

-- Reaching the closed position before lifting must not pass the rest of
-- the swipe to the dashboard's long-press editor or menu.
input(EVT_TOUCH_FIRST, touch(H - 5, H - 5, { x = 300 }))
input(EVT_TOUCH_SLIDE, touch(H - 40, H - 5, { x = 300, swipeUp = true }))
input(EVT_TOUCH_BREAK, touch(H - 40, H - 5, { x = 300 }))
input(EVT_TOUCH_FIRST, touch(5, 5, { x = 300 }))
input(EVT_TOUCH_SLIDE, touch(H - 5, 5, { x = 300, slideY = H - 10 }))
assert(not state.shown, "the held downward drag completely closes the sheet")
fixture.pump(context, 10)
assert(not context.editorUi and not context.editorTransitionRequest, "closing must not resume a stale dashboard hold")
local closedTouch = touch(H - 5, 5, { x = 300 })
assert(
    context.editorController.editorEntryHit(context, EVT_TOUCH_LONG, closedTouch),
    "the closing gesture ends over an editable dashboard panel"
)
input(EVT_TOUCH_LONG, closedTouch)
assert(not context.editorUi and not context.editorTransitionRequest, "closing a debrief must not enter editing")
input(EVT_TOUCH_BREAK, touch(0, 5, { x = 0 }))
input(EVT_TOUCH_TAP, touch(10, 5, { x = 10 }))
fixture.pump(context, 10)
assert(not context.aerogridMenu.open and not context.modelSettingsUi, "release must not tap the dashboard menu")
input(EVT_TOUCH_FIRST, touch(10, 10, { x = 10 }))
input(EVT_TOUCH_TAP, touch(10, 10, { x = 10 }))
fixture.pump(context, 10)
assert(context.aerogridMenu.open, "a fresh gesture can still open the dashboard menu")
input(EVT_VIRTUAL_EXIT)
fixture.pump(context, 10)

-- Leaving fullscreen hides the view without destroying it.
drag(H - 5, H - 40, { swipeUp = true })
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
drag(H - 5, H - 40, { swipeUp = true })
assert(context.debrief == state and state.ui and state.offset == offset, "the view opens where it was")
assert(not state.ui.overlay.hidden)
input(EVT_VIRTUAL_EXIT)

-- The next flight's debrief and a session reset destroy the view.
current = makeResult("Next")
fixture.pump(context, 5)
assert(context.debrief ~= state, "a new debrief replaces the view")
build()
drag(H - 5, H - 40, { swipeUp = true })
assert(context.debrief and context.debrief.result == current and context.debrief.offset == 0)
assert(has(labelsOf(context.debrief.ui.overlay), "NEXT 1"))
local pageChildren = #context.page.children
input(EVT_VIRTUAL_EXIT)
current = nil
fixture.pump(context, 5)
assert(context.debrief == nil, "a session reset destroys the view")
drag(H - 5, H - 40, { swipeUp = true })
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
assert(worst < 15000, "dense shading exceeded budget: " .. worst)
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

assert(worst < 15000, "debrief callback exceeded budget: " .. worst)
runtime.byId.debrief = realDebrief
print(
    "Debrief view integration passed; 12 tiles built in "
        .. callbacks
        .. " callbacks; worst callback: "
        .. worst
        .. " instructions"
)
