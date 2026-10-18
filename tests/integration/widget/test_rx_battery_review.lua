-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local fixture = WidgetFixture.new()
fixture.reset()
fixture.radio.values[100] = 16.4
local context = fixture.createLoaded(nil, { Layout = "review-rx-battery", Theme = "modern-dark" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(#context.panels, 7)
fixture.assertNoOverlap(context)

local pack = fixture.instanceOf(context, "pack")
local average = fixture.instanceOf(context, "average")
assertions.assertEqual(pack.value.properties.text, "16.40")
assertions.assertEqual(average.value.properties.text, "4.10")
-- The battery glyph never carries supporting details, whatever the room.
assertions.assertEqual(pack.area.countShown, false, "battery mode must drop the cell count")
assertions.assertEqual(pack.area.packShown, false, "battery mode must drop the alternate reading")
assertions.assertEqual(pack.showDetail, false)
assertions.assertEqual(pack.countLabel.hidden, true)
assertions.assertEqual(pack.packLabel.hidden, true)
-- Alternate reading is text only: the count and the alternate voltage.
assertions.assertEqual(average.area.countShown, true)
assertions.assertEqual(average.area.packShown, true)
assertions.assertEqual(average.countLabel.properties.text, "4S EST")
assertions.assertEqual(average.packLabel.properties.text, "16.4V")
assertions.assertEqual(average.glyph, nil, "alternate reading must not draw a battery glyph")
assertions.assertEqual(average.bar, nil, "alternate reading must not draw a bar")
-- A narrow bar keeps both, the alternate reading in its shorter wording.
local narrowPack = fixture.instanceOf(context, "narrow-pack")
assertions.assertEqual(narrowPack.countLabel.properties.text, "4S")
assertions.assertEqual(narrowPack.packLabel.properties.text, "4.10V")
assert(narrowPack.bar, "bar mode must draw its bar")
assertions.assertEqual(pack.stateName, "normal")
assertions.assertEqual(average.stateName, "normal")
assertions.assertEqual(pack.summary.lowest, nil)
assertions.assertEqual(average.summary.estimated, true)
assert(pack.glyph, "pack panel must draw a battery glyph")
assertions.assertEqual(pack.bar, nil, "battery mode must not draw a bottom bar")
assertions.assertEqual(pack.glyphShown, true)
assertions.assertEqual(pack.glyph.shell.properties.color, pack.glyph.fill.properties.color)
assertions.assertEqual(fixture.instanceOf(context, "smallest").showDetail, false)

local function assertUnitThreshold()
    local panel = fixture.module("panels/rx-battery.lua")
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

--- Sweep the supporting arrangement across sizes, modes and wordings.
---
--- Details are preferences shed quietly, so the contract is geometric: a
--- battery glyph carries none, the count outranks the alternate reading, and
--- whatever is shown fits its slot without touching the reading, the bar, the
--- heading, the other label or the panel's edge.
local function assertAdaptiveSupporting()
    local panel = fixture.module("panels/rx-battery.lua")
    local instance = average
    local theme, builder, fonts = instance.theme, instance.themeBuilder, instance.fonts
    local labelHeight = builder.fontHeight(fonts.label)
    local seen = { both = 0, count = 0, pack = 0, none = 0, footer = 0, side = 0, delta = 0, three = 0 }
    local function box(centre, y, text)
        local width = builder.measureText(fonts.label, text)
        return { x = centre - math.floor(width / 2), y = y, w = width, h = labelHeight }
    end
    local function apart(a, b)
        return a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y
    end
    for _, visual in ipairs({ "battery", "bar", "none" }) do
        for _, sample in ipairs({ average.sample, pack.sample }) do
            for width = 60, 480, 11 do
                for height = 40, 272, 7 do
                    local rect = { x = 0, y = 0, w = width, h = height }
                    for _, count in ipairs({ "8S", "8S EST", "CELLS ERR", "" }) do
                        for _, packForm in ipairs({ "88.8V", "8.88V", "" }) do
                            local delta = packForm == "8.88V" and CHAR_DELTA .. " 88.88v" or ""
                            local layout = {
                                visual = visual,
                                showVisual = true,
                                showDetail = true,
                                countForm = count,
                                deltaForm = delta,
                                packForm = packForm,
                            }
                            local where = visual
                                .. " "
                                .. width
                                .. "x"
                                .. height
                                .. " ["
                                .. count
                                .. "|"
                                .. packForm
                                .. "]"
                            local area =
                                panel.regionsFor(theme, builder, rect, layout, fonts, sample, nil, instance.primitives)
                            if visual == "battery" or (count == "" and packForm == "") then
                                assert(not area.countShown and not area.packShown, where .. ": details shown")
                            end
                            assert(not (area.countShown and count == ""), where .. ": empty count shown")
                            assert(not (area.packShown and packForm == ""), where .. ": empty reading shown")
                            if not area.countShown and count ~= "" and (area.deltaShown or area.packShown) then
                                local priority = panel.regionsFor(theme, builder, rect, {
                                    visual = visual,
                                    showVisual = true,
                                    showDetail = true,
                                    countForm = count,
                                }, fonts, sample, nil, instance.primitives)
                                assert(not priority.countShown, where .. ": a lower detail displaced a fitting count")
                            end
                            if area.packShown and not area.deltaShown and delta ~= "" then
                                local priority = panel.regionsFor(theme, builder, rect, {
                                    visual = visual,
                                    showVisual = true,
                                    showDetail = true,
                                    countForm = area.countShown and count or "",
                                    deltaForm = delta,
                                }, fonts, sample, nil, instance.primitives)
                                assert(not priority.deltaShown, where .. ": secondary displaced a fitting delta")
                            end
                            local boxes = {}
                            if area.countShown then
                                assert(
                                    builder.measureText(fonts.label, count) <= area.detailWidth,
                                    where .. ": count overflows its slot"
                                )
                                boxes[#boxes + 1] = box(area.detailCentre, area.detailY, count)
                            end
                            if area.packShown then
                                assert(
                                    builder.measureText(fonts.label, packForm) <= area.rowRightWidth,
                                    where .. ": alternate reading overflows its slot"
                                )
                                boxes[#boxes + 1] = box(area.rowRightCentre, area.rowRightY, packForm)
                            end
                            if area.deltaShown then
                                local slot = area.deltaSlot
                                assert(
                                    builder.measureText(fonts.label, delta) <= slot.w,
                                    where .. ": delta slot overflow"
                                )
                                boxes[#boxes + 1] = box(slot.centre, slot.y, delta)
                                seen.delta = seen.delta + 1
                                if area.countShown and area.packShown then
                                    seen.three = seen.three + 1
                                end
                            end
                            local readingWidth = builder.readingWidth(
                                area.value,
                                sample.digits,
                                area.unitFont,
                                area.showUnit and sample.unit or nil
                            )
                            local reading = {
                                x = area.valueCentre - math.floor(readingWidth / 2),
                                y = area.valueY,
                                w = readingWidth,
                                -- Digits stand on the baseline, so the ink ends there; the
                                -- line box below it is clearance, not drawing.
                                h = builder.fontAscent(area.value) + 1,
                            }
                            for index, label in ipairs(boxes) do
                                assert(label.x >= 0 and label.x + label.w <= width, where .. ": label leaves the panel")
                                assert(label.y >= area.frame.top, where .. ": label climbs into the heading")
                                assert(label.y + label.h <= height, where .. ": label leaves the panel")
                                assert(apart(label, reading), where .. ": label overlaps the reading")
                                if visual == "bar" and area.showVisual then
                                    assert(label.y + label.h <= area.barY, where .. ": label overlaps the bar")
                                end
                                for previous = 1, index - 1 do
                                    assert(apart(boxes[previous], label), where .. ": labels overlap")
                                end
                            end
                            if area.countShown and area.packShown then
                                seen.both = seen.both + 1
                            elseif area.countShown then
                                seen.count = seen.count + 1
                            elseif area.packShown then
                                seen.pack = seen.pack + 1
                            elseif visual ~= "battery" and count ~= "" then
                                seen.none = seen.none + 1
                            end
                            if #boxes > 0 then
                                seen[area.supportingPlacement] = seen[area.supportingPlacement] + 1
                            end
                        end
                    end
                end
            end
        end
    end
    for key, total in pairs(seen) do
        assert(total > 0, "sweep never reached supporting arrangement " .. key)
    end
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
assertUnitThreshold()
assertAdaptiveSupporting()
assertions.assertEqual(pack.themeBuilder.numberInkCentre(fixture.firmware.XXLSIZE, "1.11"), 31.5)
assertions.assertEqual(pack.themeBuilder.numberInkCentre(fixture.firmware.XXLSIZE, "4.20"), 31)
assertions.assertEqual(pack.themeBuilder.numberInkCentre(fixture.firmware.DBLSIZE, "16.40"), 20)
assertVerticalAlignment()
local glyphX = pack.glyph.shell.properties.x
local showUnit = pack.area.showUnit
fixture.radio.values[100] = 14.0
fixture.pump(context, 40)
assertions.assertEqual(pack.value.properties.text, "14.00")
assertions.assertEqual(average.value.properties.text, "3.50")
assertions.assertEqual(pack.packLabel.hidden, true, "battery mode must keep the alternate reading dropped")
assertions.assertEqual(average.packLabel.properties.text, "14.0V")
assertions.assertEqual(narrowPack.packLabel.properties.text, "3.50V")
assertions.assertEqual(pack.stateName, "warning")
assertions.assertEqual(average.stateName, "warning")
assertions.assertEqual(pack.summary.count, 4, "cell count must not change as the pack drains")
assertions.assertEqual(average.summary.count, 4, "estimated cell count changed as pack voltage fell")
assertions.assertEqual(average.countLabel.properties.text, "4S EST")
assertions.assertEqual(pack.glyph.shell.properties.x, glyphX, "voltage must not move the glyph")
assertions.assertEqual(pack.area.showUnit, showUnit, "voltage must not change unit visibility")
assertEqualGaps(pack)
assertVerticalAlignment()

fixture.radio.values[100] = 13.6
fixture.pump(context, 40)
assertions.assertEqual(pack.stateName, "critical")
assertions.assertEqual(average.stateName, "critical")
assertions.assertEqual(pack.glyph.shell.properties.color, pack.state("critical", "cyan").accent)

fixture.radio.rssi = 0
fixture.pump(context, 40)
assertions.assertEqual(pack.stateName, "stale")
assertions.assertEqual(average.stateName, "stale")
assertions.assertEqual(pack.value.properties.text, "13.60")

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
-- A short wide alternate reading stacks both details beside the number; a
-- shorter one keeps the count and drops the alternate reading. The narrow
-- panel retains the count beside its header-clearing battery glyph.
context.zone.w = 480
context.zone.h = 136
fixture.pump(context, 40)
assertions.assertEqual(average.area.supportingPlacement, "side")
assertions.assertEqual(average.countLabel.hidden, false)
assertions.assertEqual(average.packLabel.hidden, false)
assertions.assertEqual(average.packLabel.properties.text, "16.4V")
assertions.assertEqual(narrowPack.area.countShown, true)
assertions.assertEqual(narrowPack.countLabel.hidden, false)
assertions.assertEqual(narrowPack.packLabel.hidden, true)
context.zone.h = 120
fixture.pump(context, 40)
assertions.assertEqual(average.area.supportingPlacement, "side")
assertions.assertEqual(average.countLabel.properties.text, "4S")
assertions.assertEqual(average.countLabel.hidden, false)
assertions.assertEqual(average.packLabel.hidden, true, "the alternate reading must go before the count")
assertions.assertEqual(pack.countLabel.hidden, true)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
context.zone.w = 480
context.zone.h = 272
fixture.pump(context, 40)
assertions.assertEqual(pack.glyphShown, true)
assertions.assertEqual(pack.glyph.shell.properties.x, pack.area.glyphX)
assertions.assertEqual(average.area.supportingPlacement, "footer")
assertions.assertEqual(average.countLabel.properties.text, "4S EST")
assertions.assertEqual(average.packLabel.hidden, false)
assertions.assertEqual(narrowPack.countLabel.hidden, false)
assertEqualGaps(pack)
assertVerticalAlignment()
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
fixture.reset()
local rxField = fixture.radio.fields.RxBt
fixture.radio.fields.RxBt = nil
local missing = fixture.createLoaded(nil, { Layout = "review-rx-battery", Theme = "modern-dark" })
fixture.pump(missing, 40)
local missingPack = fixture.instanceOf(missing, "pack")
assertions.assertEqual(missingPack.glyphShown, false, "missing voltage must not draw an empty battery")
assertions.assertEqual(missingPack.stateName, "unavailable")
fixture.radio.fields.RxBt = rxField
fixture.reset()
fixture.radio.values[100] = 16.4
local live = fixture.createLoaded(nil, { Layout = "review-rx-battery", Theme = "modern-dark" })
fixture.pump(live, 40)
local monitor = fixture.instanceOf(live, "monitor")
local panel = fixture.module("panels/rx-battery.lua")
panel.update(monitor, { x = 0, y = 0, w = 238, h = 134 })
panel.refresh(monitor)
assertions.assertEqual(monitor.deltaText, CHAR_DELTA .. " 0.04v", "delta draws exactly two decimals and lowercase v")
assertions.assertEqual(monitor.deltaLabel.hidden, false)
assertions.assertEqual(monitor.area.countShown, true)
assertions.assertEqual(monitor.area.packShown, true, "wide cells footer must fit all three details")
monitor.settings.cells = 16
fixture.radio.values[130] = { 4.10, 4.11 }
fixture.pump(live, 40)
assertions.assertEqual(monitor.deltaText, CHAR_DELTA .. " 0.01v")
assertions.assertEqual(monitor.countText, "2S", "tables ignore configured numeric count")
fixture.radio.rssi = 0
fixture.pump(live, 40)
assertions.assertEqual(monitor.stateName, "stale")
assertions.assertEqual(monitor.deltaText, CHAR_DELTA .. " 0.01v", "stale cell delta is retained")
fixture.radio.rssi = 80
fixture.radio.values[130] = {}
fixture.pump(live, 40)
assertions.assertEqual(monitor.stateName, "unavailable")
assertions.assertEqual(monitor.countText, "NO CELLS")
assertions.assertEqual(monitor.deltaLabel.hidden, true, "empty cells reserve no delta slot")
fixture.radio.values[130] = { -1, 0 }
fixture.pump(live, 40)
assertions.assertEqual(monitor.countText, "CELLS ERR")
assertions.assertEqual(monitor.deltaLabel.hidden, true)
fixture.radio.values[130] = { 4.10, 4.11 }
fixture.pump(live, 40)
assertions.assertEqual(monitor.deltaLabel.hidden, false, "valid table restores the delta after errors")
monitor.settings.showDelta = false
fixture.pump(live, 40)
assertions.assertEqual(monitor.deltaLabel.hidden, true)
monitor.settings.showDelta = true
monitor.settings.showCount = false
monitor.settings.showPack = false
fixture.pump(live, 40)
assertions.assertEqual(monitor.deltaLabel.hidden, false, "delta alone occupies the full footer")
assertions.assertEqual(monitor.area.deltaSlot.w, monitor.area.frame.content)
-- Source changes use the newly subscribed reading's shape, not a saved selector.
monitor.settings.source = "RxBt"
monitor.settings.cells = 4
monitor.feed = fixture.instanceOf(live, "average").feed
fixture.pump(live, 40)
assertions.assertEqual(monitor.summary.shape, "pack")
assertions.assertEqual(monitor.deltaLabel.hidden, true, "numeric source has no empty delta slot")
assertions.assertEqual(monitor.primary, 4.1)
monitor.settings.source = "Cels"
monitor.feed = live.serviceRuntime.byId.telemetry:subscribe("Cels")
fixture.pump(live, 40)
assertions.assertEqual(monitor.summary.shape, "cells")
assertions.assertEqual(monitor.deltaText, CHAR_DELTA .. " 0.01v")
assertions.assertEqual(monitor.deltaLabel.hidden, false)
fixture.reset()
