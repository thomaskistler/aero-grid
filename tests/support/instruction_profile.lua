-- SPDX-License-Identifier: GPL-2.0-only

local root, costs, scenario, sink, declare = ...
local recorderModule = assert(loadfile(root .. "/tests/support/instruction_recorder.lua"))()
local count, pause = recorderModule.hookCounter()
local recorder = recorderModule.new(count, pause, sink)
recorder.scenario = scenario
local names, modules = setmetatable({}, { __mode = "k" }), setmetatable({}, { __mode = "k" })
local declarations = {}
local instrument
local foreground = {}

local function bound(name, stage, exclusive)
    if stage == nil then
        return
    end
    costs:bound(name, stage)
    return { name = name, stage = stage, exclusive = exclusive }
end

foreground["lib/model_settings_store.lua"] = function(module)
    module.new = recorder:wrap(module.new, function(_, ok, results)
        if not ok then return end
        local store = results[2]
        store.advanceLoad = recorder:bound(function(_, job)
            return bound("settings-store-load", type(job) == "table" and job.stage or nil)
        end, store.advanceLoad)
        store.advanceSave = recorder:bound(function(_, job)
            return bound("settings-store-save", type(job) == "table" and job.stage or nil)
        end, store.advanceSave)
        store.startLoad = recorder:bound(function()
            return bound("settings-store-load", "start")
        end, store.startLoad)
    end)
end

foreground["lib/log_viewer.lua"] = function(module)
    module.advance = recorder:bound(function(context)
        return bound("log-viewer", context.logViewer and module.stageOf(context.logViewer))
    end, module.advance)
    module.handle = recorder:bound(function()
        return bound("log-viewer", "input")
    end, module.handle)
end

foreground["lib/model_settings_ui.lua"] = function(module)
    module.advance = recorder:bound(function(context)
        local state = context.modelSettingsUi
        if not state then return end
        local stage, name, exclusive = module.stageOf(state), "settings-ui", false
        if string.sub(stage, 1, 5) == "save_" then
            stage, exclusive = "storeOverhead", true
        elseif string.sub(stage, 1, 5) == "load_" then
            stage = string.sub(stage, 6)
            if stage == "read" or stage == "parse" or stage == "build" or stage == "previous" then
                stage, exclusive = "storeOverhead", true
            else
                name = "settings-ui-load"
            end
        end
        if string.sub(stage, 1, 8) == "publish_" then stage = "publish" end
        if stage ~= "pending" then return bound(name, stage, exclusive) end
    end, module.advance)
end

foreground["lib/editor_drawer.lua"] = function(module)
    module.advance = recorder:bound(function(_, state)
        if module.workBound(state) == nil then return end
        local stage
        if state.drawerOpening then
            stage = state.drawerOpening.phase
        elseif state.drawerLayout then
            stage = "layout"
        elseif state.drawerRefresh then
            stage = state.drawerRefresh.phase
        elseif state.drawerBuild then
            stage = state.drawerBuild <= #state.drawerFields and "build" or "finish"
        elseif state.drawerPending then
            local action = state.drawerPending.action
            if action == "parent" or action == "item" then
                stage = "navigate"
            elseif action == "add" then
                stage = "add-" .. (state.drawerPending.phase or "module")
            else
                stage = action
            end
        end
        return bound("editor-drawer", stage)
    end, module.advance)
end

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
    local name = names[module.decl]
    if relative ~= "lib/costs.lua" and relative ~= "lib/services.lua" and relative ~= "main.lua"
        and relative ~= "lib/scheduler.lua"
        and not foreground[relative] and not (name and type(module.step) == "function") then
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
    elseif relative == "lib/scheduler.lua" then
        local steps = setmetatable({}, { __mode = "kv" })
        local ignore = function() end
        module.add = recorder:wrap(module.add, {
            before = function(_, task)
                if type(task) ~= "table" or type(task.instance) ~= "table"
                    or type(task.instance.step) ~= "function" then return end
                local fn = task.instance.step
                local wrapped = steps[fn]
                if not wrapped then
                    wrapped = recorder:wrap(fn, ignore)
                    steps[fn], steps[wrapped] = wrapped, wrapped
                end
                task.instance.step = wrapped
            end,
            after = ignore,
        })
        module.run = recorder:wrap(module.run, {
            before = function() end,
            after = function(_, own, _, ok, _, instance)
                if ok then
                    local plan = instance.lastPlan
                    recorder:sample("framework", "scheduler",
                        tostring(plan.examined) .. ":" .. tostring(plan.ran), 0, own, true)
                end
            end,
        })
    end
    if name and type(module.step) == "function" then
        module.step = recorder:task(name, module.step)
    end
    if foreground[relative] then foreground[relative](module) end
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
