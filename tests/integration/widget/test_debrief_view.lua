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
                    config = { source = "RxBt", statistic = "min", unit = "V", label = "Min" },
                    value = 3.48,
                    level = "critical",
                    thresholds = { warning = 3.6, critical = 3.5, falling = true },
                    columns = store(width, function(at)
                        return 4.2 - at / 1500
                    end),
                    levels = levels,
                },
                {
                    config = { source = "Alt", statistic = "max", unit = "m", precision = 0 },
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
assert(view.flightText({ flight = 42 }) == "Flight 42")
assert(
    view.flightText({ flight = 42, started = { year = 2025, mon = 1, day = 2, hour = 3, min = 4 } })
        == "Flight 42 - Jan 2, 03:04"
)
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
assert(items[1].x == 0 and items[1].y == 10 + row, "compact tiles start at the left")
assert(items[2].x == 0 and items[2].y == 10 + 3 * row, "a wide tile leaves a lone compact tile's right half empty")
assert(items[3].y == 10 + 4 * row and items[4].y == items[3].y and items[4].x > items[3].x, "compact tiles pair up")
assert(total == 10 + 6 * row)

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
assert(context.debrief == state and state.ui.overlay.hidden and not state.shown)
for _, item in ipairs(state.items) do
    assert(item.built and item.complete, "every tile is built before the view opens")
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
assert(state.ui.overlay.properties.y == H - 55)
input(EVT_TOUCH_SLIDE, touch(20, H - 5))
assert(state.reveal == H - 25)
input(EVT_TOUCH_BREAK, touch(20, H - 5))
assert(state.reveal == H and state.offset == 0, "release past halfway opens fully")
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
assert(has(texts, "Edge 540"), "header shows the model")
assert(has(texts, "Flight 42 - Nov 17, 14:24"), "header shows flight number and date")
assert(has(texts, "12:03"), "header shows the flight time")
assert(has(texts, "Tile 1") and has(texts, "3.48") and has(texts, "1,840"), "tiles show title and statistics")

local first = state.items[1]
assert(first.built and first.complete)
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
assert(has(labelsOf(first.box), "Min"), "wide tiles label their statistics")

-- Dragging further up scrolls; the rotary scrolls and never hides.
drag(200, 120)
assert(state.offset == 80 and state.reveal == H, "an upward drag scrolls the open sheet")
input(EVT_TOUCH_BREAK, touch(120, 200))
input(EVT_ROT_LEFT)
input(EVT_ROT_LEFT)
input(EVT_ROT_LEFT)
assert(state.offset == 0 and state.shown, "the rotary stops at the top")
for _ = 1, 20 do
    input(EVT_ROT_RIGHT)
end
assert(state.offset == state.maxOffset and state.maxOffset > 0, "the rotary stops at the bottom")

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
assert(context.debrief == state and not state.shown and overlay.hidden, "RTN hides the debrief")
drag(H - 5, H - 40, { swipeUp = true })
assert(context.debrief == state and state.shown and state.reveal == H, "a swipe up opens fully")
assert(state.ui.overlay == overlay and state.offset == offset, "the hidden view is reused as it was")

-- At the top, a downward drag slides the sheet away; a swipe hides it.
for _ = 1, 20 do
    input(EVT_ROT_LEFT)
end
drag(50, 100)
assert(state.shown and state.reveal == H - 50, "a downward drag at the top slides the sheet")
input(EVT_TOUCH_BREAK, touch(100, 50))
assert(state.reveal == H, "a short slide snaps back")
input(EVT_TOUCH_FIRST, touch(50, 50))
input(EVT_TOUCH_SLIDE, touch(80, 50, { swipeDown = true }))
assert(not state.shown and context.debrief == state, "a swipe down at the top hides")
input(EVT_TOUCH_BREAK, touch(80, 50))
assert(not context.debrief.shown, "release after hiding does not reopen")

-- Leaving fullscreen hides the view without destroying it.
drag(H - 5, H - 40, { swipeUp = true })
for _ = 1, 3 do
    input(EVT_ROT_RIGHT)
end
offset = state.offset
fixture.lvglMock.setFullScreen(false)
fixture.pump(context, 40)
assert(context.debrief == state and not state.shown, "leaving fullscreen closes the debrief")
assert(not state.ui or state.ui.overlay.hidden)
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
assert(has(labelsOf(context.debrief.ui.overlay), "Next 1"))
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

assert(worst < 15000, "debrief callback exceeded budget: " .. worst)
runtime.byId.debrief = realDebrief
print(
    "Debrief view integration passed; 12 tiles built in "
        .. callbacks
        .. " callbacks; worst callback: "
        .. worst
        .. " instructions"
)
