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
    definition = fixture.module("main.lua")
    local radio = fixture.radio
    radio.fields.ch3 = { id = 306, name = "ch3" }
    radio.values[306] = -1024
    radio.globals[8] = 39
    radio.globalsByMode[8] = nil
    radio.globalDetails[8] = { name = "Flights", min = 0, max = 999, prec = 0, unit = 0 }
    local context = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "flight-test", Theme = "modern-dark" },
        root .. "/src/WIDGETS/AeroGrid/"
    )
    while context.stage == "theme-read" or context.stage == "theme-validate" do
        measured(definition.refresh, context)
    end
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
    local owner = context.flightBroker
    error(
        "flight tracking did not reach the expected state: "
            .. tostring(fixture.instanceOf(context, "flights").phase)
            .. " status="
            .. tostring(owner and owner.state.status)
            .. " error="
            .. tostring(context.flightErrorText)
            .. " phase="
            .. tostring(owner and owner.session and owner.session.phase)
    )
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
    equal(#sounds, 0, "legacy announcements must not play audio")
end

local context, panel = create({ 2, 2 }, true)
fixture.radio.values[305], fixture.radio.values[306] = 1024, 0
backgroundUntil(context, function()
    return panel.phase == "active"
end)
fixture.radio.values[305] = -1024
backgroundUntil(context, function()
    return context.flightBroker.state.historyError ~= nil
end)
assert(string.find(context.flightErrorText, "SD card full", 1, true), context.flightErrorText)
assert(not fixture.entryById(context, "flights").failed, "history errors must not retire a counter presentation")
equal(model.getGlobalVariable(8, 0), 40, "a history failure must not discard the persistent count")
fixture.pump(context, 10)
equal(#context.errors, 0, "flight failures use recoverable service diagnostics")

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
equal(model.getGlobalVariable(8, 0), 40, "a presentation preview cannot stop the committed flight tracker")
equal(panel.phase, "active", "the shared tracker is independent of presentation flags")
fixture.radio.values[305] = -1024
fixture.pump(context, 30)
local history, sounds = recorded()
assert(history, "the committed tracker completes while its presentation is previewed")
equal(#sounds, 0, "previewing must not play flight audio")
equal(panel.value.properties.text, "40", "preview displays the shared count")

-- Exercise the unchanged callback ceiling with all Smart sensor categories
-- present, including discovery, GPS validation, qualification and completion.
context, panel, recorded = create({ 2, 2 })
local owner = context.flightBroker
local env, lookup = owner.env, owner.env.getFieldInfo
local sensors = {
    [12] = { type = 0, id = 9, instance = 0, unit = 9, prec = 2 },
    [37] = { type = 0, id = 2, instance = 0, unit = 40, prec = 0 },
    [49] = { type = 0, id = 2, instance = 2, unit = 8, prec = 1 },
    [59] = { type = 0, id = 2, instance = 5, unit = 0, prec = 0 },
}
local values = { [12] = 0, [37] = { lat = 1, lon = 2, delay = 0 }, [49] = 0, [59] = 8 }
env.getSensor = function(index)
    return sensors[index]
end
env.getModule = function(index)
    return { Type = index == 0 and 5 or 0 }
end
env.getFieldInfo = function(name)
    local index = tonumber(string.match(name, "^telem(%d+)$"))
    if index and sensors[index - 1] then
        return { id = 1000 + (index - 1) * 3, unit = sensors[index - 1].unit }
    end
    return lookup(name)
end
env.getSourceValue = function(id)
    return values[(id - 1000) / 3], true, true
end
owner:setDocument({
    revision = 1,
    flight = context.flightConfig.resolve({
        smartDetection = true,
        minFlightDuration = 30,
        disarmDuration = 2,
        announcements = true,
    }),
})
backgroundUntil(context, function()
    return owner.session.smart and owner.session.smart.altitude.fresh and owner.session.smart.speed.fresh
end)
fixture.radio.values[305], fixture.radio.values[306] = 1024, 0
backgroundUntil(context, function()
    return panel.phase == "starting"
end)
values[12], values[49] = 4, 11
backgroundUntil(context, function()
    return panel.phase == "active"
end)
equal(owner.view.reason, "smart-altitude")
equal(panel.value.properties.text, "40")
fixture.radio.values[305] = -1024
backgroundUntil(context, function()
    return panel.phase == "ground"
end)
history, sounds = recorded()
assert(history)
equal(#sounds, 0)
equal(model.getGlobalVariable(8, 0), 40)
print(string.format("Flight counter standard/Smart integration passed; worst callback: %d instructions", worstCallback))
