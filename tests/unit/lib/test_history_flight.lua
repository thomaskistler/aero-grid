-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local base = root .. "/src/WIDGETS/AeroGrid/lib/"
local support = assert(loadfile(base .. "services.lua"))()
local historyModule = assert(loadfile(base .. "history_service.lua"))()
local armedModule = assert(loadfile(base .. "armed_service.lua"))()
local controlModule = assert(loadfile(base .. "control_service.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local state = { epoch = 1, armKey = "L01", active = false, status = "ready" }
local events, sequence, values = {}, 0, {}
local env = support.environment({
    getSwitchIndex = function(name)
        return name == "L01" and 1 or 2
    end,
    getSwitchValue = function(id)
        return values[id]
    end,
})
local flight = {}
function flight:state()
    return support.snapshot(state)
end
function flight:boundaries(after, epoch)
    local records = {}
    for _, event in ipairs(events) do
        if event.sequence > after then
            records[#records + 1] = event
        end
    end
    local oldest = events[1] and events[1].sequence or sequence + 1
    return records, oldest, epoch ~= nil and epoch ~= state.epoch or after < oldest - 1
end
local function event(kind, at, observed, id, key)
    sequence = sequence + 1
    events[#events + 1] = {
        epoch = state.epoch,
        sequence = sequence,
        kind = kind,
        at = at,
        observedAt = observed,
        flightId = id,
        armKey = key or "L01",
    }
    if #events > 64 then
        table.remove(events, 1)
    end
end
local function harness(native)
    local runtime = support.runtime(env)
    runtime.nativeArmed = native
    runtime.byId.flight = flight
    local control = controlModule.new(env, support, runtime)
    runtime.byId.control = control
    runtime.byId.armed = armedModule.new(env, support, runtime)
    local history = historyModule.new(env, support, runtime)
    local session = history:session("L01")
    local independent = history:session("L02")
    local feed = history:subscribe("V", { armSwitch = "L01", precision = 3 })
    local second = history:subscribe("A", { armSwitch = "L01", precision = 3 })
    local other = history:subscribe("V", { armSwitch = "L02", precision = 3 })
    local samples = 0
    local function poll(now, armed, value, independentlyArmed)
        values[1], values[2] = armed, independentlyArmed
        control:update(now)
        history:advance(now)
        for _, name in ipairs({ "V", "A" }) do
            history:sample({
                name = name,
                value = value,
                kind = "number",
                fresh = value ~= nil,
                updatedAt = now,
                precision = 3,
                unitText = "",
            }, now)
        end
        if session.recording and value ~= nil then
            samples = samples + 1
        end
        history:update(now)
        return samples
    end
    return history, session, feed, poll, independent, other, second
end

local history, session, feed, poll, independent, other, second = harness()
poll(0, false, 0, false)
poll(100, true, 1, true)
poll(200, true, 2, true)
state.active, state.startedAt, state.flightId = true, 200, 1
event("start", 200, 300, 1)
poll(300, true, 3, true)
local at, finish, startKnown, endKnown = history:flight(session, 1)
equal(at, 100, "qualification must mark the candidate's time, not receipt time")
equal(finish, nil)
equal(startKnown, true)
equal(endKnown, nil)
equal(session.flightLast, 1)
local segment = session.segment
poll(400, false, 4, false)
poll(500, false, 5, false)
equal(feed.value, 5, "grace samples are recorded")
equal(other.value, 3, "an independently armed chart must pause without shared grace")
equal(independent.recording, false)
equal(session.recording, true)
poll(550, true, 6, false)
equal(session.segment, segment, "rearm within grace must not disconnect the recording")
equal(session.flightLast, 1, "rearm must not create another flight")
poll(600, false, 7, false)
poll(650, nil, nil, false)
equal(session.recording, true, "unknown arm cannot stop an active flight")
poll(700, false, 8, false)
equal(feed.value, 8)
equal(second.value, feed.value, "all metric series must retain grace samples")
local lastAt, _, broken = history:point(feed, feed.last)
equal(lastAt, 600)
equal(broken, true, "telemetry loss still breaks traces inside flight grace")
state.active = false
event("end", 600, 800, 1)
equal(poll(800, false, 9, false), 8, "eight fresh samples precede confirmed completion")
equal(feed.value, 8, "confirmation stops new sampling without deleting grace samples")
equal(feed.revision, 9, "eight recorded samples plus one stale transition; confirmation adds no sample")
equal(session.elapsed, 700)
at, finish, startKnown, endKnown = history:flight(session, 1)
equal(at, 100)
equal(finish, 500, "flight ends at final disarm, not confirmation")
equal(endKnown, true)
poll(900, false, 10, false)
equal(session.elapsed, 700)
poll(1000, true, 11, false)
poll(1050, true, 12, false)
state.active, state.startedAt, state.flightId = true, 1050, 2
event("start", 1050, 1200, 2)
poll(1200, true, 13, false)
equal(history:flight(session, 2), 750, "wall time between recording segments takes no axis space")
poll(1300, false, 14, false)
state.active = false
event("end", 1300, 1400, 2)
poll(1400, false, 15, false)
at, finish = history:flight(session, 2)
equal(at, 750)
equal(finish, 1000)
equal(session.flightLast, 2)

-- A pinned historical event must not follow the broker's new live arm.
state.armKey = "L02"
event("start", 200, 1500, 99, "L01")
poll(1500, false, 16, false)
equal(session.flightLast, 3)
equal(independent.flightLast, 0)
state.armKey = "L01"

-- Both the interval ring and the wall/axis mapping stay bounded.
for id = 3, 75 do
    local now = 2000 + id * 100
    poll(now, true, id, false)
    state.active, state.startedAt, state.flightId = true, now, id
    event("start", now, now + 20, id)
    poll(now + 20, true, id + 0.1, false)
    poll(now + 40, false, id + 0.2, false)
    state.active = false
    event("end", now + 40, now + 60, id)
    poll(now + 60, false, id + 0.3, false)
end
equal(session.flightLast - session.flightFirst + 1, 64)
equal(history:flight(session, session.flightFirst - 1), nil, "evicted interval IDs are not reused")
assert(#history.sessions[1].spans <= 128)
assert(#history.sessions[1].flights <= 64)

-- Journal loss is explicit; drain remains one record per service turn.
local before = session.flightLast
for id = 100, 140 do
    event("start", 9400, 9500, id)
    event("end", 9450, 9600, id)
end
poll(9700, false, 17, false)
equal(session.flightLost, true)
equal(history.flightSequence, sequence - 63)
assert(session.flightLast <= before + 1)
for now = 9701, 9770 do
    poll(now, false, 17, false)
end
equal(history.flightSequence, sequence)

-- A fresh runtime cannot invent pre-attachment recording or a start marker.
events = {}
state.active, state.startedAt, state.flightId = true, 9800, 200
event("start", 9800, 9900, 200)
local late, lateSession, lateFeed, latePoll = harness()
latePoll(10000, false, 20, false)
at, finish, startKnown = late:flight(lateSession, 1)
equal(at, 0)
equal(finish, nil)
equal(startKnown, false)
equal(lateFeed.value, 20)
latePoll(10100, false, 21, false)
equal(lateSession.flightLast, 1)
state.active = false
event("end", 10100, 10200, 200)
latePoll(10200, false, 22, false)
at, finish, startKnown, endKnown = late:flight(lateSession, 1)
equal(finish, 100)
equal(endKnown, true)

local completed, completedSession, _, completedPoll = harness()
completedPoll(10250, false, 23, false)
completedPoll(10260, false, 23, false)
equal(completedSession.flightLast, 0, "late attachment must ignore already completed historical flights")
equal(completed:flight(completedSession, 1), nil)

events = {}
state.active, state.startedAt, state.flightId = true, 10400, 300
event("start", 10400, 10500, 300)
local grace, graceSession, graceFeed, gracePoll = harness()
gracePoll(11000, false, 24, false)
equal(graceFeed.value, 24, "attachment during grace still records telemetry")
state.active = false
event("end", 10800, 11200, 300)
gracePoll(11200, false, 25, false)
equal(grace:flight(graceSession, 1), nil, "an end before attachment must not label grace-only samples as in-flight")

state.epoch, state.armKey, events = 2, "L02", {}
latePoll(10300, false, 23, false)
equal(lateSession.flightLast, 0, "model epochs remove old flight overlays even for a nonmatching arm")
equal(late:flight(lateSession, 1), nil)

-- Native Armed deliberately collapses legacy arms to the widget condition.
state.armKey, state.active, state.startedAt, state.flightId = "L01", true, 10400, 201
local native, nativeSession, _, nativePoll, nativeOther = harness(1)
equal(nativeSession, nativeOther)
nativePoll(10400, false, 24, false)
equal(nativeSession.recording, true)
equal(native:flight(nativeSession, 1), 0)

-- With no shared detector, the established arm-only behavior remains intact.
state.active, state.armKey, state.status = false, nil, "unconfigured"
local legacy, legacySession, legacyFeed, legacyPoll = harness()
legacyPoll(10500, true, 25, false)
legacyPoll(10600, false, 26, false)
equal(legacySession.recording, false)
equal(legacyFeed.value, 25)
equal(legacySession.flightLast, 0)
equal(legacy:flight(legacySession, 1), nil)

local subscriptions, sessions = legacy.count, #legacy.sessions
local controls = #legacy.runtime.byId.control.entries
local preview = legacy:preview()
equal(preview:session("L01"), legacySession)
equal(preview:subscribe("V", { armSwitch = "L01", precision = 3 }), legacyFeed)
equal(preview:subscribe("unconfigured", { armSwitch = "L03" }).previewMissing, true)
equal(preview:subscribe("V", { armSwitch = "L01", smoothing = "strong" }).previewMissing, true)
equal(preview:session("L03").elapsed, 0)
equal(legacy.count, subscriptions, "draft-only sources must not create live recordings")
equal(#legacy.sessions, sessions, "draft-only arms must not create live sessions")
equal(#legacy.runtime.byId.control.entries, controls, "draft arms must not create live control pollers")
equal(preview.sample, nil)
equal(preview.boundaries, nil)
