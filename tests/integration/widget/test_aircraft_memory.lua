-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
local radio = fixture.radio
fixture.reset()
radio.fields.VSpd = { id = 150, name = "VSpd", unit = fixture.firmware.UNIT.METERS_PER_SECOND }
radio.fields["VSpd+"] = { id = 151, name = "VSpd+", unit = fixture.firmware.UNIT.METERS_PER_SECOND }
fixture.radioMock.indexFields()
radio.globalDetails[0].prec = 0
local context = fixture.createLoaded(nil, { DashID = "default", Theme = "modern" })

local callbacks = 0
local function pump(count)
    for _ = 1, count do
        fixture.tick(20)
        definition.refresh(context)
        fixture.lvglMock.settle()
        callbacks = callbacks + 1
    end
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
end

local function inputs(index)
    radio.rssi = 75
    radio.values[100] = 6.6 + (index % 19) / 10
    radio.values[106] = index % 1000
    radio.values[108] = 1000 + index % 1000
    radio.values[150] = (index % 101 - 50) / 10
    radio.values[151] = (index % 41) / 10
    radio.values[141] = 70 + index % 31
    radio.values[143] = -110 + index % 70
    radio.values[146] = index % 2 == 0 and 21 or 27
    radio.values[320] = 6.5 + (index % 19) / 10
    radio.globals[0] = index % 101
    radio.globals[8] = index % 10000
    radio.timers[0].value = index
end

local link = assert(fixture.instanceOf(context, "link"))
local battery = assert(fixture.instanceOf(context, "receiver-battery"))
local clock = assert(fixture.instanceOf(context, "flight-clock"))
local flights = assert(fixture.instanceOf(context, "flight-count"))
local altitude = assert(fixture.instanceOf(context, "altitude"))
local baselineObjects
local function checkpoint()
    inputs(0)
    pump(40)
    assert(link.text == "70" and link.stateName == "normal", "link did not recover")
    assert(battery.text == "3.30" and battery.countText == "2S", "pack telemetry was not exercised")
    assert(clock.text and flights.text == "0", "radio-local readings were not exercised")
    fixture.lvglMock.releaseClearedObjects()
    assert(fixture.lvglMock.replacedFontRefCount() == 0, "font replacement leaked firmware registry references")
    collectgarbage("collect")
    collectgarbage("collect")
    local objects = #fixture.lvglMock.objects
    if baselineObjects then
        assert(objects == baselineObjects, "aircraft dashboard accumulated live LVGL objects")
    end
    return collectgarbage("count"), objects
end

local function cycle(number)
    for step = 1, 100 do
        inputs(number * 100 + step)
        pump(1)
    end
    pump(40)
    assert(link.text ~= "NO LINK", "live telemetry never reached the link panel")
    assert(
        battery.text == string.format("%.2f", radio.values[100] / 2),
        "changing battery telemetry never reached the panel"
    )
    assert(flights.text == tostring(radio.globals[8]), "changing GV never reached the panel")
    assert(altitude.feed.value == radio.values[106], "changing altitude never reached the panel")
    radio.rssi = 0
    pump(40)
    assert(link.text == "NO LINK" and link.stateName == "critical", "link loss was not exercised")
    assert(battery.stateName == "stale", "other telemetry did not become stale")
end

-- Warm every changing-value and recovery path before measuring retained memory.
for number = 1, 10 do
    cycle(number)
    checkpoint()
end
local baseline
baseline, baselineObjects = checkpoint()
local maximum = baseline
local midpoint
local final
for number = 11, 110 do
    cycle(number)
    final = checkpoint()
    maximum = math.max(maximum, final)
    assert(
        final - baseline < 1,
        string.format("aircraft retained %.3f KiB after %d measured cycles", final - baseline, number - 10)
    )
    if number == 60 then
        midpoint = final
    end
end
assert(
    final - midpoint < 0.25,
    string.format("aircraft retained another %.3f KiB during the final 50 cycles", final - midpoint)
)
print(
    string.format(
        "  aircraft retained-memory test: %d callbacks, 100 measured loss/recovery cycles;"
            .. " %d live objects, peak growth %.3f KiB, final growth %.3f KiB, second-half change %.3f KiB",
        callbacks,
        baselineObjects,
        maximum - baseline,
        final - baseline,
        final - midpoint
    )
)

radio.rssi = 0
pump(40)
assert(link.text == "NO LINK")
local function disconnectedMinute(minute)
    for second = 1, 60 do
        radio.timers[0].value = minute * 60 + second
        pump(5)
    end
    assert(link.text == "NO LINK" and battery.stateName == "stale")
    local timer = fixture.module("panels/flight-timer.lua")
    local expected = timer.formatClock(timer.clamp(timer.displayValue(clock.feed)))
    assert(clock.text == expected, "continuously advancing disconnected timer was not rendered")
    fixture.lvglMock.releaseClearedObjects()
    assert(fixture.lvglMock.replacedFontRefCount() == 0, "timer updates replaced firmware font callbacks")
    collectgarbage("collect")
    collectgarbage("collect")
    assert(#fixture.lvglMock.objects == baselineObjects, "disconnected dashboard accumulated objects")
    return collectgarbage("count")
end

for minute = 0, 4 do
    disconnectedMinute(minute)
end
baseline = disconnectedMinute(5)
maximum, midpoint, final = baseline, nil, nil
for minute = 6, 35 do
    final = disconnectedMinute(minute)
    maximum = math.max(maximum, final)
    assert(
        final - baseline < 1,
        string.format("disconnected aircraft retained %.3f KiB after %d minutes", final - baseline, minute - 5)
    )
    if minute == 20 then
        midpoint = final
    end
end
assert(
    final - midpoint < 0.25,
    string.format("disconnected aircraft retained another %.3f KiB during the final 15 minutes", final - midpoint)
)
print(
    string.format(
        "  disconnected aircraft timer: 30 measured simulated minutes at 5 callbacks/second;"
            .. " peak growth %.3f KiB, final growth %.3f KiB, second-half change %.3f KiB",
        maximum - baseline,
        final - baseline,
        final - midpoint
    )
)
