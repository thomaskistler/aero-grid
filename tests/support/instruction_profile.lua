-- SPDX-License-Identifier: GPL-2.0-only

local root, costs, scenario, sink, declare = ...
assert(declare, "instruction profile requires a declaration sink")
local recorderModule = assert(loadfile(root .. "/tests/support/instruction_recorder.lua"))()
local count, pause = recorderModule.hookCounter()
local recorder = recorderModule.new(count, pause, sink)
recorder.scenario = scenario
local names, modules = setmetatable({}, { __mode = "k" }), setmetatable({}, { __mode = "k" })
local instrument
local foreground = {}
local spans = {}
AUDIT_SPAN = function(label, fn, ...)
    local entries = spans[fn] or {}
    spans[fn] = entries
    local wrapped = entries[label]
    if not wrapped then
        wrapped = recorder:bound(function() return __instructionSpanBound(label) end, fn)
        entries[label] = wrapped
    end
    return wrapped(...)
end

foreground["lib/scheduler_host.lua"] = function(module)
    module.attach = recorder:wrap(module.attach, function(_, ok, results, context)
        if not ok then return end
        local host = results[2]
        host.ready = recorder:wrap(host.ready, {
            before = function()
                if host.reconciliation or host.checked ~= context.panels
                    or host.registry ~= context.serviceRuntime or context.panelTasksDirty then return "reconcile" end
                if host.pendingPanels then return "panelEnroll" end
                if host.waiting[1] then return "serviceEnroll" end
                return "settled"
            end,
            after = function(cost, _, stage, success)
                if stage == "settled" and host.panelSetup > 0 then stage = "reconcile" end
                if stage == "settled" then
                    host.instructionReady = cost
                else
                    recorder:sample("bound", "host", stage, 0, cost, success)
                end
            end,
        })
        host.finish = recorder:wrap(host.finish, {
            before = function(_, kind)
                return host.reconciliation and not host.reconciliation.servicesLive and "host-reconcile"
                    or kind or "steady"
            end,
            after = function(_, own, kind)
                host.instructionKind, host.instructionFinish = kind, own
            end,
        })
    end)
end

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
        return bound("log-viewer", context.logViewer and module.stageOf(context.logViewer) or "idle")
    end, module.advance)
    module.handle = recorder:bound(function()
        return bound("log-viewer", "input")
    end, module.handle)
end

foreground["lib/location_details.lua"] = function(module)
    module.handle = recorder:bound(function() return bound("main", "modalLocation") end, module.handle)
end

foreground["lib/theme.lua"] = function(module)
    module.advanceBuild = recorder:bound(function(work)
        local stage = work.stage
        if stage == "legibility" or stage == "chart" or stage == "alert" or stage == "display"
            or stage == "finalize" then return bound("theme-resolution", stage) end
    end, module.advanceBuild)
end

foreground["lib/aerogrid_menu.lua"] = function(module)
    module.ensure = recorder:callback("menu-ensure", module.ensure)
    module.close = recorder:bound(function() return bound("menu", "close") end, module.close)
    module.advance = recorder:bound(function(context)
        return bound("menu", context.aerogridMenu and context.aerogridMenu.pending and "pending" or "idle")
    end, module.advance)
end

foreground["lib/editor_ui.lua"] = function(module)
    module.handle = recorder:bound(function(context, event)
        if not module.inputWorkBound(context, event) then return end
        local state = context.editorUi
        local stage = state.drawerOpen and "cancel" or state.mode ~= "menu" and "modal" or nil
        if not stage then
            for key, candidate in pairs({
                EVT_VIRTUAL_ENTER = "open", EVT_TOUCH_TAP = "tap",
                EVT_VIRTUAL_PREV = "select", EVT_VIRTUAL_NEXT = "select",
                EVT_ROT_LEFT = "select", EVT_ROT_RIGHT = "select",
                EVT_TOUCH_BREAK = "release", EVT_TOUCH_FIRST = "first", EVT_TOUCH_SLIDE = "slide",
            }) do
                if _G[key] ~= nil and event == _G[key] then stage = candidate; break end
            end
        end
        assert(stage, "bounded editor input has no identified operation")
        return bound("editor-input", stage)
    end, module.handle)
end

foreground["lib/editor_controller.lua"] = function(module)
    module.new = recorder:wrap(module.new, function(_, ok, results)
        if not ok then return end
        local controller = results[2]
        controller.advanceEditor = recorder:bound(function(context)
            local ui = context.editorUi
            if not ui or ui.session.initializing then return end
            if ui.buildStage then return bound("main", "editorBuild") end
            if ui.drawerOpen then return bound("editor-drawer-open", ui.drawerOpen.mode) end
            if ui.previewPending or ui.previewRefresh or ui.exitCommand then return end
            local drag = context.editorUiModule.dragStage(ui)
            if drag then return bound("editor-drag", drag) end
            if ui.renderStage then
                if ui.renderStage == 1 and ui.handlers.layoutStep then
                    return bound("editor-layout", ui.layoutJob and ui.handlers.layoutStep(ui.layoutJob) or "visit")
                elseif ui.renderStage >= 2 then
                    return bound("editor-render", ui.renderStage == 6 and "finish" or "rows")
                end
            end
        end, controller.advanceEditor)
    end)
end

foreground["lib/dashboard_lifecycle.lua"] = function(module)
    module.new = recorder:wrap(module.new, function(_, ok, results)
        if not ok then return end
        local lifecycle = results[2]
        for _, method in ipairs({ "beginReflow", "advanceReflow", "advanceAppRebuild", "retirePage", "rebuildPage" }) do
            local name = method
            lifecycle[name] = recorder:wrap(lifecycle[name], {
                before = function(context)
                local label = "lifecycle:" .. name
                if name == "advanceReflow" then
                    local entry = context.panels[context.reflowIndex or 0]
                    if entry and not entry.failed then
                        label = label .. ":" .. entry.module.id .. ":work"
                    else
                        label = label .. (context.reflowIndex and not entry and ":finish" or ":skip")
                    end
                elseif name == "advanceAppRebuild" or name == "retirePage" then
                    local job = name == "retirePage" and context.pageRetirement or context.appRebuild
                    local phase = job and job.phase or (name == "retirePage" and "cancel" or "retire")
                    label = label .. ":" .. phase
                    if phase == "settings" and context.modelSettingsUi then label = label .. ":active" end
                end
                return __instructionSpanBound(label)
                end,
                after = function(cost, own, token, success)
                    if not token then return end
                    recorder:sample("bound", token.name, token.stage, 0,
                        token.exclusive and own or cost, success)
                    if token.name == "dashboard-lifecycle" and token.stage == "settingsDrain" then
                        recorder:sample("bound", token.name, "settingsDrainOverhead", 0, own, success)
                    end
                end,
            })
        end
    end)
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

foreground["lib/flight_registration.lua"] = function(module)
    module.begin = recorder:bound(function() return bound("flight-registration", "begin") end, module.begin)
    module.beginLoad = recorder:bound(function()
        return bound("flight-registration", "load-begin")
    end, module.beginLoad)
    module.advance = recorder:wrap(module.advance, {
        before = function(job)
            if job.done then return end
            local stage = job.stage
            if stage ~= "load" then return bound("flight-registration", stage) end
        end,
        after = function(cost, _, token, ok, results)
            if token then
                recorder:sample("bound", token.name, token.stage, 0, cost, ok)
            end
            if ok and results[2] == true and results[3] == false then
                recorder:sample("bound", "flight-registration", "reject", 0, cost, true)
            end
        end,
    })
end

foreground["lib/dashboard_loader.lua"] = function(module)
    module.new = recorder:wrap(module.new, function(_, ok, results)
        if not ok then return end
        local loader = results[2]
        loader.advanceLoad = recorder:bound(function(context)
            local stage = context.stage
            if stage == "flight-load-wait"
                and loader.workBound(context) ~= costs:bound("dashboard-loader", stage) then
                return bound("dashboard-loader", "sharedFlightOverhead", true)
            end
            if costs.bounds["dashboard-loader"][stage] then
                return bound("dashboard-loader", stage)
            end
        end, loader.advanceLoad)
    end)
end

local function registerStages(_, ok, _, _, name, declaration)
    if not ok then
        return
    end
    names[declaration] = name
    for stage, entry in pairs(declaration.stages) do
        declare(name, stage, entry.maxUnits)
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
    -- Native spans cover widget registration. Direct unit calls add focused
    -- coverage without retaining another adapter in the multi-widget heap.
    if relative == "lib/flight_registration.lua"
        and string.sub(scenario, 1, 15) ~= "tests/unit/lib/" then return end
    local name = names[module.decl]
    if relative ~= "lib/costs.lua" and relative ~= "lib/services.lua" and relative ~= "main.lua"
        and relative ~= "lib/scheduler.lua"
        and not string.match(relative, "^panels/.+%.lua$")
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
    local panel = string.match(relative, "^panels/(.+)%.lua$")
    if panel and panel ~= "chart" then
        for _, method in ipairs({ "reflow", "update" }) do
            if type(module[method]) == "function" then
                local original = module[method]
                module[method] = recorder:bound(function() return bound("panel-reflow", panel) end, original)
                if module.reflowDecl and module.reflowDecl.callback == original then
                    module.reflowDecl.callback = module[method]
                end
            end
        end
    end
    if foreground[relative] then foreground[relative](module) end
    if relative == "main.lua" then
        for _, kind in ipairs({ "create", "update", "refresh", "background" }) do
            assert(type(module[kind]) == "function", "missing widget callback " .. kind)
            module[kind] = recorder:callback(kind, module[kind], {
                before = function(context)
                    local host = type(context) == "table" and context.schedulerHost
                    if host then
                        host.instructionKind, host.instructionReady, host.instructionFinish = nil, 0, 0
                    end
                    return host
                end,
                after = function(_, own, host, ok)
                    if host and host.instructionKind then
                        recorder:sample("bound", "host-overhead", host.instructionKind, 0,
                            own + host.instructionReady + host.instructionFinish, ok)
                    end
                end,
            })
        end
    end
end

local originalLoadfile = loadfile
local function loadedChunk(_, ok, results, filename)
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
end
loadfile = recorder:wrap(originalLoadfile, function(cost, ok, results, filename)
    loadedChunk(cost, ok, results, filename)
    if ok and type(results[2]) == "function" and type(filename) == "string"
        and string.match(filename, "/tests/support/edgetx%.lua$") then
        results[2] = recorder:wrap(results[2], function(_, moduleOk, values)
            if not moduleOk then return end
            local module = values[2]
            module.radio = recorder:wrap(module.radio, function(_, radioOk)
                if radioOk then loadScript = recorder:wrap(loadScript, loadedChunk) end
            end)
        end)
    end
end)
