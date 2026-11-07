-- SPDX-License-Identifier: GPL-2.0-only

-- Stimulus for the model service task (plans/scheduler-framework.md, section 6).
-- It measures the real `step` of the real service on every starting cursor and every
-- grant, with all seven facets a layout can subscribe to (identity, flight mode, TX
-- voltage, battery range and timers 0 to 2). Two states are measured, and the worst
-- one counts: every facet on its most expensive path (identity due, unnamed flight
-- mode, countdown timers past zero with an hours field), and the opposite one (named
-- mode, count-up timers, no identity read). The radio functions are stubs that
-- return a prepared table: a stub costs a few instructions that the C function does
-- not, so the figures are slightly high.
return function(load)
    local services = load("lib/services.lua")
    local scheduler = load("lib/scheduler.lua")
    local modelService = load("lib/model_service.lua")

    local FACETS = 7
    local NOW = 1000000

    local states = {
        {
            timer = { value = -3700, start = 7200, name = "Flight", persistent = 2, showElapsed = true },
            mode = { 8, "" },
            info = { name = "Model", bitmap = "plane.png", filename = "m1.yml", labels = "fpv" },
        },
        {
            timer = { value = 12345, start = 0, name = "", persistent = 0, showElapsed = false },
            mode = { 3, "Sport" },
            info = { name = "", bitmap = "", filename = "", labels = "" },
        },
    }
    local battery = { battMin = 6.4, battMax = 8.4, battWarn = 6.6 }

    local function setup(state, start)
        return function(seed)
            local timer, mode, info = state.timer, state.mode, state.info
            local env = services.environment({
                getValue = function()
                    return 7.9
                end,
                getFlightMode = function()
                    return mode[1], mode[2]
                end,
                getGeneralSettings = function()
                    return battery
                end,
                model = {
                    getInfo = function()
                        return info
                    end,
                    getTimer = function()
                        return timer
                    end,
                },
            })
            local service = modelService.new(env, services)
            service.tickElapsed = scheduler.elapsed
            service:identity()
            service:flightMode()
            service:txVoltage()
            service:batteryRange()
            for index = 0, 2 do
                service:timer(index)
            end
            service.cursor = (start + seed - 2) % FACETS + 1
            service.due = 0
            service.facets[1].state.nextRead = 0
            return service.tasks.run, NOW
        end
    end

    local cases = {}
    for _, state in ipairs(states) do
        for start = 1, FACETS do
            for grant = 1, modelService.decl.stages.run.maxUnits do
                cases[#cases + 1] = { stage = "run", grant = grant, setup = setup(state, start) }
            end
        end
    end
    return { id = "service:model", decl = modelService.decl, cases = cases }
end
