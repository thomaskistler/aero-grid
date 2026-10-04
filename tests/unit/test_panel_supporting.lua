-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local fixture = WidgetFixture.new()
fixture.reset()
local context = fixture.createLoaded()
local panel = fixture.instanceOf(context, "altitude")
local builder = panel.themeBuilder
local function areaFor(w, h, supporting, compact, out)
    local rect = { x = 0, y = 0, w = w, h = h }
    return builder.panel(panel.theme, rect, panel.fonts, {
        frame = builder.frame(panel.theme, rect, panel.fonts),
        forms = { "100" },
        unit = "m",
        draws = { rows = true, visual = compact ~= nil },
        compact = compact,
        bar = compact == nil,
        rowItems = supporting and supporting[2] and 2 or 1,
        supporting = supporting,
    }, out or {})
end

local supporting = { "MAX 180 m", "VS 2.5 m/s" }
local area = areaFor(234, 130, supporting)
assertions.assertEqual(area.supportingPlacement, "footer")
assert(area.showDetail and not area.showSide)
assert(area.detailCentre < area.rowRightCentre)
assertions.assertEqual(area.detailY, area.rowRightY)
area = areaFor(234, 65, supporting, nil, area)
assertions.assertEqual(area.supportingPlacement, "side")
assert(area.showSide and not area.showDetail)
assertions.assertEqual(area.detailCentre, area.rowRightCentre)
assert(area.detailY < area.rowRightY)
local bare = areaFor(234, 65)
assertions.assertEqual(area.value, bare.value, "supporting text must not shrink the primary")
assertions.assertEqual(area.showUnit, bare.showUnit)
local primaryWidth = builder.readingWidth(area.value, "100", area.unitFont, area.showUnit and "m" or nil)
assert(area.valueCentre + math.ceil(primaryWidth / 2) <= area.detailX)
assert(area.rowRightY + builder.fontHeight(panel.fonts.label) <= 65 - area.frame.bottom)

area = areaFor(110, 65, supporting, nil, area)
assertions.assertEqual(area.supportingPlacement, "hidden")
assert(not area.showSide and not area.showDetail)
assertions.assertEqual(area.valueCentre, area.pad + math.floor(area.content / 2))
area = areaFor(234, 130, supporting, nil, area)
assertions.assertEqual(area.supportingPlacement, "footer")
assertions.assertEqual(area.rowRightY, area.detailY, "a previous stack must not leave vertical offsets behind")

local one = areaFor(234, 130, { "MAX 180 m" })
assertions.assertEqual(one.supportingPlacement, "footer")
assertions.assertEqual(one.detailCentre, one.pad + math.floor(one.content / 2))
one = areaFor(234, 65, { "MAX 180 m" })
assertions.assertEqual(one.supportingPlacement, "side")
assert(one.showSide)
local dial = areaFor(234, 65, supporting, function()
    return 20
end)
assert(dial.showVisual, "the dial must retain priority over a supporting stack")
assertions.assertEqual(dial.supportingPlacement, "hidden")
local oversized = areaFor(234, 130, { string.rep("M", 100), "VS 2.5 m/s" })
assertions.assertEqual(oversized.supportingPlacement, "hidden")
fixture.reset()
