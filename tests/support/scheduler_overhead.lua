-- SPDX-License-Identifier: GPL-2.0-only

--- Measures the framework's own cost with stub tasks (specification, 4.2).
---
--- `overhead.measure(scheduler, count, pause)` runs `scheduler:run` with stub
--- tasks that only return a delay and returns instruction counts. `count()` is
--- an exact instruction counter (the native harness, or `overhead.hookCounter()`
--- offline) and `pause(flag)` excludes bookkeeping from the count.

local overhead = {}

overhead.LIMIT = 500
overhead.TASK_COUNTS = { 8, 32, 128 }
overhead.RUN_COUNTS = { 1, 4, 8, 12 }
overhead.GO_TASKS = 32

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

local function stubDeclaration(class, perUnit)
    return { class = class, stages = { run = { fixed = 0, perUnit = perUnit, maxUnits = 1 } } }
end

-- `tasks` stubs; the first `ready` of each class are due now, the rest are due later.
-- Ready stubs return `delay`, which decides where they are put back in the list.
local function build(scheduler, tasks, readyCritical, readyNormal, delay, perUnit)
    local s = scheduler.new({ steady = 0 })
    local critical, normal = stubDeclaration("critical", perUnit), stubDeclaration("normal", perUnit)
    local function stub()
        return {
            step = function()
                return delay
            end,
        }
    end
    local seen = { critical = 0, normal = 0 }
    for index = 1, tasks do
        local class = index % 2 == 1 and "critical" or "normal"
        seen[class] = seen[class] + 1
        local want = class == "critical" and readyCritical or readyNormal
        local due = seen[class] <= want and 0 or 1000 + index * 7
        assert(s:add({ id = index, decl = class == "critical" and critical or normal, instance = stub(), due = due }))
    end
    return s
end

-- The most work one callback can do: ten critical tasks run, four normal tasks
-- are examined and do not fit, and two more normal tasks run (twelve in all).
local function buildWorst(scheduler, tasks, delay)
    local s = build(scheduler, tasks - 6, 10, 0, delay, 10)
    local function add(id, perUnit, due)
        local step = function()
            return delay
        end
        assert(s:add({ id = id, decl = stubDeclaration("normal", perUnit), instance = { step = step }, due = due }))
    end
    for index = 1, 4 do
        add("big" .. index, 100000, 0)
    end
    add("small1", 10, 0)
    add("small2", 10, 0)
    return s
end

local function window(count, pause, fn, a, b, c)
    pause(false)
    local first = count()
    fn(a, b, c)
    local last = count()
    pause(true)
    return last - first
end

--- Returns `{ K, idle, run, unfit, heap }` keyed by task count:
--- `idle[n]` is a callback with nothing ready, `run[n][k]` a callback running `k`
--- tasks (worst of putting them back at the end or in the middle of the lists),
--- `unfit[n]` a callback examining sixteen ready tasks that do not fit, `worst[n]`
--- the most work a callback can do (see `buildWorst`).
function overhead.measure(scheduler, count, pause)
    pause = pause or function() end
    pause(true)
    local noop = function() end
    local results = { idle = {}, run = {}, unfit = {}, worst = {}, heap = {} }
    results.K = window(count, pause, noop, nil, nil, nil)
    local function cost(s)
        return window(count, pause, s.run, s, "steady", 0) - results.K
    end
    for _, tasks in ipairs(overhead.TASK_COUNTS) do
        results.idle[tasks] = cost(build(scheduler, tasks, 0, 0, 1, 10))
        results.run[tasks] = {}
        for _, k in ipairs(overhead.RUN_COUNTS) do
            if k <= tasks then
                local worst = 0
                local middle = 1000 + tasks * 7 // 2
                for _, delay in ipairs({ 100000, middle }) do
                    local readyCritical = math.min(k, scheduler.EXAMINE_CRITICAL)
                    local s = build(scheduler, tasks, readyCritical, k - readyCritical, delay, 10)
                    worst = math.max(worst, cost(s))
                end
                results.run[tasks][k] = worst
            end
        end
        local unfit = build(scheduler, tasks - 1, 10, 6, 1, 1000000)
        assert(
            unfit:add({ id = "tiny", decl = stubDeclaration("normal", 1), instance = { step = noop }, due = 10 ^ 9 })
        )
        results.unfit[tasks] = cost(unfit)
    end
    for _, tasks in ipairs(overhead.TASK_COUNTS) do
        if tasks >= 32 then
            local worst = 0
            for _, delay in ipairs({ 100000, 1000 + tasks * 7 // 2 }) do
                worst = math.max(worst, cost(buildWorst(scheduler, tasks, delay)))
            end
            results.worst[tasks] = worst
        end
    end
    local instances = {}
    for index = 1, scheduler.MAX_TASKS do
        instances[index] = { step = noop }
    end
    local decl = stubDeclaration("normal", 10)
    local s = scheduler.new({ steady = 0 })
    collectgarbage()
    local before = collectgarbage("count")
    for index = 1, scheduler.MAX_TASKS do
        s:add({ id = index, decl = decl, instance = instances[index] })
    end
    collectgarbage()
    results.heap = { tasks = scheduler.MAX_TASKS, kib = collectgarbage("count") - before }
    return results
end

--- The go/no-go figure of the specification at `GO_TASKS` tasks:
--- `F0 + (K_c + K_n) * c1 + maxRun * o` against `LIMIT`. `o` is the worst added
--- cost per task run, `c1` the cost per examined task that does not fit.
function overhead.verdict(results, scheduler)
    local tasks = overhead.GO_TASKS
    local idle = results.idle[tasks]
    local perTask = 0
    for k, total in pairs(results.run[tasks]) do
        perTask = math.max(perTask, (total - idle) / k)
    end
    local examined = scheduler.EXAMINE_CRITICAL + scheduler.EXAMINE_NORMAL
    local perExamined = (results.unfit[tasks] - idle) / examined
    local total = idle + examined * perExamined + scheduler.MAX_RUN * perTask
    return {
        F0 = idle,
        c1 = perExamined,
        o = perTask,
        total = total,
        direct = results.worst[tasks],
        limit = overhead.LIMIT,
        go = total <= overhead.LIMIT,
    }
end

return overhead
