-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local support = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local telemetryModule = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/telemetry_service.lua"))()
local historyModule = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/history_service.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local function harness(options, configured)
    local values = { [1] = 0, [100] = 12 }
    local fields = { arm = { id = 1 }, V = { id = 100, unit = 1 } }
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
        model = {},
    })
    local runtime = support.runtime(env)
    local telemetry = telemetryModule.new(env, support)
    runtime.byId.telemetry = telemetry
    local history = historyModule.new(env, support, runtime)
    local session = history:session(configured ~= false and "arm" or nil)
    local feed = history:subscribe("V", options)
    local function poll(now, arm, value)
        values[1], values[100] = arm, value
        telemetry:update(now)
        history:update(now)
    end
    return history, session, feed, poll, telemetry
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
local point = history:point(feed, feed.count)
equal(point.breakBefore, true)
equal(point.segment, 2)
equal(history:subscribe("V"), feed, "matching histories share storage")
assert(not pcall(function()
    feed.value = 42
end), "history views must be immutable")
assert(not pcall(function()
    point.last = 42
end), "point views must be immutable")

poll(11100, 1, nil)
equal(feed.stale, true)
equal(feed.value, 11)
poll(11200, 1, 0)
equal(feed.value, 0, "live zero is a valid sample")
equal(feed.min, 0)
equal(history:point(feed, feed.count).breakBefore, true, "dropouts break the trace")
poll(11300, 1, 0 / 0)
equal(feed.value, 0, "non-finite samples must not enter history")

local missing, missingSession, missingFeed, missingPoll = harness(nil, false)
missingPoll(0, 1, 12)
equal(missingSession.configured, false)
equal(missingSession.recording, false)
equal(missingFeed.available, false)
equal(missing:point(missingFeed, 1), nil)

local smoothed, _, smoothFeed, smoothPoll = harness({ smoothing = "medium", windowSeconds = 30 })
smoothPoll(0, 1, 0)
smoothPoll(100, 1, 10)
equal(smoothFeed.value, 10)
equal(smoothFeed.min, 0)
equal(smoothFeed.max, 10)
local filtered = smoothed:point(smoothFeed, smoothFeed.count).last
assert(filtered > 6.3 and filtered < 6.4, "smoothing must use elapsed time rather than redraw count")
smoothPoll(200, 0, 10)
smoothPoll(10000, 1, 20)
equal(smoothed:point(smoothFeed, smoothFeed.count).last, 20, "filters restart at rearm boundaries")

local growing, growingSession, growingFeed, growingPoll = harness({ windowSeconds = 30 })
for tick = 0, 500000, 100 do
    growingPoll(tick, 1, tick == 10000 and -100 or tick / 100)
end
assert(growingFeed.count <= historyModule.CAPACITY, "growing recordings must have bounded storage")
equal(growingFeed.min, -100, "compaction must preserve lifetime raw extrema")
equal(growingFeed.max, 5000)
equal(growing:point(growingFeed, 1).firstAt, 0, "growing history retains the start")
equal(growingFeed.window, 768000, "duration repeatedly doubles to cover the full recording")
equal(growingSession.elapsed, 500000)
local maximum = -math.huge
for index = 1, growingFeed.count do
    local value = growing:point(growingFeed, index)
    maximum = math.max(maximum, value.high)
    assert(value.firstAt <= value.lastAt)
end
equal(maximum, 5000)

local rolling, _, rollingFeed, rollingPoll = harness({ timeRange = "rolling", windowSeconds = 30 })
for tick = 0, 10000, 100 do
    rollingPoll(tick, 1, tick / 100)
end
equal(rollingFeed.window, 3000)
assert(rolling:point(rollingFeed, 1).lastAt >= 7000, "rolling history must evict expired buckets")
equal(rollingFeed.min, 0, "rolling extrema describe all armed recording periods")
equal(rollingFeed.max, 100)
assert(rollingFeed.count <= historyModule.CAPACITY)

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
