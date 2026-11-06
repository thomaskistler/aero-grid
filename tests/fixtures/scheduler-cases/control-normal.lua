-- SPDX-License-Identifier: GPL-2.0-only

-- Normal control entry costs at the largest subscribed output-panel layout,
-- plus trim, global-variable, and display-only switch reads.
return function(load)
    local services = load("lib/services.lua")
    local controlService = load("lib/control_service.lua")
    local NOW, OUTPUTS = 1000000, 32

    local function setup(kind, start)
        return function(seed)
            local env = services.environment({
                getFieldInfo = function(name)
                    return {
                        id = type(name) == "number" and name or #name + 10,
                        name = type(name) == "string" and name or "A",
                    }
                end,
                getValue = function()
                    return seed % 2 == 0 and 128 or -128
                end,
                getFlightMode = function()
                    return 1
                end,
                getGlobalVariable = function(index)
                    return index * 10 + seed
                end,
                getGlobalVariableDetails = function(index)
                    return { name = "GV" .. tostring(index + 1), prec = 1, min = -100, max = 100, unit = 1 }
                end,
                getSwitchIndex = function(name)
                    return #name
                end,
                getSwitchValue = function()
                    return seed % 2 == 0
                end,
                getOutput = function(index)
                    return { name = "CH" .. tostring(index + 1) }
                end,
                getMix = function(_, line)
                    if line < 64 then
                        return { source = "A", name = "Mix", weight = 100, carryTrim = false }
                    end
                end,
            })
            local service = controlService.new(env, services, { host = true })
            if kind == "outputs" then
                for index = 0, OUTPUTS - 1 do
                    service:output(index)
                end
            elseif kind == "trims" then
                for index = 1, 6 do
                    service:trim("trim-" .. tostring(index))
                end
            elseif kind == "variables" then
                for index = 0, 5 do
                    service:globalVariable(index)
                end
            else
                for index = 1, 6 do
                    service:displaySwitch(string.format("L%02d", index))
                end
            end
            service.normalCursor = start
            return service.normalTask, NOW
        end
    end

    local cases = {}
    for _, kind in ipairs({ "outputs", "trims", "variables", "switches" }) do
        local starts = kind == "outputs" and { 1, 16, 32 } or { 1, 3, 6 }
        for _, start in ipairs(starts) do
            for grant = 1, controlService.TASK_DECLARATIONS.normal.stages.run.maxUnits do
                cases[#cases + 1] = { stage = "run", grant = grant, setup = setup(kind, start) }
            end
        end
    end
    return {
        id = "service:control-normal",
        decl = controlService.TASK_DECLARATIONS.normal,
        cases = cases,
    }
end
