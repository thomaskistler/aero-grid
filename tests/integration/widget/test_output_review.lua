-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
fixture.reset()
local values = { 51, -102, 819, 0 }
local names = { "AIL", "ELE", "THR", "RUD" }
local sourceNames = { "ail", "ele", "thr", "rud" }
for index, name in ipairs(sourceNames) do
    fixture.radio.fields[name] = { id = 5000 + index, name = name }
end
-- EdgeTX api_general.cpp: luaGetOutputValue returns channelOutputs[index].
-- Unlike getValue("chN"), this is the final output after limits and reversal.
function getOutputValue(index)
    return values[index + 1] or 0
end
model.getOutput = function(index)
    return { name = names[index + 1] or "" }
end
model.getMix = function(index, line)
    if index < 4 and line == 0 then
        return { source = 5001 + index, carryTrim = false, weight = 100 }
    end
end

local resolvingNames = true
local outputReader = model.getOutput
model.getOutput = function(index)
    return resolvingNames and { name = "" } or outputReader(index)
end
local context = fixture.createLoaded(nil, { Layout = "review-output", Theme = "modern-dark" })
local worst = 0
local function measured(callback)
    local count = 0
    debug.sethook(function()
        count = count + 200
    end, "", 200)
    local ok, err = pcall(callback)
    debug.sethook()
    assert(ok, err)
    worst = math.max(worst, count)
    assert(count <= 20000, "output callback exceeded firmware budget: " .. count)
end
local function pump()
    for _ = 1, 180 do
        fixture.tick(20)
        measured(function()
            definition.refresh(context)
        end)
        if resolvingNames then
            local instance = fixture.instanceOf(context, "outputs")
            if instance then
                local labeled = 0
                for index, row in ipairs(instance.rows) do
                    if row.captionText and row.captionText ~= "" then
                        labeled = labeled + 1
                        local name = sourceNames[index]
                        equal(row.captionText, "CH" .. index .. (name and ": " .. name or ""))
                    end
                end
                assert(
                    labeled == 0 or labeled == instance.area.count,
                    "initial captions must appear together with resolved names"
                )
            end
        end
    end
    equal(#context.errors, 0, table.concat(context.errors, "\n"))
    fixture.assertNoOverlap(context)
end
pump()
resolvingNames = false
pump()
local panel = assert(fixture.instanceOf(context, "outputs"))
local function checkGeometry()
    local area = panel.area
    local widestCaption = 0
    equal(#panel.rows >= area.count, true)
    assert(area.top + area.count * area.pitch <= panel.panel.height - area.frame.bottom)
    if area.count < 32 then
        assert(
            area.top + (area.count + 1) * area.pitch > panel.panel.height - area.frame.bottom,
            "must show every row that fits"
        )
    end
    for index, row in ipairs(panel.rows) do
        equal(row.root.hidden, index > area.count)
        if index <= area.count then
            assert(row.x >= area.captionWidth + 8)
            equal(row.caption.properties.x, 0, "channel captions must be left aligned")
            equal(row.x - row.caption.properties.w, 8)
            assert(row.x + row.width + 8 <= row.value.properties.x)
            widestCaption = math.max(widestCaption, panel.themeBuilder.measureText(area.font, row.captionText))
            equal(#row.dots, 2)
            equal(row.dots[1].fraction, -0.5)
            equal(row.dots[2].fraction, 0.5)
            equal(row.top, nil, "simplified tracks have no top rail")
            equal(row.bottom, nil, "simplified tracks have no bottom rail")
            equal(row.track.properties.rounded, 0, "background tracks are flat")
            for _, dot in ipairs(row.dots) do
                equal(dot.object.properties.x + 1, row.x + math.floor((dot.fraction + 1) * (row.width - 1) / 2 + 0.5))
            end
            equal(row.zero.properties.x, row.x + math.floor((row.width - 1) / 2 + 0.5))
            equal(row.zero.properties.color, panel.tapeColors.zero, "neutral tick uses the darker scale color")
            equal(row.zero.properties.w, 2, "neutral tick is two pixels wide")
        end
    end
    equal(area.captionWidth, widestCaption, "caption column must match the actual widest visible caption")
end
checkGeometry()
equal(panel.rows[1].text, "+5%")
equal(panel.rows[2].text, "-10%")
equal(panel.rows[3].text, "+80%")
equal(panel.rows[4].text, "0%")
equal(panel.rows[1].captionText, "CH1: AIL")
equal(panel.rows[1].fillOrigin.properties.x, panel.rows[1].zero.properties.x)
equal(panel.rows[1].fillOrigin.properties.rounded, 0, "positive fills have square inner corners")
names[1] = "AILERON"
pump()
equal(panel.rows[1].captionText, "CH1: AIL", "channel names are limited to three letters")
names[1] = ""
pump()
equal(panel.rows[1].captionText, "CH1: ail", "unnamed outputs use their mix source")
names[1] = "AIL"
pump()
local controlEnv = context.serviceRuntime.byId.control.env
local originalOutput, originalMix, originalInput = controlEnv.getOutput, controlEnv.getMix, controlEnv.getInput
controlEnv.getOutput = function()
    return { name = "" }
end
fixture.radio.fields.input1 = { id = 5010, name = "input1" }
controlEnv.getMix = function(index, line)
    if index < 4 and line == 0 then
        return { source = 5010, carryTrim = true, weight = 100 }
    end
end
controlEnv.getInput = function(_, line)
    if line == 0 then
        return { inputName = "Aileron", source = 5004, trimSource = 0 }
    end
end
pump()
equal(panel.rows[1].captionText, "CH1: Ail", "real model input names must reach the caption")
assert(panel.rows[1].trim.hidden, "inferred labels do not enable disabled trims")
controlEnv.getOutput, controlEnv.getMix = originalOutput, originalMix
controlEnv.getInput = originalInput or function() end
pump()
assert(not panel.rows[1].trim.hidden)
equal(panel.rows[1].trim.properties.color, panel.theme.color.green)
assert(panel.rows[5].trim.hidden, "unmapped channels must not show a trim arrow")
local row = panel.rows[1]
local trimX = row.trim.properties.pts[3][1]
values[1] = -1536
pump()
equal(row.text, "-150%")
equal(row.trim.properties.pts[3][1], trimX, "output changes must not move the trim pointer")
equal(row.fill.properties.x, row.x, "extended output fill must clamp at the tape edge")
equal(row.fill.properties.w, math.floor((row.width - 1) / 2 + 0.5))
equal(row.fillOrigin.properties.x + row.fillOrigin.properties.w, row.zero.properties.x)
equal(row.fillOrigin.properties.h, row.height, "negative fills have square inner corners")
checkGeometry()
equal(
    row.value.properties.x - row.x - row.width,
    8 + panel.area.valueWidth - panel.themeBuilder.measureText(panel.area.font, "-150%"),
    "signed percentages keep the full gutter in addition to reserved text width"
)
for _, raw in ipairs({ -1024, 1024, 1536 }) do
    values[1] = raw
    pump()
    assert(row.value.properties.x - row.x - row.width >= 8, "signed full travel must retain the right gutter")
end
fixture.radio.values[310] = 512
pump()
assert(row.trim.properties.pts[3][1] > trimX)

for _, size in ipairs({ { 320, 240 }, { 800, 480 }, { 800, 800 }, { 480, 272 } }) do
    context.zone.w, context.zone.h = size[1], size[2]
    pump()
    checkGeometry()
end
local objects = #fixture.lvglMock.objects
pump()
equal(#fixture.lvglMock.objects, objects, "steady output refresh must reuse mounted objects")
local savedReader = getOutputValue
-- A missing API is an explicit unavailable panel, not a row of plausible zeros.
context.serviceRuntime.byId.control.env.getOutputValue = nil
pump()
equal(panel.stateName, "unavailable")
equal(row.text, "--")
assert(row.fill.hidden)
assert(row.fillOrigin.hidden)
assert(row.trim.hidden)
context.serviceRuntime.byId.control.env.getOutputValue = savedReader
pump()
equal(panel.stateName, "normal")
local outputModule = fixture.module("panels/output.lua")
local function configure(options)
    local settings = {}
    for key, value in pairs(panel.settings) do
        settings[key] = value
    end
    for key, value in pairs(options) do
        settings[key] = value
    end
    measured(function()
        outputModule.update(panel, { x = 0, y = 0, w = panel.panel.width, h = panel.panel.height }, settings)
    end)
    pump()
end
configure({ firstChannel = 2, channelCount = 2, showNames = false, showTrim = false })
equal(panel.area.count, 2)
equal(panel.rows[1].channel, 2)
equal(panel.rows[1].feed.index, 1)
equal(panel.rows[1].captionText, "CH2")
equal(panel.rows[2].captionText, "CH3")
equal(panel.rows[2].text, "+80%")
assert(panel.rows[1].trim.hidden)
assert(panel.rows[3].root.hidden)
configure({ showNames = true, showTrim = true })
equal(panel.rows[1].captionText, "CH2: ELE")
assert(not panel.rows[1].trim.hidden)
configure({ firstChannel = 31, channelCount = 10 })
equal(panel.area.count, 2)
equal(panel.rows[1].captionText, "CH31")
equal(panel.rows[2].captionText, "CH32")
equal(panel.rows[2].feed.index, 31)
measured(function()
    outputModule.update(panel, { x = 0, y = 0, w = 120, h = 240 }, panel.settings)
end)
pump()
assert(not panel.area.showValues)
assert(panel.rows[1].value.hidden, "narrow rows hide the percentage label")
equal(panel.rows[1].x + panel.rows[1].width, panel.area.frame.content, "bars reclaim the percentage column")
measured(function()
    outputModule.update(panel, { x = 0, y = 0, w = 480, h = 272 }, panel.settings)
end)
pump()
assert(not panel.rows[1].value.hidden, "percentage labels return when resized wider")
print("  output review: worst refresh " .. worst .. " instructions")
fixture.reset()
