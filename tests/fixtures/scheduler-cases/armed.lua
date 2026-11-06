-- SPDX-License-Identifier: GPL-2.0-only

-- Worst first-resolution reads for unique arm conditions at every cursor and grant.
return function(load)
    local services = load("lib/services.lua")
    local controlService = load("lib/control_service.lua")
    local armedService = load("lib/armed_service.lua")
    local NOW, SWITCHES = 1000000, 6

    local function setup(start)
        return function(seed)
            local env = services.environment({
                getTime = function()
                    return NOW
                end,
                getSwitchIndex = function(name)
                    return name == "SFv" and 1 or tonumber(string.match(name, "%d+")) or 1
                end,
                getSwitchValue = function(index)
                    return (index + seed) % 2 == 0
                end,
            })
            local runtime = services.runtime(env)
            runtime.host = {}
            local control = controlService.new(env, services, runtime)
            runtime.byId.control = control
            runtime.byId.armed = armedService.new(env, services, runtime)
            local armed = runtime.byId.armed
            for index = 1, SWITCHES do
                armed:state(string.format("L%02d", index))
            end
            armed.cursor = start
            return armed.task, NOW
        end
    end

    local cases = {}
    for start = 1, SWITCHES do
        for grant = 1, armedService.decl.stages.run.maxUnits do
            cases[#cases + 1] = { stage = "run", grant = grant, setup = setup(start) }
        end
    end
    return {
        id = "service:armed",
        decl = armedService.decl,
        cases = cases,
    }
end
