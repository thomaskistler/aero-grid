-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local sim = assert(loadfile(root .. "/tests/support/scheduler_sim.lua"))()
local admission = assert(loadfile(root .. "/tests/support/scheduler_admission.lua"))()
local mixes = assert(loadfile(root .. "/tests/support/scheduler_mixes.lua"))()
local framework = assert(loadfile(root .. "/tests/support/scheduler_overhead.lua"))()
local equal = assertions.assertEqual

-- The planner's own cost is measured in the callbacks that ask for it.
local count, pause = framework.hookCounter()
local function newSim(overheads, start, measured)
    local options = { start = start }
    if measured then
        options.count, options.pause = count, pause
    end
    return sim.new(scheduler, overheads, options)
end

local LIMIT = scheduler.CEILING - scheduler.MARGIN
local CHARGE = scheduler.EXAMINE_COST + scheduler.RUN_COST
local STEADY_OVERHEAD = 1250
local RESET_POLL, TICK, SMART = 620, 1000, 2600

local once = mixes.once
local PANEL, CHART, HISTORY = mixes.PANEL, mixes.CHART, mixes.HISTORY
local NEXT_CHART_STAGE = mixes.NEXT_CHART_STAGE
local MIXES = mixes.MIXES
local RECORDED = mixes.releases({ recorded = 1, interval = 10 }, 1)[1].decl

-- Peak and sustained load per callback, and the room left beside the peak in a
-- callback with the tick (T), the tick and Smart (TS) and neither (R4), at one
-- sensor per task and at two. Plan section 4.
local EXPECTED = {
    [1] = {
        A = { peak = 6042, sustained = 4636, T = 5556, TS = 2956, R4 = 6556 },
        B = { peak = 4574, sustained = 2553, T = 7024, TS = 4424, R4 = 8024 },
        C = { peak = 4934, sustained = 4297, T = 6664, TS = 4064, R4 = 7664 },
        D = { peak = 8978, sustained = 8122, T = 2620, TS = 20, R4 = 3620 },
    },
    [2] = {
        A = { peak = 5754, sustained = 4296, T = 5844, TS = 3244, R4 = 6844 },
        B = { peak = 5754, sustained = 2400, T = 5844, TS = 3244, R4 = 6844 },
        C = { peak = 5754, sustained = 4077, T = 5844, TS = 3244, R4 = 6844 },
        D = { peak = 8402, sustained = 7546, T = 3196, TS = 596, R4 = 4196 },
    },
}

local function releases(mix, batch)
    return mixes.releases(mix, batch or 2)
end

-- Registers a mix as periodic stubs; `delay` equals the interval, so the plan
-- and the simulation see the same releases.
local function addMix(simulation, mix, batch)
    for index, release in ipairs(releases(mix, batch)) do
        simulation:add({
            id = "critical" .. index,
            decl = release.decl,
            due = scheduler.stagger(index - 1, release.interval),
            delay = release.interval,
        })
    end
end

local function addNormalWork(simulation)
    simulation:add({
        due = 0,
        id = "chart",
        decl = CHART,
        stage = "begin",
        delay = 1,
        after = function(instance, stage)
            instance.stage = NEXT_CHART_STAGE[stage]
        end,
    })
    for index = 1, 4 do
        simulation:add({ id = "panel" .. index, decl = PANEL, due = index, delay = 20 })
    end
end

local function testAdmissionReproducesTheRecomputedTables()
    local heads = { T = RESET_POLL + TICK, TS = RESET_POLL + TICK + SMART, R4 = RESET_POLL }
    for batch, rows in pairs(EXPECTED) do
        for name, expected in pairs(rows) do
            local label = "mix " .. name .. " at " .. batch .. " per task"
            local peak, sustained = admission.load(scheduler, releases(MIXES[name], batch))
            equal(peak, expected.peak, "peak of " .. label)
            assert(math.abs(sustained - expected.sustained) < 1, "sustained of " .. label .. ": " .. sustained)
            for kind, head in pairs(heads) do
                local result = admission.check({
                    scheduler = scheduler,
                    overhead = STEADY_OVERHEAD,
                    head = head,
                    releases = releases(MIXES[name], batch),
                })
                equal(result.base - result.peak, expected[kind], "room " .. kind .. " of " .. label)
                if kind ~= "TS" then
                    equal(#result.failures, 0, label .. " " .. kind .. ": " .. table.concat(result.failures, "; "))
                end
            end
        end
    end
end

local function testAdmissionRejectsOverloads()
    local function failed(config)
        config.scheduler, config.overhead = scheduler, STEADY_OVERHEAD
        return table.concat(admission.check(config).failures, " ")
    end
    -- Today's 10 Hz mix in the callback that also runs Smart (until R4).
    assert(string.find(failed({ head = RESET_POLL + TICK + SMART, releases = releases(MIXES.D) }), "A:", 1, true))
    local sixteen = mixes.releases({ recorded = 16, interval = 10 }, 2)
    local text = failed({ head = RESET_POLL, releases = sixteen })
    assert(string.find(text, "B:", 1, true) and string.find(text, "C:", 1, true))
    assert(string.find(failed({ releases = { { decl = once("critical", 11000), interval = 5 } } }), "A:", 1, true))
    assert(string.find(failed({ releases = { { decl = once("critical", 4100), interval = 100 } } }), "E:", 1, true))
    -- A two-sensor batch is a worthwhile task, a single 1180-instruction one is not.
    local small =
        admission.check({ scheduler = scheduler, overhead = STEADY_OVERHEAD, releases = releases(MIXES.A, 1) })
    assert(#small.small > 0, "single sensors are below the minimum piece")
    equal(admission.minimumPiece(scheduler), 10 * scheduler.RUN_COST)
end

-- The largest indivisible piece that fits beside the peak, per mix, phase and
-- sensors per task, against the maximum task size. The combinations below the
-- limit are listed, not hidden: M is kept at 4000 (decided) and the tasks of
-- those combinations are reviewed in their own migrations.
local function testLargestPieceAgainstTheMaximumTaskSize()
    local gaps = {}
    for batch, rows in pairs(EXPECTED) do
        for name, expected in pairs(rows) do
            for _, phase in ipairs({ "T", "TS", "R4" }) do
                local piece = expected[phase] - CHARGE
                if piece < admission.MAX_SIZE then
                    gaps[#gaps + 1] = string.format("%s/%s/%d per task=%d", name, phase, batch, piece)
                end
            end
        end
    end
    table.sort(gaps)
    equal(
        table.concat(gaps, "; "),
        table.concat({
            "A/TS/1 per task=2668",
            "A/TS/2 per task=2956",
            "B/TS/2 per task=2956",
            "C/TS/1 per task=3776",
            "C/TS/2 per task=2956",
            "D/R4/1 per task=3332",
            "D/R4/2 per task=3908",
            "D/T/1 per task=2332",
            "D/T/2 per task=2908",
            "D/TS/1 per task=-268",
            "D/TS/2 per task=308",
        }, "; ")
    )
    -- Every other combination fits M, and a piece of M is admitted there.
    local result = admission.check({
        scheduler = scheduler,
        overhead = STEADY_OVERHEAD,
        head = RESET_POLL,
        releases = releases(MIXES.A, 2),
        decls = { once("normal", admission.MAX_SIZE) },
    })
    equal(#result.failures, 0, "a piece of M fits beside mix A in R4")
    result = admission.check({
        scheduler = scheduler,
        overhead = STEADY_OVERHEAD,
        head = RESET_POLL + TICK,
        releases = releases(MIXES.D, 2),
        decls = { once("normal", admission.MAX_SIZE) },
    })
    assert(string.find(table.concat(result.failures, " "), "A:", 1, true), "a piece of M does not fit mix D before R4")
end

-- Callbacks every 3 to 15 ticks. R4: only the reset poll is legacy head work. R3:
-- the tick is too, and legacy Smart adds its cost in every second callback.
local PHASES = {
    R4 = function()
        return RESET_POLL
    end,
    R3 = function(index)
        return index % 2 == 0 and RESET_POLL + TICK + SMART or RESET_POLL + TICK
    end,
}
local PHASE_HEADS = { R4 = { RESET_POLL }, R3 = { RESET_POLL + TICK, RESET_POLL + TICK + SMART } }
-- Combinations the admission test does not admit (they stay safe, not timely).
local NOT_ADMITTED = { ["D/R3/1"] = true, ["D/R3/2"] = true }

local function jitterRun(mix, batch, phase, start, callbacks, measured, withNormal)
    local simulation = newSim({ steady = STEADY_OVERHEAD, background = 1130 }, start, measured)
    addMix(simulation, mix, batch)
    if withNormal then
        addNormalWork(simulation)
    end
    local schedule = sim.schedule(11, callbacks, 3, 15)
    for index, item in ipairs(schedule) do
        item.used = PHASES[phase](index)
    end
    simulation:run(schedule)
    return simulation, schedule
end

-- Admitted combinations run their critical tasks within two callback gaps of
-- their release (three in R3, where legacy Smart can take a callback) and at
-- least 85% of the runs an unlimited budget allows; mix D, 73% loaded, 70%.
-- The same critical tasks on an unlimited budget: the runs the callbacks allow.
local function idealRuns(mix, batch, schedule)
    local simulation = sim.new(scheduler, { steady = -1000000, background = -1000000 })
    addMix(simulation, mix, batch)
    for _, item in ipairs(schedule) do
        simulation:callback("steady", item.now, 0)
    end
    return simulation.runs
end

local function testAMixedRunUnderJitter()
    local CALLBACKS = 1500
    for _, batch in ipairs({ 1, 2 }) do
        for _, phase in ipairs({ "R4", "R3" }) do
            for _, name in ipairs({ "A", "B", "C", "D" }) do
                local mix = MIXES[name]
                local label = string.format("mix %s %s %d per task", name, phase, batch)
                local simulation, schedule = jitterRun(mix, batch, phase, 0, CALLBACKS, true, true)
                for _, report in ipairs(simulation.reports) do
                    assert(report.U <= LIMIT, label .. " planned " .. report.U)
                    assert(
                        report.actual <= report.U,
                        label .. ": a callback used " .. report.actual .. " of " .. report.U
                    )
                    assert(
                        report.framework <= report.charged,
                        label .. ": the planner cost " .. report.framework .. " of " .. report.charged
                    )
                    local ids = {}
                    for _, entry in ipairs(report.plan) do
                        assert(not ids[entry.id], "a task ran twice in one callback")
                        ids[entry.id] = true
                        assert(entry.used <= entry.grant)
                    end
                end
                equal(simulation.overruns, 0, label)
                assert(simulation.runs.chart > 0 and simulation.runs.panel1 > 0, label .. ": normal work still runs")
                local admitted = true
                for _, head in ipairs(PHASE_HEADS[phase]) do
                    local result = admission.check({
                        scheduler = scheduler,
                        overhead = STEADY_OVERHEAD,
                        head = head,
                        releases = releases(mix, batch),
                    })
                    admitted = admitted and #result.failures == 0
                end
                equal(admitted, not NOT_ADMITTED[name .. "/" .. phase .. "/" .. batch], label .. ": admission")
                if admitted then
                    local ideal = idealRuns(mix, batch, schedule)
                    local limit = phase == "R4" and 30 or 45
                    for index in ipairs(releases(mix, batch)) do
                        local id = "critical" .. index
                        assert(
                            simulation.maxWait[id] <= limit,
                            label .. ": " .. id .. " waited " .. simulation.maxWait[id]
                        )
                        assert(
                            simulation.runs[id] * 100 >= ideal[id] * (name == "D" and 70 or 85),
                            label
                                .. ": "
                                .. id
                                .. " ran "
                                .. simulation.runs[id]
                                .. " times, "
                                .. ideal[id]
                                .. " are possible"
                        )
                    end
                end
            end
        end
    end
end

-- A plain statement of the specification, used to check the library plan by plan.
local function reference(simulation, kind, now, used)
    local overhead = simulation.overhead[kind]
    local room = scheduler.CEILING - scheduler.MARGIN - overhead - used - scheduler.FIXED_COST
    local ready = { critical = {}, normal = {} }
    local smallest = math.huge
    for _, stub in pairs(simulation.stubs) do
        local decl = stub.spec.decl
        for _, stage in pairs(decl.stages) do
            smallest = math.min(smallest, stage.fixed + stage.perUnit)
        end
        if stub.dueAt <= now then
            table.insert(ready[decl.class], stub)
        end
    end
    smallest = smallest + CHARGE
    local function older(a, b)
        return a.dueAt < b.dueAt or (a.dueAt == b.dueAt and a.seq < b.seq)
    end
    table.sort(ready.critical, older)
    table.sort(ready.normal, older)
    local plan, spent, exclusive, charged = {}, 0, false, {}
    for _, pass in ipairs({
        { list = ready.critical, limit = room - scheduler.NORMAL_RESERVE },
        { list = ready.normal, limit = room },
    }) do
        for position = 1, #pass.list do
            if pass.limit - spent < smallest then
                break
            end
            spent = spent + scheduler.EXAMINE_COST
            local stub = pass.list[position]
            local decl = stub.spec.decl
            local kinds = decl.kinds or { steady = true, background = true }
            if kinds[kind] and not (exclusive and decl.exclusive) then
                local stage = stub.stage or decl.first or "run"
                local declared = decl.stages[stage]
                local fixed = declared.fixed
                for name, cost in pairs(decl.shared or {}) do
                    fixed = fixed + (charged[name] and 0 or cost)
                end
                local want = type(stub.want) == "number" and math.max(1, math.floor(stub.want)) or declared.maxUnits
                local fit = (pass.limit - spent - scheduler.RUN_COST - fixed) // declared.perUnit
                local grant = math.min(want, declared.maxUnits, fit)
                if grant >= 1 then
                    plan[#plan + 1] = { id = stub.id, stage = stage, grant = grant }
                    spent = spent + scheduler.RUN_COST + fixed + grant * declared.perUnit
                    exclusive = exclusive or decl.exclusive == true
                    for name in pairs(decl.shared or {}) do
                        charged[name] = true
                    end
                end
            end
        end
    end
    return plan
end

local SHARED = { link = 150, scan = 100 }

local function randomScenario(seed, start, measured)
    local random = sim.random(seed)
    local simulation = newSim({ steady = random(1000, 2000), background = random(800, 1500) }, start, measured)
    local names = { "a", "b", "c" }
    for index = 1, random(5, 40) do
        local stages = {}
        for position = 1, random(1, 3) do
            stages[names[position]] = {
                fixed = random(0, 3) * 100,
                perUnit = random(1, 40) * 50,
                maxUnits = random(1, 3) == 1 and random(2, 9) or 1,
            }
        end
        local decl = {
            class = random(1, 2) == 1 and "critical" or "normal",
            first = "a",
            stages = stages,
            exclusive = random(1, 6) == 1 or nil,
            kinds = random(1, 5) == 1 and { steady = true } or nil,
            shared = random(1, 4) == 1 and (random(1, 2) == 1 and { link = SHARED.link } or SHARED) or nil,
        }
        local stageNames = {}
        for name in pairs(stages) do
            stageNames[#stageNames + 1] = name
        end
        table.sort(stageNames)
        simulation:add({
            id = index,
            decl = decl,
            due = random(0, 50),
            stage = "a",
            delay = function()
                return random(1, 40)
            end,
            after = function(instance)
                instance.stage = stageNames[random(1, #stageNames)]
                local want = random(0, 12)
                instance.want = want > 10 and nil or want
            end,
        })
    end
    local schedule = sim.schedule(seed, 150, 1, 15)
    local used = { 0, 600, 1600, 3200 }
    for _, item in ipairs(schedule) do
        item.kind = random(1, 4) == 1 and "background" or "steady"
        item.used = used[random(1, 4)]
    end
    return simulation, schedule
end

local function testPlansMatchTheReferenceOnRandomTasks()
    for seed = 1, 80 do
        local simulation, schedule = randomScenario(seed, nil, seed <= 20)
        for _, item in ipairs(schedule) do
            local expected = reference(simulation, item.kind, item.now, item.used)
            local report = simulation:callback(item.kind, item.now, item.used)
            equal(#report.plan, #expected, "seed " .. seed .. " callback " .. report.index)
            local exclusive, previousClass, previousWait = 0, 1, math.huge
            for position, entry in ipairs(report.plan) do
                local want = expected[position]
                equal(entry.id, want.id, "seed " .. seed .. " callback " .. report.index .. " position " .. position)
                equal(entry.stage, want.stage)
                equal(entry.grant, want.grant)
                local decl = simulation.stubs[entry.id].spec.decl
                exclusive = exclusive + (decl.exclusive and 1 or 0)
                assert((decl.kinds or { steady = true, background = true })[item.kind], "task ran in a kind it refuses")
                assert(entry.grant >= 1 and entry.grant <= decl.stages[entry.stage].maxUnits)
                assert(entry.used <= entry.grant)
                -- Properties that do not mirror the planner: critical before normal, oldest first.
                local class = decl.class == "critical" and 1 or 2
                assert(class >= previousClass, "a critical task was planned after a normal one")
                if class ~= previousClass then
                    previousWait = math.huge
                end
                assert(entry.wait <= previousWait, "a younger task was planned before an older one")
                previousClass, previousWait = class, entry.wait
            end
            assert(exclusive <= 1, "two exclusive tasks in one callback")
            assert(report.U <= LIMIT, "plan " .. report.U .. " is above the limit")
            assert(report.actual <= report.U, "seed " .. seed .. ": a callback used more than it planned")
            if report.framework then
                assert(report.framework <= report.charged, "seed " .. seed .. ": the planner cost more than it charged")
            end
        end
        equal(simulation.overruns, 0)
    end
end

local function logOf(simulation)
    local lines = {}
    for _, report in ipairs(simulation.reports) do
        local parts = { report.kind, report.now, report.U }
        for _, entry in ipairs(report.plan) do
            parts[#parts + 1] = entry.id .. "/" .. entry.stage .. "/" .. entry.grant
        end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    return table.concat(lines, "\n")
end

local function testPlansAreDeterministic()
    for seed = 1, 10 do
        local first, second = randomScenario(seed), randomScenario(seed)
        local _, scheduleA = randomScenario(seed)
        first:run(scheduleA)
        local _, scheduleB = randomScenario(seed)
        second:run(scheduleB)
        equal(logOf(first), logOf(second), "seed " .. seed)
    end
end

-- Start points on the tick clock: small, above 2^15 and 2^20, either side of the
-- rebase at 2^29, and either side of the int32 wrap at 2^31.
local STARTS =
    { 0, 0x8000, 0x100000, 0x1FFFF830, 0x20000007, 0x40000005, 0x7FFFFE70, 0x7FFFFFF8, 0x7FFFFFFE, 0xFFFFEC78 }

-- Only differences of ticks matter: the same run from any start gives the same
-- plans, including across the wrap of the int32 clock and the epoch rebase.
local function testStartOffsetsAndClockWrapDoNotChangePlans()
    local expected
    for _, start in ipairs(STARTS) do
        local simulation = jitterRun(MIXES.D, 2, "R4", start, 800, false, true)
        local log = logOf(simulation)
        expected = expected or log
        equal(log, expected, string.format("mix D from tick %d", start))
    end
    for seed = 1, 6 do
        local first
        for _, start in ipairs(STARTS) do
            local simulation, schedule = randomScenario(seed, start)
            simulation:run(schedule)
            first = first or logOf(simulation)
            equal(logOf(simulation), first, string.format("seed %d from tick %d", seed, start))
        end
    end
end

-- Callbacks hours or days apart: the clock wraps and the epoch moves many times.
local function testLongGapsAndTheClockWrap()
    local steps = 1 << 28
    local library = scheduler.new({ steady = 0 })
    local runs = { fast = 0, medium = 0, slow = 0 }
    local function task(id, delay)
        return {
            step = function()
                runs[id] = runs[id] + 1
                return delay
            end,
        }
    end
    local decl = once("critical", 10)
    assert(library:add({ due = 0, id = "fast", decl = decl, instance = task("fast", 3) }))
    assert(library:add({ due = 0, id = "medium", decl = decl, instance = task("medium", steps) }))
    assert(library:add({ due = 0, id = "slow", decl = decl, instance = task("slow", scheduler.MAX_DELAY) }))
    for step = 0, 40 do
        library:run("steady", sim.wrap32(step * steps))
    end
    equal(runs.fast, 41, "ready at every callback")
    equal(runs.medium, 41, "released once per 2^28 ticks")
    equal(runs.slow, 11, "released once per 2^30 ticks, as often as the clock allows")
end

-- `step` receives the host's tick unchanged: across the int32 wrap, and from any
-- start. (Every stub elsewhere ignores `now`.)
local function testStepsReceiveTheHostTick()
    for _, start in ipairs({ 0, 5, 0x8000, 0x1FFFFFF0, 0x7FFFFFF0, 0xFFFFFFF0 }) do
        local library = scheduler.new({ steady = 0 })
        local seen = {}
        local decl = once("critical", 10)
        local first = sim.wrap32(start)
        assert(library:add({
            id = "a",
            decl = decl,
            due = first,
            instance = {
                step = function(_, _, _, now)
                    seen[#seen + 1] = now
                    return 7
                end,
            },
        }))
        local expected = {}
        for index = 0, 12 do
            local tick = sim.wrap32(start + index * 7)
            expected[#expected + 1] = tick
            library:run("steady", tick)
        end
        equal(table.concat(seen, ","), table.concat(expected, ","), "steps at start " .. start)
        equal(library:dueOf("a"), sim.wrap32(start + 12 * 7 + 7), "dueOf is a host tick")
    end
end

-- Wrap-safe differences, including the extremes of the window.
local function testElapsedIsWrapSafe()
    local elapsed = scheduler.elapsed
    equal(elapsed(10, 4), 6)
    equal(elapsed(4, 10), -6)
    equal(elapsed(sim.wrap32(0x80000003), sim.wrap32(0x7FFFFFFD)), 6, "across the wrap")
    equal(elapsed(sim.wrap32(0x7FFFFFFD), sim.wrap32(0x80000003)), -6)
    equal(elapsed(1 << 30, 0), 1 << 30)
    equal(elapsed(0, 1 << 30), -(1 << 30))
    equal(elapsed(0x7FFFFFFF, 0), 0x7FFFFFFF)
    equal(elapsed(0x80000000, 0), -0x80000000, "2^31 apart is the edge of the window")
end

local function testInputsAreValidated()
    local library = scheduler.new({ steady = 1000, background = 800 })
    local function instance()
        return {
            step = function()
                return 1
            end,
        }
    end
    local decl = once("normal", 100)
    local function rejected(task, text)
        local ok, reason = library:add(task)
        equal(ok, false, text)
        assert(type(reason) == "string" and reason ~= "", text .. " needs a reason")
    end
    rejected({ id = "a", decl = decl, instance = instance(), due = "5" }, "a string due")
    rejected({ id = "a", decl = decl, instance = instance(), due = 5.5 }, "a fractional due")
    rejected({ id = "a", decl = decl, instance = instance(), due = math.huge }, "an infinite due")
    rejected({ id = "a", decl = decl, instance = instance(), due = {} }, "a table due")
    assert(library:add({ id = "a", decl = decl, instance = instance(), due = 5.0 }))
    equal(math.type(library:dueOf("a")), "integer", "a whole float is stored as an integer")
    for _, bad in ipairs({ "5", 5.5, {}, false }) do
        equal(pcall(library.run, library, "steady", bad), false, "now " .. tostring(bad))
    end
    equal(pcall(library.run, library, "steady", 5.0), true)

    local delays = { ["a delay of 2^30"] = 1 << 30, ["a whole float"] = 5.0 }
    for text, delay in pairs(delays) do
        local fine = scheduler.new({ steady = 1000 })
        assert(fine:add({
            due = 0,
            id = "x",
            decl = decl,
            instance = {
                step = function()
                    return delay
                end,
            },
        }))
        fine:run("steady", 100)
        equal(fine.byId.x ~= nil, true, text)
        equal(math.type(fine:dueOf("x")), "integer", text)
    end
    local bads = { 1 << 30 | 1, 0, -3, "5", 2.5, math.huge, 0 / 0, true, {} }
    for _, delay in ipairs(bads) do
        local broken = scheduler.new({ steady = 1000 })
        assert(broken:add({
            due = 0,
            id = "x",
            decl = decl,
            instance = {
                step = function()
                    return delay
                end,
            },
        }))
        broken:run("steady", 100)
        equal(broken.byId.x, nil, "delay " .. tostring(delay) .. " retires the task")
        equal(#broken:takeErrors(), 1)
    end

    rejected(
        { id = "k1", decl = once("normal", 100, { kinds = { stedy = true } }), instance = instance() },
        "a misspelled kind"
    )
    rejected({ id = "k2", decl = once("normal", 100, { kinds = {} }), instance = instance() }, "an empty kinds set")
    rejected(
        { id = "k3", decl = once("normal", 100, { kinds = { steady = false } }), instance = instance() },
        "no allowed kind"
    )
    rejected(
        { id = "k4", decl = once("normal", 100, { kinds = { steady = "yes" } }), instance = instance() },
        "a non-boolean kind"
    )
    assert(library:add({
        due = 0,
        id = "k5",
        decl = once("normal", 100, { kinds = { steady = true, background = false } }),
        instance = instance(),
    }))
    -- The steady callback has 200 less room than the background one: it decides.
    local STEADY_ONLY = { kinds = { steady = true } }
    local room = scheduler.CEILING - scheduler.MARGIN - scheduler.FIXED_COST - 1000
    rejected(
        { id = "n1", decl = once("normal", room, STEADY_ONLY), instance = instance() },
        "a stage that cannot fit with the planner's charge"
    )
    assert(
        library:add({ due = 0, id = "n2", decl = once("normal", room - CHARGE, STEADY_ONLY), instance = instance() })
    )
    rejected(
        { id = "n3", decl = once("critical", room - CHARGE, STEADY_ONLY), instance = instance() },
        "a critical stage above the reserved room"
    )
    rejected({
        id = "n4",
        decl = once("normal", room - CHARGE, { kinds = { steady = true }, shared = { big = 1 } }),
        instance = instance(),
    }, "a shared cost that no longer fits")
    assert(library:add({
        due = 0,
        id = "n5",
        decl = once("normal", 100, { shared = { link = 560 } }),
        instance = instance(),
    }))
    rejected(
        { id = "n6", decl = once("normal", 100, { shared = { link = 561 } }), instance = instance() },
        "one shared name with two costs"
    )
    -- A kind the host does not have is not a reason to refuse the default kinds.
    assert(scheduler.new({ steady = 0 }):add({ due = 0, id = "only", decl = decl, instance = instance() }))
    equal(scheduler.new({ modal = 0 }):add({ due = 0, id = "none", decl = decl, instance = instance() }), false)

    equal(scheduler.stagger(3, 0), 0)
    equal(scheduler.stagger(3, -5), 0)
    equal(scheduler.stagger(3, 1), 0)
end

-- The planner bills a shared cost to the first task it plans; the first task that
-- really does the work pays it. The plan total is the same either way.
local function testSharedCostIsPaidByWhoeverRunsFirst()
    local link = once("critical", 1000, { shared = { link = 560 } })
    local plain = once("critical", 100)
    local variants = {
        baseline = {},
        removed = { removeFirst = true },
        raises = {
            fail = function()
                error("broken")
            end,
        },
        idle = {
            idle = function()
                return true
            end,
        },
    }
    for name, variant in pairs(variants) do
        local simulation = newSim({ steady = STEADY_OVERHEAD })
        simulation:add({ id = "x", decl = plain, due = 0, delay = 50 })
        simulation:add({
            id = "a",
            decl = link,
            due = 1,
            delay = 50,
            fail = variant.fail,
            idle = variant.idle,
        })
        simulation:add({ id = "b", decl = link, due = 2, delay = 50 })
        if variant.removeFirst then
            simulation.stubs.x.spec.after = function()
                simulation.library:remove("a")
            end
        end
        local report = simulation:callback("steady", 10)
        local planned = 100 + (1000 + 560) + 1000
        equal(
            report.U - STEADY_OVERHEAD - scheduler.FIXED_COST - 3 * CHARGE,
            planned,
            name .. ": the plan bills the cost once"
        )
        if name == "baseline" then
            equal(report.spent, planned)
            equal(report.actual, report.U)
        else
            equal(report.spent, 100 + 1000 + 560, name .. ": the second task pays it")
            equal(report.U - report.actual, 1000, name .. ": the plan over-charged the task that did not run")
        end
        assert(report.actual <= report.U)
    end
end

local function testFirstReadyTaskRunsUnderConstantOverload()
    local simulation = sim.new(scheduler, { steady = STEADY_OVERHEAD })
    for index = 1, 60 do
        simulation:add({
            due = 0,
            id = index,
            decl = once(index % 2 == 0 and "critical" or "normal", 300 + index * 20),
            delay = 1,
        })
    end
    local first = {}
    for now = 10, 400, 10 do
        local ready = {}
        for _, stub in pairs(simulation.stubs) do
            ready[#ready + 1] = stub
        end
        table.sort(ready, function(a, b)
            local x, y = a.spec.decl.class == "critical", b.spec.decl.class == "critical"
            if x ~= y then
                return x
            end
            return a.dueAt < b.dueAt or (a.dueAt == b.dueAt and a.seq < b.seq)
        end)
        local report = simulation:callback("steady", now, 0)
        equal(report.plan[1].id, ready[1].id, "the oldest ready critical task always runs first")
        first[ready[1].id] = true
    end
    local count = 0
    for _ in pairs(first) do
        count = count + 1
    end
    assert(count > 5, "the front of the line moves on")
end

local function testNoStackingAfterLongSkips()
    local simulation = sim.new(scheduler, { steady = STEADY_OVERHEAD })
    for index = 1, 30 do
        simulation:add({ due = 0, id = index, decl = once(index % 3 == 0 and "critical" or "normal", 200), delay = 5 })
    end
    for now = 1000, 20000, 1000 do
        local report = simulation:callback("steady", now, 0)
        local seen = {}
        for _, entry in ipairs(report.plan) do
            assert(not seen[entry.id])
            seen[entry.id] = true
        end
    end
    local listed = #simulation.library.lists[1] + #simulation.library.lists[2]
    equal(listed, 30, "each task is listed once")
    for id, stub in pairs(simulation.stubs) do
        equal(simulation.library.byId[id].due, stub.dueAt, "the library holds one release per task")
    end
end

local function testExclusiveChartsAndKinds()
    local simulation = sim.new(scheduler, { steady = STEADY_OVERHEAD, background = 1130 })
    for index = 1, 4 do
        simulation:add({
            id = "chart" .. index,
            decl = CHART,
            stage = "begin",
            delay = 1,
            due = index,
            after = function(instance, stage)
                instance.stage = NEXT_CHART_STAGE[stage]
            end,
        })
    end
    simulation:add({ due = 0, id = "service", decl = RECORDED, delay = 10 })
    local ran = {}
    for now = 10, 3000, 10 do
        local report = simulation:callback(now % 100 == 0 and "background" or "steady", now, 0)
        local charts = 0
        for _, entry in ipairs(report.plan) do
            if string.sub(entry.id, 1, 5) == "chart" then
                charts = charts + 1
                assert(report.kind == "steady", "a steady-only chart ran in a background callback")
                ran[entry.id] = (ran[entry.id] or 0) + 1
            end
        end
        assert(charts <= 1, "one exclusive task per callback")
    end
    for index = 1, 4 do
        assert(ran["chart" .. index] > 50, "every chart gets turns")
    end
end

local function testFailingTasksRetireAlone()
    local simulation = sim.new(scheduler, { steady = STEADY_OVERHEAD })
    addMix(simulation, MIXES.A)
    simulation:add({
        due = 0,
        id = "raises",
        decl = PANEL,
        delay = 5,
        fail = function()
            error("broken task")
        end,
    })
    simulation:add({ due = 0, id = "bad delay", decl = PANEL, delay = 0 })
    simulation:add({ due = 0, id = "bad stage", decl = PANEL, delay = 5, stage = "nowhere" })
    local before = simulation.library.count
    for now = 10, 1000, 10 do
        simulation:callback("steady", now, 0)
    end
    equal(simulation.library.count, before - 3)
    local errors = simulation.library:takeErrors()
    equal(#errors, 3)
    for index = 1, #releases(MIXES.A) do
        assert(simulation.runs["critical" .. index] >= 20, "critical" .. index .. " kept running")
    end
    equal(simulation.overruns, 0)
end

local function testThePlannedStageIsWhatTheStepReceives()
    local seen = {}
    local library = scheduler.new({ steady = 1000 })
    local decl = {
        class = "normal",
        first = "begin",
        stages = {
            begin = { fixed = 0, perUnit = 100, maxUnits = 1 },
            apply = { fixed = 0, perUnit = 100, maxUnits = 1 },
        },
    }
    local chart = { stage = "begin" }
    function chart.step(instance, grant, stage)
        seen[#seen + 1] = stage .. "/" .. instance.stage
        if instance.stage ~= stage then
            return 1
        end
        return 10
    end
    local reset = {}
    function reset.step()
        chart.stage = "apply"
        return 10
    end
    assert(library:add({ id = "reset", decl = once("critical", 100), instance = reset, due = 0 }))
    assert(library:add({ id = "chart", decl = decl, instance = chart, due = 0 }))
    library:run("steady", 1)
    equal(seen[1], "begin/apply", "a state change after planning is seen by the step, which does no work")
    equal(library:dueOf("chart"), 2, "and asks to be released again")
end

local function testFaultInjectionNeverReachesTheFirmwareLimit()
    local function overloaded(seed)
        local random = sim.random(seed)
        local simulation = sim.new(scheduler, { steady = STEADY_OVERHEAD, background = 1130 })
        addMix(simulation, MIXES.D)
        addNormalWork(simulation)
        for index = 1, 20 do
            simulation:add({
                due = 0,
                id = "filler" .. index,
                decl = { class = "normal", stages = { run = { fixed = 100, perUnit = 400, maxUnits = 12 } } },
                delay = 1,
            })
        end
        local headroom = sim.FIRMWARE_LIMIT - scheduler.CEILING
        local steps = {}
        simulation.faults = function(index, id, stage, grant)
            local cost = sim.bound(simulation.stubs[id].spec.decl, stage, grant)
            local extra = index > 200 and cost // 4 or 0
            if index % 37 == 0 then
                extra = extra + headroom
            end
            steps[index] = (steps[index] or 0) + extra
            return math.min(extra, headroom - (steps[index] - extra))
        end
        simulation.burst = function(index, report)
            return index % 53 == 0 and headroom - report.excess or 0
        end
        local schedule = sim.schedule(seed, 1500, 3, 15)
        for _, item in ipairs(schedule) do
            item.used = random(0, 2) * RESET_POLL
        end
        simulation:run(schedule)
        return simulation
    end
    for seed = 1, 5 do
        local simulation = overloaded(seed)
        local topPlan = 0
        for _, report in ipairs(simulation.reports) do
            topPlan = math.max(topPlan, report.U)
        end
        -- The limit check is arithmetic (a plan is at most the limit and the excess
        -- at most what is left of 20000); what the run shows is that plans really
        -- fill the budget, so the excess is injected on top of full callbacks.
        assert(topPlan >= LIMIT - 1500, "plans reached only " .. topPlan)
        assert(simulation.maxActual >= sim.FIRMWARE_LIMIT - 1000, "the faults really pushed the callbacks")
        assert(simulation.maxActual < sim.FIRMWARE_LIMIT, "a callback reached " .. simulation.maxActual)
        equal(simulation.overruns, 0)
    end
    local simulation = overloaded(1)
    local unbounded = sim.new(scheduler, { steady = STEADY_OVERHEAD })
    unbounded:add({ due = 0, id = "x", decl = RECORDED, delay = 1 })
    unbounded.burst = function()
        return sim.FIRMWARE_LIMIT
    end
    unbounded:callback("steady", 10, 0)
    equal(unbounded.overruns, 1, "the simulator does report an overrun")
    equal(simulation.overruns, 0)
end

local function testAnOverloadBurstDrainsWithoutDroppingCriticalWork()
    local simulation = sim.new(scheduler, { steady = STEADY_OVERHEAD })
    addMix(simulation, MIXES.A)
    for index = 1, 100 do
        simulation:add({ id = "burst" .. index, decl = once("critical", 900), due = 1000, delay = 1000 })
    end
    for now = 5, 5000, 5 do
        local report = simulation:callback("steady", now, RESET_POLL)
        assert(report.U <= LIMIT)
    end
    for index = 1, 100 do
        assert(simulation.runs["burst" .. index] >= 4, "burst" .. index .. " was dropped")
    end
    for index = 1, #releases(MIXES.A) do
        assert(simulation.runs["critical" .. index] >= 5000 // 100, "critical" .. index .. " starved")
    end
end

testAdmissionReproducesTheRecomputedTables()
testAdmissionRejectsOverloads()
testAMixedRunUnderJitter()
testPlansMatchTheReferenceOnRandomTasks()
testPlansAreDeterministic()
testStartOffsetsAndClockWrapDoNotChangePlans()
testLongGapsAndTheClockWrap()
testStepsReceiveTheHostTick()
testElapsedIsWrapSafe()
testInputsAreValidated()
testSharedCostIsPaidByWhoeverRunsFirst()
testLargestPieceAgainstTheMaximumTaskSize()
testFirstReadyTaskRunsUnderConstantOverload()
testNoStackingAfterLongSkips()
testExclusiveChartsAndKinds()
testFailingTasksRetireAlone()
testThePlannedStageIsWhatTheStepReceives()
testFaultInjectionNeverReachesTheFirmwareLimit()
testAnOverloadBurstDrainsWithoutDroppingCriticalWork()

print("Scheduler simulation passed")
