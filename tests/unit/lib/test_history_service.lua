-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local support = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local telemetryModule = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/telemetry_service.lua"))()
local controlModule = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()
local historyModule = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/history_service.lua"))()
local armedModule = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/armed_service.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local function harness(options, configured)
    local values = { [1] = 0, [2] = 0, [100] = 12 }
    local fields = { V = { id = 100, unit = 1 } }
    local env = support.environment({
        getFieldInfo = function(name)
            return fields[name]
        end,
        getValue = function(id)
            return values[id]
        end,
        getRSSI = function()
            return 80
        end,
        getSwitchIndex = function(name)
            return name == "L01" and 1 or name == "L02" and 2 or 0
        end,
        getSwitchValue = function(id)
            if values[id] ~= nil then
                return values[id] > 0
            end
        end,
        model = {},
    })
    local runtime = support.runtime(env)
    local telemetry = telemetryModule.new(env, support)
    local control = controlModule.new(env, support)
    runtime.byId.telemetry = telemetry
    runtime.byId.control = control
    runtime.modelArmed = configured ~= false and "L01" or ""
    runtime.byId.armed = armedModule.new(env, support, runtime)
    local history = historyModule.new(env, support, runtime)
    local session = history:session()
    local feed = history:subscribe("V", options or {})
    local function poll(now, arm, value)
        values[1], values[100] = arm, value
        control:update(now)
        telemetry:update(now)
        history:update(now)
    end
    return history, session, feed, poll, telemetry, control
end

local function recorder(options)
    local history, session, feed, _, _, control = harness(options)
    local arm = control.entries[1].state
    arm.available, arm.fresh, arm.value = true, true, true
    local reading = { name = "V", fresh = true, kind = "number", precision = 1, unitText = "V" }
    local function sample(at, value)
        arm.updatedAt = at
        reading.value, reading.updatedAt = value, at
        history:sample(reading, at)
        history:update(at)
    end
    return history, feed, sample, reading, session
end

for _, sampleFirst in ipairs({ false, true }) do
    for _, age in ipairs({ -1, 100, 101, 499, 500, 501 }) do
        local history, session, _, _, _, control = harness()
        local arm = control.entries[1].state
        arm.available, arm.fresh, arm.value, arm.updatedAt = true, true, true, 1000 - age
        if sampleFirst then
            history:sample({
                name = "V",
                fresh = true,
                kind = "number",
                precision = 1,
                value = 12,
                updatedAt = 1000,
            }, 1000)
        end
        history:update(1000)
        equal(session.recording, age >= 0 and age <= 500, "recording honors the five-second arm age limit")
    end
end

local function knots(history, feed)
    local result = {}
    for index = feed.first, feed.last do
        local at, value, broken = history:point(feed, index)
        result[#result + 1] = { at, value, broken }
    end
    equal(#result, feed.count)
    return result
end

--- Every sample must read back exactly as the value held at its time.
local function held(history, feed, samples)
    local points = knots(history, feed)
    local cursor = 1
    for _, sample in ipairs(samples) do
        while cursor < #points and points[cursor + 1][1] <= sample[1] do
            cursor = cursor + 1
        end
        equal(points[cursor][2], sample[2], string.format("value held at %d", sample[1]))
    end
end

local history, session, feed, poll = harness()
poll(0, 0, 12)
equal(feed.available, false, "disarmed readings must not enter the recording")
poll(100, 1, 12)
equal(session.resumeLast, 0, "the first recording must not invent a pause")
equal(session.armLast, 0, "initial arming starts the recording without a boundary line")
poll(200, 1, 10)
poll(300, 1, 13)
equal(feed.min, 10)
equal(feed.max, 13)
equal(feed.value, 13)
equal(session.elapsed, 200)
poll(400, 0, 1)
local paused = session.elapsed
equal(session.stoppedAt, paused, "recording stop is available immediately, before any resume")
poll(10000, 0, 30)
equal(session.resumeLast, 0, "pausing must not mark a seam before recording resumes")
equal(session.elapsed, paused, "disarmed wall time must not consume the chart")
equal(feed.value, 13)
poll(11000, 1, 11)
equal(feed.min, 10, "rearming must retain extrema")
equal(feed.max, 13)
equal(session.elapsed, paused)
equal(session.segment, 2)
equal(session.stoppedAt, nil, "resuming moves the pending stop into the retained boundary journal")
local at, value, broken, resumed = history:point(feed, feed.last)
equal(at, paused)
equal(value, 11)
equal(broken, true)
equal(resumed, true, "resumed samples retain their break reason separately from telemetry gaps")
equal(session.resumeLast, 1)
equal(history:recordingBreak(session, 1), paused, "resume boundaries use cumulative time, excluding the pause")
equal(history:preview():recordingBreak(session, 1), paused, "previews expose the same read-only resume journal")
equal(history:recordingBreak(session, 0), nil)
equal(history:recordingBreak(session, 2), nil)
equal(history:recordingBreak({}, 1), nil)
equal(history:subscribe("V", {}), feed, "matching histories share storage")
equal(history:subscribe("V", { windowSeconds = 30 }), feed, "growing durations no longer distinguish recordings")
equal(
    history:subscribe("V", { windowSeconds = 600 }),
    feed,
    "legacy growing windows must share the canonical recording"
)
local minuteHistory, minuteFeed, minuteSample = recorder({ windowSeconds = 30 })
for _, case in ipairs({
    { 0, 6000 },
    { 6000, 6000 },
    { 6001, 12000 },
    { 12000, 12000 },
    { 12001, 18000 },
    { 18001, 24000 },
    { 600000, 600000 },
    { 600001, 606000 },
}) do
    minuteSample(case[1], 12)
    equal(minuteFeed.window, case[2], "history windows must grow by whole minutes without doubling")
end
equal(minuteHistory:point(minuteFeed, 1), 0, "minute growth must retain the beginning of the recording")
assert(not pcall(function()
    feed.value = 42
end), "history views must be immutable")

poll(11100, 1, nil)
equal(feed.stale, true)
equal(feed.value, 11)
poll(11200, 1, 0)
equal(feed.value, 0, "live zero is a valid sample")
equal(feed.min, 0)
at, value, broken, resumed = history:point(feed, feed.last)
equal(broken, true, "dropouts break the trace")
equal(resumed, false, "a dropout immediately after a resumed sample is still a telemetry gap")
equal(session.resumeLast, 1, "telemetry loss must not create a compressed-time recording seam")
poll(11300, 1, 0 / 0)
equal(feed.value, 0, "non-finite samples must not enter history")

local missing, missingSession, missingFeed, missingPoll = harness(nil, false)
missingPoll(0, 1, 12)
equal(missingSession.configured, false)
equal(missingSession.recording, false)
equal(missingFeed.available, false)
equal(missing:point(missingFeed, 1), nil)

local independent, firstSession, firstFeed, independentPoll = harness()
independentPoll(600, 1, 40)
independentPoll(700, nil, 45)
equal(firstSession.available, false, "an unavailable switch must not be treated as a known disarm condition")
equal(firstSession.recording, false)
equal(firstFeed.value, 40, "switch loss must freeze the last recorded reading")
local unavailableElapsed = firstSession.elapsed
local previousSegment = firstSession.segment
independentPoll(800, nil, 55)
equal(firstSession.elapsed, unavailableElapsed)
independentPoll(900, 1, 50)
equal(firstSession.available, true)
equal(firstSession.segment, previousSegment + 1, "switch recovery must start a disconnected segment")
equal(firstFeed.value, 50)
equal(firstSession.elapsed, unavailableElapsed, "unavailable time must not consume the chart")
equal(
    independent:recordingBreak(firstSession, firstSession.resumeLast),
    unavailableElapsed,
    "recovering an unavailable arm source also leaves a recording seam"
)

local bounded, boundedSession, boundedFeed, boundedPoll = harness({ timeRange = "rolling", windowSeconds = 30 })
boundedPoll(0, 1, 12)
for index = 1, historyModule.CAPACITY + 2 do
    boundedPoll(index * 20, 0, 12)
    boundedPoll(index * 20 + 10, 1, 12)
end
equal(boundedSession.resumeLast - boundedSession.resumeFirst + 1, historyModule.CAPACITY)
equal(bounded:recordingBreak(boundedSession, boundedSession.resumeFirst - 1), nil)
equal(bounded:recordingBreak(boundedSession, boundedSession.resumeLast), boundedSession.elapsed)
equal(#bounded.sessions[1].resumes, historyModule.CAPACITY, "the recording seam journal must stay bounded")
equal(#bounded.sessions[1].armValues, historyModule.CAPACITY, "arm directions use the same bounded ring")
equal(select(2, bounded:armBoundary(boundedSession, boundedSession.armLast)), true)
equal(select(2, bounded:armBoundary(boundedSession, boundedSession.armLast - 1)), false)
equal(select(2, bounded:preview():armBoundary(boundedSession, boundedSession.armLast)), true)
assert(#bounded.entries[1].resumeBits <= historyModule.CAPACITY // 32, "break reasons must use a bounded bitset")
equal(select(4, bounded:point(boundedFeed, boundedFeed.last)), true, "resume bits survive physical ring reuse")

-- A reading holds until it changes: only changes are written, exactly as read.
local steps, stepFeed, stepSample = recorder()
for _, reading in ipairs({ { 0, 11 }, { 100, 10 }, { 299, 10 }, { 310, 10 } }) do
    stepSample(reading[1], reading[2])
end
local stepKnots = knots(steps, stepFeed)
equal(#stepKnots, 3, "two changes plus the end of the last hold")
equal(stepKnots[1][1], 0)
equal(stepKnots[1][2], 11)
equal(stepKnots[2][1], 100)
equal(stepKnots[2][2], 10)
equal(stepKnots[3][1], 310)
equal(stepKnots[3][2], 10)
equal(stepFeed.min, 10)

local waves, waveFeed, waveSample = recorder()
local waveOriginals = {}
for index = 0, 800 do
    local number = math.floor(math.sin(index * 0.017) * 3 + 0.5)
    waveSample(index * 10, number)
    waveOriginals[#waveOriginals + 1] = { index * 10, number }
end
held(waves, waveFeed, waveOriginals)
for _, point in ipairs(knots(waves, waveFeed)) do
    equal(point[2] % 1, 0, "stored values are never invented")
end
assert(waveFeed.count < #waveOriginals // 4, "unchanged readings must not add entries")

-- A dropout closes the hold at the last reading before it.
local gaps, gapFeed, gapSample, gapReading = recorder()
gapSample(0, 5)
gapSample(100, 5)
gapReading.fresh = false
gapSample(200, 5)
gapReading.fresh = true
gapSample(300, 5)
local gapKnots = knots(gaps, gapFeed)
equal(#gapKnots, 3)
equal(gapKnots[2][1], 100, "the hold ends where the signal was last seen")
equal(gapKnots[3][3], true, "the value after a dropout starts a new run")

local growing, growingFeed, growingSample, _, growingSession = recorder({ windowSeconds = 30 })
local growingOriginals = {}
for tick = 0, 500000, 100 do
    local number = tick == 10000 and -100 or tick // 100000
    growingSample(tick, number)
    growingOriginals[#growingOriginals + 1] = { tick, number }
end
equal(growingFeed.min, -100)
equal(growingFeed.max, 5)
equal(growing:point(growingFeed, 1), 0, "growing history retains the start")
equal(growingFeed.window, 504000)
equal(growingSession.elapsed, 500000)
held(growing, growingFeed, growingOriginals)
assert(growingFeed.count < 20, "constant spans must not grow with flight duration")

local rolling, rollingFeed, rollingSample = recorder({ timeRange = "rolling", windowSeconds = 30 })
for tick = 0, 10000, 10 do
    rollingSample(tick, 5)
end
equal(rollingFeed.window, 3000)
equal(rollingFeed.count, 2, "a rolling hold retains its start and its live end")
equal(rollingFeed.min, 5)
equal(rollingFeed.max, 5)

local dense, denseFeed, denseSample = recorder()
local denseOriginals = {}
for index = 0, 6000 do
    local number = index % 2 == 0 and -100 or 100
    denseSample(index * 10, number)
    denseOriginals[#denseOriginals + 1] = { index * 10, number }
end
equal(denseFeed.count, 6001, "ten minutes at 10 Hz must fit even without compression savings")
equal(denseFeed.full, false)
held(dense, denseFeed, denseOriginals)
for index = 6001, historyModule.CAPACITY do
    denseSample(index * 10, index % 2 == 0 and -100 or 100)
end
equal(denseFeed.count, historyModule.CAPACITY)
equal(denseFeed.full, true)
local retained = knots(dense, denseFeed)
local revision = denseFeed.plotRevision
denseSample(100000, 1000)
equal(denseFeed.value, 1000)
equal(denseFeed.max, 1000)
equal(denseFeed.min, -100)
equal(denseFeed.plotRevision, revision, "full histories must not trigger redraws for raw-only updates")
local frozen = knots(dense, denseFeed)
for index, point in ipairs(retained) do
    for field = 1, 3 do
        equal(frozen[index][field], point[field], "capacity exhaustion must preserve every existing knot")
    end
end
local entry = dense.views[denseFeed]
local packedBytes = 0
for _, chunk in pairs(entry.chunks) do
    packedBytes = packedBytes + #chunk
end
equal(packedBytes, historyModule.CAPACITY * historyModule.BYTES_PER_POINT)
collectgarbage("collect")
local fullMemory = collectgarbage("count")
for index = 1, 2000 do
    denseSample(100000 + index * 10, index)
end
collectgarbage("collect")
assert(collectgarbage("count") - fullMemory < 2, "full history must not retain more storage for live readouts")
equal(denseFeed.count, historyModule.CAPACITY)
equal(denseFeed.plotRevision, revision)

local ring, ringFeed, ringSample = recorder({ timeRange = "rolling", windowSeconds = 600 })
for index = 0, historyModule.CAPACITY * 3 do
    ringSample(index * 10, index % 2 == 0 and -100 or 100)
end
equal(ringFeed.full, false, "rolling storage must reuse expired space instead of declaring history full")
assert(ringFeed.first > historyModule.CAPACITY * 2 - 6000)
assert(ringFeed.count <= 6002)
local ringOriginals = {}
for index = historyModule.CAPACITY * 3 - 6000, historyModule.CAPACITY * 3 do
    ringOriginals[#ringOriginals + 1] = { index * 10, index % 2 == 0 and -100 or 100 }
end
held(ring, ringFeed, ringOriginals)
local lastAt, lastValue = ring:point(ringFeed, ringFeed.last)
assert(lastAt and lastValue, "knots must remain readable after ring wrap")

local huge, hugeFeed, hugeSample = recorder()
local hugeOriginals = {}
for index = 0, 30 do
    local number = index % 2 == 0 and 1e16 or -1e16
    hugeSample(index * 10, number)
    hugeOriginals[#hugeOriginals + 1] = { index * 10, number }
end
held(huge, hugeFeed, hugeOriginals)
equal(hugeFeed.count, 31, "every change is retained exactly")

local integers, integerFeed, integerSample = recorder()
integerSample(0, math.maxinteger)
integerSample(10, math.maxinteger - 1)
local _, integerValue = integers:point(integerFeed, integerFeed.first)
equal(integerValue, math.maxinteger, "native integers must not be truncated through floating-point packing")
_, integerValue = integers:point(integerFeed, integerFeed.last)
equal(integerValue, math.maxinteger - 1)

local failures, _, _, failurePoll, failureTelemetry = harness()
failureTelemetry:observe({
    sample = function()
        error("observer failed")
    end,
})
failurePoll(0, 1, 12)
equal(failureTelemetry.failed, nil, "an observer failure must not retire telemetry")
failures.failure = "history observer failed"
local ok, message = pcall(failures.update, failures, 10)
assert(not ok and string.find(message, "history observer failed", 1, true))

local resetHistory, resetFeed, resetSample, _, resetView = recorder()
resetSample(0, 10)
resetSample(100, 20)
local oldRevision, oldPlotRevision = resetFeed.revision, resetFeed.plotRevision
local nextItem = 1
repeat
    nextItem = resetHistory:resetSession(120, nextItem)
until not nextItem
equal(resetHistory:session(), resetView, "reset must retain the session view")
equal(resetHistory:subscribe("V"), resetFeed)
equal(resetView.elapsed, 0)
equal(resetView.segment, 0)
equal(resetFeed.count, 0)
equal(resetFeed.min, nil)
equal(resetFeed.max, nil)
equal(resetFeed.full, false)
assert(resetFeed.revision > oldRevision and resetFeed.plotRevision > oldPlotRevision)
resetSample(140, 50)
equal(resetFeed.min, 50)
equal(resetFeed.max, 50)
local _, resetValue = resetHistory:point(resetFeed, resetFeed.last)
equal(resetValue, 50, "the first post-reset sample must not inherit old recordings")
print(
    string.format(
        "  chart history: 6001 worst-case samples fit; %d bytes/knot on this runtime",
        historyModule.BYTES_PER_POINT
    )
)
