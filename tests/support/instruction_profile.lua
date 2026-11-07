-- SPDX-License-Identifier: GPL-2.0-only

local root, costs, scenario, sink, declare = ...
local recorderModule = assert(loadfile(root .. "/tests/support/instruction_recorder.lua"))()
local count, pause = recorderModule.hookCounter()
local recorder = recorderModule.new(count, pause, sink)
recorder.scenario = scenario
local names, modules = setmetatable({}, { __mode = "k" }), setmetatable({}, { __mode = "k" })
local declarations = {}
local instrument

local function registerStages(_, ok, _, _, name, declaration)
    if not ok then
        return
    end
    names[declaration] = name
    for stage, entry in pairs(declaration.stages) do
        if declare then
            declare(name, stage, entry.maxUnits)
        else
            local key = name .. "|" .. stage
            declarations[key] = math.max(declarations[key] or 0, entry.maxUnits)
        end
    end
end

local function bindModule(_, ok, results, _, relative)
    if ok and instrument then
        instrument(relative, results[2])
    end
end

local function bindNames(instance)
    instance.stages = recorder:wrap(instance.stages, registerStages)
    instance.bind = recorder:wrap(instance.bind, bindModule)
end
bindNames(costs)

local function taskName(task)
    local name = names[task.decl]
    if name then
        return name
    end
    local category = type(task.id) == "string" and string.match(task.id, "^service:telemetry:source:([^:]+):")
    if category then
        return "telemetry." .. category
    end
    error("instruction recorder cannot identify task " .. tostring(task.id), 0)
end

instrument = function(relative, module)
    if type(module) ~= "table" or modules[module] then
        return
    end
    modules[module] = true
    if relative == "lib/costs.lua" then
        local new = module.new
        module.new = recorder:wrap(new, function(_, ok, results)
            if ok then
                bindNames(results[2])
            end
        end)
    elseif relative == "lib/services.lua" then
        local task = module.task
        module.task = recorder:wrap(task, function(_, ok, results, owner)
            if not ok then
                return
            end
            local result = results[2]
            if names[result.decl] or owner.id == "telemetry" or result.id == "service:flight"
                or result.id == "service:smart" then
                result.step = recorder:task(taskName, result.step)
            end
        end)
    end
    local name = names[module.decl]
    if name and type(module.step) == "function" then
        module.step = recorder:task(name, module.step)
    end
    if relative == "main.lua" then
        for _, kind in ipairs({ "create", "update", "refresh", "background" }) do
            assert(type(module[kind]) == "function", "missing widget callback " .. kind)
            module[kind] = recorder:callback(kind, module[kind])
        end
    end
end

local originalLoadfile = loadfile
loadfile = recorder:wrap(originalLoadfile, function(_, ok, results, filename)
    local chunk = ok and results[2]
    local relative = type(chunk) == "function" and type(filename) == "string" and (
        string.match(filename, "WIDGETS/AeroGrid/(.+%.lua)$")
        or string.match(filename, "build/test%-widget%-fixture/(.+%.lua)$")
    )
    if not relative then
        return
    end
    results[2] = recorder:wrap(chunk, function(_, chunkOk, values)
        if chunkOk then
            costs:bind(relative, values[2])
            instrument(relative, values[2])
        end
    end)
end)

return recorder, declarations
