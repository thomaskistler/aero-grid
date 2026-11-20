-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local base = root .. "/src/WIDGETS/AeroGrid/lib/"
local support = assert(loadfile(base .. "services.lua"))()
local historyModule = assert(loadfile(base .. "history_service.lua"))()
local armedModule = assert(loadfile(base .. "armed_service.lua"))()
local controlModule = assert(loadfile(base .. "control_service.lua"))()
local telemetryModule = assert(loadfile(base .. "telemetry_service.lua"))()
local debriefModule = assert(loadfile(base .. "debrief_service.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local state = { epoch = 1, armKey = "L01", active = false, status = "ready", countAvailable = true, displayCount = 42 }
local events, sequence, values = {}, 0, {}
-- Radio wall clock in ticks from 2025-01-01, or a fixed 00:00:05.
local wall
local env = support.environment({
    getSwitchIndex = function(name)
        return name == "L01" and 1 or 2
    end,
    getSwitchValue = function(id)
        return values[id]
    end,
    getDateTime = function()
        local seconds = wall and wall // 100 or 5
        return { year = 2025, mon = 1, day = 1, hour = seconds // 3600, min = seconds % 3600 // 60, sec = seconds % 60 }
    end,
    model = {
        getInfo = function()
            return { name = "Edge 540" }
        end,
    },
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
local flightId = 0
local function event(kind, at)
    if kind == "start" then
        flightId = flightId + 1
    end
    sequence = sequence + 1
    events[#events + 1] = {
        epoch = state.epoch,
        sequence = sequence,
        kind = kind,
        at = at,
        observedAt = at,
        flightId = flightId,
        armKey = "L01",
    }
    state.active = kind == "start"
    state.flightId, state.startedAt = flightId, at
end

local subscribed, thresholds = {}, {}
local telemetry = { level = telemetryModule.level }
function telemetry:subscribe(source)
    subscribed[source] = true
end
function telemetry:observe() end
function telemetry:thresholdMap()
    return thresholds
end

local runtime, control, history
local function boot()
    runtime = support.runtime(env)
    runtime.modelArmed = "L01"
    runtime.chartColumns = assert(loadfile(base .. "chart_columns.lua"))()
    runtime.byId.flight = flight
    runtime.byId.telemetry = telemetry
    control = controlModule.new(env, support, runtime)
    runtime.byId.control = control
    runtime.byId.armed = armedModule.new(env, support, runtime)
    history = historyModule.new(env, support, runtime)
    runtime.byId.history = history
    local debrief = debriefModule.new(env, support, runtime)
    runtime.byId.debrief = debrief
    return debrief
end

--- One telemetry poll; `curves` maps source to a function of time
--- returning its reading, or nil for a missing reading.
local function poll(now, armed, curves)
    values[1] = armed
    control:update(now)
    history:advance(now)
    for name, curve in pairs(curves or {}) do
        local value = curve(now)
        history:sample({
            name = name,
            value = value,
            kind = "number",
            fresh = value ~= nil,
            updatedAt = now,
            precision = 2,
            unitText = "",
        }, now)
    end
    history:update(now)
end

local worst = 0
--- Run the recorder until it is idle; returns the number of busy callbacks.
local function drain(debrief, now, slots)
    slots = slots or 1
    local calls = 0
    while true do
        local count = 0
        debug.sethook(function()
            count = count + 1
        end, "", 1)
        local used, busy = debrief:update(now, slots)
        debug.sethook()
        assert(used >= 1 and used <= slots, "used slots must stay within the grant")
        worst = math.max(worst, count / slots)
        if not busy then
            return calls
        end
        calls = calls + 1
        assert(calls < 10000, "capture must finish")
    end
end

local function tile(series, colSpan)
    return { colSpan = colSpan or 2, rowSpan = 1, series = series }
end

--- Arm at `from`, start the flight at `from + lead`, sample until `to`, disarm,
--- keep sampling for `grace` ticks, then confirm the end.
local function fly(from, to, curves, lead, grace)
    lead, grace = lead or 0, grace or 0
    poll(from - 100, false, {})
    for now = from, to, 10 do
        if now == from + lead + 20 then
            event("start", from + lead)
        end
        poll(now, true, curves)
    end
    for now = to + 10, to + 10 + grace, 10 do
        poll(now, false, curves)
    end
    event("end", to + 10)
    for now = to + 20 + grace, to + 100 + grace, 10 do
        poll(now, false, {})
    end
end

local function near(actual, expected, message)
    assert(math.abs(actual - expected) < 1e-3, message .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

local function ramp(t)
    return (t - 1000) / 100
end

-- A completed flight records statistics over the flight slice, one sample
-- per pixel column.
local debrief = boot()
debrief:configure({
    tiles = {
        tile({
            { source = "V", statistic = "max" },
            { source = "A", statistic = "avg" },
        }),
        tile({
            { source = "V", statistic = "min" },
            { source = "A", statistic = "delta" },
        }),
    },
}, { 40, 20 })
equal(debrief.count, 4, "every series counts toward the task")
assert(subscribed.V and subscribed.A, "series must be subscribed before the flight")
poll(0, false, {})
drain(debrief, 0)
equal(debrief:result(), nil, "no flight means no debrief")
local steps = function(t)
    return 10 + (t - 1000) // 100
end
fly(1000, 2000, { V = steps, A = ramp })
local start, finish = history:flight(debrief.session, 1)
local result = assert(debrief:result() == nil and drain(debrief, 3000) > 0 and debrief:result())
equal(result.duration, finish - start)
local first, second = result.tiles[1].series, result.tiles[2].series
equal(first[1].value, 20, "max")
near(first[2].value, (finish - start) / 200, "time-weighted average of a ramp")
equal(second[1].value, 10, "min")
near(second[2].value, (finish - start) / 100, "delta is end minus start")
equal(first[1].config.source, "V")
equal(result.tiles[2].config, debrief.tiles[2])
local columns = first[2].columns
equal(columns.width, 40)
for slot = 1, 40 do
    equal(columns.kinds[slot], "data", "a straight segment fills every column")
    -- Each column starts with the line's value at the column's first tick.
    local at = ((slot - 1) * (finish - start + 1) + 39) // 40
    near(columns.low[slot], at / 100, "column " .. slot)
end
equal(first[1].level, "normal", "no thresholds means normal")
equal(next(first[1].levels), nil)
equal(first[1].thresholds, nil)
-- Header metadata is taken when the capture starts; the flight began more
-- than 5 s before the clock read 2025-01-01 00:00:05.
equal(result.flight, 42)
equal(result.model, "Edge 540")
equal(result.started.year, 2024)
equal(result.started.mon, 12)
equal(result.started.day, 31)

-- Start dates step back across midnight, month and leap-year boundaries.
local function date(now, age, year, mon, day, hour, min)
    local value = debriefModule.dateBefore(now, age)
    local text = string.format("%d-%d-%d %d:%d", value.year, value.mon, value.day, value.hour, value.min)
    equal(text, string.format("%d-%d-%d %d:%d", year, mon, day, hour, min))
end
date({ year = 2025, mon = 11, day = 17, hour = 14, min = 30, sec = 0 }, 360, 2025, 11, 17, 14, 24)
date({ year = 2025, mon = 3, day = 1, hour = 0, min = 2, sec = 0 }, 180, 2025, 2, 28, 23, 59)
date({ year = 2024, mon = 3, day = 1, hour = 0, min = 0, sec = 30 }, 60, 2024, 2, 29, 23, 59)
date({ year = 2025, mon = 1, day = 1, hour = 0, min = 0, sec = 0 }, 1, 2024, 12, 31, 23, 59)
equal(debriefModule.dateBefore(nil, 10), nil, "no clock means no date")

-- A flight starting after arming and confirmed after a grace period is
-- clipped to its own bounds; a missing reading breaks the line; threshold
-- levels are judged on the recorded values.
debrief:configure({
    tiles = {
        tile({
            { source = "V", statistic = "max" },
            { source = "A", statistic = "min" },
        }),
        tile({ { source = "A", statistic = "avg" } }),
    },
}, { 40, 20 })
thresholds.V = { sensor = "V", warning = 15, critical = 18, falling = false }
local function climb(t)
    return (t - 3000) / 50
end
local function gappy(t)
    if t >= 3500 and t < 3600 then
        return nil
    end
    return (t - 3000) / 100
end
local previous = result
local function during()
    equal(drain(debrief, 3900), 0, "an in-progress flight is not captured")
    equal(debrief:result(), previous, "the last debrief stays until the next flight ends")
end
poll(2900, false, {})
for now = 3000, 4000, 10 do
    if now == 3220 then
        event("start", 3200)
    end
    if now == 3900 then
        during()
    end
    poll(now, true, { V = climb, A = gappy })
end
for now = 4010, 4060, 10 do
    poll(now, false, { V = climb, A = gappy })
end
event("end", 4010)
for now = 4070, 4150, 10 do
    poll(now, false, {})
end
start, finish = history:flight(debrief.session, 2)
equal(finish - start, 810, "the flight runs from its start to the final disarm")
drain(debrief, 4200)
result = debrief:result()
assert(result ~= previous, "a new flight replaces the debrief")
equal(result.duration, 810)
first = result.tiles[1].series
near(first[1].value, 20.2, "max ignores samples after the flight")
near(first[2].value, 2, "min starts at the interpolated flight start")
near(first[2].columns.low[1], 2, "the first column starts at the flight start")
equal(first[1].level, "critical", "the worst level is kept")
equal(first[1].thresholds.warning, 15, "series carry their threshold spec")
equal(first[1].thresholds.critical, 18)
equal(first[1].thresholds.falling, false)
equal(first[2].level, "normal", "a source without thresholds stays normal")
local levels = first[1].levels
equal(levels[1], nil)
equal(levels[40], 2)
local warned = 0
for slot = 1, 40 do
    local value = first[1].columns.high[slot]
    local expected = value >= 18 and 2 or value >= 15 and 1 or nil
    equal(levels[slot], expected, "column " .. slot .. " level")
    warned = warned + (levels[slot] == 1 and 1 or 0)
end
assert(warned > 0, "warning columns are shaded")
local gap = result.tiles[2].series[1]
equal(gap.columns.breakLast, 1, "a missing reading breaks the line")
local empty = 0
for slot = 1, 20 do
    empty = empty + (gap.columns.kinds[slot] == nil and 1 or 0)
end
assert(empty > 0, "nothing is drawn across the gap")
-- Average over the recorded time only: the ramp from 2 to 10.1 with
-- 3500..3600 missing (the line resumes at 3600, value 6).
local area = (2 + 4.9) / 2 * 290 + (6 + 10.1) / 2 * 410
near(gap.value, area / 700, "the average skips the gap")

-- Session reset clears the debrief; the next flight is recorded afresh.
debrief:resetSession()
for index = 1, 8 do
    history:resetSession(4300, index)
end
equal(debrief:result(), nil, "reset clears the debrief")
equal(drain(debrief, 4300), 0)
fly(5000, 5500, { V = climb, A = gappy })
drain(debrief, 5700)
equal(debrief:result().duration, 510, "the first flight after a reset is recorded")

-- A Save during a capture restarts it with the saved debrief.
fly(6000, 6500, { V = climb, A = gappy })
local used, busy = debrief:update(6700, 1)
assert(busy and debrief.job, "the capture is under way")
equal(debrief:result(), nil, "the old debrief is released when a capture starts")
local saved = { tiles = { tile({ { source = "V", statistic = "avg" } }) } }
debrief:configure(saved, { 30 })
equal(debrief.job, nil)
drain(debrief, 6700)
result = assert(debrief:result(), "the interrupted flight is captured again")
equal(result.tiles[1].config, saved.tiles[1])
equal(result.tiles[1].series[1].columns.width, 30)
equal(#result.tiles, 1)

-- Saving after a flight does not capture it again.
debrief:configure(saved, { 30 })
equal(drain(debrief, 6800), 0)
equal(debrief:result(), result)

-- A Save between a flight's end and its capture still captures the flight.
fly(7000, 7500, { V = climb, A = gappy })
debrief:configure(saved, { 30 })
drain(debrief, 7700)
assert(debrief:result() ~= result, "a Save must not skip a finished flight")
equal(debrief:result().duration, 510)

-- A session reset during a capture drops it; flights the history has not reset
-- yet are not captured, and the next flight is.
fly(8000, 8500, { V = climb, A = gappy })
used, busy = debrief:update(8700, 1)
assert(busy and debrief.job, "the capture is under way")
debrief:resetSession()
equal(debrief.job, nil)
equal(debrief:result(), nil)
equal(drain(debrief, 8700), 0, "flights before the reset are not captured")
for index = 1, 8 do
    history:resetSession(8800, index)
end
equal(drain(debrief, 8800), 0)
equal(debrief:result(), nil)
fly(9000, 9500, { V = climb, A = gappy })
drain(debrief, 9700)
equal(debrief:result().duration, 510, "the first flight after a reset is captured")

-- An empty flight slice after a long history is searched within budget.
debrief:configure({
    tiles = {
        tile({
            { source = "Z", statistic = "min" },
            { source = "Z", statistic = "max" },
            { source = "Z", statistic = "avg" },
            { source = "Z", statistic = "delta" },
        }),
    },
}, { 40 })
local function zigzag(t)
    return t // 10 % 2
end
poll(9900, false, {})
for now = 10000, 71000, 10 do
    poll(now, true, { Z = zigzag })
end
fly(71100, 71600, {})
drain(debrief, 71800)
for _, quiet in ipairs(debrief:result().tiles[1].series) do
    equal(quiet.value, nil, "no samples, no statistic")
    equal(next(quiet.columns.kinds), nil, "no samples, no columns")
end
debrief:configure(saved, { 30 })

-- A rebind replaces the history; the old one is ignored until reconfigured.
local old = history
history = historyModule.new(env, support, runtime)
runtime.byId.history = history
used, busy = debrief:update(6900, 4)
equal(used, 1)
equal(busy, nil)
debrief:configure(saved, { 30 })
equal(debrief.history, history)
assert(debrief.history ~= old)
equal(debrief.session, history:session())

-- No tiles: nothing to subscribe, no task.
debrief:configure(nil, {})
equal(debrief.count, 0)
debrief:configure({ tiles = {} }, {})
equal(debrief.count, 0)
equal(debrief:update(7000, 4), 1)

--- Capture one flight from a fake history of `knots` ({ at, value, broken }).
local function fake(knots, from, to, series, width)
    local feed = { first = 1, last = #knots, count = #knots }
    local source = {}
    function source:session()
        return { flightLast = 1 }
    end
    function source:subscribe()
        return feed
    end
    function source:flight()
        return from, to
    end
    function source:point(_, index)
        local knot = knots[index]
        if knot then
            return knot[1], knot[2], knot[3] == true
        end
    end
    local recorder = debriefModule.new(env, support, runtime)
    runtime.byId.history = source
    recorder:configure({ tiles = { tile(series) } }, { width or 40 })
    recorder.handled = 0
    drain(recorder, 0)
    runtime.byId.history = history
    return recorder:result().tiles[1].series
end
local all = {
    { source = "X", statistic = "min" },
    { source = "X", statistic = "max" },
    { source = "X", statistic = "avg" },
    { source = "X", statistic = "delta" },
}

-- Flight time is scaled so column arithmetic stays within int32.
do
    local series = fake({ { 0, 0 }, { 400000000, 100 } }, 0, 400000000, { { source = "X", statistic = "avg" } }, 400)[1]
    local store = series.columns
    assert(store.window * store.width < 0x7fffffff, "column times must fit int32")
    for slot = 1, 400 do
        equal(store.kinds[slot], "data", "column " .. slot)
    end
    near(series.value, 50, "average of a long ramp")
end

-- A flight with a single sample.
local single = fake({ { 50, 7 } }, 0, 100, all)
equal(single[1].value, 7, "min of one sample")
equal(single[2].value, 7, "max of one sample")
near(single[3].value, 7, "avg of one sample")
near(single[4].value, 0, "delta of one sample")

-- Integer readings at int32 scale: clipping and averaging must not overflow.
local clipped = fake({ { 0, 0 }, { 60000, 100000 } }, 30000, 60000, all)
near(clipped[1].value, 50000, "min at the interpolated flight start")
near(clipped[2].value, 100000, "max")
near(clipped[3].value, 75000, "avg")
near(clipped[4].value, 50000, "delta")
local wide = fake({ { 0, 2000000000 }, { 1000, 2000000000 }, { 2000, -2000000000 } }, 0, 2000, all)
near(wide[1].value, -2e9, "min")
near(wide[2].value, 2e9, "max")
near(wide[3].value, 1e9, "avg")
near(wide[4].value, -4e9, "delta")

-- The start date counts back by the time since the flight started, not by
-- recorded time: recording pauses while disarmed mid-flight, and the capture
-- may run long after the flight ended.
do
    local recorder = boot()
    recorder:configure({ tiles = { tile({ { source = "V", statistic = "max" } }) } }, { 20 })
    for now = 99000, 100000, 10 do
        poll(now, false, {})
    end
    local level = {
        V = function()
            return 4
        end,
    }
    for now = 200000, 203000, 10 do
        if now == 200020 then
            event("start", 200000)
        end
        poll(now, true, level)
    end
    for now = 203010, 230000, 10 do
        poll(now, false, level)
    end
    for now = 230010, 233000, 10 do
        poll(now, true, level)
    end
    event("end", 233010)
    for now = 233020, 293000, 100 do
        poll(now, false, {})
    end
    wall = 293000
    drain(recorder, 293000)
    wall = nil
    local started = assert(recorder:result(), "the delayed flight is captured").started
    equal(string.format("%02d:%02d", started.hour, started.min), "00:33", "start is 930 s before 00:48:50")
end

-- One slot is a nominal 2000 instructions, setup included.
assert(worst <= 2000, "capture work must fit its slots: " .. worst)
