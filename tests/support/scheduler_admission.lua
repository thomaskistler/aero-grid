-- SPDX-License-Identifier: GPL-2.0-only

--- Design-time admission test of the scheduler specification (section 3, A to E),
--- for one ownership configuration and callback kind.
---
--- A critical load is a list of periodic releases `{ decl, interval, units }` in
--- registration order (`units` defaults to the first stage's `maxUnits`). Callbacks
--- come every `admission.SPACING` ticks and releases are staggered by
--- `scheduler.stagger`; the peak is the largest cost due in one callback, a
--- `shared` cost counted once per callback. Every release also costs what the
--- planner charges to examine and run a task, so the peak and the sustained
--- load include it, and a callback's fixed charge comes off the base.

local admission = {}

admission.SPACING = 5
admission.MAX_SIZE = 4000
-- A task whose release is below this spends more than a tenth of it on the
-- planner's run charge. The charge is read from the library when checking.
admission.MIN_FACTOR = 10

local function releaseCost(scheduler, decl, units)
    local stage = decl.stages[decl.first or "run"]
    return stage.fixed + (units or stage.maxUnits) * stage.perUnit + scheduler.EXAMINE_COST + scheduler.RUN_COST
end

--- `{ peak, sustained }` of the load: the largest and the mean cost per callback.
function admission.load(scheduler, releases)
    local longest = 0
    local state = {}
    for index, release in ipairs(releases) do
        longest = math.max(longest, release.interval)
        state[index] = { due = scheduler.stagger(index - 1, release.interval) }
    end
    local peak, total, callbacks = 0, 0, 0
    for now = 0, 4 * longest, admission.SPACING do
        local load, charged = 0, {}
        for index, release in ipairs(releases) do
            if state[index].due <= now then
                load = load + releaseCost(scheduler, release.decl, release.units)
                for name, cost in pairs(release.decl.shared or {}) do
                    if not charged[name] then
                        charged[name] = true
                        load = load + cost
                    end
                end
                state[index].due = now + release.interval
            end
        end
        peak = math.max(peak, load)
        total, callbacks = total + load, callbacks + 1
    end
    return peak, total / callbacks
end

--- The smallest release worth a task of its own: a tenth of it is the run charge.
function admission.minimumPiece(scheduler)
    return math.max(1000, admission.MIN_FACTOR * scheduler.RUN_COST)
end

--- Check A to C and E. `config`: `scheduler` (the library), `overhead` (declared
--- for the kind), `head` (largest `used` the host passes), `legacy` (declared
--- legacy work reserved in the feasibility model), `releases` (critical load),
--- and `decls` (every declaration that may run, default those of the releases).
--- Returns `{ base, peak, sustained, failures, small }`; `failures` lists the
--- tests that fail, by letter, `small` the stages whose smallest release is
--- below the minimum piece (information, not a failure).
function admission.check(config)
    local scheduler = config.scheduler
    local base = scheduler.CEILING
        - scheduler.MARGIN
        - scheduler.FIXED_COST
        - config.overhead
        - (config.head or 0)
        - (config.legacy or 0)
    local peak, sustained = admission.load(scheduler, config.releases)
    local decls = config.decls
    if not decls then
        decls = {}
        for _, release in ipairs(config.releases) do
            decls[#decls + 1] = release.decl
        end
    end
    local failures, small = {}, {}
    local function fail(letter, message)
        failures[#failures + 1] = letter .. ": " .. message
    end
    for _, decl in ipairs(decls) do
        for name, stage in pairs(decl.stages) do
            local smallest = stage.fixed + stage.perUnit
            local charge = scheduler.EXAMINE_COST + scheduler.RUN_COST
            if smallest + charge > base - peak then
                fail("A", "stage " .. name .. " (" .. smallest .. ") does not fit beside the peak " .. peak)
            end
            if stage.maxUnits == 1 and smallest < admission.minimumPiece(scheduler) then
                small[#small + 1] = name
            end
            if smallest > admission.MAX_SIZE then
                fail("E", "stage " .. name .. " (" .. smallest .. ") is above the maximum task size")
            end
        end
    end
    if sustained > base - scheduler.NORMAL_RESERVE then
        fail("B", "sustained load " .. math.floor(sustained) .. " is above " .. (base - scheduler.NORMAL_RESERVE))
    end
    if peak > base - scheduler.NORMAL_RESERVE then
        fail("C", "peak " .. peak .. " is above " .. (base - scheduler.NORMAL_RESERVE))
    end
    return { base = base, peak = peak, sustained = sustained, failures = failures, small = small }
end

return admission
