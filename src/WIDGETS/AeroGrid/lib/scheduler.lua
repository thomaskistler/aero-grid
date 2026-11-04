-- SPDX-License-Identifier: GPL-2.0-only

--- Budgeted task scheduler (specification: plans/scheduler-framework.md).
---
--- Tasks declare a worst-case cost per stage. Each callback the planner admits
--- ready tasks against a fixed budget, oldest release first, so the plan never
--- exceeds the ceiling. The planner charges its own cost to the same budget.
--- Planning never reads `getUsage`. Nothing in the widget calls this library yet.
---
--- A task is `{ id, decl, instance, due }`. `decl` is shared by all tasks of a
--- type:
---   class = "critical" | "normal"
---   exclusive = true      at most one exclusive task per callback
---   shared = { name = cost }   at most two; charged once per plan to the first
---                         task planned, whoever then pays it (a name has one cost)
---   kinds = { steady = true, background = true }   default: both
---   first = "run"         stage the instance starts in
---   stages = { run = { fixed = F, perUnit = U, maxUnits = N } }
--- The instance has `step(instance, grant, stage, now) -> delay` (a whole number
--- of ticks, 1 to MAX_DELAY) and may keep `stage` and `want` current. `step` runs
--- exactly the planned stage with at most `grant` units, or does no work and
--- returns 1.
---
--- Time is the host's tick counter, which wraps like EdgeTX's int32 `getTime()`:
--- the library only uses differences, kept relative to an epoch that moves
--- forward, so no stored value grows past about 2^30. The dues given to `add`
--- must lie within about 2^30 ticks of each other and of the clock, as `now +
--- offset` does. All numbers are integers; EdgeTX Lua has 32-bit integers.

local scheduler = {
    CEILING = 15000,
    MARGIN = 400,
    NORMAL_RESERVE = 2000,
    MAX_TASKS = 128,
    MAX_DELAY = 1 << 30,
    -- The planner's own cost, charged against the budget: a callback, a task
    -- examined, a task run or retired. Upper bounds from the instruction counts
    -- of tests/support/scheduler_overhead.lua, which fails if one is exceeded.
    FIXED_COST = 120,
    EXAMINE_COST = 52,
    RUN_COST = 176,
    -- Moving the epoch (once per 2^29 ticks): a fixed part and one per task.
    REBASE_COST = 60,
    REBASE_TASK_COST = 16,
}
scheduler.__index = scheduler

local CEILING, MARGIN, NORMAL_RESERVE = scheduler.CEILING, scheduler.MARGIN, scheduler.NORMAL_RESERVE
local MAX_TASKS, MAX_DELAY = scheduler.MAX_TASKS, scheduler.MAX_DELAY
local FIXED_COST, EXAMINE_COST, RUN_COST = scheduler.FIXED_COST, scheduler.EXAMINE_COST, scheduler.RUN_COST
local REBASE_COST, REBASE_TASK_COST = scheduler.REBASE_COST, scheduler.REBASE_TASK_COST
local STEADY_AND_BACKGROUND = { steady = true, background = true }
local STAGGER_SPACING = 5
local MAX_SHARED = 2

-- Moves the epoch forward when the relative clock gets this far, and keeps a
-- task that has waited longer than FLOOR from falling off the int32 range.
local REBASE = 1 << 29
local FLOOR = -(1 << 30)
-- Sign extension of the low 32 bits: wraps a difference of ticks on any Lua.
local MASK, SIGN = 0xFFFFFFFF, 0x80000000

local floor, pcall, type = math.floor, pcall, type
local tointeger, mtype = math.tointeger, math.type
local move = table.move

local CRITICAL, NORMAL = 1, 2
local CLASS = { critical = CRITICAL, normal = NORMAL }
local RESERVE = { NORMAL_RESERVE, 0 }

local function whole(value)
    return mtype(value) == "integer"
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
    local slots = (interval + STAGGER_SPACING - 1) // STAGGER_SPACING
    return STAGGER_SPACING * (index % (slots > 1 and slots or 1))
end

--- `overhead[kind]` is the host's declared fixed cost of a callback of that kind.
---@param overhead table<string, integer>
function scheduler.new(overhead)
    return setmetatable({
        overhead = overhead,
        byId = {},
        count = 0,
        seq = 0,
        epoch = 0,
        stamp = 0,
        lists = { {}, {} },
        minStep = math.huge,
        errors = {},
        lastPlan = { kind = nil, U = 0, charged = 0, examined = 0, ran = 0 },
        planned = {},
        stages = {},
        grants = {},
        charged = {},
        sharedCost = {},
        metas = setmetatable({}, { __mode = "k" }),
    }, scheduler)
end

-- Lists are sorted by (due, seq). A task that ran usually goes to the end.
local function insert(list, record)
    local due, seq, size = record.due, record.seq, #list
    local last = size > 0 and list[size]
    if not last or last.due < due or (last.due == due and last.seq < seq) then
        list[size + 1] = record
        return
    end
    local low, high = 1, size
    while low < high do
        local middle = (low + high) // 2
        local at = list[middle]
        if at.due < due or (at.due == due and at.seq < seq) then
            low = middle + 1
        else
            high = middle
        end
    end
    table.insert(list, low, record)
end

-- The kinds a declaration runs in, checked against the host's kinds: a
-- misspelled kind or an empty set would silently never run. Returns the set,
-- or nil and a reason.
local function kindsOf(self, decl)
    local kinds = decl.kinds
    if kinds == nil then
        for kind in pairs(STEADY_AND_BACKGROUND) do
            if self.overhead[kind] ~= nil then
                return STEADY_AND_BACKGROUND
            end
        end
        return nil, "no callback kind of the host is eligible"
    end
    local any = false
    for kind, allowed in pairs(kinds) do
        if self.overhead[kind] == nil or type(allowed) ~= "boolean" then
            return nil, "kinds names an unknown callback kind or a non-boolean: " .. tostring(kind)
        end
        any = any or allowed
    end
    if not any then
        return nil, "kinds allows no callback"
    end
    return kinds
end

-- A stage that cannot fit the room of any eligible kind would never run and
-- would be charged every callback.
local function neverFits(self, decl, kinds)
    local reserve = decl.class == "critical" and NORMAL_RESERVE or 0
    local shared = 0
    for _, cost in pairs(decl.shared or {}) do
        shared = shared + cost
    end
    for name, stage in pairs(decl.stages) do
        local need = stage.fixed + stage.perUnit + shared + EXAMINE_COST + RUN_COST
        local fits = false
        for kind, allowed in pairs(kinds) do
            local overhead = self.overhead[kind]
            if allowed and overhead and need <= CEILING - MARGIN - FIXED_COST - overhead - reserve then
                fits = true
            end
        end
        if not fits then
            return "stage " .. tostring(name) .. " (" .. need .. ") can never fit the room of its callback kinds"
        end
    end
    return nil
end

--- Register a task. Returns true, or false and a reason; a host must check it (the
--- list holds at most MAX_TASKS tasks). `due` is a tick of the host's clock. An
--- add during a plan takes effect at the next plan.
---@param task { id: any, decl: table, instance: table, due?: integer }
---@return boolean ok
---@return string? reason
function scheduler:add(task)
    local id, decl, instance, due = task.id, task.decl, task.instance, task.due
    if id == nil or self.byId[id] then
        return false, "id is missing or already registered"
    end
    if self.count >= MAX_TASKS then
        return false, "too many tasks"
    end
    if type(instance) ~= "table" or type(instance.step) ~= "function" then
        return false, "instance needs a step function"
    end
    if due == nil then
        due = 0
    elseif type(due) ~= "number" or not tointeger(due) then
        return false, "due must be a whole number of ticks"
    end
    local meta = self.metas[decl]
    if not meta then
        local message = scheduler.check(decl)
        if message then
            return false, message
        end
        local kinds, reason = kindsOf(self, decl)
        if not kinds then
            return false, reason
        end
        message = neverFits(self, decl, kinds)
        if message then
            return false, message
        end
        local shared = {}
        for name, cost in pairs(decl.shared or {}) do
            if self.sharedCost[name] ~= nil and self.sharedCost[name] ~= cost then
                return false, "shared cost " .. tostring(name) .. " is declared with two different costs"
            end
            shared[#shared + 1] = { name, cost }
        end
        for _, item in ipairs(shared) do
            self.sharedCost[item[1]] = item[2]
        end
        for _, stage in pairs(decl.stages) do
            if stage.fixed + stage.perUnit < self.minStep then
                self.minStep = stage.fixed + stage.perUnit
            end
        end
        -- One per declaration, so a task record stays small.
        meta = {
            list = self.lists[CLASS[decl.class]],
            kinds = kinds,
            stages = decl.stages,
            first = decl.first or "run",
            exclusive = decl.exclusive,
            s1 = shared[1] and shared[1][1],
            c1 = shared[1] and shared[1][2],
            s2 = shared[2] and shared[2][1],
            c2 = shared[2] and shared[2][2],
        }
        self.metas[decl] = meta
    end
    if self.seq == 0 then
        -- Dues are stored as offsets from an epoch near the first of them, so the
        -- order of the numbers is the order in time even where the clock wraps.
        self.epoch = tointeger(due)
    end
    self.seq = self.seq + 1
    self.count = self.count + 1
    local record = {
        id = id,
        instance = instance,
        meta = meta,
        list = meta.list,
        due = ((tointeger(due) - self.epoch) & MASK ~ SIGN) - SIGN,
        seq = self.seq,
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

-- Moves the epoch to now, so every stored due is a small offset from the present
-- and the raw order of the numbers is the order in time. Dues are shifted by the
-- same amount, which keeps their order; a task that has waited longer than FLOOR
-- (more than 120 days) is held at FLOOR and may lose its place among such tasks.
local function rebase(self, elapsed)
    self.epoch = ((self.epoch + elapsed) & MASK ~ SIGN) - SIGN
    for _, list in ipairs(self.lists) do
        for _, record in ipairs(list) do
            local due = ((record.due - elapsed) & MASK ~ SIGN) - SIGN
            record.due = due < FLOOR and FLOOR or due
        end
    end
end

--- The tick a task is next due at, in the host's clock, or nil.
---@param id any
---@return integer?
function scheduler:dueOf(id)
    local record = self.byId[id]
    return record and ((record.due + self.epoch) & MASK ~ SIGN) - SIGN
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
    local tick = type(now) == "number" and tointeger(now)
    if not tick then
        error("now must be a whole number of ticks", 2)
    end
    local t = ((tick - self.epoch) & MASK ~ SIGN) - SIGN
    local fixed = FIXED_COST
    if t >= REBASE then
        fixed = FIXED_COST + REBASE_COST + self.count * REBASE_TASK_COST
        rebase(self, t)
        t = 0
    end
    used = used or 0
    local room = CEILING - MARGIN - overhead - used - fixed
    local lists, charged = self.lists, self.charged
    local records, stages, grants = self.planned, self.stages, self.grants
    local smallest = self.minStep + EXAMINE_COST + RUN_COST
    local spent, planned, exclusive = 0, 0, false
    local examinedTotal, runTotal = 0, 0
    local stamp = self.stamp + 1
    self.stamp = stamp

    for class = 1, 2 do
        local list = lists[class]
        local limit = room - RESERVE[class]
        local examined, taken = 0, 0
        for index = 1, #list do
            local record = list[index]
            if record.due > t or limit - spent < smallest then
                break
            end
            examined = index
            spent = spent + EXAMINE_COST
            local meta = record.meta
            if meta.kinds[kind] and not (exclusive and meta.exclusive) then
                local instance = record.instance
                local stage = instance.stage or meta.first
                local declared = meta.stages[stage]
                if declared == nil then
                    retire(self, record, "unknown stage " .. tostring(stage))
                    taken = taken + 1
                    runTotal = runTotal + 1
                    spent = spent + RUN_COST
                else
                    -- Shared costs are looked at only for a task that fits without them.
                    local perUnit = declared.perUnit
                    local space = limit - spent - RUN_COST - declared.fixed
                    local grant = space // perUnit
                    local s1 = meta.s1
                    local extra = 0
                    if grant >= 1 and s1 then
                        if charged[s1] ~= stamp then
                            extra = meta.c1
                        end
                        local s2 = meta.s2
                        if s2 and charged[s2] ~= stamp then
                            extra = extra + meta.c2
                        end
                        if extra > 0 then
                            grant = (space - extra) // perUnit
                        end
                    end
                    if grant >= 1 then
                        local cap, want = declared.maxUnits, instance.want
                        if type(want) == "number" and want < cap then
                            cap = want >= 1 and floor(want) or 1
                        end
                        if grant > cap then
                            grant = cap
                        end
                        spent = spent + RUN_COST + declared.fixed + extra + grant * perUnit
                        planned = planned + 1
                        runTotal = runTotal + 1
                        records[planned], stages[planned], grants[planned] = record, stage, grant
                        record.state = "planned"
                        taken = taken + 1
                        exclusive = exclusive or meta.exclusive
                        if s1 then
                            charged[s1] = stamp
                            if meta.s2 then
                                charged[meta.s2] = stamp
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
    local plan = self.lastPlan
    plan.kind, plan.U, plan.examined, plan.ran = kind, overhead + used + fixed + spent, examinedTotal, runTotal
    plan.charged = fixed + examinedTotal * EXAMINE_COST + runTotal * RUN_COST

    for index = 1, planned do
        local record = records[index]
        records[index] = nil
        if record.state == "planned" then
            local instance = record.instance
            local ok, delay = pcall(instance.step, instance, grants[index], stages[index], tick)
            local ticks = ok and type(delay) == "number" and tointeger(delay)
            if record.state ~= "planned" then
                -- Removed by its own step: nothing to put back or report.
            elseif not ok then
                retire(self, record, tostring(delay))
            elseif not ticks or ticks < 1 or ticks > MAX_DELAY then
                retire(self, record, "step returned an invalid delay: " .. tostring(delay))
            else
                record.due, record.state = t + ticks, "listed"
                insert(record.list, record)
            end
        end
    end
    return planned
end

return scheduler
