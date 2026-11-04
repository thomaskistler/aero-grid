-- SPDX-License-Identifier: GPL-2.0-only

--- Offline scheduler simulator: the real planner on a virtual clock.
---
--- Tasks are stubs built from real declarations. A stub step charges a virtual
--- cost (by default the declared bound), may change its own `stage` and `want`,
--- and returns a scripted delay. Every callback yields a report.
---
--- Time is logical (ticks from zero) in the stubs, the reports and the schedule;
--- the library sees `wrap32(start + logical)`, like EdgeTX's int32 `getTime()`
--- (which also wraps), so a run can start anywhere on the clock. With a
--- `count`/`pause` pair (see scheduler_overhead.lua) the planner's own cost is
--- measured in each callback instead of being taken from its charge.

local sim = {}
sim.__index = sim

sim.FIRMWARE_LIMIT = 20000

--- Wraps an integer to int32, whatever the width of the Lua integer.
function sim.wrap32(value)
    return ((value & 0xFFFFFFFF) ~ 0x80000000) - 0x80000000
end
local wrap32 = sim.wrap32

--- Deterministic integer generator: `next(low, high)` is in [low, high].
function sim.random(seed)
    local state = seed % 2147483647
    return function(low, high)
        state = (state * 1103515245 + 12345) & 0x7fffffff
        return low + (state >> 8) % (high - low + 1)
    end
end

-- The instructions the pause calls of a stub add to a measured callback.
local function calibrate(count, pause)
    local function window(fn)
        pause(false)
        local first = count()
        fn()
        local last = count()
        pause(true)
        return last - first
    end
    local noop = function() end
    local empty = window(noop)
    return window(function()
        pause(true)
        pause(false)
    end) - empty
end

--- `scheduler` is the library module; `overhead` maps callback kinds to costs.
--- `options`: `start` (clock offset, default 0), `count` and `pause`.
function sim.new(scheduler, overhead, options)
    options = options or {}
    local self = setmetatable({
        scheduler = scheduler,
        library = scheduler.new(overhead),
        overhead = overhead,
        start = options.start or 0,
        count = options.count,
        pause = options.pause,
        stubs = {},
        reports = {},
        maxActual = 0,
        overruns = 0,
        maxWait = {},
        runs = {},
        lastRun = {},
        maxGap = {},
    }, sim)
    if self.count then
        self.probe = calibrate(self.count, self.pause)
    end
    return self
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
--- `want`, `fail` (a function that may raise), `idle` (a function returning true
--- when the step finds its state moved on and does no work: it costs nothing and
--- pays no shared cost). A shared cost is paid by the first step that does work.
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
    local pause = self.pause or function() end
    function stub.step(instance, grant, stage)
        pause(true)
        local report = owner.current
        local now = report.now
        report.entered = report.entered + 1
        if spec.fail then
            local ok, message = pcall(spec.fail, instance, grant, stage, now)
            if not ok then
                pause(false)
                error(message, 0)
            end
        end
        local idle = spec.idle and spec.idle(instance, stage)
        local cost = 0
        if not idle then
            cost = spec.cost and spec.cost(instance, stage, grant) or bound(spec.decl, stage, grant)
            for name, shared in pairs(spec.decl.shared or {}) do
                if not report.sharedCharged[name] then
                    report.sharedCharged[name] = true
                    cost = cost + shared
                end
            end
        end
        local wait = now - instance.dueAt
        instance.used = idle and 0 or spec.units and spec.units(instance, grant) or grant
        report.plan[#report.plan + 1] = {
            id = spec.id,
            stage = stage,
            grant = grant,
            used = instance.used,
            cost = cost,
            wait = wait,
            idle = idle or nil,
        }
        report.spent = report.spent + cost
        if wait > (owner.maxWait[spec.id] or -1) then
            owner.maxWait[spec.id] = wait
        end
        local previous = owner.lastRun[spec.id]
        if previous and now - previous > (owner.maxGap[spec.id] or 0) then
            owner.maxGap[spec.id] = now - previous
        end
        owner.lastRun[spec.id] = now
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
        pause(false)
        return delay
    end
    self.stubs[spec.id] = stub
    local ok, message = self.library:add({
        id = spec.id,
        decl = spec.decl,
        instance = stub,
        due = wrap32(self.start + (spec.due or 0)),
    })
    assert(ok, message)
    return stub
end

--- Run one callback and return its report: `plan` (id, stage, grant, cost, wait
--- per step), `U` (the planner's total), `actual` (the instructions the
--- callback really used: the host's overhead and `used`, the stubs' costs, the
--- planner's own cost as measured when the simulator has a counter, else as
--- charged, and injected excess), `framework`, `charged`, `used` and `now`.
function sim:callback(kind, now, used)
    used = used or 0
    local report = {
        kind = kind,
        now = now,
        used = used,
        plan = {},
        spent = 0,
        excess = 0,
        entered = 0,
        sharedCharged = {},
        index = #self.reports + 1,
    }
    self.current = report
    local tick = wrap32(self.start + now)
    if self.count then
        local noop = function() end
        local count, pause = self.count, self.pause
        pause(false)
        local first = count()
        noop(self.library, kind, tick, used)
        local mid = count()
        self.library:run(kind, tick, used)
        local last = count()
        pause(true)
        report.framework = (last - mid) - (mid - first) - self.probe * report.entered
    end
    if not self.count then
        self.library:run(kind, tick, used)
    end
    self.current = nil
    local plan = self.library.lastPlan
    report.U, report.charged = plan.U, plan.charged
    if self.burst then
        report.excess = report.excess + (self.burst(report.index, report) or 0)
    end
    report.actual = self.overhead[kind] + used + report.spent + (report.framework or plan.charged) + report.excess
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
