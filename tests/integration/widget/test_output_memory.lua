-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
fixture.reset()
local sample, readable, named, ambiguous = 0, true, true, false
fixture.radio.fields.ail = { id = 5001, name = "ail" }
fixture.radio.fields.ele = { id = 5002, name = "ele" }
fixture.radioMock.indexFields()
function getOutputValue(index)
    if readable then
        return (sample + index * 67) % 3073 - 1536
    end
end
model.getOutput = function(index)
    return { name = named and (index % 2 == 0 and "AILERON" or "ELE") or "" }
end
model.getMix = function(_, line)
    if line == 0 or ambiguous and line == 1 then
        return { source = 5001 + line, carryTrim = false, weight = 100 }
    end
end
local context = fixture.createLoaded({ x = 0, y = 0, w = 800, h = 800 }, {
    Layout = "review-output",
    Theme = "modern-dark",
})
local panel = assert(fixture.instanceOf(context, "outputs"))
local output = fixture.module("panels/output.lua")
local callbacks = 0
local function pump(count)
    for _ = 1, count do
        fixture.tick(10)
        definition.refresh(context)
        fixture.lvglMock.settle()
        callbacks = callbacks + 1
    end
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
end

local function configure(first, count, names, trims, width)
    output.update(panel, { x = 0, y = 0, w = width, h = 800 }, {
        label = "CHANNEL OUTPUT",
        accent = "cyan",
        firstChannel = first,
        channelCount = count,
        showNames = names,
        showTrim = trims,
    })
    pump(180)
    assert(panel.showRows == panel.area.count, "configured rows never finished mounting")
    assert(panel.rows[1].feed.index == first - 1, "channel range was not exercised")
end

local baselineObjects
local function checkpoint()
    readable, named, ambiguous, sample = true, true, false, 0
    fixture.radio.values[310] = 0
    configure(1, 32, true, true, 800)
    assert(#panel.rows == 32, "all channel slots must be warmed before measurement")
    assert(panel.rows[1].captionText == "CH1: AIL", "named captions did not recover")
    assert(not panel.rows[1].trim.hidden, "trim associations did not recover")
    fixture.lvglMock.releaseClearedObjects()
    assert(fixture.lvglMock.replacedFontRefCount() == 0, "output reflow replaced firmware font callbacks")
    collectgarbage("collect")
    collectgarbage("collect")
    if baselineObjects then
        assert(#fixture.lvglMock.objects == baselineObjects, "output panel accumulated live LVGL objects")
    end
    return collectgarbage("count"), #fixture.lvglMock.objects
end

local function cycle(number)
    for step = 1, 60 do
        sample = number * 71 + step * 37
        fixture.radio.values[310] = (step % 9 - 4) * 128
        pump(1)
    end
    pump(20)
    assert(panel.rows[1].feed.raw == sample % 3073 - 1536, "changing outputs never reached the feed")
    assert(panel.rows[1].trimFraction ~= 0, "changing trims never reached the panel")
    readable = false
    pump(30)
    assert(panel.stateName == "unavailable", "output availability loss was not exercised")
    assert(panel.rows[1].fill.hidden and panel.rows[1].fillOrigin.hidden and panel.rows[1].trim.hidden)
    readable, named, ambiguous = true, false, true
    pump(180)
    assert(panel.rows[1].captionText == "CH1", "ambiguous inferred names must disappear")
    assert(panel.rows[1].trim.hidden, "ambiguous trim associations must disappear")
    configure(9, 8, false, false, 120)
    assert(panel.rows[1].captionText == "CH9")
    assert(panel.rows[1].value.hidden and panel.rows[1].trim.hidden, "narrow display toggles were not exercised")
    configure(31, 32, true, true, 480)
    assert(panel.area.count == 2 and panel.rows[2].channel == 32, "CH32 range limit was not exercised")
    assert(not panel.rows[1].value.hidden, "wide percentage readouts did not recover")
end

for number = 1, 5 do
    checkpoint()
    cycle(number)
end
local baseline
baseline, baselineObjects = checkpoint()
local maximum, midpoint, final = baseline, nil, nil
for number = 1, 100 do
    cycle(number)
    final = checkpoint()
    maximum = math.max(maximum, final)
    assert(final - baseline < 1, string.format("output retained %.3f KiB after %d cycles", final - baseline, number))
    if number == 50 then
        midpoint = final
    end
end
assert(final - midpoint < 0.25, "output retained memory continued growing during the final 50 cycles")
print(
    string.format(
        "  output retained-memory test: %d callbacks, 100 measured cycles; %d live objects;"
            .. " peak growth %.3f KiB, final growth %.3f KiB, second-half change %.3f KiB",
        callbacks,
        baselineObjects,
        maximum - baseline,
        final - baseline,
        final - midpoint
    )
)
