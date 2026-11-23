-- SPDX-License-Identifier: GPL-2.0-only

-- `derived` leaves the debrief out of the layout, so one is derived from the
-- charts and records beside them.
local root, independent, withFlights, smartEnabled, derived = ...
assert(root)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
local chartView = assert(loadfile(root .. "/tests/support/chart_assertions.lua"))()
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
if not derived then
    -- Only the charts record here; a derived debrief would record its own series.
    lines[#lines + 1] = "debrief:\n  tiles: []"
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
if withFlights or smartEnabled then
    local path = root .. "/build/test-widget-fixture/"
    os.execute("mkdir -p '" .. path .. "AEROGRID/models'")
    local filename = model.getInfo().filename
    local modelPath = assert(fixture.module("lib/model_settings_store.lua").path(path, "AGTEST"))
    local modelFile = assert(hostIo.open(modelPath, "w"))
    modelFile:write(assert(fixture.module("lib/yaml.lua").serialize({
        version = 1,
        revision = 0,
        modelFilename = filename,
        armed = "SAv",
        sessionReset = smartEnabled and "L64" or nil,
    })))
    modelFile:close()
end

local context
-- Worst callback and worst recording work in one callback, in instructions
-- counted 100 at a time.
local worst, counted, recording, worstRecording = 0, 0, 0, 0
local capture, worstCapture = 0, 0
local function runCallback(fn, ...)
    fixture.lvglMock.setPropertyValidation(false)
    fixture.lvglMock.setCallCounting(false)
    fixture.lcdMock.setTextMeasurement(false)
    counted, recording, capture = 0, 0, 0
    debug.sethook(function()
        counted = counted + 100
    end, "", 100)
    local ok, message = pcall(fn, ...)
    debug.sethook()
    worst = math.max(worst, counted)
    worstRecording = math.max(worstRecording, recording)
    worstCapture = math.max(worstCapture, capture)
    fixture.lcdMock.setTextMeasurement(true)
    fixture.lvglMock.setCallCounting(true)
    fixture.lvglMock.setPropertyValidation(true)
    assert(ok, message)
end

context = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "chart-stress",
    Theme = "modern-dark",
}, root .. "/build/test-widget-fixture/")
local function pump(count, background)
    for _ = 1, count do
        fixture.tick(10)
        runCallback(background and definition.background or definition.refresh, context)
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
setArmed(0)
local prepared = false
for _ = 1, 2500 do
    pump(1)
    prepared = #context.panels == 8
    for _, entry in ipairs(context.panels) do
        prepared = prepared and entry.instance.columnRenderer and entry.instance.gridVersion == entry.instance.version
    end
    if prepared then
        break
    end
end
assert(prepared, "all chart frames must be initialized before recording starts")
worst = 0
collectgarbage("collect")
local startHeap = collectgarbage("count")
local function measure(service, name, add)
    local original = service[name]
    service[name] = function(...)
        local before = counted
        local a, b, c = original(...)
        add(counted - before)
        return a, b, c
    end
end
for _, name in ipairs({ "sample", "update" }) do
    measure(context.serviceRuntime.byId.history, name, function(spent)
        recording = recording + spent
    end)
end
if context.serviceRuntime.byId.debrief then
    measure(context.serviceRuntime.byId.debrief, "update", function(spent)
        capture = capture + spent
    end)
end
if independent then
    local sessions = {}
    for index, entry in ipairs(context.panels) do
        local session = entry.instance.session
        assert(not session.recording, "independent charts must start disarmed")
        for _, other in ipairs(sessions) do
            assert(session ~= other, "different arm switches must own different sessions")
        end
        sessions[index] = session
    end
    local function transition(index, armed)
        local before, revisions = {}, {}
        for other, session in ipairs(sessions) do
            before[other] = { recording = session.recording, segment = session.segment, elapsed = session.elapsed }
        end
        for _, item in ipairs(context.panels[index].instance.series) do
            revisions[item] = item.feed.plotRevision
        end
        fixture.radio.logicalSwitches[index] = armed
        pump(40)
        assert(sessions[index].recording == armed, "only the selected chart must follow its switch")
        for other, session in ipairs(sessions) do
            if other ~= index then
                assert(session.recording == before[other].recording, "one chart switch changed another recording")
                assert(session.segment == before[other].segment, "one chart switch split another session")
                if before[other].recording then
                    assert(session.elapsed > before[other].elapsed, "another active chart stopped recording time")
                else
                    assert(session.elapsed == before[other].elapsed, "disarmed chart time advanced")
                end
            end
        end
        if armed then
            assert(sessions[index].elapsed > before[index].elapsed, "the selected chart must record elapsed time")
            for _, item in ipairs(context.panels[index].instance.series) do
                assert(
                    item.feed.available and item.feed.plotRevision > revisions[item],
                    "each independently armed source must record"
                )
            end
        end
    end
    for index = 1, 8 do
        transition(index, true)
    end
    for index = 7, 1, -2 do
        transition(index, false)
    end
    transition(1, true)
    assert(sessions[1].segment == 2, "rearming one chart must start only its next segment")
    transition(1, false)
    for index = 2, 8, 2 do
        transition(index, false)
    end
    assert(context.serviceRuntime.byId.history.count == 24, "all independent chart sources must be subscribed")
    return
end
setArmed(1024)
pump(200)
if withFlights then
    context.flightBroker:setDocument({
        modelFilename = context.flightBroker.filename,
        flightCount = context.flightBroker.document.flightCount,
        revision = 1,
        armed = "SAv",
        flight = context.flightConfig.resolve({ minFlightDuration = 1, disarmDuration = 1 }),
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
        flightCount = owner.document.flightCount,
        armed = "SAv",
        sessionReset = "L64",
        flight = context.flightConfig.resolve({ smartDetection = true }),
    })
    pump(100)
    assert(owner.session.smart.altitude.fresh and owner.session.smart.speed.fresh)
    setArmed(1024)
end
local liveRevisions = {}
for _, entry in ipairs(context.panels) do
    for _, item in ipairs(entry.instance.series) do
        liveRevisions[item] = item.feed.plotRevision
    end
end
local maxSmartAge = 0
for step = 1, 10000 do
    for id = 1, 24 do
        fixture.radio.values[5000 + id] = id + 1 + step % 17
    end
    pump(1, step < 100)
    if smartEnabled then
        local sensors = context.flightBroker.session.smart
        maxSmartAge = math.max(maxSmartAge, getTime() - sensors.altitude.updatedAt, getTime() - sensors.speed.updatedAt)
    end
    local advanced = true
    for _, entry in ipairs(context.panels) do
        for _, item in ipairs(entry.instance.series) do
            advanced = advanced and item.drawnRevision and item.drawnRevision > liveRevisions[item]
        end
    end
    if smartEnabled then
        local telemetry = context.serviceRuntime.byId.telemetry
        for id = 1, 24 do
            local reading = telemetry:subscribe("Q" .. id)
            advanced = advanced and reading.updatedAt > getTime() - 300 and reading.value > id
        end
    end
    if step >= ((withFlights or smartEnabled) and 100 or 1000) and advanced then
        break
    end
end
for _, entry in ipairs(context.panels) do
    for _, item in ipairs(entry.instance.series) do
        assert(item.feed.plotRevision > liveRevisions[item], "live telemetry must keep recording during a flight")
        assert(
            item.drawnRevision and item.drawnRevision > liveRevisions[item],
            string.format(
                "live charts must keep drawing changing telemetry before disarming: source=%s drawn=%s baseline=%s current=%s job=%s/%s geometry=%s/%s pending=%s",
                tostring(item.settings.source),
                tostring(item.drawnRevision),
                tostring(liveRevisions[item]),
                tostring(item.feed.plotRevision),
                tostring(item.job and item.job.index),
                tostring(item.job and item.job.last),
                tostring(item.job and item.job.geometryVersion),
                tostring(entry.instance.geometryVersion),
                tostring(entry.instance.pending and entry.instance.pending.settings.source)
            )
        )
    end
end
local history = context.serviceRuntime.byId.history
if derived then
    local section = context.document.debrief
    assert(context.debriefGenerated and #section.tiles == 8, "each chart derives a debrief tile")
    -- The debrief records each reading unsmoothed, beside the chart's smoothed one.
    assert(history.count == 48, "debrief recordings: " .. history.count)
else
    assert(history.count == 24)
end
if smartEnabled then
    local telemetry = context.serviceRuntime.byId.telemetry
    for id = 1, 24 do
        local reading = telemetry:subscribe("Q" .. id)
        assert(reading.updatedAt > getTime() - 300, "Smart must not starve ordinary telemetry polling")
        assert(reading.value > id, "chart sources must continue receiving changing data")
    end
    local sensors = context.flightBroker.session.smart
    -- Eight busy charts may delay the flight service; Smart confirms takeoff only
    -- after a two second hold, so readings up to a second old are harmless.
    assert(
        sensors.altitude.fresh and sensors.speed.fresh and maxSmartAge <= 100,
        "Smart samples must remain fresh within one second, maximum age: " .. maxSmartAge
    )
end
for _, entry in ipairs(context.panels) do
    for index, series in ipairs(entry.instance.series) do
        assert(series.feed.available and series.feed.count <= 6144)
        assert(entry.instance.columnRenderer.published[index], "recorded series must reach the sole renderer")
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
    local after = 0
    -- Reach the next poll within the three-second grace, independent of the
    -- round-robin phase when the charts were hidden.
    for _ = 1, 20 do
        pump(1, true)
        assert(session.recording and context.flightBroker.state.active, "hidden charts must record during grace")
        after = 0
        for _, entry in ipairs(history.entries) do
            after = after + entry.state.revision
        end
        if after > revision then
            break
        end
    end
    assert(after > revision, "hidden grace must contain fresh samples")
    setArmed(1024)
    pump(6, true)
    assert(session.segment == segment and session.flightLast == 1, "grace rearm must not pause or duplicate flights")
end
setArmed(0)
-- Eight charts crowd the mock budget, so the arm switch is read late.
for _ = 1, 100 do
    pump(1)
    if not context.panels[1].instance.session.recording then
        break
    end
end
assert(not context.panels[1].instance.session.recording, "disarming must stop recording")
pump(1)
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
    assert(panel.flightBands and panel.flightBands[1], "completed flights must have background bands")
end

if withFlights then
    local debrief = context.serviceRuntime.byId.debrief
    assert((debrief ~= nil) == (derived == true), "only a derived debrief records")
    collectgarbage("collect")
    local flightHeap = collectgarbage("count")
    if derived then
        local captured
        for _ = 1, 3000 do
            pump(1, true)
            captured = debrief:result()
            if captured and captured.tiles and #captured.tiles == 8 then
                break
            end
        end
        assert(captured and #captured.tiles == 8, "the flight's debrief must be captured")
        for _, tile in ipairs(captured.tiles) do
            assert(#tile.series == 3 and tile.series[1].value ~= nil, "every reading is summarized")
        end
    end
    collectgarbage("collect")
    local knots = 0
    for _, entry in ipairs(history.entries) do
        knots = knots + entry.state.count
    end
    print(
        string.format(
            "  %s: %d recordings, %d knots; worst callback %d, recording %d, capture %d instructions;"
                .. " heap %.0f KiB at start, +%.0f flying, +%.0f captured",
            derived and "derived debrief" or "charts only",
            history.count,
            knots,
            worst,
            worstRecording,
            worstCapture,
            startHeap,
            flightHeap - startHeap,
            collectgarbage("count") - flightHeap
        )
    )
    -- Recording and capture are only part of a callback.
    local share = fixture.firmware.INSTRUCTION_BUDGET // 2
    assert(worstRecording < share, "recording took " .. worstRecording .. " instructions in one callback")
    assert(worstCapture < share, "capture took " .. worstCapture .. " instructions in one callback")
end
if withFlights or smartEnabled then
    return
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
            assert(#item.connectors <= entry.instance.area.w // 48, "resume connectors must fit the bounded axis")
        end
        assert(
            chartView.nativeColumns(entry.instance.columnRenderer) <= entry.instance.area.w * #entry.instance.series * 2
        )
    end
end
local settled = false
-- Finish pending appends and decorations across eight three-series charts.
for step = 1, 200000 do
    settled = true
    for _, entry in ipairs(context.panels) do
        if entry.instance.columnsDecorating then
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
end
assert(settled, "retained multi-flight histories must finish their bounded staged redraws")
-- Readouts follow the last redraw by a cycle; give each chart a few to catch up.
pump(40)
for _, entry in ipairs(context.panels) do
    assert(entry.instance.status.properties.text == "", "stopped recordings must not show a pause label")
    assert(entry.instance.gapRoot == nil, "recording pauses must not allocate flight-shading masks")
    for _, item in ipairs(entry.instance.series) do
        assert(
            item.drawnRevision == item.feed.plotRevision and not entry.instance.pending,
            string.format(
                "a chart was starved: revision %s/%s, pending %s, projected %s/%s, versions %s/%s, connectors %d/%d, apply %s, markers %s/%s (%d)",
                tostring(item.drawnRevision),
                tostring(item.feed.plotRevision),
                tostring(entry.instance.pending ~= nil),
                tostring(item.job and item.job.index),
                tostring(item.job and item.job.last),
                tostring(item.drawnVersion),
                tostring(entry.instance.version),
                item.runCount or 0,
                #item.connectors,
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
    return 37, false, 1
end
first.nextRefresh = 0
first.refreshTask.due = 0
context.scheduler.reschedule(first.refreshTask)
for _ = 1, 4 do
    runCallback(definition.refresh, context)
    if first.interval == 37 then
        break
    end
end
assert(
    first.interval == 37 and first.nextRefresh == getTime() + 37,
    "dynamic intervals must schedule from this refresh"
)
first.module.refresh = refresh
print("Chart recording lifecycle passed")
