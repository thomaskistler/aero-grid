-- SPDX-License-Identifier: GPL-2.0-only

--- Budgeted task scheduler (specification: plans/scheduler-framework.md).
---
--- Tasks declare a worst-case cost per stage. Each callback the planner admits
--- ready tasks against a fixed budget, oldest release first, so the plan never
--- exceeds the ceiling. The planner charges its own cost to the same budget.
--- Planning never reads `getUsage`. Nothing in the widget
--- calls this library yet.
---
--- A task is `{ id, decl, instance, due }`. `decl` is shared by all tasks of a
--- type:
---   class = "critical" | "normal"
---   exclusive = true      at most one exclusive task per callback
---   shared = { name = cost }   charged once per plan, whoever runs first
---   kinds = { steady = true, background = true }   default: both
---   first = "run"         stage the instance starts in
---   stages = { run = { fixed = F, perUnit = U, maxUnits = N } }
--- The instance has `step(instance, grant, stage, now) -> delay` (integer ticks,
--- at least 1) and may keep `stage` and `want` current. `step` runs exactly the
--- planned stage with at most `grant` units, or does no work and returns 1.

local scheduler = {
    CEILING = 15000,
    MARGIN = 400,
    NORMAL_RESERVE = 2000,
    MAX_TASKS = 128,
    -- The planner's own cost, charged against the budget: a callback, a task
    -- examined, a task run or retired. Upper bounds from the instruction counts
    -- of tests/support/scheduler_overhead.lua, which fails if one is exceeded.
    FIXED_COST = 100,
    EXAMINE_COST = 48,
    RUN_COST = 160,
}
scheduler.__index = scheduler

local CEILING, MARGIN, NORMAL_RESERVE = scheduler.CEILING, scheduler.MARGIN, scheduler.NORMAL_RESERVE
local MAX_TASKS = scheduler.MAX_TASKS
local FIXED_COST, EXAMINE_COST, RUN_COST = scheduler.FIXED_COST, scheduler.EXAMINE_COST, scheduler.RUN_COST
local STEADY_AND_BACKGROUND = { steady = true, background = true }
local STAGGER_SPACING = 5
local MAX_SHARED = 2

local floor, pcall, type = math.floor, pcall, type
local move = table.move

-- A key packs `due` and the registration order so lists compare one number.
local ORDER = 1 << 20
local CRITICAL, NORMAL = 1, 2
local CLASS = { critical = CRITICAL, normal = NORMAL }
local RESERVE = { NORMAL_RESERVE, 0 }

local checked = setmetatable({}, { __mode = "k" })

local function whole(value)
    return type(value) == "number" and value % 1 == 0
end

--- Return a message when `decl` is not a usable declaration, else nil.
---@param decl table
---@return string?
function scheduler.check(decl)
    if type(decl) ~= "table" then
        return "declaration must be a table"
    end
    if CLASS[decl.class] == nil then
        return "class must be critical or normal"
    end
    if type(decl.stages) ~= "table" or next(decl.stages) == nil then
        return "stages are required"
    end
    if decl.stages[decl.first or "run"] == nil then
        return "first names no stage"
    end
    if decl.kinds ~= nil and type(decl.kinds) ~= "table" then
        return "kinds must be a table"
    end
    local names = 0
    for name, cost in pairs(decl.shared or {}) do
        names = names + 1
        if names > MAX_SHARED then
            return "at most " .. MAX_SHARED .. " shared costs (the charged run cost assumes it)"
        end
        if not whole(cost) or cost < 0 then
            return "shared cost " .. tostring(name) .. " must be a non-negative integer"
        end
    end
    for name, stage in pairs(decl.stages) do
        if
            type(stage) ~= "table"
            or not whole(stage.fixed)
            or stage.fixed < 0
            or not whole(stage.perUnit)
            or stage.perUnit < 1
            or not whole(stage.maxUnits)
            or stage.maxUnits < 1
        then
            return "stage " .. tostring(name) .. " needs integer fixed >= 0, perUnit >= 1 and maxUnits >= 1"
        end
    end
    return nil
end

--- Initial due offset in ticks for the `index`th periodic task (registration
--- order, from 0) of the given interval, spreading releases five ticks apart.
---@param index integer
---@param interval integer
---@return integer
function scheduler.stagger(index, interval)
    return STAGGER_SPACING * (index % ((interval + STAGGER_SPACING - 1) // STAGGER_SPACING))
end

--- `overhead[kind]` is the host's declared fixed cost of a callback of that kind.
---@param overhead table<string, integer>
function scheduler.new(overhead)
    return setmetatable({
        overhead = overhead,
        byId = {},
        count = 0,
        seq = 0,
        lists = { {}, {} },
        minStep = math.huge,
        errors = {},
        lastPlan = { kind = nil, U = 0, charged = 0, examined = 0, ran = 0 },
        planned = {},
        stages = {},
        grants = {},
        charged = {},
    }, scheduler)
end

-- Lists are sorted by key. A task that ran usually goes to the end.
local function insert(list, record)
    local key, size = record.key, #list
    if size == 0 or list[size].key < key then
        list[size + 1] = record
        return
    end
    local low, high = 1, size
    while low < high do
        local middle = (low + high) // 2
        if list[middle].key < key then
            low = middle + 1
        else
            high = middle
        end
    end
    table.insert(list, low, record)
end

--- Register a task. Returns true, or false and a reason. An add during a plan
--- takes effect at the next plan.
---@param task { id: any, decl: table, instance: table, due?: integer }
---@return boolean ok
---@return string? reason
function scheduler:add(task)
    local id, decl, instance = task.id, task.decl, task.instance
    if id == nil or self.byId[id] then
        return false, "id is missing or already registered"
    end
    if self.count >= MAX_TASKS then
        return false, "too many tasks"
    end
    if type(instance) ~= "table" or type(instance.step) ~= "function" then
        return false, "instance needs a step function"
    end
    if not checked[decl] then
        local message = scheduler.check(decl)
        if message then
            return false, message
        end
        checked[decl] = true
    end
    for _, stage in pairs(decl.stages) do
        if stage.fixed + stage.perUnit < self.minStep then
            self.minStep = stage.fixed + stage.perUnit
        end
    end
    self.seq = self.seq % (ORDER - 1) + 1
    self.count = self.count + 1
    local due = task.due or 0
    local record = {
        id = id,
        decl = decl,
        instance = instance,
        list = self.lists[CLASS[decl.class]],
        due = due,
        key = due * ORDER + self.seq,
        state = "listed",
    }
    self.byId[id] = record
    insert(record.list, record)
    return true
end

local function retire(self, record, message)
    record.state = "removed"
    self.byId[record.id] = nil
    self.count = self.count - 1
    self.errors[#self.errors + 1] = { id = record.id, message = message }
end

--- Remove a task. A removed task never runs again, even in the current plan.
---@param id any
---@return boolean removed
function scheduler:remove(id)
    local record = self.byId[id]
    if not record then
        return false
    end
    if record.state == "listed" then
        local list = record.list
        for index = 1, #list do
            if list[index] == record then
                table.remove(list, index)
                break
            end
        end
    end
    record.state = "removed"
    self.byId[id] = nil
    self.count = self.count - 1
    return true
end

--- Errors of tasks retired since the last call, as `{ id, message }`, or nil.
--- The host reports them at the head of the next callback.
---@return table[]?
function scheduler:takeErrors()
    local errors = self.errors
    if #errors == 0 then
        return nil
    end
    self.errors = {}
    return errors
end

-- Takes the first `examined` records of `list` out: the ones planned or retired
-- leave, the ones skipped stay in order.
local function compact(list, examined, taken)
    local size = #list
    if taken < examined then
        local kept = 0
        for index = 1, examined do
            local record = list[index]
            if record.state == "listed" then
                kept = kept + 1
                list[kept] = record
            end
        end
        move(list, examined + 1, size, kept + 1)
    else
        move(list, examined + 1, size, 1)
    end
    for index = size - taken + 1, size do
        list[index] = nil
    end
end

--- Plan and run one callback of `kind` at tick `now`. `used` is the declared
--- cost of work the host already ran in this callback. Returns the number of
--- tasks run.
---
--- The planner charges its own cost against the budget as it goes: FIXED_COST
--- once, EXAMINE_COST for every task it looks at and RUN_COST for every task it
--- plans or retires. The scan stops when the remaining room cannot admit another
--- task. It needs no cap: the list holds at most MAX_TASKS tasks, and the
--- measured cost of any scan is within what it charged (see lastPlan).
---@param kind string
---@param now integer
---@param used? integer
---@return integer
function scheduler:run(kind, now, used)
    local overhead = self.overhead[kind]
    if overhead == nil then
        error("unknown callback kind " .. tostring(kind), 2)
    end
    used = used or 0
    local room = CEILING - MARGIN - overhead - used - FIXED_COST
    local lists, charged = self.lists, self.charged
    local records, stages, grants = self.planned, self.stages, self.grants
    local smallest = self.minStep + EXAMINE_COST + RUN_COST
    local spent, planned, exclusive, sharedUsed = 0, 0, false, false
    local examinedTotal, runTotal = 0, 0

    for class = 1, 2 do
        local list = lists[class]
        local limit = room - RESERVE[class]
        local examined, taken = 0, 0
        for index = 1, #list do
            local record = list[index]
            if record.due > now or limit - spent < smallest then
                break
            end
            examined = index
            spent = spent + EXAMINE_COST
            local decl, instance = record.decl, record.instance
            if (decl.kinds or STEADY_AND_BACKGROUND)[kind] and not (exclusive and decl.exclusive) then
                local stage = instance.stage or decl.first or "run"
                local declared = decl.stages[stage]
                if declared == nil then
                    retire(self, record, "unknown stage " .. tostring(stage))
                    taken = taken + 1
                    runTotal = runTotal + 1
                    spent = spent + RUN_COST
                else
                    local fixed, shared = declared.fixed, decl.shared
                    if shared then
                        for name, cost in pairs(shared) do
                            if not charged[name] then
                                fixed = fixed + cost
                            end
                        end
                    end
                    local grant = (limit - spent - RUN_COST - fixed) // declared.perUnit
                    if grant >= 1 then
                        local cap, want = declared.maxUnits, instance.want
                        if type(want) == "number" and want < cap then
                            cap = want >= 1 and floor(want) or 1
                        end
                        if grant > cap then
                            grant = cap
                        end
                        spent = spent + RUN_COST + fixed + grant * declared.perUnit
                        planned = planned + 1
                        runTotal = runTotal + 1
                        records[planned], stages[planned], grants[planned] = record, stage, grant
                        record.state = "planned"
                        taken = taken + 1
                        exclusive = exclusive or decl.exclusive
                        if shared then
                            sharedUsed = true
                            for name in pairs(shared) do
                                charged[name] = true
                            end
                        end
                    end
                end
            end
        end
        examinedTotal = examinedTotal + examined
        if taken > 0 then
            compact(list, examined, taken)
        end
    end
    if sharedUsed then
        for name in pairs(charged) do
            charged[name] = nil
        end
    end
    local plan = self.lastPlan
    plan.kind, plan.U, plan.examined, plan.ran = kind, overhead + used + FIXED_COST + spent, examinedTotal, runTotal
    plan.charged = FIXED_COST + examinedTotal * EXAMINE_COST + runTotal * RUN_COST

    for index = 1, planned do
        local record = records[index]
        records[index] = nil
        if record.state == "planned" then
            local instance = record.instance
            local ok, delay = pcall(instance.step, instance, grants[index], stages[index], now)
            if record.state ~= "planned" then
                -- Removed by its own step: nothing to put back or report.
            elseif not ok then
                retire(self, record, tostring(delay))
            elseif type(delay) ~= "number" or not (delay >= 1) or delay % 1 ~= 0 then
                retire(self, record, "step returned an invalid delay: " .. tostring(delay))
            else
                local due = now + delay
                record.due, record.key, record.state = due, due * ORDER + record.key % ORDER, "listed"
                insert(record.list, record)
            end
        end
    end
    return planned
end

return scheduler
