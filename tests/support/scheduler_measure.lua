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

--- Measure a case: `{ worst, proposed, findings }`.
function measure.report(case, count, pause)
    local worst = measure.run(case, count, pause)
    return { worst = worst, proposed = measure.propose(case, worst), findings = measure.check(case.decl, worst) }
end

return measure
