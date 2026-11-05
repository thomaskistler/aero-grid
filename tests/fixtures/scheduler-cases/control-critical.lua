-- SPDX-License-Identifier: GPL-2.0-only

-- Worst first-resolution reads for the switch conditions needed by flight and
-- recording boundaries.
return function(load)
    local services = load("lib/services.lua")
    local scheduler = load("lib/scheduler.lua")
    local controlService = load("lib/control_service.lua")
    local NOW, SWITCHES = 1000000, 6

    local function setup(start)
        return function(seed)
            local env = services.environment({
                getSwitchIndex = function()
                    return 1
                end,
                getSwitchValue = function()
                    return seed % 2 == 0
                end,
            })
            local service = controlService.new(env, services, { host = true })
            for index = 1, SWITCHES do
                service:switch(string.format("L%02d", index))
            end
            service.criticalCursor = start
            return service.criticalTask, NOW
        end
    end

    local cases = {}
    for start = 1, SWITCHES do
        for grant = 1, controlService.TASK_DECLARATIONS.critical.stages.run.maxUnits do
            cases[#cases + 1] = { stage = "run", grant = grant, setup = setup(start) }
        end
    end
    return {
        id = "service:control",
        decl = controlService.TASK_DECLARATIONS.critical,
        cases = cases,
    }
end
