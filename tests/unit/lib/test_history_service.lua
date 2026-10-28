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
    runtime.byId.armed = armedModule.new(env, support, runtime)
    local history = historyModule.new(env, support, runtime)
    local armSwitch = configured ~= false and "L01" or ""
    local session = history:session(armSwitch)
    options = options or {}
    options.armSwitch = armSwitch
    local feed = history:subscribe("V", options)
    local function poll(now, arm, value, otherArm)
        values[1], values[100] = arm, value
        if otherArm ~= nil then
            values[2] = otherArm
        end
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

local function knots(history, feed)
    local result = {}
    for index = feed.first, feed.last do
        local at, value, broken = history:point(feed, index)
        result[#result + 1] = { at, value, broken }
    end
    equal(#result, feed.count)
    return result
end

local function accuracy(history, feed, samples, epsilon)
    local points = knots(history, feed)
    local cursor, worst = 1, 0
    for _, sample in ipairs(samples) do
        while cursor < #points and points[cursor + 1][1] <= sample[1] do
            cursor = cursor + 1
        end
        local first, second = points[cursor], points[cursor + 1]
        local value = first[2]
        if first[1] ~= sample[1] then
            assert(second and not second[3], "sample has no connected reconstruction")
            local fraction = (sample[1] - first[1]) / (second[1] - first[1])
            value = first[2] * (1 - fraction) + second[2] * fraction
        end
        local difference = math.abs(value - sample[2])
        worst = math.max(worst, difference)
        assert(difference <= epsilon, string.format("at %d: error %.12g exceeds %.12g", sample[1], difference, epsilon))
    end
    return worst
end

local history, session, feed, poll = harness()
poll(0, 0, 12)
equal(feed.available, false, "disarmed readings must not enter the recording")
poll(100, 1, 12)
poll(200, 1, 10)
poll(300, 1, 13)
equal(feed.min, 10)
equal(feed.max, 13)
equal(feed.value, 13)
equal(session.elapsed, 200)
poll(400, 0, 1)
local paused = session.elapsed
poll(10000, 0, 30)
equal(session.elapsed, paused, "disarmed wall time must not consume the chart")
equal(feed.value, 13)
poll(11000, 1, 11)
equal(feed.min, 10, "rearming must retain extrema")
equal(feed.max, 13)
equal(session.elapsed, paused)
equal(session.segment, 2)
local at, value, broken = history:point(feed, feed.last)
equal(at, paused)
equal(value, 11)
equal(broken, true)
equal(history:subscribe("V", { armSwitch = "L01" }), feed, "matching histories share storage")
equal(
    history:subscribe("V", { armSwitch = "L01", windowSeconds = 30 }),
    feed,
    "growing durations no longer distinguish recordings"
)
equal(
    history:subscribe("V", { armSwitch = "L01", windowSeconds = 600 }),
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
assert(
    history:subscribe("V", { armSwitch = "L01", precision = 0 }) ~= feed,
    "Sensor and explicit precision subscriptions differ"
)
equal(
    history:subscribe("V", { armSwitch = "L01", precision = 1 }),
    history:subscribe("V", { armSwitch = "L01", precision = 1 })
)
assert(
    history:subscribe("V", { armSwitch = "L01", precision = 2 })
        ~= history:subscribe("V", { armSwitch = "L01", precision = 1 })
)
assert(not pcall(function()
    feed.value = 42
end), "history views must be immutable")

poll(11100, 1, nil)
equal(feed.stale, true)
equal(feed.value, 11)
poll(11200, 1, 0)
equal(feed.value, 0, "live zero is a valid sample")
equal(feed.min, 0)
at, value, broken = history:point(feed, feed.last)
equal(broken, true, "dropouts break the trace")
poll(11300, 1, 0 / 0)
equal(feed.value, 0, "non-finite samples must not enter history")

local missing, missingSession, missingFeed, missingPoll = harness(nil, false)
missingPoll(0, 1, 12)
equal(missingSession.configured, false)
equal(missingSession.recording, false)
equal(missingFeed.available, false)
equal(missing:point(missingFeed, 1), nil)

local independent, firstSession, firstFeed, independentPoll = harness()
local secondSession = independent:session("L02")
local secondFeed = independent:subscribe("V", { armSwitch = "L02" })
assert(firstSession ~= secondSession and firstFeed ~= secondFeed, "different panel switches must isolate recordings")
equal(independent:session("L01"), firstSession, "matching switch configurations share their clock")
equal(independent:subscribe("V", { armSwitch = "L02" }), secondFeed)
independentPoll(0, 1, 12, 0)
independentPoll(100, 1, 15, 0)
equal(firstFeed.max, 15)
equal(secondFeed.available, false, "another panel's switch must not arm this history")
independentPoll(200, 0, 20, 1)
local firstElapsed = firstSession.elapsed
independentPoll(300, 0, 25, 1)
equal(firstSession.elapsed, firstElapsed, "only the second panel's clock may advance")
equal(firstFeed.max, 15)
equal(secondFeed.min, 20)
equal(secondFeed.max, 25)
local secondElapsed = secondSession.elapsed
independentPoll(400, 1, 30, 1)
independentPoll(500, 1, 35, 0)
equal(firstFeed.max, 35)
equal(secondFeed.max, 30, "the second recording must freeze when its own switch is off")
assert(secondSession.elapsed > secondElapsed)
local unconfigured = independent:session()
local unconfiguredFeed = independent:subscribe("V")
independentPoll(600, 1, 40, 1)
equal(unconfigured.configured, false, "a blank panel must not inherit another panel's arm switch")
equal(unconfiguredFeed.available, false)
local unknownSession = independent:session("L03")
local unknownFeed = independent:subscribe("V", { armSwitch = "L03" })
independentPoll(700, nil, 45, 1)
equal(firstSession.available, false, "an unavailable switch must not be treated as a known disarm condition")
equal(firstSession.recording, false)
equal(firstFeed.value, 40, "switch loss must freeze the last recorded reading")
local unavailableElapsed = firstSession.elapsed
local previousSegment = firstSession.segment
independentPoll(800, nil, 55, 1)
equal(firstSession.elapsed, unavailableElapsed)
equal(secondFeed.max, 55, "another panel must continue recording during switch loss")
equal(unknownSession.configured, true)
equal(unknownSession.available, false)
equal(unknownFeed.available, false, "unresolved switches must not start a recording")
independentPoll(900, 1, 50, 0)
equal(firstSession.available, true)
equal(firstSession.segment, previousSegment + 1, "switch recovery must start a disconnected segment")
equal(firstFeed.value, 50)
equal(firstSession.elapsed, unavailableElapsed, "unavailable time must not consume the chart")

local smoothed, _, smoothFeed, smoothPoll = harness({ smoothing = "medium", windowSeconds = 30 })
smoothPoll(0, 1, 0)
smoothPoll(100, 1, 10)
equal(smoothFeed.value, 10)
equal(smoothFeed.min, 0)
equal(smoothFeed.max, 10)
local _, filtered = smoothed:point(smoothFeed, smoothFeed.last)
assert(filtered > 6.3 and filtered < 6.4, "smoothing must use elapsed time rather than redraw count")
smoothPoll(200, 0, 10)
smoothPoll(10000, 1, 20)
_, filtered = smoothed:point(smoothFeed, smoothFeed.last)
equal(filtered, 20, "filters restart at rearm boundaries")

for precision = 0, 3 do
    local compressor, output, sample = recorder({ precision = precision })
    local originals = {}
    local epsilon = 0.5 * 10 ^ -precision
    for index = 0, 800 do
        local number = math.sin(index * 0.17) * 10 + index * 0.002
        if index % 29 == 0 then
            number = number + 20
        end
        sample(index * 10, number)
        originals[#originals + 1] = { index * 10, number }
        if index < 40 or index % 80 == 0 then
            accuracy(compressor, output, originals, epsilon)
        end
    end
    equal(output.epsilon, epsilon)
    accuracy(compressor, output, originals, epsilon)
    assert(output.count < #originals)
end

-- A last raw sample need not lie on ANY line feasible for the whole corridor.
local corridor, corridorFeed, corridorSample = recorder({ precision = 0 })
local corridorOriginals = {}
for index, number in ipairs({ 0, 1.4, 1.1, 2.4, -2, 3, -3, 1 }) do
    corridorSample((index - 1) * 10, number)
    corridorOriginals[#corridorOriginals + 1] = { (index - 1) * 10, number }
    accuracy(corridor, corridorFeed, corridorOriginals, 0.5)
end
local synthesized = false
for _, point in ipairs(knots(corridor, corridorFeed)) do
    for _, original in ipairs(corridorOriginals) do
        if point[1] == original[1] and point[2] ~= original[2] then
            synthesized = true
        end
    end
end
assert(synthesized, "corridor failures must commit a synthesized shared endpoint")

local growing, growingFeed, growingSample, _, growingSession = recorder({ windowSeconds = 30, precision = 3 })
local growingOriginals = {}
for tick = 0, 500000, 100 do
    local number = tick == 10000 and -100 or tick / 100
    growingSample(tick, number)
    growingOriginals[#growingOriginals + 1] = { tick, number }
end
equal(growingFeed.min, -100)
equal(growingFeed.max, 5000)
equal(growing:point(growingFeed, 1), 0, "growing history retains the start")
equal(growingFeed.window, 504000)
equal(growingSession.elapsed, 500000)
accuracy(growing, growingFeed, growingOriginals, 0.0005)
assert(growingFeed.count < 20, "straight spans must not grow with flight duration")

local rolling, rollingFeed, rollingSample = recorder({ timeRange = "rolling", windowSeconds = 30 })
for tick = 0, 10000, 10 do
    rollingSample(tick, tick / 100)
end
equal(rollingFeed.window, 3000)
equal(rollingFeed.count, 2, "rolling ramps retain a bracketing anchor and the live endpoint")
equal(rollingFeed.min, 0)
equal(rollingFeed.max, 100)
accuracy(rolling, rollingFeed, { { 7000, 70 }, { 8000, 80 }, { 10000, 100 } }, 0.05)

local dense, denseFeed, denseSample = recorder({ precision = 3 })
local denseOriginals = {}
for index = 0, 6000 do
    local number = index % 2 == 0 and -100 or 100
    denseSample(index * 10, number)
    denseOriginals[#denseOriginals + 1] = { index * 10, number }
end
equal(denseFeed.count, 6001, "ten minutes at 10 Hz must fit even without compression savings")
equal(denseFeed.full, false)
accuracy(dense, denseFeed, denseOriginals, 0.0005)
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

local ring, ringFeed, ringSample = recorder({ precision = 3, timeRange = "rolling", windowSeconds = 600 })
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
accuracy(ring, ringFeed, ringOriginals, 0.0005)
local lastBlock = ring:block(ringFeed, (math.floor((ringFeed.first - 1) / 256) + 1) * 256 + 1, ringFeed.last, math.huge)
assert(lastBlock, "projection summaries must remain valid after ring wrap")
local lastAt, lastValue = ring:point(ringFeed, lastBlock)
assert(lastAt and lastValue)

local pending, pendingFeed, pendingSample, pendingReading = recorder()
pendingReading.precision, pendingReading.precisionKnown = 0, false
pendingSample(0, 0)
pendingSample(10, 0.009)
equal(pendingFeed.epsilon, 0.0005, "unknown sensor precision must not irreversibly compress too loosely")
pendingReading.precision, pendingReading.precisionKnown = 2, true
pendingSample(20, 0.013)
equal(pendingFeed.epsilon, 0.005)
accuracy(pending, pendingFeed, { { 0, 0 }, { 10, 0.009 }, { 20, 0.013 } }, 0.005)

local huge, hugeFeed, hugeSample = recorder({ precision = 3 })
local hugeOriginals = {}
for index = 0, 30 do
    local number = index % 2 == 0 and 1e16 or -1e16
    hugeSample(index * 10, number)
    hugeOriginals[#hugeOriginals + 1] = { index * 10, number }
end
accuracy(huge, hugeFeed, hugeOriginals, 0.0005)
equal(hugeFeed.count, 31, "when numerical margin consumes tolerance, retain exact native values")

local integers, integerFeed, integerSample = recorder({ precision = 3 })
integerSample(0, math.maxinteger)
integerSample(10, math.maxinteger - 1)
local _, integerValue = integers:point(integerFeed, integerFeed.first)
equal(integerValue, math.maxinteger, "native integers must not be truncated through floating-point packing")
_, integerValue = integers:point(integerFeed, integerFeed.last)
equal(integerValue, math.maxinteger - 1)

local extremes, extremesFeed, extremesSample = recorder({ precision = 3, smoothing = "medium" })
extremesSample(0, 1e308)
extremesSample(100, -1e308)
local _, extremeValue = extremes:point(extremesFeed, extremesFeed.last)
assert(extremeValue == extremeValue and math.abs(extremeValue) < math.huge, "EMA must not overflow finite endpoints")

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
print(
    string.format(
        "  chart history: 6001 worst-case samples fit; %d bytes/knot on this runtime",
        historyModule.BYTES_PER_POINT
    )
)
