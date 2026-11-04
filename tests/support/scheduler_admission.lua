-- SPDX-License-Identifier: GPL-2.0-only

--- Design-time admission test of the scheduler specification (section 3, A to E),
--- for one ownership configuration and callback kind.
---
--- A critical load is a list of periodic releases `{ decl, interval, units }` in
--- registration order (`units` defaults to the first stage's `maxUnits`). Callbacks
--- come every `admission.SPACING` ticks and releases are staggered by
--- `scheduler.stagger`; the peak is the largest cost due in one callback, a
--- `shared` cost counted once per callback.

local admission = {}

admission.SPACING = 5
admission.MAX_SIZE = 4000

local function releaseCost(decl, units)
    local stage = decl.stages[decl.first or "run"]
    return stage.fixed + (units or stage.maxUnits) * stage.perUnit
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
                load = load + releaseCost(release.decl, release.units)
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

--- Check A to E. `config`: `scheduler` (the library), `overhead` (declared for the
--- kind), `head` (largest `used` the host passes), `legacy` (the capped legacy share
--- `L`), `releases` (critical load), `decls` (every declaration that may run,
--- default those of the releases) and `legacyBounds` (declared bound of each legacy
--- item). Returns `{ base, peak, sustained, failures }`; `failures` lists the tests
--- that fail, by letter.
function admission.check(config)
    local scheduler = config.scheduler
    local base = scheduler.CEILING - scheduler.MARGIN - config.overhead - (config.head or 0) - (config.legacy or 0)
    local peak, sustained = admission.load(scheduler, config.releases)
    local decls = config.decls
    if not decls then
        decls = {}
        for _, release in ipairs(config.releases) do
            decls[#decls + 1] = release.decl
        end
    end
    local failures = {}
    local function fail(letter, message)
        failures[#failures + 1] = letter .. ": " .. message
    end
    for _, decl in ipairs(decls) do
        for name, stage in pairs(decl.stages) do
            local smallest = stage.fixed + stage.perUnit
            if smallest > base - peak then
                fail("A", "stage " .. name .. " (" .. smallest .. ") does not fit beside the peak " .. peak)
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
    for name, bound in pairs(config.legacyBounds or {}) do
        if bound > (config.legacy or 0) then
            fail("D", "legacy item " .. name .. " (" .. bound .. ") is above the legacy share")
        end
    end
    return { base = base, peak = peak, sustained = sustained, failures = failures }
end

return admission
