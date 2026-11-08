-- SPDX-License-Identifier: GPL-2.0-only

--- Measures the framework's own cost and checks it against what the planner
--- charges (plans/scheduler-framework.md, sections 4 and 6).
---
--- `overhead.measure(scheduler, count, pause, mixes)` runs `scheduler:run` in
--- scenarios built from stub tasks that only return a delay and records, for
--- each, the instructions it really took and the amount the planner charged
--- (`lastPlan.charged`). `count()` is an exact instruction counter (the native
--- harness, or `overhead.hookCounter()` offline) and `pause(flag)` excludes
--- bookkeeping from the count. `mixes` is the optional scheduler_mixes module.

local overhead = {}

overhead.TASK_COUNTS = { 8, 32, 128 }
overhead.RUN_COUNTS = { 1, 4, 16, 128 }
overhead.MIX_BATCHES = { 1, 2 }
overhead.MIX_CALLBACKS = 400
overhead.FUZZ_SEEDS = 12
overhead.FUZZ_CALLBACKS = 60

--- An offline exact counter: every Lua instruction increments it. The hook is
--- installed only while counting (`pause(false)`) and removed again by
--- `pause(true)`, so code between measurement windows runs at full speed.
function overhead.hookCounter()
    local counter = 0
    local function hook()
        counter = counter + 1
    end
    return function()
        return counter
    end, function(flag)
        if flag then
            debug.sethook()
        else
            debug.sethook(hook, "", 1)
        end
    end
end

local function declaration(class, perUnit, extra)
    local decl = { class = class, stages = { run = { fixed = 0, perUnit = perUnit, maxUnits = 1 } } }
    for key, value in pairs(extra or {}) do
        decl[key] = value
    end
    return decl
end

local function stub(delay)
    return {
        step = function()
            return delay
        end,
    }
end

-- Registers `count` stubs. The first `ready` are due now, the others much later.
local function fill(s, count, make, ready)
    for index = 1, count do
        local decl, instance = make(index)
        assert(s:add({ id = index, decl = decl, instance = instance, due = index <= ready and 0 or 1000 + index }))
    end
    return s
end

-- A tiny far-off task keeps `minStep` small, so a scan is never cut short by
-- the stop rule and every ready task is really examined.
local function withTiny(s)
    assert(s:add({ id = "tiny", decl = declaration("normal", 1), instance = stub(1), due = 1000000000 }))
    return s
end

-- The `used` that leaves room for `n` examinations and the stop rule, and no more.
local function crowded(scheduler, n)
    local charge = scheduler.EXAMINE_COST + scheduler.RUN_COST
    return scheduler.CEILING - scheduler.MARGIN - scheduler.FIXED_COST - n * scheduler.EXAMINE_COST - 2 * charge
end

-- Each scenario builds a scheduler and names the callback kind and `used`.
local function scenarios(scheduler, n)
    local list = {}
    -- Leave room for two shared costs even with candidate framework estimates.
    local BIG = scheduler.CEILING - scheduler.MARGIN - scheduler.FIXED_COST
        - scheduler.EXAMINE_COST - scheduler.RUN_COST - 200
    assert(BIG > 0, "framework reservation leaves no room for an audit task")
    local function add(name, build)
        list[#list + 1] = { name = name, build = build }
    end
    local function new()
        return scheduler.new({ steady = 0, background = 0 })
    end
    local function classOf(index)
        return index % 2 == 1 and "critical" or "normal"
    end
    add("idle", function()
        return fill(new(), n, function(index)
            return declaration(classOf(index), 10), stub(1)
        end, 0),
            "steady",
            0
    end)
    for _, k in ipairs(overhead.RUN_COUNTS) do
        if k <= n then
            for _, delay in ipairs({ 100000, 1, 1000 + n // 2 }) do
                add("run " .. k .. ", delay " .. delay, function()
                    return fill(new(), n, function(index)
                        return declaration(classOf(index), 10), stub(delay)
                    end, k),
                        "steady",
                        0
                end)
            end
            add("shared run " .. k .. ", two distinct names each", function()
                return fill(new(), n, function(index)
                    local shared = { ["a" .. index] = 10, ["b" .. index] = 10 }
                    return declaration(classOf(index), 10, { shared = shared }), stub(100000)
                end, k),
                    "steady",
                    0
            end)
        end
    end
    add("none fits", function()
        return withTiny(fill(new(), n - 1, function()
            return declaration("normal", BIG), stub(1)
        end, n)),
            "steady",
            crowded(scheduler, n)
    end)
    add("none fits, wrong kind", function()
        return withTiny(fill(new(), n - 1, function()
            return declaration("normal", 10, { kinds = { steady = true } }), stub(1)
        end, n)),
            "background",
            0
    end)
    add("exclusive after the first", function()
        return withTiny(fill(new(), n - 1, function()
            return declaration("normal", 10, { exclusive = true }), stub(100000)
        end, n)),
            "steady",
            0
    end)
    add("all skipped, the last one runs", function()
        return withTiny(fill(new(), n - 1, function(index)
            return declaration("normal", index < n - 1 and BIG or 10), stub(100000)
        end, n)),
            "steady",
            crowded(scheduler, n)
    end)
    for names = 1, 2 do
        local each = 12000 // names
        add("skipped for shared cost, " .. names .. " name(s) each", function()
            return withTiny(fill(new(), n - 1, function(index)
                local shared = {}
                for position = 1, names do
                    shared["n" .. index .. "-" .. position] = each
                end
                return declaration("normal", 10, { shared = shared }), stub(1)
            end, n)),
                "steady",
                crowded(scheduler, n)
        end)
        add("skipped for shared cost, the last one runs, " .. names .. " name(s)", function()
            return withTiny(fill(new(), n - 1, function(index)
                if index == n - 1 then
                    return declaration("normal", 10), stub(100000)
                end
                local shared = {}
                for position = 1, names do
                    shared["n" .. index .. "-" .. position] = each
                end
                return declaration("normal", 10, { shared = shared }), stub(1)
            end, n)),
                "steady",
                crowded(scheduler, n)
        end)
        add("skipped for size with shared costs, " .. names .. " name(s)", function()
            return withTiny(fill(new(), n - 1, function(index)
                local shared = {}
                for position = 1, names do
                    shared["m" .. index .. "-" .. position] = 100
                end
                return declaration("normal", BIG, { shared = shared }), stub(1)
            end, n)),
                "steady",
                crowded(scheduler, n)
        end)
    end
    add("rounded stages skipped for shared cost, last one runs", function()
        return withTiny(fill(new(), n - 1, function(index)
            if index == n - 1 then
                return declaration("normal", 10), stub(100000)
            end
            local decl = declaration("normal", 10, { shared = {
                ["rounded-a" .. index] = 6000, ["rounded-b" .. index] = 6000,
            } })
            decl.stages.run.quantum = 500
            return decl, stub(1)
        end, n)),
            "steady",
            crowded(scheduler, n)
    end)
    add("stages, shared costs and want", function()
        local stages = {
            run = { fixed = 100, perUnit = 40, maxUnits = 9 },
            second = { fixed = 0, perUnit = 60, maxUnits = 1 },
            third = { fixed = 50, perUnit = 20, maxUnits = 4 },
        }
        return fill(new(), n, function(index)
            local decl = {
                class = classOf(index),
                first = "run",
                stages = stages,
                shared = { link = 100, cache = 50 },
                exclusive = index % 5 == 0 or nil,
            }
            local instance = stub(100000 + index)
            instance.stage = index % 3 == 0 and "second" or index % 3 == 1 and "third" or nil
            instance.want = index % 4 + 1
            return decl, instance
        end, n),
            "steady",
            0
    end)
    add("failing steps", function()
        return fill(new(), n, function(index)
            local instance = stub(100000)
            local kind = index % 3
            if kind == 0 then
                function instance.step()
                    error("failure")
                end
            elseif kind == 1 then
                instance.step = function()
                    return 0
                end
            end
            return declaration(classOf(index), 10), instance
        end, n),
            "steady",
            0
    end)
    add("all retired (unknown stage)", function()
        return fill(new(), n, function(index)
            local instance = stub(100000)
            instance.stage = "missing"
            return declaration(classOf(index), 10), instance
        end, n),
            "steady",
            0
    end)
    add("unknown stage", function()
        return fill(new(), n, function(index)
            local instance = stub(100000)
            instance.stage = index % 2 == 0 and "missing" or nil
            return declaration(classOf(index), 10), instance
        end, n),
            "steady",
            0
    end)
    return list
end

local function window(count, pause, fn, a, b, c, d)
    pause(false)
    local first = count()
    fn(a, b, c, d)
    local last = count()
    pause(true)
    return last - first
end

-- A mix: its critical releases as periodic stubs, a staged chart and four
-- panels.
local function installMix(scheduler, mixes, mix, batch)
    local s = scheduler.new({ steady = 1750, background = 1130 })
    for index, release in ipairs(mixes.releases(mix, batch)) do
        assert(s:add({
            id = "critical" .. index,
            decl = release.decl,
            instance = stub(release.interval),
            due = scheduler.stagger(index - 1, release.interval),
        }))
    end
    local chart = { stage = "begin" }
    function chart.step(instance)
        instance.stage = mixes.NEXT_CHART_STAGE[instance.stage]
        return 1
    end
    assert(s:add({ due = 0, id = "chart", decl = mixes.CHART, instance = chart }))
    for index = 1, 4 do
        assert(s:add({ id = "panel" .. index, decl = mixes.PANEL, instance = stub(20), due = index }))
    end
    return s
end

local function row(name, s, measured)
    local plan = s.lastPlan
    return {
        name = name,
        tasks = s.count,
        measured = measured,
        charged = plan.charged,
        examined = plan.examined,
        ran = plan.ran,
        slack = plan.charged - measured,
    }
end

-- An over-charged callback always wins; otherwise a callback that ran tasks
-- beats an idle one.
local function rank(item)
    if item.slack < 0 then
        return item.slack - 1000000000
    end
    return item.ran > 0 and item.slack or item.slack + 1000000
end

local function keepLeast(least, item)
    item.rank = rank(item)
    if least == nil or item.rank < least.rank then
        return item
    end
    return least
end

local function random(seed)
    local state = seed * 7919 + 13
    return function(low, high)
        state = (state * 1103515245 + 12345) & 0x7fffffff
        return low + (state >> 8) % (high - low + 1)
    end
end

local function mixRow(scheduler, mixes, count, pause, K, name, mix, batch)
    local s = installMix(scheduler, mixes, mix, batch)
    local least
    local next, now = random(7), 0
    for _ = 1, overhead.MIX_CALLBACKS do
        now = now + next(3, 15)
        local measured = window(count, pause, s.run, s, "steady", now) - K
        least = keepLeast(least, row(name, s, measured))
    end
    return least
end

-- Random task sets with shared names, kinds, exclusive tasks, wants, stages and
-- failing steps, run at random callbacks: the callback with the least slack.
local function fuzzRow(scheduler, count, pause, K, seed)
    local next = random(seed)
    local s = scheduler.new({ steady = next(0, 2000), background = next(0, 2000) })
    local shared = { link = 560, scan = 150, cache = 300, big = 3000, huge = 9000, tiny = 20 }
    local names = { "link", "scan", "cache", "big", "huge", "tiny" }
    for id = 1, next(8, 128) do
        local stages = {}
        local stageCount = next(1, 3)
        for position = 1, stageCount do
            stages["s" .. position] = { fixed = next(0, 6) * 100, perUnit = next(1, 60) * 50, maxUnits = next(1, 8) }
        end
        local decl = {
            class = next(1, 2) == 1 and "critical" or "normal",
            first = "s1",
            stages = stages,
            exclusive = next(1, 5) == 1 or nil,
            kinds = next(1, 4) == 1 and { steady = true } or nil,
        }
        local howMany = next(0, 2)
        if howMany > 0 then
            decl.shared = {}
            for _ = 1, howMany do
                local name = names[next(1, #names)]
                decl.shared[name] = shared[name]
            end
        end
        local instance = { stage = next(1, 12) == 1 and "missing" or "s" .. next(1, stageCount), want = next(0, 10) }
        local behaviour = next(1, 14)
        function instance.step()
            if behaviour == 1 then
                error("failure")
            elseif behaviour == 2 then
                return 0
            end
            return next(1, 60)
        end
        s:add({ id = id, decl = decl, instance = instance, due = next(0, 40) })
    end
    local least
    local now = 0
    for _ = 1, overhead.FUZZ_CALLBACKS do
        now = now + next(3, 15)
        local kind = next(1, 3) == 1 and "background" or "steady"
        local measured = window(count, pause, s.run, s, kind, now, next(0, 9000)) - K
        least = keepLeast(least, row("fuzz seed " .. seed, s, measured))
    end
    return least
end

--- Returns `{ K, rows, heap }`. A row is `{ name, tasks, measured, charged,
--- examined, ran, slack }`; for a mix or a fuzz seed it is the callback that ran
--- tasks with the least slack (an over-charged callback always wins).
function overhead.measure(scheduler, count, pause, mixes)
    pause = pause or function() end
    pause(true)
    local noop = function() end
    local K = window(count, pause, noop, nil, nil, nil, nil)
    local rows = {}
    for _, n in ipairs(overhead.TASK_COUNTS) do
        for _, scenario in ipairs(scenarios(scheduler, n)) do
            local s, kind, used = scenario.build()
            local measured = window(count, pause, s.run, s, kind, 0, used) - K
            rows[#rows + 1] = row(scenario.name .. " (" .. n .. " tasks)", s, measured)
        end
    end
    if mixes then
        for _, name in ipairs({ "A", "B", "C", "D" }) do
            for _, batch in ipairs(overhead.MIX_BATCHES) do
                local label = "mix " .. name .. ", " .. batch .. " per task"
                rows[#rows + 1] = mixRow(scheduler, mixes, count, pause, K, label, mixes.MIXES[name], batch)
            end
        end
    end
    for seed = 1, overhead.FUZZ_SEEDS do
        rows[#rows + 1] = fuzzRow(scheduler, count, pause, K, seed)
    end
    local instances = {}
    for index = 1, scheduler.MAX_TASKS do
        instances[index] = stub(1)
    end
    local decl = declaration("normal", 10)
    local s = scheduler.new({ steady = 0 })
    collectgarbage()
    local before = collectgarbage("count")
    for index = 1, scheduler.MAX_TASKS do
        s:add({ due = 0, id = index, decl = decl, instance = instances[index] })
    end
    collectgarbage()
    return { K = K, rows = rows, heap = { tasks = scheduler.MAX_TASKS, kib = collectgarbage("count") - before } }
end

function overhead.measurePaths(scheduler, count, pause, paths)
    local K = window(count, pause, function() end, nil, nil, nil, nil)
    local rows = {}
    paths(scheduler, function(s, used, examined, ran)
        local measured = window(count, pause, s.run, s, "steady", 0, used) - K
        rows[#rows + 1] = row("rounded path " .. examined .. ":" .. ran, s, measured)
    end)
    return rows
end

--- The check that replaces a fixed go/no-go figure: every measured callback
--- took no more than the planner charged for it. It also reports what the
--- measurements show per part: `fixed` (an idle callback), `examine` (per task
--- examined, from scenarios that run nothing), `perRun` (per task examined and
--- run, from scenarios where every examined task runs), the least slack and the
--- least headroom (charged / measured).
function overhead.verdict(results)
    local verdict =
        { ok = true, failures = {}, fixed = 0, examine = 0, perRun = 0, slack = math.huge, headroom = math.huge }
    for _, item in ipairs(results.rows) do
        if string.find(item.name, "^idle") then
            verdict.fixed = math.max(verdict.fixed, item.measured)
        end
    end
    for _, item in ipairs(results.rows) do
        if item.measured > item.charged then
            verdict.ok = false
            verdict.failures[#verdict.failures + 1] = item
        end
        if item.measured > 0 and item.charged / item.measured < verdict.headroom then
            verdict.headroom, verdict.tightestRatio = item.charged / item.measured, item
        end
        if item.slack < verdict.slack then
            verdict.slack, verdict.tightest = item.slack, item
        end
        if item.ran == 0 and item.examined > 0 then
            verdict.examine = math.max(verdict.examine, (item.measured - verdict.fixed) / item.examined)
        elseif string.find(item.name, "^run ") then
            verdict.perRun = math.max(verdict.perRun, (item.measured - verdict.fixed) / item.ran)
        end
    end
    return verdict
end

return overhead
