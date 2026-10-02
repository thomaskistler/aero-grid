-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local fixture = WidgetFixture.new()
fixture.reset()
local context = fixture.createLoaded(nil, { DashID = "review-trim-panel", Theme = "modern" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(#context.components, 7)
fixture.assertNoOverlap(context)
local axes = fixture.instanceOf(context, "axes")
assertions.assertEqual(#axes.indicators, 3)
assertions.assertEqual(axes.indicators[1].name, "trim-ail")
assertions.assertEqual(axes.indicators[2].name, "trim-ele")
assertions.assertEqual(axes.indicators[3].name, "trim-rud")
assertions.assertEqual(axes.dot.properties.color, lcd.RGB(0xFFFFFF))
assert(axes.showValue, "square review panel must retain all three readouts")
for _, indicator in ipairs(axes.indicators) do
    assert(not indicator.value.hidden, "axis readout must be visible")
    assert(indicator.value.properties.x > axes.indicators[1].bar.x + axes.indicators[1].bar.w)
end
local function assertAxes()
    local top, right, bottom = axes.indicators[1].bar, axes.indicators[2].bar, axes.indicators[3].bar
    assert(top.y < bottom.y and right.x < top.x)
    assert(not top.vertical and right.vertical and not bottom.vertical)
    assertions.assertEqual(top.w, right.h, "horizontal and vertical bars must have equal lengths")
    assertions.assertEqual(bottom.w, right.h, "rudder must share the square's side length")
    assertions.assertEqual(
        top.x + top.w - right.x,
        bottom.y + bottom.h - right.y,
        "corner gaps must preserve square geometry"
    )
    assert(top.x >= right.x + right.w + 2, "top bar must clear the left corner")
    assert(bottom.x >= right.x + right.w + 2, "bottom bar must clear the left corner")
    assert(right.y >= top.y + top.h + 2, "vertical bar must start below the top corner")
    assert(right.y + right.h <= bottom.y - 2, "vertical bar must stop above the bottom corner")
    assertions.assertEqual(
        axes.dot.properties.x + 3,
        axes.area.centreX + math.floor(axes.indicators[1].feed.fraction * (top.w - 6) / 2 + 0.5)
    )
    assertions.assertEqual(
        axes.dot.properties.y + 3,
        axes.area.centreY - math.floor(axes.indicators[2].feed.fraction * (right.h - 6) / 2 + 0.5)
    )
    assertions.assertEqual(top.x + math.floor(top.w / 2), bottom.x + math.floor(bottom.w / 2))
    local textRight = 0
    for _, indicator in ipairs(axes.indicators) do
        local bar = indicator.bar
        local inkCentre = indicator.value.properties.y
            + axes.themeBuilder.numberInkCentre(axes.area.readoutFont, indicator.valueText)
        assert(math.abs(inkCentre - (bar.y + bar.h / 2)) <= 0.5, "readout ink must center on its bar")
        textRight = math.max(textRight, indicator.value.properties.x + indicator.value.properties.w)
    end
    assert(math.abs(right.x - (axes.panel.width - textRight)) <= 1, "visible group must have equal outer margins")
end
assertAxes()
local compact = fixture.instanceOf(context, "single")
assert(compact.showValue, "1x1 axes must retain numeric readouts")
for index, suffix in ipairs({ " A", " E", " R" }) do
    assertions.assertEqual(string.sub(compact.indicators[index].valueText, -2), suffix)
    assertions.assertEqual(string.sub(axes.indicators[index].valueText, -2), suffix)
end
for _, indicator in ipairs(compact.indicators) do
    assert(not indicator.value.hidden)
    assert(indicator.value.properties.x > compact.indicators[1].bar.x + compact.indicators[1].bar.w)
end
local compactRight = 0
for _, indicator in ipairs(compact.indicators) do
    compactRight = math.max(compactRight, indicator.value.properties.x + indicator.value.properties.w)
end
assert(
    math.abs(compact.indicators[2].bar.x - (compact.panel.width - compactRight)) <= 1,
    "1x1 square and reserved number column must be centered"
)
local fixedBarX = axes.indicators[1].bar.x
local fixedTextRight = axes.indicators[1].value.properties.x + axes.indicators[1].value.properties.w
assertions.assertEqual(
    axes.area.cells[1].valueX + axes.area.groupOffset - (axes.indicators[1].bar.x + axes.indicators[1].bar.w),
    4,
    "reserved text column must start four pixels beyond the horizontal bar end"
)
for _, raw in ipairs({ 0, 256, -256, 1024, -1024, 0 }) do
    fixture.radio.values[310] = raw
    fixture.pump(context, 40)
    local bar = axes.indicators[1].bar
    assertions.assertEqual(bar.x, fixedBarX, "trim changes must not move the square")
    assertions.assertEqual(
        axes.indicators[1].value.properties.x + axes.indicators[1].value.properties.w,
        fixedTextRight,
        "readout right edge must stay fixed"
    )
    assert(axes.area.cells[1].textWidth >= axes.themeBuilder.measureText(axes.area.readoutFont, "-100%"))
    assertions.assertEqual(bar.fill.properties.color, axes.state("normal", "green").accent)
    assert(not bar.fill.hidden, "fill must stay mounted through neutral")
    assertions.assertEqual(bar.endpoint, nil, "no moving endpoint tick")
    local centre = bar.x + math.floor(bar.w / 2)
    local fill = bar.fill.properties
    if raw > 0 then
        assertions.assertEqual(fill.x, centre)
        assert(axes.dot.properties.x + 3 > axes.area.centreX, "positive aileron must move dot right")
    elseif raw < 0 then
        assertions.assertEqual(fill.x + fill.w, centre)
        assert(axes.dot.properties.x + 3 < axes.area.centreX, "negative aileron must move dot left")
    end
    if raw ~= 0 then
        assertions.assertEqual(fill.w, math.max(1, math.floor(math.abs(raw / 1024) * math.floor(bar.w / 2) + 0.5)))
        assertions.assertEqual(fill.color, axes.theme.color.green)
    end
end
for _, raw in ipairs({ 0, 256, -256, 1024, -1024, 0 }) do
    fixture.radio.values[311] = raw
    fixture.radio.values[312] = raw
    fixture.pump(context, 40)
    local bar = axes.indicators[2].bar
    assertions.assertEqual(bar.fill.properties.color, axes.state("normal", "green").accent)
    assertions.assertEqual(axes.indicators[3].bar.fill.properties.color, axes.state("normal", "green").accent)
    local centre = bar.y + math.floor(bar.h / 2)
    local fill = bar.fill.properties
    if raw > 0 then
        assertions.assertEqual(fill.y + fill.h, centre)
        assert(axes.dot.properties.y + 3 < axes.area.centreY, "positive elevator must move dot up")
    elseif raw < 0 then
        assertions.assertEqual(fill.y, centre)
        assert(axes.dot.properties.y + 3 > axes.area.centreY, "negative elevator must move dot down")
    end
end
context.zone.w = 320
context.zone.h = 240
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
fixture.assertNoOverlap(context)
assertAxes()
context.zone.w = 480
context.zone.h = 272
fixture.pump(context, 40)
assertAxes()
fixture.assertNoOverlap(context)
fixture.reset()
