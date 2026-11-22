-- SPDX-License-Identifier: GPL-2.0-only

--- Slot scheduler: shares a callback's slots among tasks in order of due time.
--- It knows nothing about panels, services or EdgeTX; the host wraps its work
--- as tasks. One slot is a nominal 2000 Lua instructions.
---
--- Tasks stay enrolled until removed, sorted by the tick they are due. A run
--- takes tasks from the front and stops at the first one that is not due, so
--- idle tasks cost nothing. A task that asks for another step keeps its place;
--- one that finishes is re-inserted at its next due tick, behind tasks already
--- due at that tick, which ran less recently. A task that does not fit keeps
--- its place, so it stays ahead of later work.
---
---@class AeroGridTask
---@field name string Label used in error reports.
---@field step fun(task: AeroGridTask, now: integer, slots: integer, context: any): integer?, boolean? Returns slots used and whether more work is ready now.
--- A fixed-cost step that returns no consumption used its whole grant; a
--- variable-cost step must report it. No continuation means none is wanted.
---@field cost? integer|"variable" Slots one step needs, 0 to 8. Defaults to 1. Read before every step.
---@field minCost? integer Minimum grant for a variable-cost step, 1 to 8.
---@field due? integer Tick from which the task is eligible. Ignored while pending.
--- A step may change its own `due`; any other source that makes a task due
--- earlier calls `reschedule` to move it forward. A later `due` set from
--- outside takes effect when the task reaches the front.
---@field hold? {on: boolean?} Shared hold; the task waits while `hold.on`.
---@field ready? fun(task: AeroGridTask, now: integer, context: any): boolean Extra gate for rare work, read on every pass while the task is due.
---@field failed? boolean Set by the host or a step to retire the task, or by the scheduler after a failure.
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
--- A task due `NEVER` sleeps until a source wakes it.
local scheduler = {
    SLOTS = MAX_TASK_SLOTS,
    CAPACITY = MAX_TASK_SLOTS,
    INSTRUCTIONS_PER_SLOT = 2000,
    NEVER = math.huge,
}

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
    -- `tasks` is sorted by `keys`, the due tick each task was placed at.
    local tasks, keys, count = {}, {}, 0
    -- Position of the task being stepped, kept current while steps add or remove tasks.
    local walk
    -- A task placed at or before the walk while it was due needs another pass.
    local rerun
    local self = {
        -- Read-only description of the callback budget, shared with panels.
        budget = {
            capacity = capacity,
            slots = math.min(capacity, MAX_TASK_SLOTS),
            instructionsPerSlot = scheduler.INSTRUCTIONS_PER_SLOT,
        },
        tasks = tasks,
        count = 0,
        callbacks = 0,
        segments = 0,
        -- Slots left in the last segment of the last run.
        remaining = 0,
    }
    -- Cumulative counters since creation; readers take differences.
    local totals = { callbacks = 0, used = 0, available = 0, requested = 0, denied = 0 }
    -- Weak keys: a retired task is collectable once its owner drops it.
    local records = setmetatable({}, { __mode = "k" })

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

    local function positionOf(task)
        for index = 1, count do
            if tasks[index] == task then
                return index
            end
        end
    end

    local function unlink(index)
        table.remove(tasks, index)
        table.remove(keys, index)
        count = count - 1
        self.count = count
        if walk and index < walk then
            walk = walk - 1
        end
    end

    --- Insert behind every task due at or before `due`. With `ahead`, a task
    --- due at `due` that already ran in callback `ahead` stays behind it.
    local function link(task, due, now, ahead)
        local low, high = 1, count + 1
        while low < high do
            local middle = (low + high) // 2
            if keys[middle] < due or not ahead and keys[middle] == due then
                low = middle + 1
            else
                high = middle
            end
        end
        if ahead then
            while low <= count and keys[low] == due and records[tasks[low]].ran ~= ahead do
                low = low + 1
            end
        end
        table.insert(tasks, low, task)
        table.insert(keys, low, due)
        count = count + 1
        self.count = count
        if walk and low <= walk then
            walk = walk + 1
            if now and due <= now then
                rerun = true
            end
        end
        return low
    end

    -- `current` is the tick of the run in progress, `latest` of the last run.
    -- Work already overdue queues behind tasks waiting since that run.
    local current, latest = 0, 0

    --- Move an enrolled task forward to its `due` tick if that is earlier than
    --- its place. A task that asked for another step keeps its place. Unless
    --- `exact`, overdue work queues behind tasks waiting since the last run.
    ---@param task AeroGridTask
    ---@param exact? boolean
    function self.reschedule(task, exact)
        local state = records[task]
        local due = exact and task.due or math.max(task.due or 0, latest)
        if state and state.enrolled and not state.pending and due < state.key then
            unlink(positionOf(task))
            state.key = due
            link(task, due, current)
        end
    end

    --- Enrol a task at its `due` tick, or as due now if it asked for another
    --- step; an enrolled task is rescheduled.
    ---@param task AeroGridTask
    function self.add(task)
        local state = record(task)
        if state.enrolled then
            self.reschedule(task)
            return
        end
        local due = state.pending and latest or math.max(task.due or 0, latest)
        state.enrolled, state.key = true, due
        link(task, due, current)
    end

    --- Withdraw a task. Its bookkeeping survives re-enrolment.
    ---@param task AeroGridTask
    function self.remove(task)
        local state = records[task]
        if state and state.enrolled then
            state.enrolled = nil
            unlink(positionOf(task))
        end
    end

    --- Whether a task is enrolled.
    function self.has(task)
        local state = records[task]
        return state ~= nil and state.enrolled == true
    end

    --- Withdraw every task.
    function self.clear()
        for index = count, 1, -1 do
            records[tasks[index]].enrolled = nil
            tasks[index], keys[index] = nil, nil
        end
        count = 0
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

    local function open(task, now, context)
        local hold = task.hold
        return not (hold and hold.on) and (not task.ready or task.ready(task, now, context))
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
    --- another step runs again only after the rest of the due tasks have had
    --- their turn. Once a task does not fit, nothing charged runs after it,
    --- though free tasks still do. Consecutive zero-charge turns are limited
    --- to at most eight per task per callback; unfinished work resumes on the
    --- next callback.
    local function execute(now, slots, context, resuming)
        local turnSlots = self.budget.slots
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
        current, latest = now, now
        if resuming then
            -- Tasks that did not fit the last segment continue with the new
            -- allowance; tasks that spun on free turns wait for the next callback.
            for index = 1, count do
                if keys[index] > now then
                    break
                end
                local task = tasks[index]
                local state = records[task]
                if state.denied == previous and carries(task, state, callback, previous) then
                    state.refused, state.pending = nil, true
                end
            end
        end
        local remaining, deferred, requested, denied = slots, false, 0, 0

        local progressed
        repeat
            progressed, rerun = false, false
            local index = 1
            while index <= count and keys[index] <= now do
                local task = tasks[index]
                local state = records[task]
                local due = task.due or 0
                index = index + 1
                if task.failed then
                    state.enrolled, state.pending = nil, false
                    unlink(index - 1)
                    index = index - 1
                elseif not state.pending and due > now then
                    -- Another scheduler sharing this task stepped it; move it back.
                    unlink(index - 1)
                    state.key = due
                    if link(task, due) >= index then
                        index = index - 1
                    end
                elseif
                    state.refused ~= callback
                    and (state.pending or state.ran ~= callback)
                    and open(task, now, context)
                then
                    local cost = task.cost
                    if cost == nil then
                        cost = 1
                    end
                    local granted = grant(cost, task.minCost, deferred and 0 or remaining)
                    if granted == nil then
                        failTask(task, state, cost == "variable" and "invalid minimum slot cost" or "invalid slot cost")
                    else
                        if cost ~= 0 then
                            requested = requested + 1
                        end
                        if granted == 0 and cost ~= 0 then
                            denied = denied + 1
                            state.refused, state.denied = callback, segment
                            deferred = true
                            if state.ran == callback then
                                -- It already had a turn: it goes behind work due earlier
                                -- that has not, but ahead of work that finished.
                                unlink(index - 1)
                                state.key = now
                                if link(task, now, nil, callback) >= index then
                                    index = index - 1
                                end
                            end
                        else
                            walk = index - 1
                            local ok, used, again = pcall(task.step, task, now, granted, context)
                            local after = walk
                            walk = nil
                            local position = after
                            if tasks[position] ~= task then
                                -- The step moved or withdrew its own task.
                                position = positionOf(task)
                                index = after
                            end
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
                            if ok and again and not task.failed then
                                state.pending = true
                                progressed = true
                                if state.zeroTurns >= turnSlots then
                                    state.refused, state.spun = callback, callback
                                end
                                if position then
                                    index = position + 1
                                end
                            else
                                state.pending = false
                                if position then
                                    unlink(position)
                                    if task.failed then
                                        state.enrolled = nil
                                        index = position
                                    else
                                        -- Behind tasks already due, which ran less recently.
                                        due = math.max(task.due or 0, now)
                                        state.key = due
                                        index = link(task, due) > position and position or position + 1
                                    end
                                end
                            end
                            if charge and spent > 0 then
                                charge(task, spent)
                            end
                        end
                    end
                end
            end
        until not (progressed or rerun)

        current = 0
        return slots - remaining, requested, denied
    end

    --- Whether another segment of this callback has work to do.
    local function more(now, context)
        local callback, segment = self.callbacks, self.segments
        for index = 1, count do
            if keys[index] > now then
                break
            end
            local task = tasks[index]
            if carries(task, records[task], callback, segment) and open(task, now, context) then
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
