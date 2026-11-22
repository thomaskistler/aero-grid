-- SPDX-License-Identifier: GPL-2.0-only

--- Slot scheduler: shares a callback's slots among tasks in fair round-robin.
--- It knows nothing about panels, services or EdgeTX; the host wraps its work
--- as tasks. One slot is a nominal 2000 Lua instructions.
---
---@class AeroGridTask
---@field name string Label used in error reports.
---@field step fun(task: AeroGridTask, now: integer, slots: integer, context: any): integer?, boolean? Returns slots used and whether more work is ready now.
--- A fixed-cost step that returns no consumption used its whole grant; a
--- variable-cost step must report it. No continuation means none is wanted.
---@field cost? integer|"variable" Slots one step needs, 0 to 8. Defaults to 1. Read before every step.
---@field minCost? integer Minimum grant for a variable-cost step, 1 to 8.
---@field due? integer Tick from which the task is eligible. Ignored while pending.
---@field ready? fun(task: AeroGridTask, now: integer, context: any): boolean Extra gate.
---@field failed? boolean Set by the host before a run, or by the scheduler after a failure.
---@field error? string Set by the scheduler with `failed`.
---
--- The scheduler keeps its bookkeeping off the task; `state(task)` reads it.
---@class AeroGridTaskState
---@field pending? boolean The last step asked for another.
---@field spent integer Slots charged so far.
---@field refused? integer Callback in which the task was denied slots or spun on free turns.
---@field denied? integer Segment in which the task did not fit its grant.
---@field spun? integer Callback in which the task was stopped after repeated free turns.

local MAX_TASK_SLOTS = 8
--- `SLOTS` caps one turn; `CAPACITY` is the default allowance of one callback segment.
local scheduler = { SLOTS = MAX_TASK_SLOTS, CAPACITY = MAX_TASK_SLOTS, INSTRUCTIONS_PER_SLOT = 2000 }

--- Slots a task is granted, zero when it does not fit, or nil when its cost is invalid.
---@param cost any
---@param minCost any
---@param allowance integer Slots still available to charged work.
---@return integer?
local function grant(cost, minCost, allowance)
    if cost == "variable" then
        if type(minCost) ~= "number" or minCost < 1 or minCost > MAX_TASK_SLOTS or minCost % 1 ~= 0 then
            return nil
        end
        if allowance < minCost then
            return 0
        end
        return math.min(allowance, MAX_TASK_SLOTS)
    end
    if type(cost) ~= "number" or cost < 0 or cost > MAX_TASK_SLOTS or cost % 1 ~= 0 then
        return nil
    end
    return cost <= allowance and cost or 0
end

--- Create one scheduler.
--- `fail(task, message)` reports a failed task once. `charge(task, spent)`
--- observes every non-zero charge.
---@param dependencies? table
---@return table scheduler
function scheduler.new(dependencies)
    dependencies = dependencies or {}
    local fail, charge = dependencies.fail, dependencies.charge
    local capacity = dependencies.capacity == nil and scheduler.CAPACITY or dependencies.capacity
    assert(
        type(capacity) == "number" and capacity > 0 and capacity < math.huge and capacity % 1 == 0,
        "capacity must be a positive whole number"
    )
    local cursor = 1
    local deferredTurn = setmetatable({}, { __mode = "v" })
    local self = setmetatable({
        -- Read-only description of the callback budget, shared with panels.
        budget = {
            capacity = capacity,
            slots = math.min(capacity, MAX_TASK_SLOTS),
            instructionsPerSlot = scheduler.INSTRUCTIONS_PER_SLOT,
        },
        tasks = {},
        count = 0,
        callbacks = 0,
        segments = 0,
        -- Slots left in the last segment of the last run.
        remaining = 0,
    }, {
        __index = function(_, key)
            if key == "cursor" then
                return cursor
            end
        end,
        __newindex = function(target, key, value)
            if key == "cursor" then
                cursor = value
                deferredTurn[1], deferredTurn[2] = nil, nil
            else
                rawset(target, key, value)
            end
        end,
    })
    -- Cumulative counters since creation; readers take differences.
    local totals = { callbacks = 0, used = 0, available = 0, requested = 0, denied = 0 }
    -- Weak keys: a retired task is collectable once its owner drops it.
    local records = setmetatable({}, { __mode = "k" })

    local function positionOf(tasks, count, task)
        if task then
            for index = 1, count do
                if tasks[index] == task then
                    return index
                end
            end
        end
    end

    local function record(task)
        local state = records[task]
        if not state then
            state = { spent = 0 }
            records[task] = state
        end
        return state
    end

    --- The scheduler's bookkeeping for a task, for diagnostics and tests. Read only.
    ---@param task AeroGridTask
    ---@return AeroGridTaskState
    function self.state(task)
        return record(task)
    end

    --- Enrol one task for the coming run.
    function self.add(task)
        local count = self.count + 1
        self.tasks[count] = task
        self.count = count
    end

    --- Release every enrolled task. Deferred identity is weak, so retired
    --- owners remain collectable.
    function self.clear()
        local tasks = self.tasks
        for index = self.count, 1, -1 do
            tasks[index] = nil
        end
        self.count = 0
    end

    --- Whether a task carries over into the next segment of this callback:
    --- it asked for another step or did not fit the last segment, and it did
    --- not spin on free turns.
    local function carries(task, state, callback, segment)
        return not task.failed
            and state.spun ~= callback
            and (state.pending and state.refused ~= callback or state.denied == segment)
    end

    local function failTask(task, state, message)
        task.failed, task.error, state.pending = true, message, false
        if fail then
            fail(task, message)
        end
    end

    --- Run one segment of a callback's work. Without `resuming` it starts a
    --- new callback; with it, it continues the same callback with new slots.
    --- Every eligible task takes a turn per pass, and a task that asks for
    --- another step runs again only after the rest of the ring has had its turn.
    --- The first task that does not fit keeps the next callback's first turn;
    --- nothing charged runs after it, though free tasks still do.
    --- Consecutive zero-charge turns are limited to at most eight per task
    --- per callback; unfinished work resumes on the next callback.
    local function execute(now, slots, context, resuming)
        local count, tasks, turnSlots = self.count, self.tasks, self.budget.slots
        if count == 0 then
            return 0, 0, 0
        end
        local callback, previous = self.callbacks, self.segments
        if not resuming then
            callback = callback + 1
            self.callbacks = callback
        end
        local segment = previous + 1
        self.segments = segment
        if resuming then
            -- Tasks that did not fit the last segment continue with the new
            -- allowance; tasks that spun on free turns wait for the next callback.
            for index = 1, count do
                local task = tasks[index]
                local state = record(task)
                if state.denied == previous and carries(task, state, callback, previous) then
                    state.refused, state.pending = nil, true
                end
            end
        end
        local start = positionOf(tasks, count, deferredTurn[1]) or positionOf(tasks, count, deferredTurn[2]) or cursor
        if start > count then
            start = 1
        end
        deferredTurn[1], deferredTurn[2] = tasks[start], tasks[start % count + 1]
        local remaining, deferredPosition, requested, denied = slots, nil, 0, 0

        local progressed
        repeat
            progressed = false
            local index = start
            for _ = 1, count do
                local position = index
                local task = tasks[position]
                local state = record(task)
                index = index % count + 1
                if
                    not task.failed
                    and state.refused ~= callback
                    and (state.pending or (state.ran ~= callback and now >= (task.due or 0)))
                    and (not task.ready or task.ready(task, now, context))
                then
                    local cost = task.cost
                    if cost == nil then
                        cost = 1
                    end
                    local granted = grant(cost, task.minCost, deferredPosition and 0 or remaining)
                    if granted == nil then
                        failTask(task, state, cost == "variable" and "invalid minimum slot cost" or "invalid slot cost")
                    else
                        if cost ~= 0 then
                            requested = requested + 1
                        end
                        if granted == 0 and cost ~= 0 then
                            denied = denied + 1
                            state.refused, state.denied = callback, segment
                            if not deferredPosition then
                                deferredPosition = position
                                deferredTurn[1], deferredTurn[2] = task, tasks[position % count + 1]
                            end
                        else
                            local ok, used, again = pcall(task.step, task, now, granted, context)
                            local spent = granted
                            if used == nil and cost ~= "variable" then
                                used = granted
                            end
                            if again == nil then
                                again = false
                            end
                            if not ok then
                                failTask(task, state, tostring(used))
                            elseif type(used) == "number" and used >= 0 and used <= granted and used % 1 == 0 then
                                if type(again) ~= "boolean" then
                                    ok = false
                                    failTask(task, state, "continuation must be boolean")
                                else
                                    spent = used
                                end
                            else
                                ok = false
                                failTask(task, state, "consumption must be whole slots within the grant")
                            end
                            if spent == 0 then
                                state.zeroTurns = state.ran == callback and (state.zeroTurns or 0) + 1 or 1
                            else
                                state.zeroTurns = 0
                            end
                            state.ran = callback
                            state.spent = state.spent + spent
                            remaining = remaining - spent
                            if ok and again then
                                state.pending = true
                                progressed = true
                                if state.zeroTurns >= turnSlots then
                                    state.refused, state.spun = callback, callback
                                end
                            else
                                state.pending = false
                            end
                            if charge and spent > 0 then
                                charge(task, spent)
                            end
                        end
                    end
                end
            end
        until not progressed

        cursor = deferredPosition or start
        return slots - remaining, requested, denied
    end

    --- Whether another segment of this callback has work to do.
    local function more(now, context)
        local callback, segment, tasks = self.callbacks, self.segments, self.tasks
        for index = 1, self.count do
            local task = tasks[index]
            if
                carries(task, record(task), callback, segment)
                and (not task.ready or task.ready(task, now, context))
            then
                return true
            end
        end
        return false
    end

    --- Run one callback's worth of work in one or more segments of `slots`.
    --- Later segments only continue work that asked for another step or did
    --- not fit; a task that already ran does not run again just because it is
    --- due. `options.segments` allows that many further segments, run inside
    --- `options.cross(fn)`, which reports `ok, failure` like `pcall`; without
    --- `cross` no further segment runs.
    --- Every allowed segment counts as available, whether or not it was needed.
    ---@param now integer
    ---@param slots integer Slots available to each segment.
    ---@param context any Passed through to `ready` and `step`.
    ---@param options? {segments?: integer, cross?: fun(fn: function): boolean, any}
    ---@return integer used
    ---@return integer requested Eligible tasks that asked for slots.
    ---@return integer denied Eligible tasks that did not fit the last segment.
    ---@return string? failure Why the further segments were abandoned.
    function self.run(now, slots, context, options)
        local extra = options and options.segments or 0
        local cross = options and options.cross
        local used, requested, denied = execute(now, slots, context, false)
        self.remaining = slots - used
        local failure
        if cross and extra > 0 and more(now, context) then
            local ok, message = cross(function()
                for _ = 1, extra do
                    if not more(now, context) then
                        break
                    end
                    local segmentUsed, segmentRequested, segmentDenied = execute(now, slots, context, true)
                    -- A request denied earlier and retried here is still one request,
                    -- and only what remains denied after the last segment is deferred.
                    used, requested, denied = used + segmentUsed, requested + segmentRequested - denied, segmentDenied
                    self.remaining = slots - segmentUsed
                end
            end)
            if not ok then
                failure = tostring(message)
            end
        end
        totals.callbacks = totals.callbacks + 1
        totals.used, totals.available = totals.used + used, totals.available + slots * (1 + extra)
        totals.requested, totals.denied = totals.requested + requested, totals.denied + denied
        return used, requested, denied, failure
    end

    --- Cumulative counters since creation: callbacks, used, available,
    --- requested and denied. Read only; readers take differences.
    ---@return table
    function self.stats()
        return totals
    end

    return self
end

return scheduler
