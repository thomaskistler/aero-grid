-- SPDX-License-Identifier: GPL-2.0-only

-- Measure partial and full reads with the largest legal 32-channel output panel.
return function(load)
    local services = load("lib/services.lua")
    local controlService = load("lib/control_service.lua")
    local NOW, OUTPUTS = 1000000, 32

    local function setup(start)
        return function(seed)
            local env = services.environment({
                getOutputValue = function(index)
                    return index * 32 + seed
                end,
            })
            local service = controlService.new(env, services, { host = true })
            for index = 0, OUTPUTS - 1 do
                service:output(index)
            end
            service.outputCursor = start
            return service.tasks.outputs, NOW
        end
    end

    local cases = {}
    for _, start in ipairs({ 1, 16, 32 }) do
        for grant = 1, controlService.TASK_DECLARATIONS.outputs.stages.run.maxUnits do
            cases[#cases + 1] = { stage = "run", grant = grant, setup = setup(start) }
        end
    end
    return {
        id = "service:control-outputs",
        decl = controlService.TASK_DECLARATIONS.outputs,
        cases = cases,
    }
end
