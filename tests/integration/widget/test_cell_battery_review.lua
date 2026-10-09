-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local fixture = WidgetFixture.new()
fixture.reset()
fixture.radio.values[100] = 16.4
local context = fixture.createLoaded(nil, { Layout = "review-cell-battery", Theme = "modern" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(#context.panels, 7)
fixture.assertNoOverlap(context)

local pack = fixture.instanceOf(context, "pack")
local average = fixture.instanceOf(context, "average")
assertions.assertEqual(pack.value.properties.text, "16.40")
assertions.assertEqual(average.value.properties.text, "4.10")
assertions.assertEqual(pack.countLabel.properties.text, "4S")
assertions.assertEqual(average.countLabel.properties.text, "4S")
assertions.assertEqual(pack.packLabel.properties.text, "4.10V AVG")
assertions.assertEqual(average.packLabel.properties.text, "16.4V")
assertions.assertEqual(pack.stateName, "normal")
assertions.assertEqual(average.stateName, "normal")
assertions.assertEqual(pack.summary.lowest, nil)
assert(pack.glyph, "pack panel must draw a battery glyph")
assert(average.glyph, "average panel must draw a battery glyph")
assertions.assertEqual(pack.bar, nil, "battery mode must not draw a bottom bar")
assertions.assertEqual(pack.glyphShown, true)
assertions.assertEqual(pack.glyph.shell.properties.color, pack.glyph.fill.properties.color)
assertions.assertEqual(fixture.instanceOf(context, "smallest").showDetail, false)

local function assertUnitThreshold()
    local panel = fixture.module("panels/cell-battery.lua")
    local kept, dropped = 0, 0
    for width = 100, 320 do
        local rect = { x = 0, y = 0, w = width, h = 136 }
        local area = panel.regionsFor(
            pack.theme,
            pack.themeBuilder,
            rect,
            pack.layout,
            pack.fonts,
            pack.sample,
            nil,
            pack.primitives
        )
        local preferred = pack.primitives.batterySize(math.floor(area.content / 2), area.ladder.room)
        if preferred and area.visualSize then
            local withUnit = pack.themeBuilder.readingWidth(area.value, pack.sample.digits, area.unitFont, "V")
            local whitespace = area.content - withUnit - preferred
            assertions.assertEqual(area.showUnit, whitespace >= rect.w * 0.3, "unit threshold at width " .. width)
            if area.showUnit then
                kept = kept + 1
            else
                dropped = dropped + 1
                assertions.assertEqual(
                    area.valueWidth,
                    pack.themeBuilder.measureText(area.value, pack.sample.digits),
                    "dropped unit must release its reserved width"
                )
            end
        end
    end
    assert(kept > 0 and dropped > 0, "threshold coverage must include both unit states")
    local rect = { x = 0, y = 0, w = 256, h = 136 }
    local frame = pack.themeBuilder.frame(pack.theme, rect, pack.fonts)
    local spec = {
        frame = frame,
        forms = { pack.sample.digits },
        unit = "V",
        draws = { rows = true, visual = true },
        compact = function()
            return 25
        end,
        equalGaps = true,
        rowItems = 2,
    }
    local area = pack.themeBuilder.panel(pack.theme, rect, pack.fonts, spec, {})
    local remaining = area.content - area.valueWidth - 25
    assert(area.showUnit and remaining > 0, "boundary fixture must have room for V")
    spec.minimumGapFraction = remaining / rect.w
    area = pack.themeBuilder.panel(pack.theme, rect, pack.fonts, spec, area)
    assert(area.showUnit, "exactly meeting the whitespace threshold must keep V")
    spec.minimumGapFraction = (remaining + 1) / rect.w
    area = pack.themeBuilder.panel(pack.theme, rect, pack.fonts, spec, area)
    assert(not area.showUnit, "one pixel below the whitespace threshold must drop V")
    spec.unitRequired = true
    area = pack.themeBuilder.panel(pack.theme, rect, pack.fonts, spec, area)
    assert(area.showUnit, "required units in other panels must not be dropped")
end

local function assertEqualGaps(instance)
    local area = instance.area
    assertions.assertEqual(instance.unitDrawn, area.showUnit, "live unit must follow the reserved layout")
    local left = area.valueX - area.frame.pad
    local middle = area.glyphX - (area.valueX + area.valueWidth)
    local right = area.frame.pad + area.frame.content - (area.glyphX + area.glyphWidth)
    assertions.assertEqual(left, right, "outer reserved margins must be equal")
    assert(math.abs(middle - left) <= 2, "three gaps differ by more than integer rounding")
    assert(left >= 4, "the glyph must leave a minimum gap")
    local width =
        instance.themeBuilder.readingWidth(area.value, instance.text, area.unitFont, area.showUnit and "V" or nil)
    assertions.assertEqual(
        instance.value.properties.x,
        area.valueCentre - math.floor(width / 2),
        "number and V must center together within their reserved block"
    )
end

local function assertVerticalAlignment()
    for _, entry in ipairs(context.panels) do
        local instance = entry.instance
        if instance.glyphShown then
            local glyph = instance.glyph
            local top = glyph.nub.properties.y
            local bottom = glyph.shell.properties.y + glyph.shell.properties.h
            local glyphCentre = (top + bottom) / 2
            -- EdgeTX v2.12.0 std glyph_dsc: XXL zero has box_h 48,
            -- ofs_y -1; XL digits have box_h 22, ofs_y 0.
            local font = instance.area.value
            local inkCentre = font == fixture.firmware.XXLSIZE and 31
                or (font == fixture.firmware.DBLSIZE and 20 or (font == fixture.firmware.MIDSIZE and 14.5 or 8.5))
            local numberCentre = instance.value.properties.y + inkCentre
            assert(
                math.abs(glyphCentre - numberCentre) <= 0.5,
                entry.placement.id .. ": battery centre must align with the number's visible ink"
            )
        end
    end
end

assertEqualGaps(pack)
assertEqualGaps(average)
assertUnitThreshold()
assertions.assertEqual(pack.themeBuilder.numberInkCentre(fixture.firmware.XXLSIZE, "1.11"), 31.5)
assertions.assertEqual(pack.themeBuilder.numberInkCentre(fixture.firmware.XXLSIZE, "4.20"), 31)
assertions.assertEqual(pack.themeBuilder.numberInkCentre(fixture.firmware.DBLSIZE, "16.40"), 20)
assertVerticalAlignment()
local glyphX = pack.glyph.shell.properties.x
local showUnit = pack.area.showUnit
fixture.radio.values[100] = 13.6
fixture.pump(context, 40)
assertions.assertEqual(pack.value.properties.text, "13.60")
assertions.assertEqual(average.value.properties.text, "3.40")
assertions.assertEqual(pack.packLabel.properties.text, "3.40V AVG")
assertions.assertEqual(pack.stateName, "warning")
assertions.assertEqual(average.stateName, "warning")
assertions.assertEqual(pack.summary.count, 4, "cell count must not change as the pack drains")
assertions.assertEqual(pack.glyph.shell.properties.x, glyphX, "voltage must not move the glyph")
assertions.assertEqual(pack.area.showUnit, showUnit, "voltage must not change unit visibility")
assertEqualGaps(pack)
assertEqualGaps(average)
assertVerticalAlignment()

fixture.radio.values[100] = 13.2
fixture.pump(context, 40)
assertions.assertEqual(pack.stateName, "critical")
assertions.assertEqual(average.stateName, "critical")
assertions.assertEqual(pack.glyph.shell.properties.color, pack.state("critical", "cyan").accent)

fixture.radio.rssi = 0
fixture.pump(context, 40)
assertions.assertEqual(pack.stateName, "stale")
assertions.assertEqual(average.stateName, "stale")
assertions.assertEqual(pack.value.properties.text, "13.20")

fixture.radio.rssi = 80
fixture.radio.values[100] = 16.4
fixture.pump(context, 40)
assertions.assertEqual(pack.stateName, "normal")
assertions.assertEqual(average.stateName, "normal")
context.zone.w = 320
context.zone.h = 240
fixture.pump(context, 40)
assertions.assertEqual(pack.bar, nil)
assertVerticalAlignment()
context.zone.w = 480
context.zone.h = 272
fixture.pump(context, 40)
assertions.assertEqual(pack.glyphShown, true)
assertions.assertEqual(pack.glyph.shell.properties.x, pack.area.glyphX)
assertEqualGaps(pack)
assertEqualGaps(average)
assertVerticalAlignment()
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
fixture.reset()
fixture.radio.fields.RxBt = nil
local missing = fixture.createLoaded(nil, { Layout = "review-cell-battery", Theme = "modern" })
fixture.pump(missing, 40)
local missingPack = fixture.instanceOf(missing, "pack")
assertions.assertEqual(missingPack.glyphShown, false, "missing voltage must not draw an empty battery")
assertions.assertEqual(missingPack.stateName, "unavailable")
fixture.reset()
