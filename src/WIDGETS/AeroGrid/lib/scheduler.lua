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
--- Time is the host's tick counter, which wraps like EdgeTX's int32 `getTime()`.
--- Due times are stored as given (absolute ticks) and only ever compared by
--- difference, `scheduler.elapsed(a, b)`, which wraps on any Lua. That is exact
--- while two ticks are less than 2^31 apart: a task is at most MAX_DELAY (2^30)
--- ahead of the clock and runs when it is behind it, so a task starved for more
--- than 2^31 ticks (248 days) would look as if it were in the future. `step`
--- receives the host's `now` unchanged, not a stored value. All numbers are
--- integers; EdgeTX Lua has 32-bit integers.
---
--- `run` raises for a call the host got wrong (unknown kind, `now` or `used` not
--- a number). Everything a task supplies is validated by `add` or retires the
--- task. A step that adds or removes tasks costs instructions the planner does
--- not charge (`add` up to about 700 for a new declaration, about 400 otherwise,
--- `remove` about 400 with 128 tasks): it declares that margin in its bound.

local scheduler = {
    CEILING = 15000,
    MARGIN = 400,
    NORMAL_RESERVE = 2000,
    MAX_TASKS = 128,
    MAX_DELAY = 1 << 30,
    -- The planner's own cost, charged against the budget: a callback, a task
    -- examined, a task run or retired. Upper bounds from the instruction counts
    -- of tests/support/scheduler_overhead.lua, which fails if one is exceeded.
    FIXED_COST = 132,
    EXAMINE_COST = 64,
    RUN_COST = 224,
}
scheduler.__index = scheduler

local CEILING, MARGIN, NORMAL_RESERVE = scheduler.CEILING, scheduler.MARGIN, scheduler.NORMAL_RESERVE
local MAX_TASKS, MAX_DELAY = scheduler.MAX_TASKS, scheduler.MAX_DELAY
local FIXED_COST, EXAMINE_COST, RUN_COST = scheduler.FIXED_COST, scheduler.EXAMINE_COST, scheduler.RUN_COST
local STEADY_AND_BACKGROUND = { steady = true, background = true }
local STAGGER_SPACING = 5
local MAX_SHARED = 2

-- Sign extension of the low 32 bits: wraps a difference of ticks on any Lua
-- (the identity on EdgeTX's 32-bit integers). Written out where it is hot.
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

--- The wrap-safe difference `a - b` of two ticks, as a signed 32-bit number.
---@param a integer
---@param b integer
---@return integer
function scheduler.elapsed(a, b)
    return ((a - b) & MASK ~ SIGN) - SIGN
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
    if decl.shared ~= nil and type(decl.shared) ~= "table" then
        return "shared must be a table"
    end
    local names = 0
    for name, cost in pairs(decl.shared or {}) do
        names = names + 1
        if names > MAX_SHARED then
            return "at most " .. MAX_SHARED .. " shared costs (the charged run cost assumes it)"
        end
        if not whole(cost) or cost < 0 or cost > CEILING then
            return "shared cost " .. tostring(name) .. " must be an integer from 0 to the ceiling"
        end
    end
    for name, stage in pairs(decl.stages) do
        if
            type(stage) ~= "table"
            or not whole(stage.fixed)
            or stage.fixed < 0
            or stage.fixed > CEILING
            or not whole(stage.perUnit)
            or stage.perUnit < 1
            or stage.perUnit > CEILING
            or not whole(stage.maxUnits)
            or stage.maxUnits < 1
            or stage.maxUnits > CEILING
        then
            return "stage "
                .. tostring(name)
                .. " needs integers: fixed 0 to the ceiling, perUnit and maxUnits 1 to the ceiling"
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
    local slots = (floor(interval) + STAGGER_SPACING - 1) // STAGGER_SPACING
    return STAGGER_SPACING * (floor(index) % (slots > 1 and slots or 1))
end

--- `overhead[kind]` is the host's declared fixed cost of a callback of that kind.
---@param overhead table<string, integer>
function scheduler.new(overhead)
    return setmetatable({
        overhead = overhead,
        byId = {},
        count = 0,
        seq = 0,
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
        sharedRefs = {},
        metas = setmetatable({}, { __mode = "k" }),
    }, scheduler)
end

-- Lists are sorted by (due, seq), due by wrapped difference. A task that ran
-- usually goes to the end.
local function insert(list, record)
    local due, seq, size = record.due, record.seq, #list
    local last = list[size]
    if last then
        local d = ((last.due - due) & MASK ~ SIGN) - SIGN
        if d > 0 or (d == 0 and last.seq > seq) then
            local low, high = 1, size
            while low < high do
                local middle = (low + high) // 2
                local at = list[middle]
                d = ((at.due - due) & MASK ~ SIGN) - SIGN
                if d < 0 or (d == 0 and at.seq < seq) then
                    low = middle + 1
                else
                    high = middle
                end
            end
            table.insert(list, low, record)
            return
        end
    end
    list[size + 1] = record
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
--- list holds at most MAX_TASKS tasks). `due` is required: the tick of the host's
--- clock the task is first ready at (`now` plus a stagger offset), within 2^30
--- ticks of it. A declaration is read once; changing it afterwards has no effect.
--- An add during a plan takes effect at the next plan.
---@param task { id: any, decl: table, instance: table, due: integer }
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
    local tick = type(due) == "number" and tointeger(due)
    if not tick then
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
        -- Copies, so a host that changes its declaration cannot break the planner.
        local stages, shared = {}, {}
        for name, stage in pairs(decl.stages) do
            stages[name] = { fixed = stage.fixed, perUnit = stage.perUnit, maxUnits = stage.maxUnits }
            if stage.fixed + stage.perUnit < self.minStep then
                self.minStep = stage.fixed + stage.perUnit
            end
        end
        for name, cost in pairs(decl.shared or {}) do
            shared[#shared + 1] = { name, cost }
        end
        local copy = {}
        for kind, allowed in pairs(kinds) do
            copy[kind] = allowed
        end
        meta = {
            list = self.lists[CLASS[decl.class]],
            kinds = kinds == STEADY_AND_BACKGROUND and kinds or copy,
            stages = stages,
            first = decl.first or "run",
            exclusive = decl.exclusive,
            s1 = shared[1] and shared[1][1],
            c1 = shared[1] and shared[1][2],
            s2 = shared[2] and shared[2][1],
            c2 = shared[2] and shared[2][2],
        }
        self.metas[decl] = meta
    end
    -- A shared name has one cost while any task uses it.
    local costs = self.sharedCost
    if
        (meta.s1 and costs[meta.s1] ~= nil and costs[meta.s1] ~= meta.c1)
        or (meta.s2 and costs[meta.s2] ~= nil and costs[meta.s2] ~= meta.c2)
    then
        return false, "a shared cost is declared with two different costs"
    end
    for _, name in ipairs({ meta.s1 or false, meta.s2 or false }) do
        if name then
            costs[name] = name == meta.s1 and meta.c1 or meta.c2
            self.sharedRefs[name] = (self.sharedRefs[name] or 0) + 1
        end
    end
    self.seq = self.seq + 1
    self.count = self.count + 1
    local record = {
        id = id,
        instance = instance,
        meta = meta,
        list = meta.list,
        due = tick,
        seq = self.seq,
        state = "listed",
    }
    self.byId[id] = record
    insert(record.list, record)
    return true
end

-- Frees the shared names no other task uses.
local function release(self, meta)
    for _, name in ipairs({ meta.s1 or false, meta.s2 or false }) do
        if name then
            local refs = self.sharedRefs[name] - 1
            self.sharedRefs[name] = refs > 0 and refs or nil
            if refs <= 0 then
                self.sharedCost[name] = nil
            end
        end
    end
end

local function retire(self, record, message)
    record.state = "removed"
    self.byId[record.id] = nil
    self.count = self.count - 1
    release(self, record.meta)
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
    release(self, record.meta)
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

--- The tick a task is next due at, or nil.
---@param id any
---@return integer?
function scheduler:dueOf(id)
    local record = self.byId[id]
    return record and ((record.due & MASK) ~ SIGN) - SIGN
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
    if used == nil then
        used = 0
    elseif type(used) ~= "number" then
        error("used must be a number", 2)
    end
    local room = CEILING - MARGIN - overhead - used - FIXED_COST
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
            if ((record.due - tick) & MASK ~ SIGN) - SIGN > 0 or limit - spent < smallest then
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
    plan.kind, plan.U, plan.examined, plan.ran = kind, overhead + used + FIXED_COST + spent, examinedTotal, runTotal
    plan.charged = FIXED_COST + examinedTotal * EXAMINE_COST + runTotal * RUN_COST

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
                record.due, record.state = tick + ticks, "listed"
                insert(record.list, record)
            end
        end
    end
    return planned
end

return scheduler
