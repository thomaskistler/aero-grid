-- SPDX-License-Identifier: GPL-2.0-only

--- Offline scheduler simulator: the real planner on a virtual clock.
---
--- Tasks are stubs built from real declarations. A stub step charges a virtual
--- cost (by default the declared bound), may change its own `stage` and `want`,
--- and returns a scripted delay. Every callback yields a report; nothing here
--- uses a clock or randomness except the seeded generator below.

local sim = {}
sim.__index = sim

sim.FIRMWARE_LIMIT = 20000

--- Deterministic integer generator: `next(low, high)` is in [low, high].
function sim.random(seed)
    local state = seed % 2147483647
    return function(low, high)
        state = (state * 1103515245 + 12345) & 0x7fffffff
        return low + (state >> 8) % (high - low + 1)
    end
end

--- `scheduler` is the library module; `overhead` maps callback kinds to costs.
function sim.new(scheduler, overhead)
    return setmetatable({
        scheduler = scheduler,
        library = scheduler.new(overhead),
        overhead = overhead,
        stubs = {},
        reports = {},
        maxActual = 0,
        overruns = 0,
        maxWait = {},
        runs = {},
    }, sim)
end

local function bound(decl, stage, grant)
    local declared = decl.stages[stage]
    return declared.fixed + grant * declared.perUnit
end
sim.bound = bound

--- Add a stub task. `spec` fields: `id`, `decl`, `due`, `delay` (ticks, or a
--- function of the stub and `now`), `cost` (a function of the stub, stage and
--- grant; default the declared bound), `units` (units consumed; default the
--- grant), `after` (called after each step to change `stage` or `want`), `stage`,
--- `want`, `fail` (a function that may raise).
function sim:add(spec)
    self.added = (self.added or 0) + 1
    local stub = {
        id = spec.id,
        spec = spec,
        stage = spec.stage,
        want = spec.want,
        dueAt = spec.due or 0,
        seq = self.added,
    }
    local owner = self
    function stub.step(instance, grant, stage, now)
        local report = owner.current
        if spec.fail then
            spec.fail(instance, grant, stage, now)
        end
        local cost = spec.cost and spec.cost(instance, stage, grant) or bound(spec.decl, stage, grant)
        for name, shared in pairs(spec.decl.shared or {}) do
            if not report.sharedCharged[name] then
                report.sharedCharged[name] = true
                cost = cost + shared
            end
        end
        local wait = now - instance.dueAt
        instance.used = spec.units and spec.units(instance, grant) or grant
        report.plan[#report.plan + 1] = {
            id = spec.id,
            stage = stage,
            grant = grant,
            used = instance.used,
            cost = cost,
            wait = wait,
        }
        report.spent = report.spent + cost
        if wait > (owner.maxWait[spec.id] or -1) then
            owner.maxWait[spec.id] = wait
        end
        owner.runs[spec.id] = (owner.runs[spec.id] or 0) + 1
        if owner.faults then
            report.excess = report.excess + (owner.faults(report.index, spec.id, stage, grant) or 0)
        end
        if spec.after then
            spec.after(instance, stage, grant)
        end
        local delay = spec.delay
        if type(delay) == "function" then
            delay = delay(instance, now)
        end
        instance.dueAt = now + (delay or 1)
        return delay
    end
    self.stubs[spec.id] = stub
    local ok, message = self.library:add({ id = spec.id, decl = spec.decl, instance = stub, due = spec.due })
    assert(ok, message)
    return stub
end

--- Run one callback and return its report: `plan` (id, stage, grant, cost, wait
--- per step), `U` (the planner's total), `actual` (the instructions the
--- callback really used: the planner's measured-bounded charge, the stubs' costs
--- and injected excess), `used` and `now`.
function sim:callback(kind, now, used)
    used = used or 0
    local report = {
        kind = kind,
        now = now,
        used = used,
        plan = {},
        spent = 0,
        excess = 0,
        sharedCharged = {},
        index = #self.reports + 1,
    }
    self.current = report
    self.library:run(kind, now, used)
    self.current = nil
    report.U = self.library.lastPlan.U
    if self.burst then
        report.excess = report.excess + (self.burst(report.index, report) or 0)
    end
    report.actual = self.overhead[kind] + used + report.spent + self.library.lastPlan.charged + report.excess
    if report.actual > self.maxActual then
        self.maxActual = report.actual
    end
    if report.actual >= sim.FIRMWARE_LIMIT then
        self.overruns = self.overruns + 1
    end
    self.reports[#self.reports + 1] = report
    return report
end

--- A callback schedule with gaps of `low` to `high` ticks, as `{ kind, now, used }`.
function sim.schedule(seed, count, low, high, kind)
    local random = sim.random(seed)
    local list, now = {}, 0
    for index = 1, count do
        now = now + random(low, high)
        list[index] = { kind = kind or "steady", now = now, used = 0 }
    end
    return list
end

function sim:run(schedule)
    for _, item in ipairs(schedule) do
        self:callback(item.kind, item.now, item.used)
    end
end

--- Run `ticks` ticks of callbacks every `gap` ticks.
function sim:runEvery(gap, ticks, kind, used)
    for now = gap, ticks, gap do
        self:callback(kind or "steady", now, used)
    end
end

return sim
