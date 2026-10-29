-- SPDX-License-Identifier: GPL-2.0-only

local root, independent, withFlights, smartEnabled = ...
assert(root)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
fixture.reset()
if withFlights then
    fixture.radio.fields.ch3 = { id = 306, name = "ch3" }
    fixture.radio.values[306] = 1024
    fixture.radio.rssi = 80
    model.setGlobalVariable(8, 0, 0)
end
local lines = { "version: 3", "grid:", "  columns: 4", "  rows: 4", "panels:" }
for index = 1, 8 do
    lines[#lines + 1] = string.format(
        "  - id: chart%d\n    type: chart\n    col: %d\n    row: %d\n    colSpan: 2\n    rowSpan: 1\n"
            .. "    config:\n      armSwitch: %s\n      scaling: independent\n      timeRange: %s\n      smoothing: medium\n      metrics:",
        index,
        (index - 1) % 2 * 2,
        math.floor((index - 1) / 2),
        independent and string.format("L%02d", index) or "SAv",
        index % 2 == 0 and "rolling" or "growing"
    )
    for source = 1, 3 do
        local id = (index - 1) * 3 + source
        local name = "Q" .. id
        fixture.radio.fields[name] = { id = 5000 + id, name = name, unit = 1 }
        fixture.radio.values[5000 + id] = id
        lines[#lines + 1] = "        - source: " .. name .. "\n          precision: 1"
    end
end
fixture.radioMock.indexFields()
if smartEnabled then
    local sensors = {
        [12] = { type = 0, id = 9, instance = 0, unit = 9, prec = 2 },
        [37] = { type = 0, id = 2, instance = 0, unit = 40, prec = 0 },
        [49] = { type = 0, id = 2, instance = 2, unit = 8, prec = 1 },
        [59] = { type = 0, id = 2, instance = 5, unit = 0, prec = 0 },
    }
    local values = { [12] = 0, [37] = { lat = 1, lon = 2, delay = 0 }, [49] = 0, [59] = 8 }
    model.getModule = function(index)
        return { Type = index == 0 and 5 or 0 }
    end
    model.getSensor = function(index)
        return sensors[index]
    end
    getSourceValue = function(id)
        return values[(id - 6000) / 3], true, true
    end
    fixture.radio.fields.ch3 = { id = 4400, name = "ch3" }
    fixture.radio.values[4400] = 0
    for index, sensor in pairs(sensors) do
        fixture.radio.fields["telem" .. (index + 1)] = { id = 6000 + index * 3, unit = sensor.unit }
    end
end
local file = assert(hostIo.open(root .. "/build/test-widget-fixture/layouts/chart-stress.yaml", "w"))
file:write(table.concat(lines, "\n") .. "\n")
file:close()

local worst, callbacks, context = 0, 0, nil
local function measure(fn, ...)
    fixture.lvglMock.setPropertyValidation(false)
    fixture.lvglMock.setCallCounting(false)
    fixture.lcdMock.setTextMeasurement(false)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    local ok, message = pcall(fn, ...)
    debug.sethook()
    fixture.lcdMock.setTextMeasurement(true)
    fixture.lvglMock.setCallCounting(true)
    fixture.lvglMock.setPropertyValidation(true)
    assert(ok, message)
    worst, callbacks = math.max(worst, instructions), callbacks + 1
    assert(
        instructions < 15000,
        string.format("chart callback %d (%s) used %d instructions", callbacks, tostring(context.stage), instructions)
    )
end

context = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "chart-stress",
    Theme = "modern-dark",
    Armed = (withFlights or smartEnabled) and getSwitchIndex("SA" .. CHAR_DOWN) or 0,
}, root .. "/build/test-widget-fixture/")
local function pump(count, background)
    for _ = 1, count do
        fixture.tick(10)
        measure(background and definition.background or definition.refresh, context)
        fixture.lvglMock.settle()
    end
    assert(#context.errors == 0, table.concat(context.errors, "\n"))
end
local function setArmed(value)
    fixture.radio.values[300] = value
    if independent then
        for index = 1, 8 do
            fixture.radio.logicalSwitches[index] = value > 0
        end
    end
end
setArmed(1024)
pump(200)
if withFlights then
    context.flightBroker:setDocument({
        modelFilename = context.flightBroker.filename,
        revision = 1,
        flight = context.flightConfig.resolve({ minFlightDuration = 1, disarmDuration = 1, history = false }),
    })
    setArmed(0)
    pump(20)
    setArmed(1024)
    pump(150)
    assert(context.flightBroker.state.active, "charts must receive flight state without a counter panel")
end
assert(#context.panels == 8)
if smartEnabled then
    setArmed(0)
    local owner = assert(context.flightBroker)
    owner:setDocument({
        revision = 1,
        flight = context.flightConfig.resolve({ smartDetection = true, history = false }),
    })
    pump(100)
    assert(owner.session.smart.altitude.fresh and owner.session.smart.speed.fresh)
    setArmed(1024)
end
for step = 1, 1000 do
    for id = 1, 24 do
        fixture.radio.values[5000 + id] = id + step % 17
    end
    pump(1, step < 500)
end
local history = context.serviceRuntime.byId.history
assert(history.count == 24)
if smartEnabled then
    local telemetry = context.serviceRuntime.byId.telemetry
    for id = 1, 24 do
        local reading = telemetry:subscribe("Q" .. id)
        assert(reading.updatedAt > getTime() - 300, "Smart must not starve ordinary telemetry polling")
        assert(reading.value > id, "chart sources must continue receiving changing data")
    end
    local sensors = context.flightBroker.session.smart
    assert(sensors.altitude.updatedAt == getTime() and sensors.speed.updatedAt == getTime())
end
for _, entry in ipairs(context.panels) do
    for _, series in ipairs(entry.instance.series) do
        assert(series.feed.available and series.feed.count <= 6144)
        assert(series.runs[1] and series.runs[1].line)
    end
end
local elapsed = context.panels[1].instance.session.elapsed
if withFlights then
    local session = context.panels[1].instance.session
    local segment, revision = session.segment, 0
    for _, entry in ipairs(history.entries) do
        revision = revision + entry.state.revision
    end
    setArmed(0)
    pump(6, true)
    assert(session.recording and context.flightBroker.state.active, "hidden charts must record during grace")
    local after = 0
    for _, entry in ipairs(history.entries) do
        after = after + entry.state.revision
    end
    assert(after > revision, "hidden grace must contain fresh samples")
    setArmed(1024)
    pump(6, true)
    assert(session.segment == segment and session.flightLast == 1, "grace rearm must not pause or duplicate flights")
end
setArmed(0)
pump(30)
local paused = context.panels[1].instance.session.elapsed
assert(paused >= elapsed)
pump(100, true)
assert(context.panels[1].instance.session.elapsed == paused)
if withFlights then
    local panel = context.panels[1].instance
    local start, finish, startKnown, endKnown = history:flight(panel.session, 1)
    assert(
        start and finish and start < finish and endKnown,
        string.format(
            "flight interval %s..%s known=%s/%s last=%s",
            tostring(start),
            tostring(finish),
            tostring(startKnown),
            tostring(endKnown),
            tostring(panel.session.flightLast)
        )
    )
    assert(panel.flightLines and panel.flightLines[1], "completed flights must have interval overlays")
end

for cycle = 1, 20 do
    for _ = 1, 60 do
        setArmed(1024)
        pump(6)
        setArmed(0)
        pump(6)
    end
    pump(150)
    fixture.lcdMock.clearTextMeasurements()
    collectgarbage("collect")
    assert(fixture.lvglMock.replacedFontRefCount() == 0)
end
for cycle = 1, 5 do
    for _ = 1, 60 do
        setArmed(1024)
        pump(6)
        setArmed(0)
        pump(6)
    end
    pump(150)
    fixture.lcdMock.clearTextMeasurements()
    collectgarbage("collect")
    for _, entry in ipairs(context.panels) do
        for _, item in ipairs(entry.instance.series) do
            assert(#item.runs <= 6144, "native trace fragments must be bounded by history capacity")
            assert(#item.markerKeys <= entry.instance.rect.w + 1, "gap markers must be pooled by screen column")
            for _, run in ipairs(item.runs) do
                assert(#run.pool <= 4 * (entry.instance.rect.w + 1), "point pools must use screen-column reduction")
            end
        end
    end
end
local settled = false
local drain = 0
for step = 1, 3000 do
    settled = true
    for _, entry in ipairs(context.panels) do
        if entry.instance.pending then
            settled = false
        end
        for _, item in ipairs(entry.instance.series) do
            if item.drawnRevision ~= item.feed.plotRevision then
                settled = false
            end
        end
    end
    if settled then
        break
    end
    pump(1)
    drain = step
end
assert(settled, "retained multi-flight histories must finish their staged redraws within 3000 callbacks")
for _, entry in ipairs(context.panels) do
    for _, item in ipairs(entry.instance.series) do
        assert(
            item.drawnRevision == item.feed.plotRevision and not entry.instance.pending,
            string.format(
                "a chart was starved: revision %s/%s, pending %s, projected %s/%s, versions %s/%s, runs %d/%d, apply %s, markers %s/%s (%d)",
                tostring(item.drawnRevision),
                tostring(item.feed.plotRevision),
                tostring(entry.instance.pending ~= nil),
                tostring(item.job and item.job.index),
                tostring(item.job and item.job.last),
                tostring(item.drawnVersion),
                tostring(entry.instance.version),
                item.runCount or 0,
                #item.runs,
                tostring(item.applyIndex),
                tostring(item.markerPhase),
                tostring(item.markerIndex),
                #item.markerKeys
            )
        )
    end
    entry.nextRefresh = math.huge
end
local first = context.panels[1]
local refresh = first.module.refresh
first.module.refresh = function()
    return 37
end
first.nextRefresh = 0
measure(definition.refresh, context)
if smartEnabled and first.interval ~= 37 then
    measure(definition.refresh, context)
end
assert(
    first.interval == 37 and first.nextRefresh == getTime() + 37,
    "dynamic intervals must schedule from this refresh"
)
first.module.refresh = refresh
print(
    string.format(
        "  chart recording%s: %d callbacks, 24 sources, worst %d instructions, drain %d callbacks",
        smartEnabled and " + Smart" or "",
        callbacks,
        worst,
        drain
    )
)
