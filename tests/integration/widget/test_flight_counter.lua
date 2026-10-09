-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local definition = fixture.module("main.lua")
local worstCallback = 0

local function measured(callback, context)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 200
    end, "", 200)
    local ok, err = pcall(callback, context)
    debug.sethook()
    assert(ok, err)
    assert(instructions <= 15000, "flight counter exceeded 75% of the firmware instruction budget")
    worstCallback = math.max(worstCallback, instructions)
end

local function create(span, failWrite)
    fixture.reset()
    local radio = fixture.radio
    radio.fields.ch3 = { id = 306, name = "ch3" }
    radio.values[306] = -1024
    radio.globals[8] = 39
    radio.globalsByMode[8] = nil
    radio.globalDetails[8] = { name = "Flights", min = 0, max = 999, prec = 0, unit = 0 }
    local context = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "flight-test", Theme = "modern" },
        root .. "/src/WIDGETS/AeroGrid/"
    )
    context.source = table.concat({
        "version: 1",
        "grid:",
        "  columns: 4",
        "  rows: 4",
        "panels:",
        "  - id: flights",
        "    type: flight-counter",
        "    col: 0",
        "    row: 2",
        "    colSpan: " .. span[1],
        "    rowSpan: " .. span[2],
        "    config:",
        "      armSwitch: SFv",
        "      minFlightDuration: 1",
        "      disarmDuration: 2",
        "      announcements: true",
    }, "\n")
    context.tokens, context.readPosition, context.readLine, context.stage = {}, 1, 1, "tokenize"
    while context.stage do
        measured(definition.refresh, context)
    end
    equal(#context.errors, 0, table.concat(context.errors, "\n"))
    local panel = assert(fixture.instanceOf(context, "flights"))
    local env = context.serviceRuntime.env
    local history, sounds = nil, {}
    env.getDateTime = function()
        return { year = 2026, mon = 10, day = 6, hour = 16, min = 0 }
    end
    env.playTone = function(frequency)
        sounds[#sounds + 1] = frequency
    end
    env.playNumber = function(count)
        sounds[#sounds + 1] = count
    end
    env.fileOpen = function(_, access)
        if access == "r" then
            return history and {} or nil
        end
        history = history or ""
        return {}
    end
    env.fileClose = function() end
    env.fileWrite = function(_, text)
        if failWrite then
            error("SD card full")
        end
        history = history .. text
    end
    return context, panel, function()
        return history, sounds
    end
end

local function backgroundUntil(context, predicate, limit)
    for _ = 1, limit or 100 do
        fixture.tick(20)
        measured(definition.background, context)
        if predicate() then
            return
        end
    end
    error("flight tracking did not reach the expected state")
end

for _, span in ipairs({ { 1, 1 }, { 2, 1 }, { 2, 2 }, { 4, 2 } }) do
    local context, panel, recorded = create(span)
    fixture.pump(context, 10)
    equal(panel.text, "39")
    fixture.radio.values[305], fixture.radio.values[306] = 1024, 0
    backgroundUntil(context, function()
        return panel.phase == "active"
    end)
    equal(model.getGlobalVariable(8, 0), 40)
    equal(panel.value.properties.text, "40")
    equal(panel.stateName, "active")
    equal(panel.panel.background.properties.color, context.theme.alertColor.active)
    equal(panel.panel.accent.properties.color, context.theme.color.blue)
    equal(panel.badge.properties.text, "IN-FLIGHT")
    assert(panel.badge.properties.x + panel.badge.properties.w <= panel.area.frame.badgeX + panel.area.frame.badgeWidth)
    local font = panel.value.properties.font
    local objects = #fixture.lvglMock.objects
    context.zone.w = 640
    fixture.pump(context, 10)
    equal(panel.value.properties.font, font, "reflow must not replace a font callback")
    equal(#fixture.lvglMock.objects, objects, "reflow must not allocate new objects")
    fixture.radio.rssi = 0
    fixture.pump(context, 60)
    equal(panel.phase, "active", "telemetry loss must not finish the flight")
    fixture.radio.values[305] = -1024
    backgroundUntil(context, function()
        return panel.phase == "ending"
    end)
    local log = recorded()
    equal(log, nil, "history is written only at confirmed end")
    equal(panel.stateName, "active", "the pending end retains active styling")
    backgroundUntil(context, function()
        return panel.phase == "ground"
    end)
    log = recorded()
    assert(string.find(log, ",Test Model,40,", 1, true), log)
    equal(panel.stateName, "normal")
    equal(panel.panel.background.properties.color, context.theme.color.surface)
    equal(model.getGlobalVariable(8, 0), 40)
    equal(#context.errors, 0)
    local _, sounds = recorded()
    equal(sounds[1], 1200)
    equal(sounds[2], 40)
    equal(sounds[3], 800)
    equal(sounds[4], 40)
end

local context, panel = create({ 2, 2 }, true)
fixture.radio.values[305], fixture.radio.values[306] = 1024, 0
backgroundUntil(context, function()
    return panel.phase == "active"
end)
fixture.radio.values[305] = -1024
backgroundUntil(context, function()
    return #context.errors > 0
end)
assert(string.find(context.errors[1], "SD card full", 1, true), context.errors[1])
assert(fixture.entryById(context, "flights").failed, "failed history must be reported through panel isolation")
equal(model.getGlobalVariable(8, 0), 40, "a history failure must not discard the persistent count")
fixture.pump(context, 10)
equal(#context.errors, 1, "report a failed panel only once")

context, panel = create({ 2, 2 })
fixture.radio.values[305], fixture.radio.values[306] = 1024, 0
backgroundUntil(context, function()
    return panel.phase == "starting"
end)
fixture.tick(200)
definition.background(context)
assert(panel.phase ~= "active", "a scheduling gap must restart qualification")
backgroundUntil(context, function()
    return panel.phase == "active"
end)
fixture.radio.values[305] = -1024
backgroundUntil(context, function()
    return panel.phase == "ending"
end)
fixture.tick(300)
definition.background(context)
assert(panel.phase ~= "ground", "a scheduling gap must restart the disarm timeout")
backgroundUntil(context, function()
    return panel.phase == "ground"
end)
assert(worstCallback > 0, "the flight counter budget was not measured")

local recorded
context, panel, recorded = create({ 2, 2 })
panel.preview = true
fixture.radio.values[305], fixture.radio.values[306] = 1024, 0
for _ = 1, 100 do
    fixture.tick(20)
    measured(definition.background, context)
end
equal(model.getGlobalVariable(8, 0), 39, "unsaved preview cannot increment the persistent counter")
equal(panel.phase, "ground", "unsaved preview cannot start a flight tracker")
fixture.radio.values[305] = -1024
fixture.pump(context, 30)
local history, sounds = recorded()
equal(history, nil, "unsaved preview cannot write flight history")
equal(#sounds, 0, "unsaved preview cannot announce flights")
equal(panel.value.properties.text, "39", "unsaved preview still displays the current count")
