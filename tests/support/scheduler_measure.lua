-- SPDX-License-Identifier: GPL-2.0-only

--- Per-task cost measurement (specification, section 6): measured costs in,
--- declared bounds out.
---
--- A case file returns `{ id, decl, cases }`. Each case is
--- `{ stage = "run", grant = 1, setup = function(seed) return instance, now end }`
--- and supplies only the stimulus: `setup` builds the instance in its worst
--- legal state for clock phase or seed `seed`. The harness calls the real
--- `step(instance, grant, stage, now)` inside one counter window.
---
--- `count()` is an exact instruction counter (native harness or
--- `overhead.hookCounter()`); `pause(flag)` excludes bookkeeping and may be nil.

local measure = {}

measure.SEEDS = 5
-- The contracts' margin rule: declared = ceil10(F * m + A).
measure.MARGIN = {
    critical = { factor = 1.25, constant = 100 },
    normal = { factor = 1.10, constant = 50 },
}
measure.WARN_HIGH = 0.9
measure.WARN_LOW = 0.6

local function ceil10(value)
    return math.ceil(value / 10 - 1e-9) * 10
end

--- A case file returns the case, or a function of `load(relative)` that builds it
--- from modules of the widget (`load("lib/model_service.lua")`), so the native
--- harness and the offline tests each supply their own loader.
function measure.open(loaded, load)
    if type(loaded) == "function" then
        return loaded(load)
    end
    return loaded
end

--- Worst measured cost per stage and grant: `worst[stage][grant]`.
function measure.run(case, count, pause)
    pause = pause or function() end
    local noop = function() end
    pause(true)
    local function window(step, instance, grant, stage, now)
        pause(false)
        local first = count()
        step(instance, grant, stage, now)
        local last = count()
        pause(true)
        return last - first
    end
    local probe = window(noop, nil, 0, "", 0)
    local worst = {}
    for _, item in ipairs(case.cases) do
        for seed = 1, measure.SEEDS do
            local instance, now = item.setup(seed)
            local cost = window(instance.step, instance, item.grant, item.stage, now or seed) - probe
            local grants = worst[item.stage] or {}
            worst[item.stage] = grants
            if cost > (grants[item.grant] or -1) then
                grants[item.grant] = cost
            end
        end
    end
    return worst
end

--- Fit `fixed + g * perUnit` over the measured grants so that it holds at every
--- measured point: `perUnit` is the steepest slope from one unit, `fixed` the
--- largest remaining offset. A stage measured only at one unit is indivisible.
---@param grants table<integer, integer> worst cost per grant
function measure.fit(grants)
    local base = grants[1]
    assert(base, "a stage needs a measurement at one unit")
    local perUnit = nil
    for grant, cost in pairs(grants) do
        if grant >= 2 then
            local slope = (cost - base) / (grant - 1)
            perUnit = math.max(perUnit or slope, slope)
        end
    end
    if perUnit == nil then
        return 0, base
    end
    perUnit = math.max(perUnit, 1)
    local fixed = 0
    for grant, cost in pairs(grants) do
        fixed = math.max(fixed, cost - grant * perUnit)
    end
    return fixed, perUnit
end

--- A declaration from fitted costs by the margin rule. A stage that is one
--- indivisible call carries the per-call constant; a divisible one carries it
--- on `fixed` only.
---@param class string "critical" or "normal"
---@param maxUnits integer
function measure.declare(class, fixed, perUnit, maxUnits)
    local rule = measure.MARGIN[class]
    if maxUnits == 1 then
        return { fixed = 0, perUnit = ceil10(rule.factor * (fixed + perUnit) + rule.constant), maxUnits = 1 }
    end
    return {
        fixed = fixed > 0 and ceil10(rule.factor * fixed + rule.constant) or 0,
        perUnit = ceil10(rule.factor * perUnit),
        maxUnits = maxUnits,
    }
end

--- Compare measurements with a declaration. Returns findings
--- `{ level, stage, grant, ratio }`; `level` is "exceeds" (a bug), "high" (above
--- 90% of the bound: re-declare) or "loose" (below 60%: wasted utilization).
function measure.check(decl, worst)
    local findings = {}
    for name, grants in pairs(worst) do
        local stage = decl.stages[name]
        for grant, cost in pairs(grants) do
            local ratio = cost / (stage.fixed + grant * stage.perUnit)
            local level = (ratio > 1 and "exceeds")
                or (ratio > measure.WARN_HIGH and "high")
                or (ratio < measure.WARN_LOW and "loose")
                or nil
            if level then
                findings[#findings + 1] = { level = level, stage = name, grant = grant, ratio = ratio }
            end
        end
    end
    table.sort(findings, function(a, b)
        return a.stage < b.stage or (a.stage == b.stage and a.grant < b.grant)
    end)
    return findings
end

--- The `stages` of a declaration proposed from measurements.
function measure.propose(case, worst)
    local stages = {}
    for name, grants in pairs(worst) do
        local fixed, perUnit = measure.fit(grants)
        local maxUnits = 1
        for grant in pairs(grants) do
            maxUnits = math.max(maxUnits, grant)
        end
        stages[name] = measure.declare(case.decl.class, fixed, perUnit, maxUnits)
    end
    return stages
end

--- The framework's own cost of one release of the real task: a planner pass that
--- plans and runs it alone, less what its step cost. `charged` is what the planner
--- charged for the pass (`lastPlan.charged`), which must cover `measured`. The
--- bracket around the step adds a few instructions that count as framework cost.
---@param scheduler table The scheduler library.
---@return { measured: integer, charged: integer }
function measure.planner(case, scheduler, count, pause)
    pause = pause or function() end
    pause(true)
    local function window(run)
        pause(false)
        local first = count()
        run()
        local last = count()
        pause(true)
        return last - first
    end
    local probe = window(function() end)
    local worst, charged = 0, 0
    for _, item in ipairs(case.cases) do
        for seed = 1, measure.SEEDS do
            local instance, now = item.setup(seed)
            local s = scheduler.new({ steady = 1250, background = 1130 })
            local tick = now or seed
            assert(s:add({ id = case.id, decl = case.decl, instance = instance, due = tick }))
            local step, inside = instance.step, 0
            instance.step = function(self, grant, stage, at)
                local first = count()
                local delay = step(self, grant, stage, at)
                inside = count() - first
                return delay
            end
            local total = window(function()
                s:run("steady", tick, 0)
            end)
            assert(s.lastPlan.ran == 1, "the task must be planned and run")
            worst = math.max(worst, total - inside - probe)
            charged = s.lastPlan.charged
        end
    end
    return { measured = worst, charged = charged }
end

--- Measure a case: `{ worst, proposed, findings }`, and `planner` when the
--- scheduler library is given.
function measure.report(case, count, pause, scheduler)
    local worst = measure.run(case, count, pause)
    return {
        worst = worst,
        proposed = measure.propose(case, worst),
        findings = measure.check(case.decl, worst),
        planner = scheduler and measure.planner(case, scheduler, count, pause) or nil,
    }
end

return measure
