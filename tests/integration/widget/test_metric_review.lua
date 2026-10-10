-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local fixture = WidgetFixture.new()
fixture.reset()
fixture.radio.fields.GAlt = { id = 106, name = "GAlt", unit = fixture.radio.fields.Alt.unit }
fixture.radio.fields["GAlt+"] = { id = 108, name = "GAlt+", unit = fixture.radio.fields.Alt.unit }
local context = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(#context.panels, 7)
fixture.assertNoOverlap(context)
local altitude = fixture.instanceOf(context, "altitude")
local speed = fixture.instanceOf(context, "speed")
local voltage = fixture.instanceOf(context, "voltage")
assert(altitude.bar)
assert(speed.radial)
assertions.assertEqual(speed.settings.source, "VSpd")
assert(altitude.showRange and altitude.showSecondary)
assertions.assertEqual(altitude.settings.source, "GAlt")
assertions.assertEqual(altitude.stateName, "normal")
assertions.assertEqual(altitude.unitText, "m")
assertions.assertEqual(altitude.rangeText, "MAX 180 m")
assertions.assertEqual(altitude.secondaryText, "VS 2.5 m/s")
assertions.assertEqual(speed.rangeText, "RX 24.0 V")
assertions.assertEqual(speed.secondaryText, "ALT 100 m")
local sensorUnit = fixture.instanceOf(context, "sensor-unit")
assertions.assertEqual(sensorUnit.unitText, "m/s")
assert(sensorUnit.showUnit and not sensorUnit.unit.hidden)
assertions.assertEqual(fixture.instanceOf(context, "unavailable").stateName, "unavailable")
assert(not fixture.instanceOf(context, "compact").showRange)
local gv = fixture.instanceOf(context, "compact")
assertions.assertEqual(gv.settings.source, "gvar1")
assertions.assertEqual(gv.text, "4.5")
assertions.assertEqual(gv.feed.telemetry, false)
fixture.radio.globalsByMode[0] = { [1] = 75 }
fixture.radio.flightMode = 1
fixture.pump(context, 40)
assertions.assertEqual(gv.text, "7.5")
fixture.radio.flightMode = 0
fixture.radio.globalsByMode[0] = nil
fixture.pump(context, 40)
assertions.assertEqual(gv.text, "4.5")
assert(not voltage.range)
local wide = fixture.instanceOf(context, "wide-altitude")
assertions.assertEqual(altitude.area.supportingPlacement, "footer")
assertions.assertEqual(wide.area.supportingPlacement, "side")
assert(wide.showRange and wide.showSecondary)
assert(not wide.range.hidden and not wide.secondary.hidden)
assertions.assertEqual(wide.rangeText, "MAX 180 m")
assertions.assertEqual(wide.secondaryText, "VS 2.5 m/s")
assert(wide.area.valueCentre < wide.area.detailCentre)
assert(wide.range.properties.y < wide.secondary.properties.y)
local primaryFont = wide.area.value
local caption = wide.metrics[2].label
wide.metrics[2].label = string.rep("M", 100)
fixture.pump(context, 40)
assertions.assertEqual(wide.area.supportingPlacement, "hidden")
assert(wide.range.hidden and wide.secondary.hidden)
assertions.assertEqual(wide.area.value, primaryFont)
assertions.assertEqual(wide.area.valueCentre, wide.area.pad + math.floor(wide.area.content / 2))
wide.metrics[2].label = caption
fixture.pump(context, 40)
assertions.assertEqual(wide.area.supportingPlacement, "side")
assert(not wide.range.hidden and not wide.secondary.hidden)
assertions.assertEqual(wide.rangeText, "MAX 180 m")
fixture.radio.values[108] = 250
fixture.radio.values[120] = 7.25
fixture.pump(context, 40)
assertions.assertEqual(altitude.rangeText, "MAX 250 m")
assertions.assertEqual(altitude.secondaryText, "VS 7.2 m/s")
assertions.assertEqual(altitude.stateName, "normal")
assertions.assertEqual(speed.text, "7.2")
assertions.assertEqual(speed.stateName, "warning")
fixture.radio.values[120] = 2.5
fixture.radio.values[106] = 300
fixture.radio.values[100] = 22
fixture.pump(context, 40)
assertions.assertEqual(altitude.stateName, "warning")
assertions.assertEqual(voltage.stateName, "warning")
fixture.radio.values[106] = 400
fixture.radio.values[100] = 20
fixture.pump(context, 40)
assertions.assertEqual(altitude.stateName, "critical")
assertions.assertEqual(voltage.stateName, "critical")
for _, zone in ipairs({ { w = 320, h = 240 }, { w = 480, h = 272 } }) do
    context.zone.w, context.zone.h = zone.w, zone.h
    fixture.pump(context, 40)
    assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    fixture.assertNoOverlap(context)
    if wide.showRange then
        local primaryWidth = lcd.sizeText(wide.text, wide.area.value)
        local unitWidth = wide.showUnit and lcd.sizeText(wide.unitText, wide.area.unitFont) or 0
        assert(wide.value.properties.x + primaryWidth + unitWidth <= wide.range.properties.x)
        local _, height = lcd.sizeText("M", wide.fonts.label)
        assert(wide.range.properties.y + height <= wide.secondary.properties.y)
        assert(wide.secondary.properties.y + height <= wide.area.barY)
    else
        assert(wide.range.hidden and wide.secondary.hidden)
    end
end
fixture.lvglMock.setAppMode(true)
for _, fullscreen in ipairs({ false, true, false, true }) do
    fixture.lvglMock.setFullScreen(fullscreen)
    fixture.pump(context, 40)
    for _, entry in ipairs(context.panels) do
        local panel = entry.instance
        if panel.area.valueCentre then
            local x, width = panel.value.properties.x, panel.value.properties.w
            local unitX = panel.unit and panel.unit.properties.x
            panel.readingAnchor, panel.readingUnitAnchor = nil, nil
            context.primitives.centreReading(panel, context.themeBuilder, panel.area, panel.area.value, panel.text)
            assertions.assertEqual(panel.value.properties.x, x, "fullscreen reflow already centres unchanged readings")
            assertions.assertEqual(panel.value.properties.w, width, "fullscreen reflow preserves reading group width")
            if panel.unit then
                assertions.assertEqual(
                    panel.unit.properties.x,
                    unitX,
                    "fullscreen reflow keeps unit beside unchanged reading"
                )
            end
        end
    end
end
fixture.lvglMock.setFullScreen(false)
fixture.lvglMock.setAppMode(false)
fixture.reset()
fixture.radio.fields.GAlt = nil
fixture.radio.fields["GAlt+"] = nil
