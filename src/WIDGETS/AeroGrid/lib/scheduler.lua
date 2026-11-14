-- SPDX-License-Identifier: GPL-2.0-only

--- Slot scheduler: shares a callback's slots among tasks in fair round-robin.
--- It knows nothing about panels, services or EdgeTX; the host wraps its work
--- as tasks. One slot is a nominal 2000 Lua instructions.
---
---@class AeroGridTask
---@field name string Label used in error reports.
---@field step fun(task: AeroGridTask, now: integer, slots: integer, context: any): integer, boolean Returns slots used and whether more work is ready now.
---@field cost? integer|"variable" Slots one step needs, 0 to 8. Defaults to 1. Read before every step.
---@field minCost? integer Minimum grant for a variable-cost step, 1 to 8.
---@field due? integer Tick from which the task is eligible. Ignored while pending.
---@field ready? fun(task: AeroGridTask, now: integer, context: any): boolean Extra gate.
---@field verb? string Names the work in the consumption error message.
---@field failed? boolean Set by the host before a run, or by the scheduler after a failure.
---@field error? string
---@field pending? boolean Set by the scheduler while a step asked for another.
---@field spent? integer Slots charged so far.

local MAX_TASK_SLOTS = 8
local scheduler = { RUNTIME_API = 1, SLOTS = MAX_TASK_SLOTS, INSTRUCTIONS_PER_SLOT = 2000 }

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
    local self = {
        capacity = dependencies.capacity == nil and scheduler.SLOTS or dependencies.capacity,
        instructionsPerSlot = scheduler.INSTRUCTIONS_PER_SLOT,
        tasks = {},
        count = 0,
        cursor = 1,
        callbacks = 0,
    }
    assert(
        type(self.capacity) == "number" and self.capacity > 0 and self.capacity < math.huge and self.capacity % 1 == 0,
        "capacity must be a positive whole number"
    )

    --- Enrol one task for the coming run.
    function self.add(task)
        local count = self.count + 1
        self.tasks[count] = task
        self.count = count
    end

    --- Release every task. The scheduler keeps nothing between callbacks, so a
    --- retired panel is collectable as soon as its owner drops it; only the
    --- cursor, an index, persists.
    function self.clear()
        local tasks = self.tasks
        for index = self.count, 1, -1 do
            tasks[index] = nil
        end
        self.count = 0
    end

    local function failTask(task, message)
        task.failed, task.error, task.pending = true, message, false
        if fail then
            fail(task, message)
        end
    end

    --- Run one callback's worth of work.
    --- Every eligible task takes a turn per pass, and a task that asks for
    --- another step runs again only after the rest of the ring has had its turn.
    --- The first task that does not fit keeps the next callback's first turn;
    --- nothing charged runs after it, though free tasks still do.
    --- Consecutive zero-charge turns are limited to at most eight per task
    --- per callback; unfinished work resumes on the next callback.
    ---@param now integer
    ---@param slots integer Slots available to this callback.
    ---@param context any Passed through to `ready` and `step`.
    ---@return integer used
    ---@return integer requested Eligible tasks that asked for slots.
    ---@return integer denied Eligible tasks that did not fit.
    function self.run(now, slots, context)
        local count, tasks, capacity = self.count, self.tasks, self.capacity
        if count == 0 then
            return 0, 0, 0
        end
        local callback = self.callbacks + 1
        self.callbacks = callback
        local start = self.cursor
        if start > count then
            start = 1
        end
        local remaining, deferred, requested, denied = slots, nil, 0, 0

        local progressed
        repeat
            progressed = false
            local index = start
            for _ = 1, count do
                local position = index
                local task = tasks[position]
                index = index % count + 1
                if
                    not task.failed
                    and task.refused ~= callback
                    and (task.pending or (task.ran ~= callback and now >= (task.due or 0)))
                    and (not task.ready or task.ready(task, now, context))
                then
                    local cost = task.cost
                    if cost == nil then
                        cost = 1
                    end
                    local granted = grant(cost, task.minCost, deferred and 0 or remaining)
                    if granted == nil then
                        failTask(task, cost == "variable" and "invalid minimum slot cost" or "invalid slot cost")
                    else
                        if cost ~= 0 then
                            requested = requested + 1
                        end
                        if granted == 0 and cost ~= 0 then
                            denied = denied + 1
                            task.refused = callback
                            deferred = deferred or position
                        else
                            local ok, used, again = pcall(task.step, task, now, granted, context)
                            local spent = granted
                            if not ok then
                                failTask(task, tostring(used))
                            elseif type(used) == "number" and used >= 0 and used <= granted and used % 1 == 0 then
                                spent = used
                                if type(again) ~= "boolean" then
                                    ok = false
                                    failTask(task, (task.verb or "step") .. " continuation must be boolean")
                                end
                            else
                                ok = false
                                failTask(
                                    task,
                                    (task.verb or "step") .. " consumption must be whole slots within the grant"
                                )
                            end
                            if spent == 0 then
                                task.zeroTurns = task.ran == callback and (task.zeroTurns or 0) + 1 or 1
                            else
                                task.zeroTurns = 0
                            end
                            task.ran = callback
                            task.spent = (task.spent or 0) + spent
                            remaining = remaining - spent
                            if ok and again then
                                task.pending = true
                                progressed = true
                                if task.zeroTurns >= math.min(capacity, MAX_TASK_SLOTS) then
                                    task.refused = callback
                                end
                            else
                                task.pending = false
                            end
                            if charge and spent > 0 then
                                charge(task, spent)
                            end
                        end
                    end
                end
            end
        until not progressed

        self.cursor = deferred or start
        return slots - remaining, requested, denied
    end

    return self
end

return scheduler
