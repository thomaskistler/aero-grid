-- SPDX-License-Identifier: GPL-2.0-only

-- Declared bounds of the audited tasks (plans/scheduler-contracts.md), keyed by
-- the label the native audit uses in tests/fixtures/scheduler-traces. They are
-- the legacy granularity of the audit, not the final per-task declarations.
local function once(bound)
    return { fixed = 0, perUnit = bound, maxUnits = 1 }
end

return {
    tasks = {
        ["service:telemetry:source:recorded"] = {
            class = "critical",
            fixed = 480,
            perUnit = 320,
            maxUnits = 24,
        },
        ["service:telemetry:source:plain"] = {
            class = "critical",
            fixed = 0,
            perUnit = 320,
            maxUnits = 1,
        },
        ["service:telemetry:source:recorded-one"] = {
            class = "critical",
            fixed = 0,
            perUnit = 740,
            maxUnits = 1,
        },
        ["service:telemetry:maintenance"] = {
            class = "critical",
            fixed = 450,
            perUnit = 10,
            maxUnits = 128,
        },
    },
    bounds = {
        ["telemetry:link"] = once(5),
        ["telemetry:poll"] = once(500),
        ["history:sample"] = once(800),
        ["service:telemetry:maintenance"] = once(420),
        ["chart:frame-begin"] = once(1300),
        ["chart:frame-idle"] = once(1300),
        ["chart:axis"] = once(900),
        ["chart:traces-select"] = once(7800),
        ["chart:traces-project"] = { fixed = 200, perUnit = 830, maxUnits = 9 },
        ["chart:traces-apply"] = once(1300),
        ["chart:flights"] = once(500),
        ["chart:arms"] = once(300),
        ["chart:resumes"] = once(300),
        ["flight:tick"] = once(3600),
        ["flight:pollReset"] = once(620),
        ["service:telemetry"] = { fixed = 750, perUnit = 1180, maxUnits = 8 },
        ["service:armed"] = { fixed = 180, perUnit = 120, maxUnits = 6 },
        ["service:control"] = { fixed = 1300, perUnit = 220, maxUnits = 6 },
        ["service:control-normal"] = { fixed = 130, perUnit = 240, maxUnits = 6 },
        ["service:history"] = { fixed = 410, perUnit = 90, maxUnits = 16 },
        ["reset:extrema"] = once(200),
        ["reset:history"] = once(200),
        ["reset:navigation"] = once(200),
        ["panel:chart:resetSession"] = once(1200),
        ["panel:flight-counter:refresh"] = once(700),
        ["panel:metric:refresh"] = once(4800),
        ["load:theme-read"] = once(10000),
        ["load:header"] = once(3600),
        ["load:header-finalize"] = once(5100),
        ["load:tokenize"] = once(2300),
        ["load:services"] = once(1000),
        ["load:panel-prepare:chart"] = once(2100),
        ["load:panel-prepare:flight-counter"] = once(1200),
        ["load:panel-prepare:metric"] = once(1340),
        ["load:panel-build:chart"] = once(11400),
        ["load:panel-build:flight-counter"] = once(5900),
        ["load:panel-build:metric"] = once(7000),
    },
    -- Labels the contracts give no bound: loader detail and one-line hooks.
    unbounded = {
        ["lifecycle:updateEmptyHint"] = true,
        ["load:header-migrate"] = true,
        ["load:panel-migrate"] = true,
        ["load:panel-validate:chart"] = true,
        ["load:panel-validate:flight-counter"] = true,
        ["load:panel-validate:metric"] = true,
        ["load:panels"] = true,
        ["load:read"] = true,
        ["load:theme-validate"] = true,
    },
    -- Bounds above the maximum task size that the migration must split (spec 4.2).
    splitBeforeMigration = {
        ["chart:traces-select"] = true,
        ["panel:metric:refresh"] = true,
        ["load:theme-read"] = true,
        ["load:header-finalize"] = true,
        ["load:panel-build:chart"] = true,
        ["load:panel-build:flight-counter"] = true,
        ["load:panel-build:metric"] = true,
    },
}
