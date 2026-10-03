-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local fixture = WidgetFixture.new()
fixture.reset()
fixture.radio.rssiAbsent = true
fixture.radio.rssi = 0
fixture.radio.values[140] = 0
fixture.radio.values[141] = 0
fixture.radio.values[143] = 0
fixture.radio.values[147] = 0
local context = fixture.createLoaded(nil, { DashID = "review-link-status", Theme = "modern" })
fixture.pump(context, 40)
local disconnected = fixture.instanceOf(context, "detailed")
assertions.assertEqual(disconnected.stateName, "unavailable")
assertions.assertEqual(disconnected.link.live, false, "RFMD and TPWR cannot prove receiver telemetry is live")
assertions.assertEqual(disconnected.readingCache.margin, nil)
fixture.radio.values[141] = 100
fixture.radio.values[143] = -72
fixture.pump(context, 40)
assertions.assertEqual(disconnected.link.live, true, "receiver telemetry can establish a live link without getRSSI")
assertions.assertEqual(disconnected.readingCache.margin, 36)
fixture.reset()
context = fixture.createLoaded(nil, { DashID = "review-link-status", Theme = "modern" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(#context.components, 6)
fixture.assertNoOverlap(context)
local detailed = fixture.instanceOf(context, "detailed")
assertions.assertEqual(detailed.primaryName, "quality")
assertions.assertEqual(detailed.text, "96")
assertions.assertEqual(detailed.readingCache.margin, 36)
assertions.assertEqual(detailed.stateName, "normal")
assertions.assertEqual(detailed.linkDetail, "-72dBm (+36dB)")
assert(detailed.detailLabel.hidden, "paired row must not duplicate RSSI")
assert(detailed.showExtra, "2x3 must show RF mode, SNR and power")
assert(string.find(detailed.extra, "250Hz", 1, true))
assert(string.find(detailed.extra, "8dB", 1, true))
assert(string.find(detailed.extra, "250mW", 1, true))
assertions.assertEqual(fixture.instanceOf(context, "unavailable").stateName, "unavailable")
assert(not fixture.instanceOf(context, "compact").showDetail)
assert(not fixture.instanceOf(context, "wide-quality").showDetail)
local wide = fixture.instanceOf(context, "wide-quality")
assert(wide.showSide)
assertions.assertEqual(wide.side, "-72dBm")
assertions.assertEqual(wide.margin, "(+36dB)")
assert(not wide.detailLabel.hidden and not wide.linkLabel.hidden)
assert(wide.area.valueCentre < wide.area.sideCentre)
assert(not fixture.instanceOf(context, "compact").showSide)

fixture.radio.values[143] = -103
fixture.pump(context, 40)
assertions.assertEqual(detailed.stateName, "critical")
assertions.assertEqual(wide.margin, "(+5dB)")
assertions.assertEqual(wide.stateName, "critical")
assertions.assertEqual(detailed.linkDetail, "LOW MARGIN (+5dB)")
assertions.assertEqual(detailed.text, "96", "LQ remains measured, not a composite score")
fixture.radio.values[146] = 21
fixture.pump(context, 40)
assertions.assertEqual(detailed.stateName, "normal")
assertions.assertEqual(detailed.readingCache.margin, 12)
assert(string.find(detailed.extra, "50Hz", 1, true))
fixture.radio.values[147] = -8
fixture.radio.values[148] = 100
fixture.pump(context, 40)
assert(string.find(detailed.extra, "-8dB", 1, true))
assert(string.find(detailed.extra, "100mW", 1, true))
fixture.radio.values[146] = 255
fixture.pump(context, 40)
assertions.assertEqual(detailed.readingCache.margin, nil)
assertions.assertEqual(detailed.linkDetail, "UNKNOWN MODE")
fixture.radio.values[141] = 70
fixture.pump(context, 40)
assertions.assertEqual(detailed.stateName, "critical")
assertions.assertEqual(detailed.linkDetail, "LOW LQ")

for _, zone in ipairs({ { w = 320, h = 240 }, { w = 480, h = 272 } }) do
    context.zone.w, context.zone.h = zone.w, zone.h
    fixture.pump(context, 40)
    assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    fixture.assertNoOverlap(context)
    if wide.showSide then
        local _, height = lcd.sizeText("M", wide.fonts.label)
        assert(wide.detailLabel.properties.y + height <= wide.linkLabel.properties.y)
        assert(wide.linkLabel.properties.y + height <= wide.area.barY)
        local valueX = wide.value.properties.x
        local valueWidth = lcd.sizeText(wide.text, wide.area.value)
        assert(valueX + valueWidth <= wide.detailLabel.properties.x)
    else
        assert(wide.detailLabel.hidden and wide.linkLabel.hidden)
    end
    if detailed.showExtra then
        assertions.assertEqual(detailed.extraLabel.hidden, false)
        local _, height = lcd.sizeText("M", detailed.fonts.label)
        assert(detailed.linkLabel.properties.y + height <= detailed.extraLabel.properties.y)
    else
        assert(detailed.extraLabel.hidden)
    end
end
fixture.reset()
