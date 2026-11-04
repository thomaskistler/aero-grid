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

--- An offline exact counter: every Lua instruction increments it.
function overhead.hookCounter()
    local counter, paused = 0, false
    debug.sethook(function()
        if not paused then
            counter = counter + 1
        end
    end, "", 1)
    return function()
        return counter
    end, function(flag)
        paused = flag
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
    assert(s:add({ id = "tiny", decl = declaration("normal", 1), instance = stub(1), due = 10 ^ 9 }))
    return s
end

local HUGE = 1000000

-- Each scenario builds a scheduler and names the callback kind to run.
local function scenarios(scheduler, n)
    local list = {}
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
            "steady"
    end)
    for _, k in ipairs(overhead.RUN_COUNTS) do
        if k <= n then
            for _, delay in ipairs({ 100000, 1, 1000 + n // 2 }) do
                add("run " .. k .. ", delay " .. delay, function()
                    return fill(new(), n, function(index)
                        return declaration(classOf(index), 10), stub(delay)
                    end, k),
                        "steady"
                end)
            end
        end
    end
    add("none fits", function()
        return withTiny(fill(new(), n - 1, function(index)
            return declaration(classOf(index), HUGE), stub(1)
        end, n)),
            "steady"
    end)
    add("none fits, wrong kind", function()
        return withTiny(fill(new(), n - 1, function()
            return declaration("normal", 10, { kinds = { steady = true } }), stub(1)
        end, n)),
            "background"
    end)
    add("exclusive after the first", function()
        return withTiny(fill(new(), n - 1, function()
            return declaration("normal", 10, { exclusive = true }), stub(100000)
        end, n)),
            "steady"
    end)
    add("all skipped, the last one runs", function()
        return withTiny(fill(new(), n - 1, function(index)
            return declaration("normal", index < n - 1 and HUGE or 10), stub(100000)
        end, n)),
            "steady"
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
            "steady"
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
            "steady"
    end)
    add("unknown stage", function()
        return fill(new(), n, function(index)
            local instance = stub(100000)
            instance.stage = index % 2 == 0 and "missing" or nil
            return declaration(classOf(index), 10), instance
        end, n),
            "steady"
    end)
    return list
end

local function window(count, pause, fn, a, b, c)
    pause(false)
    local first = count()
    fn(a, b, c)
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
    assert(s:add({ id = "chart", decl = mixes.CHART, instance = chart }))
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

local function mixRow(scheduler, mixes, count, pause, K, name, mix, batch)
    local s = installMix(scheduler, mixes, mix, batch)
    local least
    local state, now = 7, 0
    for _ = 1, overhead.MIX_CALLBACKS do
        state = (state * 1103515245 + 12345) & 0x7fffffff
        now = now + 3 + (state >> 8) % 13
        local measured = window(count, pause, s.run, s, "steady", now) - K
        local this = row(name, s, measured)
        -- A callback that ran something is the interesting one, unless a
        -- callback went over its charge, which always wins.
        local rank = this.ran > 0 and this.slack or this.slack + 1000000
        if least == nil or rank < least.rank then
            least = this
            least.rank = rank
        end
    end
    return least
end

--- Returns `{ K, rows, heap }`. A row is `{ name, tasks, measured, charged,
--- examined, ran, slack }`; for a mix it is the callback that ran tasks with the
--- least slack (an over-charged callback always wins).
function overhead.measure(scheduler, count, pause, mixes)
    pause = pause or function() end
    pause(true)
    local noop = function() end
    local K = window(count, pause, noop, nil, nil, nil)
    local rows = {}
    for _, n in ipairs(overhead.TASK_COUNTS) do
        for _, scenario in ipairs(scenarios(scheduler, n)) do
            local s, kind = scenario.build()
            local measured = window(count, pause, s.run, s, kind, 0) - K
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
    local instances = {}
    for index = 1, scheduler.MAX_TASKS do
        instances[index] = stub(1)
    end
    local decl = declaration("normal", 10)
    local s = scheduler.new({ steady = 0 })
    collectgarbage()
    local before = collectgarbage("count")
    for index = 1, scheduler.MAX_TASKS do
        s:add({ id = index, decl = decl, instance = instances[index] })
    end
    collectgarbage()
    return { K = K, rows = rows, heap = { tasks = scheduler.MAX_TASKS, kib = collectgarbage("count") - before } }
end

--- The check that replaces a fixed go/no-go figure: every measured callback
--- took no more than the planner charged for it. It also reports what the
--- measurements show per part: `fixed` (an idle callback), `examine` (per task
--- examined, from scenarios that run nothing), `perRun` (per task examined and
--- run, from scenarios where every examined task runs), and the least slack.
function overhead.verdict(results)
    local verdict = { ok = true, failures = {}, fixed = 0, examine = 0, perRun = 0, slack = math.huge }
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
