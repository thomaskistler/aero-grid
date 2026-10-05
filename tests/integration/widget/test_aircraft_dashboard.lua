-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local radio = fixture.radio
radio.globals[0] = 70
radio.globalDetails[0].prec = 0
radio.globals[8] = 39
radio.fields.VSpd = { id = 140, name = "VSpd", unit = fixture.firmware.UNIT.METERS_PER_SECOND }
radio.fields["VSpd+"] = { id = 142, name = "VSpd+", unit = fixture.firmware.UNIT.METERS_PER_SECOND }
radio.values[140] = 2.5
radio.values[142] = 4.2
radio.values[100] = 8.0

local context = fixture.createLoaded(nil, { DashID = "default", Theme = "modern" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
assertions.assertEqual(#context.panels, 8)
fixture.assertNoOverlap(context)

local expected = {
    ["transmitter-battery"] = { 3, 0, 1, 1 },
    ["receiver-battery"] = { 0, 1, 2, 1 },
    link = { 0, 2, 2, 1 },
    altitude = { 0, 3, 2, 1 },
    ["flight-clock"] = { 0, 0, 2, 1 },
    ["flight-count"] = { 2, 1, 1, 1 },
    expo = { 3, 1, 1, 1 },
    identity = { 2, 2, 2, 2 },
}
for id, dimensions in pairs(expected) do
    local placement = assert(fixture.entryById(context, id)).placement
    assertions.assertEqual(placement.col, dimensions[1])
    assertions.assertEqual(placement.row, dimensions[2])
    assertions.assertEqual(placement.colSpan, dimensions[3])
    assertions.assertEqual(placement.rowSpan, dimensions[4])
end
assertions.assertEqual(fixture.instanceOf(context, "flight-count").text, "39")
assertions.assertEqual(fixture.instanceOf(context, "expo").text, "70")
assertions.assertEqual(fixture.entryById(context, "transmitter-battery").placement.type, "tx-battery")
assertions.assertEqual(fixture.entryById(context, "receiver-battery").placement.type, "cell-battery")
local battery = fixture.instanceOf(context, "receiver-battery")
assertions.assertEqual(battery.area.supportingPlacement, "side")
assertions.assertEqual(battery.text, "4.00")
assertions.assertEqual(battery.settings.source, "RxBt")
assertions.assertEqual(battery.settings.sourceType, "pack")
assertions.assertEqual(battery.countText, "2S")
assertions.assertEqual(battery.packText, "8.0V")
assert(battery.packLabel.properties.y > battery.countLabel.properties.y)
assertions.assertEqual(fixture.entryById(context, "link").placement.type, "link-status")
assert(not fixture.instanceOf(context, "link").bar, "link bar should not be constructed")
local altitude = fixture.instanceOf(context, "altitude")
assertions.assertEqual(altitude.settings.source, "Alt")
assertions.assertEqual(altitude.area.supportingPlacement, "side")
assertions.assertEqual(altitude.metrics[2].source, "Alt+")
assertions.assertEqual(altitude.metrics[3].source, "VSpd+")
local link = fixture.instanceOf(context, "link")
assertions.assertEqual(link.detailLabel.properties.color, altitude.range.properties.color)
assertions.assertEqual(link.linkLabel.properties.color, altitude.secondary.properties.color)
assertions.assertEqual(link.detailLabel.properties.color, battery.countLabel.properties.color)
assertions.assertEqual(link.linkLabel.properties.color, battery.packLabel.properties.color)

radio.globals[8] = 40
radio.globals[0] = 65
fixture.pump(context, 40)
assertions.assertEqual(fixture.instanceOf(context, "flight-count").text, "40")
assertions.assertEqual(fixture.instanceOf(context, "expo").text, "65")

local corner = fixture.createLoaded(fixture.lvglMock.appZone(), { DashID = "default", Theme = "modern" })
fixture.pump(corner, 40)
local timer = fixture.instanceOf(corner, "flight-clock")
assert(timer.area.frame.reserved.side)
assert(timer.area.valueCentre > timer.area.frame.reserved.w)
assert(timer.area.valueY < timer.area.frame.reserved.h, "timer was still forced below the button")
assertions.assertEqual(timer.area.clock, fixture.instanceOf(context, "flight-clock").area.clock)
assertions.assertEqual(timer.area.valueCentre, fixture.instanceOf(context, "flight-clock").area.valueCentre)

local cellBattery = fixture.module("panels/cell-battery.lua")
local originalRect = battery.rect
local originalFont = battery.area.value
cellBattery.update(battery, { x = 0, y = 0, w = 80, h = originalRect.h })
cellBattery.refresh(battery)
assertions.assertEqual(battery.showDetail, false, "narrow panels must shed supporting readings")
assert(battery.countLabel.hidden and battery.packLabel.hidden)
cellBattery.update(battery, originalRect)
cellBattery.refresh(battery)
assertions.assertEqual(battery.area.supportingPlacement, "side")
assertions.assertEqual(battery.area.value, originalFont, "supporting readings must not shrink the headline")
assertions.assertEqual(battery.countText, "2S")
assertions.assertEqual(battery.packText, "8.0V")
assert(not battery.countLabel.hidden and not battery.packLabel.hidden)

battery.settings.showCount = false
cellBattery.refresh(battery)
assertions.assertEqual(battery.countText, "")
assertions.assertEqual(battery.packText, "8.0V")
assertions.assertEqual(battery.packLabel.properties.y, battery.area.detailY)
assertions.assertEqual(battery.layout.supporting[2], nil, "a disabled count must not reserve a stack row")
battery.settings.showCount = true
battery.settings.showPack = false
cellBattery.refresh(battery)
assertions.assertEqual(battery.countText, "2S")
assertions.assertEqual(battery.packText, "")
assertions.assertEqual(battery.layout.supporting[2], nil, "a disabled voltage must not reserve a stack row")
battery.settings.showPack = true
cellBattery.refresh(battery)
assertions.assertEqual(battery.packText, "8.0V")
assert(battery.packLabel.properties.y > battery.countLabel.properties.y)

cellBattery.update(battery, { x = 0, y = 0, w = originalRect.w, h = 136 })
cellBattery.refresh(battery)
assertions.assertEqual(battery.area.supportingPlacement, "footer")
assertions.assertEqual(battery.packLabel.properties.y, battery.countLabel.properties.y)
cellBattery.update(battery, originalRect)
cellBattery.refresh(battery)
assertions.assertEqual(battery.area.supportingPlacement, "side")

local span = { colSpan = 2, rowSpan = 1 }
assertions.assertEqual(#cellBattery.validateSettings(battery.settings, span, { showPack = true, showCount = true }), 0)
span.colSpan = 1
assertions.assertEqual(#cellBattery.validateSettings(battery.settings, span, { showPack = true, showCount = true }), 2)
