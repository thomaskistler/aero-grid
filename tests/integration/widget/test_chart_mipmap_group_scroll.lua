-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local function load(path, ...)
    local base = string.sub(path, 1, 6) == "tests/" and root .. "/" or root .. "/src/WIDGETS/AeroGrid/"
    return assert(loadfile(base .. path))(...)
end
local prototype = load("tests/support/chart_mipmap_prototype.lua", load)

-- Integer physical widths, including unequal ring quarters, gaps and wraps.
for _, width in ipairs({ 226, 397, 398, 399, 400, 600, 800 }) do
    local plotWidth = width
    fixture.reset()
    local chart = {
        plotHost = lvgl.box({ x = 0, y = 0, w = plotWidth + 20, h = 120 }),
        rect = { w = plotWidth + 20, h = 120 },
        area = { x = 4, y = 10, w = plotWidth, h = 90 },
        series = {
            { color = lcd.RGB(255, 0, 0) },
            { color = lcd.RGB(0, 255, 0) },
            { color = lcd.RGB(0, 0, 255) },
        },
    }
    local item = prototype.new(chart, width)
    item.groupedScroll, item.scrollGaps, item.live = true, true, true
    while not item:prepare() do
    end
    assert(item.width == plotWidth, "output must use the drawable pixel width")
    assert(#item.objects == plotWidth * #chart.series, "span representation expanded its native pool")
    assert(#item.groups == 12, "one integer parent per ring quarter and series")
    for _, object in ipairs(item.objects) do
        assert(object.kind == "rectangle", "span should use native filled rectangle geometry")
        assert(object.properties.w == 1 and object.properties.filled, "span should remain one pixel wide")
        assert(object.properties.thickness == 0, "span should not add border pixels")
    end
    while not item:prepareScroll() do
    end
    item:verify()
    local resized = false
    for _, operation in ipairs({ "scroll", "vertical", "scroll", "scroll", "scroll", "resize", "scroll" }) do
        item:begin(operation)
        item:sample(item.nextStamp)
        item.admitted = true
        local turns = 0
        repeat
            fixture.tick(5)
            item:sample(item.clock + 1, turns % 3 == 2)
            local mapped = item.mapped
            item:step()
            fixture.lvglMock.settle()
            turns = turns + 1
            assert(item.mapped - mapped <= 3 * item.batch, "catch-up exceeded the column allowance")
            assert(turns < 30, "grouped redraw failed to settle")
        until not item.active
        item:verify()
        if operation == "resize" then
            resized = true
        elseif operation == "scroll" then
            assert(item.groupMoves == (resized and 0 or 12), "scroll used the wrong geometry path")
        end
    end
    -- One series can advance the shared window while the others receive no reading.
    item:begin("vertical")
    item:step()
    local span = item.maps[1].levels[10].span
    item.clock = math.ceil(span * (1 + (item.published[1].origin + item.width / 4) / item.width))
    item.maps[1]:sample(item.clock, 0.8)
    local turns = 0
    while item.active do
        item:step()
        fixture.lvglMock.settle()
        turns = turns + 1
        assert(turns < 30, "uneven-series boundary redraw failed to settle")
    end
    item:verify()
    for series, map in ipairs(item.maps) do
        assert(item.published[series].origin == select(2, map:select(item.clock)), "series retained an old window")
    end
end
print("Grouped native-parent scroll geometry checks passed")
