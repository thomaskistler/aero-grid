-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local sim = assert(loadfile(root .. "/tests/support/scheduler_sim.lua"))()
local admission = assert(loadfile(root .. "/tests/support/scheduler_admission.lua"))()
local mixes = assert(loadfile(root .. "/tests/support/scheduler_mixes.lua"))()
local equal = assertions.assertEqual

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
        A = { peak = 5722, sustained = 4388, T = 5908, TS = 3308, R4 = 6908 },
        B = { peak = 4334, sustained = 2401, T = 7296, TS = 4696, R4 = 8296 },
        C = { peak = 4694, sustained = 4076, T = 6936, TS = 4336, R4 = 7936 },
        D = { peak = 8498, sustained = 7684, T = 3132, TS = 532, R4 = 4132 },
    },
    [2] = {
        A = { peak = 5514, sustained = 4113, T = 6116, TS = 3516, R4 = 7116 },
        B = { peak = 5514, sustained = 2264, T = 6116, TS = 3516, R4 = 7116 },
        C = { peak = 5514, sustained = 3893, T = 6116, TS = 3516, R4 = 7116 },
        D = { peak = 8082, sustained = 7268, T = 3548, TS = 948, R4 = 4548 },
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
    local text = failed({ legacy = 6650, legacyBounds = { telemetry = 10190 }, releases = {} })
    assert(string.find(text, "D:", 1, true))
    -- A two-sensor batch is a worthwhile task, a single 1180-instruction one is not.
    local small =
        admission.check({ scheduler = scheduler, overhead = STEADY_OVERHEAD, releases = releases(MIXES.A, 1) })
    assert(#small.small > 0, "single sensors are below the minimum piece")
    equal(admission.minimumPiece(scheduler), 1600)
end

local function testAMixedRunUnderJitter()
    for _, batch in ipairs({ 1, 2 }) do
        for name, mix in pairs(MIXES) do
            local simulation = sim.new(scheduler, { steady = STEADY_OVERHEAD, background = 1130 })
            addMix(simulation, mix, batch)
            addNormalWork(simulation)
            local schedule = sim.schedule(11, 3000, 3, 15)
            for _, item in ipairs(schedule) do
                item.used = RESET_POLL
            end
            simulation:run(schedule)
            local runs = {}
            for _, report in ipairs(simulation.reports) do
                assert(report.U <= LIMIT, "mix " .. name .. " planned " .. report.U)
                equal(report.actual, report.U, "stubs cost exactly their bound")
                assert(#report.plan <= scheduler.MAX_TASKS)
                local ids = {}
                for _, entry in ipairs(report.plan) do
                    assert(not ids[entry.id], "a task ran twice in one callback")
                    ids[entry.id] = true
                    assert(entry.used <= entry.grant)
                end
            end
            equal(simulation.overruns, 0)
            for id, wait in pairs(simulation.maxWait) do
                if string.sub(id, 1, 8) == "critical" then
                    assert(wait <= 2 * 15, "mix " .. name .. ": " .. id .. " waited " .. wait .. " ticks")
                end
            end
            for index, release in ipairs(releases(mix, batch)) do
                runs[index] = simulation.runs["critical" .. index]
                local expected = 3000 * 9 // (release.interval + 2 * 15)
                assert(
                    runs[index] >= expected,
                    "mix " .. name .. ": critical" .. index .. " ran " .. runs[index] .. " times"
                )
            end
            assert(simulation.runs.chart > 0 and simulation.runs.panel1 > 0, "normal work still runs")
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

local function randomScenario(seed)
    local random = sim.random(seed)
    local simulation = sim.new(scheduler, { steady = random(1000, 2000), background = random(800, 1500) })
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
            shared = random(1, 6) == 1 and { link = random(1, 6) * 50 } or nil,
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
        local simulation, schedule = randomScenario(seed)
        for _, item in ipairs(schedule) do
            local expected = reference(simulation, item.kind, item.now, item.used)
            local report = simulation:callback(item.kind, item.now, item.used)
            equal(#report.plan, #expected, "seed " .. seed .. " callback " .. report.index)
            local exclusive = 0
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
            end
            assert(exclusive <= 1, "two exclusive tasks in one callback")
            assert(report.U <= LIMIT, "plan " .. report.U .. " is above the limit")
            equal(report.actual, report.U)
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

local function testFirstReadyTaskRunsUnderConstantOverload()
    local simulation = sim.new(scheduler, { steady = STEADY_OVERHEAD })
    for index = 1, 60 do
        simulation:add({
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
        simulation:add({ id = index, decl = once(index % 3 == 0 and "critical" or "normal", 200), delay = 5 })
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
    simulation:add({ id = "service", decl = RECORDED, delay = 10 })
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
        id = "raises",
        decl = PANEL,
        delay = 5,
        fail = function()
            error("broken task")
        end,
    })
    simulation:add({ id = "bad delay", decl = PANEL, delay = 0 })
    simulation:add({ id = "bad stage", decl = PANEL, delay = 5, stage = "nowhere" })
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
    equal(library.byId.chart.due, 2, "and asks to be released again")
end

local function testFaultInjectionNeverReachesTheFirmwareLimit()
    local function overloaded(seed)
        local random = sim.random(seed)
        local simulation = sim.new(scheduler, { steady = STEADY_OVERHEAD, background = 1130 })
        addMix(simulation, MIXES.D)
        addNormalWork(simulation)
        for index = 1, 20 do
            simulation:add({
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
        assert(simulation.maxActual >= sim.FIRMWARE_LIMIT - 1000, "the faults really pushed the callbacks")
        assert(simulation.maxActual < sim.FIRMWARE_LIMIT, "a callback reached " .. simulation.maxActual)
        equal(simulation.overruns, 0)
    end
    local simulation = overloaded(1)
    local unbounded = sim.new(scheduler, { steady = STEADY_OVERHEAD })
    unbounded:add({ id = "x", decl = RECORDED, delay = 1 })
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
testFirstReadyTaskRunsUnderConstantOverload()
testNoStackingAfterLongSkips()
testExclusiveChartsAndKinds()
testFailingTasksRetireAlone()
testThePlannedStageIsWhatTheStepReceives()
testFaultInjectionNeverReachesTheFirmwareLimit()
testAnOverloadBurstDrainsWithoutDroppingCriticalWork()

print("Scheduler simulation passed")
