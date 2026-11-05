-- SPDX-License-Identifier: GPL-2.0-only

-- Parity harness for migrating one task to the new scheduler
-- (plans/scheduler-framework.md, section 7). A task is described by an adapter
-- and run over a recorded input trace in four ways:
--
--   golden      the pre-migration code, under the real legacy loop
--   extraction  the same loop calling the extracted `step` (what the new
--               scheduler will call); must equal golden exactly
--   replay      the extraction run's schedule replayed into `step` alone; must
--               equal golden exactly (the task, isolated from any planner)
--   budgeted    the real planner under a real budget; timing may differ within
--               stated limits, never unboundedly
--
-- adapter = {
--   id        the task id,
--   decl      the declaration the new scheduler runs,
--   new()     a fresh task: `step` (the new scheduler's entry point), `update` (the
--             legacy loop's entry point: the extracted work at the full cap),
--             `interval` and the fields the registry needs (see standin),
--   feed(task, callback)     applies the callback's recorded input,
--   old(task, now)           the pre-migration update,
--   snapshot(task) -> string the task's observable state,
-- }
-- trace = list of callbacks `{ now = tick, kind = "steady"|"background", ... }`.
--
-- The native gate (pixels and the worst callback on the matched harness) needs
-- macOS and Companion; it is a release gate run by hand, not part of this harness.
local root = (... and ... ~= "" and ...) or "."

local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()

local parity = {}

-- Runs the task under the real legacy loop (the services registry), calling
-- `update` in callbacks where it is due: the one given (the golden run) or the
-- task's own, whose calls are recorded as the schedule (the extraction run). The
-- loop runs the first stage at its full cap.
local function legacy(adapter, trace, update)
    local task = adapter.new()
    local run, current = { snapshots = {}, schedule = {}, task = task }, 0
    if update then
        task.update = update
    else
        local own = task.update
        local first = adapter.decl.first or "run"
        local cap = adapter.decl.stages[first].maxUnits
        task.update = function(self, now)
            run.schedule[#run.schedule + 1] = { index = current, now = now, grant = cap, stage = first }
            return own(self, now)
        end
    end
    local runtime = services.runtime({})
    services.register(runtime, task, trace[1].now)
    for index, callback in ipairs(trace) do
        current = index
        adapter.feed(task, callback)
        local _, failure = services.update(runtime, callback.now)
        assert(not failure, failure)
        run.snapshots[index] = adapter.snapshot(task)
    end
    return run
end

--- The pre-migration code under the legacy loop.
function parity.golden(adapter, trace)
    return legacy(adapter, trace, function(task, now)
        adapter.old(task, now)
    end)
end

--- The extracted step under the legacy loop. Its schedule is recorded.
function parity.extraction(adapter, trace)
    return legacy(adapter, trace)
end

--- The recorded schedule replayed into `step` at the same callbacks.
function parity.replay(adapter, trace, schedule)
    local task, at = adapter.new(), 1
    local run = { snapshots = {}, schedule = schedule, task = task }
    for index, callback in ipairs(trace) do
        adapter.feed(task, callback)
        while schedule[at] and schedule[at].index == index do
            local call = schedule[at]
            task:step(call.grant, call.stage, call.now)
            at = at + 1
        end
        run.snapshots[index] = adapter.snapshot(task)
    end
    return run
end

--- The real planner. `options`: `overhead` (default steady 1250, background
--- 1130), `used` (instructions of head work, a number or `function(callback)`),
--- `setup(s)` to add competing tasks. Every plan must stay under the budget.
function parity.budgeted(adapter, trace, options)
    options = options or {}
    local s = scheduler.new(options.overhead or { steady = 1250, background = 1130 })
    local task = adapter.new()
    local run, current = { snapshots = {}, schedule = {}, task = task }, 0
    local step = task.step
    task.step = function(self, grant, stage, now)
        run.schedule[#run.schedule + 1] = { index = current, now = now, grant = grant, stage = stage }
        return step(self, grant, stage, now)
    end
    local ok, reason = s:add({ id = adapter.id, decl = adapter.decl, instance = task, due = trace[1].now })
    assert(ok, reason)
    if options.setup then
        options.setup(s)
    end
    local used = options.used or 0
    for index, callback in ipairs(trace) do
        current = index
        adapter.feed(task, callback)
        s:run(callback.kind or "steady", callback.now, type(used) == "function" and used(callback) or used)
        assert(s.lastPlan.U <= scheduler.CEILING - scheduler.MARGIN, "plan over the budget at callback " .. index)
        assert(not s:takeErrors(), "the task was retired at callback " .. index)
        run.snapshots[index] = adapter.snapshot(task)
    end
    return run
end

--- Fail at the first callback where two runs' snapshots differ.
function parity.assertSame(expected, actual, label)
    assert(#expected.snapshots == #actual.snapshots, label .. ": different number of callbacks")
    for index, snapshot in ipairs(expected.snapshots) do
        if actual.snapshots[index] ~= snapshot then
            error(
                string.format(
                    "%s: callback %d differs\n  expected %s\n  actual   %s",
                    label,
                    index,
                    snapshot,
                    actual.snapshots[index]
                )
            )
        end
    end
end

--- Lateness of the budgeted run against the legacy run: for every legacy
--- release, how long until the budgeted run next released the task (at least
--- until `endTick`, the end of the trace, when it did not), and the longest gap
--- between releases of each run.
function parity.timing(legacyRun, budgetedRun, endTick)
    local late, at = 0, 1
    for _, release in ipairs(legacyRun.schedule) do
        while budgetedRun.schedule[at] and budgetedRun.schedule[at].now < release.now do
            at = at + 1
        end
        local other = budgetedRun.schedule[at]
        late = math.max(late, (other and other.now or endTick) - release.now)
    end
    local function longestGap(run)
        local gap = 0
        for index = 2, #run.schedule do
            gap = math.max(gap, run.schedule[index].now - run.schedule[index - 1].now)
        end
        return gap
    end
    return { late = late, legacyGap = longestGap(legacyRun), budgetedGap = longestGap(budgetedRun) }
end

return parity
