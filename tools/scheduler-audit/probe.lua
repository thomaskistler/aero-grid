-- SPDX-License-Identifier: GPL-2.0-only
-- Scheduler audit probe. Copied only into an isolated simulator SD image.
--
-- `__count` and `__pause` come from tools/audit-native.cpp. Every measurement
-- window reads the exact instruction counter; bookkeeping runs with the counter
-- paused, so recording a sample does not change what is recorded.

local config = assert(loadScript("/WIDGETS/AeroGrid/audit/config.lua"))()
local previewTasks = string.match(config.scenario, "^editor%-preview%-.+%-tasks$") ~= nil
local count, pause
local P = { offset = 0 }
local loaderDeclarations = {}
local boundedConstructors = {
    metric = true,
    ["link-status"] = true,
    ["rx-battery"] = true,
    ["tx-battery"] = true,
    ["flight-timer"] = true,
}

local realTime = getTime
_G.getTime = function()
    return realTime() + P.offset
end

local stats, trace, errorsSeen, worst = {}, {}, {}, {}
local gateErrors = {}
local function gate(condition, message)
    if not condition then
        gateErrors[message] = true
    end
end
local depth, childSum, visits, childList = 0, {}, {}, {}
local top, topLabels, topSum = {}, {}, 0
local callbackIndex, phaseIndex, phaseDone = 0, 1, 0
local kindCounts = {}
local K, LEAK_WRAP, LEAK_SPAN, K_CALLBACK = 0, 0, 0, 0
local calibrating, calibrationRaw = false, 0
local installed, wrappedKeys = setmetatable({}, { __mode = "k" }), setmetatable({}, { __mode = "k" })
local finished = false
local recording = true
local refreshFn, backgroundFn

local function record(label, cost, own, units, children)
    local entry = stats[label]
    if not entry then
        entry = { n = 0, sum = 0, max = 0, min = math.huge, selfMax = 0, units = {} }
        stats[label] = entry
    end
    entry.n = entry.n + 1
    entry.sum = entry.sum + cost
    if cost > entry.max then
        entry.max = cost
        entry.worstChildren = children
    end
    if cost < entry.min then
        entry.min = cost
    end
    if own > entry.selfMax then
        entry.selfMax = own
    end
    local bucket = entry.units[units]
    if not bucket then
        bucket = { n = 0, max = 0, selfMax = 0 }
        entry.units[units] = bucket
    end
    bucket.n = bucket.n + 1
    if cost > bucket.max then
        bucket.max = cost
    end
    if own > bucket.selfMax then
        bucket.selfMax = own
    end
end

local function finish(label, raw, leak)
    local d = depth
    if calibrating then
        calibrationRaw = raw
        depth = d - 1
        return
    end
    local cost = raw - K
    local own = cost - childSum[d]
    local units = visits[d]
    local children = table.concat(childList[d], ",")
    depth = d - 1
    if type(label) ~= "string" then
        label = "unlabelled"
    end
    if P.lifecycleServiceOnly or P.lifecycleOperation then
        gate(
            not string.match(label, "^task:panel:")
                and not string.match(label, "^panel:[^:]+:refresh")
                and not string.match(label, "^panel:[^:]+:background")
                and not string.match(label, "^chart:"),
            "lifecycle callback dispatched hidden panel work: " .. label
        )
    end
    local loadBound = loaderDeclarations[label]
        or ({
            ["load:theme-read"] = 240,
            ["load:theme-tokenize"] = 3200,
            ["load:theme-parse"] = 900,
            ["load:theme-resolve-begin"] = 240,
            ["load:tokenize"] = 3300,
            ["load:header"] = 950,
            ["load:header-parse"] = 1650,
            ["load:header-validate"] = 350,
            ["load:header-finalize"] = 350,
            ["load:panel-tokens"] = 1120,
            ["load:panel-parse"] = 1650,
            ["load:read"] = 750,
            ["load:load-error"] = 1500,
        })[label]
    local resolution = string.match(label, "^load:theme%-resolve:(%a+)$")
    if resolution then
        loadBound = ({ legibility = 2400, chart = 1800, alert = 2200, display = 650, finalize = 180 })[resolution]
    elseif string.match(label, "^load:theme%-publish:") then
        loadBound = 500
    end
    if loadBound then
        gate(cost <= loadBound, label .. " exceeds its bounded loading charge: " .. cost)
    end
    local rxReflow = string.match(label, "^lifecycle:advanceReflow:rx%-battery:")
    if label == "lifecycle:advanceReflow" or rxReflow then
        gate(cost <= 4000, "complete geometry advance exceeds the atom cap: " .. cost)
    end
    local loadingConstructor = string.match(label, "^load:panel%-build:([^:]+)$")
        or string.match(label, "^load:panel%-construct:([^:]+):")
    if
        string.match(label, "^lifecycle:advanceAppRebuild:")
        or string.match(label, "^lifecycle:retirePage:")
        or label == "lifecycle:rebuildPage"
        or label == "lifecycle:restartLoading"
        or loadingConstructor and boundedConstructors[loadingConstructor]
        or rxReflow
    then
        local fitted = math.ceil((cost * 1.10 + 50) / 10) * 10
        gate(fitted <= 4000, label .. " exceeds the fitted lifecycle atom cap: " .. cost .. " -> " .. fitted)
        local bound = label == "lifecycle:restartLoading" and 600
            or label == "lifecycle:rebuildPage" and 200
            or P.lifecycleBounds and P.lifecycleBounds[label]
        gate(not bound or fitted <= bound, label .. " exceeds its declared lifecycle charge: " .. fitted)
    end
    if previewTasks and string.sub(label, 1, 11) == "task:panel:" then
        gate(cost <= 4000, label .. " exceeds the preview atom cap: " .. cost)
    end
    if string.sub(config.scenario, 1, 6) == "modal-" and string.sub(label, 1, 6) == "modal:" then
        gate(cost <= 4000, label .. " exceeds the modal atom cap: " .. cost)
        local stage = string.match(label, "^modal:log:advance:(.+)$")
        local bound = stage and P.logBounds and P.logBounds[stage]
        gate(not bound or cost <= bound, label .. " exceeds its declared modal charge: " .. cost)
    end
    if string.sub(label, 1, 5) == "unit:" and depth >= 1 then
        visits[depth] = visits[depth] + 1
    end
    if depth >= 1 then
        childSum[depth] = childSum[depth] + raw + leak
        local siblings = childList[depth]
        siblings[#siblings + 1] = label .. "=" .. cost
    elseif label == "flight:identity" then
        -- Runs in every callback: part of the fixed overhead, not a schedulable task.
    else
        topSum = topSum + raw + leak
        top[#top + 1] = label .. "=" .. cost .. (units > 0 and "/" .. units or "")
        topLabels[#topLabels + 1] = label
    end
    if recording then
        record(label, cost, own, units > 0 and units or 1, children)
        if string.match(label, "^editor:input:") then
            gate(cost <= 4000, label .. " exceeds the editor input atom cap: " .. cost)
            local bound = P.editorInputBounds and P.editorInputBounds[string.sub(label, #"editor:input:" + 1)]
            if bound then
                gate(cost <= bound, label .. " exceeds the editor input charge: " .. cost)
            end
        end
        if rxReflow then
            record("lifecycle:advanceReflow", cost, own, units > 0 and units or 1, children)
        end
        local stage = tonumber(string.match(label, "^editor:advanceEditor:render:(%d+)$"))
        local opening = string.match(label, "^editor:advanceEditor:drawer%-open:(%a+)$")
        if opening then
            gate(cost <= 4000, label .. " exceeds the drawer-open atom cap: " .. cost)
            gate(cost <= P.editorOpenBounds[opening], label .. " exceeds the drawer-open charge: " .. cost)
        end
        if stage and stage >= 2 and P.editorRenderBounds then
            gate(cost <= 4000, label .. " exceeds the editor paint atom cap: " .. cost)
            gate(
                cost <= P.editorRenderBounds[stage == 6 and "finish" or "rows"],
                label .. " exceeds the editor paint charge: " .. cost
            )
        end
        local drawerStage = string.match(label, "^editor:drawer:advance:(%a+)")
        if label == "editor:drawer:open" then
            gate(cost <= 4000, label .. " exceeds the drawer opening atom cap: " .. cost)
        end
        local drawerBound = drawerStage and P.editorDrawerBounds and P.editorDrawerBounds[drawerStage]
        if drawerBound then
            gate(cost <= 4000, label .. " exceeds the drawer atom cap: " .. cost)
            gate(cost <= drawerBound, label .. " exceeds the drawer work charge: " .. cost)
        end
        local settingsStage = string.match(label, "^modal:settings:advance:([%w_%-]+)")
        local settingsBound = settingsStage and P.settingsBounds and P.settingsBounds[settingsStage]
        if settingsBound then
            gate(cost <= settingsBound, label .. " exceeds the settings work charge: " .. cost)
        end
        local saveStage = string.match(label, "^modal:settings:store:([%w_]+)")
        local saveBound = saveStage and P.settingsStoreBounds and P.settingsStoreBounds[saveStage]
        if saveBound then
            gate(cost <= saveBound, label .. " exceeds the settings store charge: " .. cost)
        end
        local loadStage = string.match(label, "^modal:settings:load:([%w_]+)")
        local loadBound = loadStage and P.settingsLoadBounds and P.settingsLoadBounds[loadStage]
        if loadBound then
            gate(cost <= 4000 and cost <= loadBound, label .. " exceeds the settings reader charge: " .. cost)
        end
        local editorPrefix = "editor:advanceEditor:"
        if string.sub(label, 1, #editorPrefix) == editorPrefix then
            record("editor:advanceEditor", cost, own, units > 0 and units or 1, children)
        end
    end
end

-- A labelled measurement window. `label` is a string, or a function that is
-- called before the work (returning a token) and after it (returning the label).
local function core(leak, label, fn, a, b, c, d, e, f, g, h)
    pause(true)
    depth = depth + 1
    childSum[depth], visits[depth], childList[depth] = 0, 0, {}
    local token
    if type(label) == "function" then
        token = label(nil, a, b, c, d, e, f, g, h)
    end
    pause(false)
    local c0 = count()
    local r1, r2, r3, r4 = fn(a, b, c, d, e, f, g, h)
    local c1 = count()
    pause(true)
    if type(label) == "function" then
        label = label(token, a, b, c, d, e, f, g, h)
    end
    finish(label, c1 - c0, leak)
    pause(false)
    return r1, r2, r3, r4
end

-- Direct spans: patched call sites in the isolated copy call this.
local function span(label, fn, a, b, c, d, e, f, g, h)
    return core(LEAK_SPAN, label, fn, a, b, c, d, e, f, g, h)
end
_G.AUDIT_SPAN = span

-- Wrapper spans: installed over existing functions at run time.
local function wrap(label, fn)
    return function(a, b, c, d, e, f, g, h)
        return core(LEAK_WRAP, label, fn, a, b, c, d, e, f, g, h)
    end
end

local function wrapField(owner, key, label)
    local original = owner[key]
    local keys = wrappedKeys[owner]
    if type(original) ~= "function" or keys and keys[key] then
        return
    end
    if not keys then
        keys = {}
        wrappedKeys[owner] = keys
    end
    keys[key] = true
    owner[key] = wrap(label, original)
end

local function calibrate()
    local empty = function() end
    local function bare() end
    local function window(fn)
        local c0 = count()
        fn()
        return count() - c0
    end
    calibrating = true
    span("calibrate", bare)
    K = calibrationRaw
    local baseline = window(function() end)
    local direct = window(function()
        span("calibrate", empty)
    end)
    local wrapped = wrap("calibrate", empty)
    local viaWrapper = window(function()
        wrapped()
    end)
    calibrating = false
    LEAK_SPAN = direct - baseline - K
    LEAK_WRAP = viaWrapper - baseline - K
    local shape = function() end
    local c0 = count()
    local c1 = count()
    local floor = c1 - c0
    c0 = count()
    shape(P, c0, c1)
    c1 = count()
    K_CALLBACK = c1 - c0 - floor
end

local function panelLabel(token, entry, event, ...)
    local module = entry and entry.module
    local id = module and rawget(module, "id") or "unknown"
    local instance = entry and entry.instance
    if event == "reflow" then
        if token == nil then
            local work = instance.reflowWork
            return (select(5, ...) or work and work.invalidated) and "begin" or work and work.stage or "done"
        end
        return "panel:" .. id .. ":reflow:" .. tostring(token)
    end
    if event == "step" and module and type(module.stageOf) == "function" then
        return token == nil and module.stageOf(instance) or "panel:" .. id .. ":step:" .. tostring(token)
    end
    if id ~= "chart" or event ~= "refresh" or type(instance) ~= "table" then
        return token == nil and true or "panel:" .. id .. ":" .. tostring(event)
    end
    if token == nil then
        local pending = instance.pending
        return {
            phase = instance.framePhase,
            projecting = pending and pending.job and pending.job.projecting or false,
            pending = pending ~= nil,
            projectionTurn = instance.projectionTurn,
        }
    end
    if not token.phase then
        return instance.framePhase and "chart:frame-begin" or "chart:frame-idle"
    end
    if token.phase == "traces" then
        if token.pending then
            return token.projecting and "chart:traces-project" or "chart:traces-apply"
        end
        return "chart:traces-select"
    end
    return "chart:" .. token.phase
end

local function loadLabel(token, context)
    if token == nil then
        local stage = context.stage or "idle"
        local bound = context.dashboardLoader.workBound and context.dashboardLoader.workBound(context)
        if stage == "flight-load" or stage == "flight-register" then
            local job = context.flightLoading.job
            stage = stage .. ":" .. tostring(job.stage or "done")
            if job.stage == "load" then
                stage = stage .. ":" .. tostring(job.load.stage)
            end
        end
        if stage == "theme-resolve" then
            stage = stage .. ":" .. tostring(context.themeBuildWork.stage)
        elseif stage == "theme-publish" then
            stage = stage .. ":" .. tostring(context.themePublication.phase)
        else
            local placement = context.pendingPlacement
            if stage == "panel-construct" and context.pendingConstruction then
                stage = stage
                    .. ":"
                    .. placement.type
                    .. ":"
                    .. tostring(context.pendingConstruction.instance.createStage)
            elseif (stage == "panel-build" or stage == "panel-prepare" or stage == "panel-validate") and placement then
                stage = stage .. ":" .. tostring(placement.type)
            end
        end
        loaderDeclarations["load:" .. stage] = bound
        return stage
    end
    return "load:" .. token
end

local function editorLabel(token, context)
    if token then
        return "editor:advanceEditor:" .. token
    end
    local ui = context.editorUi
    if ui.session.initializing then
        return "copy:" .. ui.session.initializing.phase
    end
    if ui.buildStage then
        return "build:" .. tostring(ui.buildStage)
    end
    if ui.drawerOpen then
        return "drawer-open:" .. ui.drawerOpen.mode
    end
    if ui.renderStage and not ui.previewPending and not ui.previewRefresh and not ui.exitCommand then
        return "render:" .. tostring(ui.renderStage)
    end
    local job = ui.previewRefresh
    if job then
        local action = job.actions[job.index]
        if not action then
            return "preview-finish"
        end
        if not action.retired then
            return "preview-retire"
        end
        if not action.preparedPlacement then
            return "preview-copy"
        end
        if not action.prepared then
            return "preview-prepare"
        end
        local partial = action.constructing and context.pendingConstruction
        if partial then
            return "preview-construct:" .. tostring(partial.instance.createStage)
        end
        return "preview-create"
    end
    return "other"
end

local function install(context)
    pause(true)
    local scheduling = context.schedulerHost
    if scheduling and not installed[scheduling] then
        installed[scheduling] = true
        wrapField(scheduling, "ready", "scheduler:ready")
        wrapField(scheduling, "finish", function(token, _, kind)
            if token then
                return "scheduler:finish:" .. token
            end
            if kind == "editor-input" then
                P.editorInputAdmission = true
            end
            P.lifecycleAdmissionKind = kind
            if kind == "loader" and (context.reloadState or context.appRebuild) then
                P.lifecycleServiceOnly = true
            end
            return kind or "steady"
        end)
        wrapField(scheduling, "syncPanels", "scheduler:panels")
        wrapField(scheduling, "resetServiceRelease", "scheduler:reset-service-release")
        wrapField(scheduling, "resetPanelRelease", "scheduler:reset-panel-release")
    end
    for _, task in pairs(context.schedulerHost and context.schedulerHost.panelTasks or {}) do
        if not installed[task] then
            installed[task] = true
            task.step = wrap(function(token, current, _, stage)
                return token == nil and stage or "task:panel:" .. current.entry.module.id .. ":" .. tostring(token)
            end, task.step)
        end
    end
    for _, entry in ipairs(context.panels) do
        local module = entry.module
        if module and not installed[module] then
            installed[module] = true
            local id = tostring(rawget(module, "id"))
            wrapField(module, "render", "panel:" .. id .. ":render")
            wrapField(module, "apply", "panel:" .. id .. ":apply")
        end
    end
    local host = context.panelHost
    if host and not installed[host] then
        installed[host] = true
        host.dispatch = wrap(panelLabel, host.dispatch)
    end
    local loader = context.dashboardLoader
    if loader and not installed[loader] then
        installed[loader] = true
        loader.advanceLoad = wrap(loadLabel, loader.advanceLoad)
        loader.beginLoad = wrap("load:begin", loader.beginLoad)
    end
    local lifecycle = context.dashboardLifecycle
    if lifecycle and not installed[lifecycle] then
        installed[lifecycle] = true
        for key, value in pairs(lifecycle) do
            if type(value) == "function" and key ~= "workBound" then
                local name = key
                local label = "lifecycle:" .. name
                if name == "advanceReflow" then
                    label = function(token, current)
                        if token then
                            return token
                        end
                        local entry = current.panels[current.reflowIndex or 0]
                        if entry and entry.module.id == "rx-battery" then
                            local work = entry.instance.reflowWork
                            local stage = current.reflowEntry ~= entry or not work or work.invalidated
                            return "lifecycle:advanceReflow:rx-battery:" .. (stage and "begin" or work.stage)
                        end
                        return "lifecycle:advanceReflow"
                    end
                elseif name == "advanceAppRebuild" or name == "retirePage" then
                    label = function(token, current)
                        if token then
                            return "lifecycle:" .. name .. ":" .. token
                        end
                        local job
                        if name == "retirePage" then
                            job = current.pageRetirement
                        else
                            job = current.appRebuild
                        end
                        local phase = job and job.phase or (name == "retirePage" and "cancel" or "retire")
                        if phase == "construct" then
                            local entry = current.pendingConstruction
                            phase = phase
                                .. ":"
                                .. tostring(entry and entry.module.id)
                                .. ":"
                                .. tostring(entry and entry.instance.createStage)
                        elseif phase == "build" or phase == "prepare" then
                            phase = phase .. ":" .. tostring(job.entry.module.id)
                        elseif phase == "panel" then
                            local entry = current.panels[1]
                            phase = phase .. ":" .. tostring(entry and entry.module.id or "done")
                        elseif phase == "settings" and current.modelSettingsUi then
                            phase = phase .. ":" .. current.modelSettingsUiModule.stageOf(current.modelSettingsUi)
                        end
                        P.lifecycleBounds = P.lifecycleBounds or {}
                        P.lifecycleBounds["lifecycle:" .. name .. ":" .. phase] = lifecycle.workBound
                            and lifecycle.workBound(current, name)
                        P.lifecycleOperation = name .. ":" .. phase
                        local bound = P.lifecycleBounds["lifecycle:" .. name .. ":" .. phase]
                        gate(
                            (bound ~= nil) == (P.lifecycleAdmissionKind == "loader"),
                            P.lifecycleOperation .. " has incorrect administrative service admission"
                        )
                        return phase
                    end
                end
                lifecycle[key] = wrap(label, value)
            end
        end
        local controller = context.editorController
        if controller and not installed[controller] then
            installed[controller] = true
            for _, name in ipairs({ "openEditor", "advanceEditor", "restorePreview" }) do
                controller[name] = wrap(name == "advanceEditor" and editorLabel or "editor:" .. name, controller[name])
            end
        end
    end
    local runtime = context.serviceRuntime
    local store = context.flightBroker and context.flightBroker.store
    if store and store.advanceSave then
        P.settingsStoreBounds = P.settingsStoreBounds or {}
        wrapField(store, "advanceSave", function(token, _, job)
            if token then
                return "modal:settings:store:" .. token
            end
            P.settingsStoreBounds[job.stage] = store:saveWorkBound(job)
            return job.stage
        end)
        P.settingsLoadBounds = P.settingsLoadBounds or {}
        wrapField(store, "advanceLoad", function(token, _, job)
            if token then
                return "modal:settings:load:" .. token
            end
            P.settingsLoadBounds[job.stage] = store:loadWorkBound(job)
            return job.stage
        end)
    end
    local broker = context.flightBroker
    if broker then
        wrapField(broker, "startPublication", "modal:settings:publication:begin")
        wrapField(broker, "advancePublication", function(token, _, job)
            if token then
                return "modal:settings:publication:" .. token
            end
            return job.stage
        end)
    end
    P.editorRenderBounds = context.editorUiModule and context.editorUiModule.RENDER_BOUNDS
    P.editorOpenBounds = context.editorUiModule and context.editorUiModule.DRAWER_OPEN_BOUNDS
    if context.editorUiModule then
        wrapField(context.editorUiModule, "handle", function(token, current, e)
            if token then
                return "editor:input:" .. token
            end
            P.editorInputSeen = true
            local name = tostring(current.editorUi and current.editorUi.mode) .. ":" .. tostring(e)
            P.editorInputBounds = P.editorInputBounds or {}
            P.editorInputBounds[name] = current.editorUiModule.inputWorkBound(current, e)
            return name
        end)
    end
    local drawer = context.editorDrawerModule
    if drawer then
        P.editorDrawerBounds = drawer.WORK_BOUNDS
        wrapField(drawer, "open", "editor:drawer:open")
        wrapField(drawer, "advance", function(token, _, state)
            if token then
                return "editor:drawer:advance:" .. token
            end
            if state.drawerLayout then
                return "layout"
            elseif state.drawerRefresh then
                return state.drawerRefresh.phase
            elseif state.drawerBuild then
                return state.drawerBuild <= #state.drawerFields
                        and "build:" .. tostring(state.drawerFields[state.drawerBuild].type)
                    or "finish"
            end
            return state.drawerPending and state.drawerPending.action or "command"
        end)
    end
    if context.diagnosticsLog then
        wrapField(context.diagnosticsLog, "startSnapshot", "modal:log:freeze")
        wrapField(context.diagnosticsLog, "advanceSnapshot", "modal:log:snapshot")
    end
    for _, surface in ipairs({
        { "logViewerModule", "log", "logViewer" },
        { "modelSettingsUiModule", "settings", "modelSettingsUi" },
        { "locationDetailsModule", "location", "locationDetails" },
        { "aeroMenuModule", "menu", "aerogridMenu" },
    }) do
        local module = context[surface[1]]
        if module then
            if surface[2] == "log" then
                P.logBounds = module.WORK_BOUNDS
            elseif surface[2] == "settings" then
                P.settingsBounds = {}
                for stage, bound in pairs(module.WORK_BOUNDS) do
                    P.settingsBounds[stage] = bound
                end
            end
            for _, name in ipairs({ "open", "advance", "handle", "close", "ensure" }) do
                wrapField(module, name, function(token, current)
                    if token then
                        return "modal:" .. surface[2] .. ":" .. name .. ":" .. token
                    end
                    local state = current[surface[3]]
                    if surface[2] == "settings" and state then
                        local stage = module.stageOf(state)
                        if name == "advance" then
                            P.settingsBounds[stage] = module.workBound(current)
                            if state.loading and state.loading.phase == "setup" then
                                P.settingsLegacyStatus = state.loading.status
                            end
                        end
                        return stage .. ":" .. tostring(state.build or "idle")
                    end
                    return tostring(
                        state
                                and (state.build or state.buildStage or state.renderIndex and "render" or state.stage or state.prepareIndex and "wrap" or state.pending and "pending")
                            or "idle"
                    )
                end)
            end
        end
    end
    if runtime then
        local support = context.servicesModule
        if support and not installed[support] then
            installed[support] = true
            local original = support.roundRobin
            support.roundRobin = function(entries, cursor, cap, visit, owner, now)
                local label = "unit:" .. tostring(owner and owner.id)
                return original(entries, cursor, cap, function(o, entry, at)
                    return core(LEAK_WRAP, label, visit, o, entry, at)
                end, owner, now)
            end
        end
        for _, instance in ipairs(runtime.order) do
            if not installed[instance] then
                installed[instance] = true
                local update = instance.update
                if type(update) == "function" then
                    instance.update = wrap("service:" .. tostring(instance.id), update)
                end
                if not instance.schedulerTasks then
                    wrapField(instance, "step", "service:" .. tostring(instance.id))
                end
                wrapField(instance, "resetSession", "reset:" .. tostring(instance.id))
                if instance.id == "telemetry" then
                    wrapField(instance, "scanPrecision", "telemetry:scan")
                    wrapField(instance, "poll", "telemetry:poll")
                    wrapField(instance, "publishLink", "telemetry:link")
                end
            end
            -- Broker adapters can be activated after their facade was installed.
            for _, task in ipairs(instance.schedulerTasks or {}) do
                if task.id == "service:flight" or task.id == "service:smart" then
                    local id = task.id
                    wrapField(task.instance, "step", function(token, _, _, stage)
                        return token == nil and stage or "task:" .. id .. ":" .. tostring(token)
                    end)
                else
                    wrapField(task.instance, "step", task.id)
                end
            end
        end
        local telemetry = runtime.byId.telemetry
        for _, observer in ipairs(telemetry and telemetry.observers or {}) do
            wrapField(observer, "sample", "history:sample")
        end
    end
    local broker = context.flightFactory and context.flightFactory.broker
    for _, name in ipairs({ "runtime", "smartRuntime" }) do
        local owned = broker and broker[name]
        if owned and not installed[owned] then
            installed[owned] = true
            for _, instance in ipairs(owned.order) do
                local update = instance.update
                if type(update) == "function" then
                    instance.update = wrap("flight-" .. name .. ":" .. tostring(instance.id), update)
                end
            end
        end
    end
    if broker and not installed[broker] then
        installed[broker] = true
        wrapField(broker, "tick", "flight:tick")
        wrapField(broker, "pollReset", "flight:pollReset")
        wrapField(broker, "identity", "flight:identity")
    end
    if broker and broker.store and not installed[broker.store] then
        installed[broker.store] = true
        wrapField(broker.store, "load", "flight:storeLoad")
    end
    pause(false)
end

local function json(value)
    local kind = type(value)
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        if value == math.floor(value) then
            return string.format("%d", value)
        end
        return string.format("%.4f", value)
    elseif kind == "string" then
        return '"'
            .. string.gsub(value, '[%c"\\]', function(char)
                return string.format("\\u%04x", string.byte(char))
            end)
            .. '"'
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "table" then
        local parts = {}
        if #value > 0 or next(value) == nil then
            for index, item in ipairs(value) do
                parts[index] = json(item)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = tostring(key)
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            parts[#parts + 1] = json(key) .. ":" .. json(value[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function write(path, text)
    local file = assert(io.open(path, "w"))
    io.write(file, text)
    io.close(file)
end

-- How much history the charts hold when the run ends: proves the fill reached capacity.
local function feeds(context)
    local rows = {}
    for _, entry in ipairs(context and context.panels or {}) do
        for _, item in ipairs(entry.instance.series or {}) do
            local feed = item.feed
            if feed and feed.last then
                rows[#rows + 1] = { first = feed.first, last = feed.last, full = feed.full == true }
            end
        end
    end
    return rows
end

local function unexpectedErrors(context)
    local errors = {}
    for _, message in ipairs(context and context.errors or errorsSeen) do
        if message == config.expectedError then
            P.expectedErrorSeen = true
        else
            errors[#errors + 1] = message
        end
    end
    return errors
end

local function report(context)
    local errors = unexpectedErrors(context)
    gate(not config.expectedError or P.expectedErrorSeen, "expected scenario error was not reported")
    for message in pairs(gateErrors) do
        errors[#errors + 1] = message
    end
    local labels = {}
    for label, entry in pairs(stats) do
        local units = {}
        for unit, bucket in pairs(entry.units) do
            units[tostring(unit)] = bucket
        end
        labels[label] = {
            n = entry.n,
            mean = entry.sum / entry.n,
            max = entry.max,
            min = entry.min,
            selfMax = entry.selfMax,
            worstChildren = entry.worstChildren,
            units = units,
        }
    end
    write(
        "/audit-results.json",
        json({
            scenario = config.scenario,
            calibration = { K = K, leakWrap = LEAK_WRAP, leakSpan = LEAK_SPAN, callbackK = K_CALLBACK },
            panels = context and #context.panels or 0,
            errors = errors,
            expectedError = config.expectedError and { message = config.expectedError, observed = P.expectedErrorSeen },
            callbacks = kindCounts,
            feeds = feeds(context),
            construction = P.construction and {
                checked = P.construction.checked,
                total = P.construction.total,
                done = P.construction.done,
            },
            stats = labels,
            worst = (function()
                local rows = {}
                for index, item in ipairs(worst) do
                    rows[index] = item.text
                end
                return rows
            end)(),
            trace = trace,
        })
    )
    write("/audit-ready.txt", "done")
    finished = true
end

local function ready(context)
    if P.lifecycleStarted then
        return true
    end
    if config.fullscreen and not lvgl.isFullScreen() and not P.settingsWindowLoss then
        return false
    end
    return not context.stage
        and (not context.reloadState or context.modelSettingsUi ~= nil)
        and #context.panels >= (config.expectedPanels or 1)
        and not context.runtimeFailed
end

local function settingsMembers(context, phase)
    P.settingsMembers = {}
    for index = 1, phase.members or 0 do
        local host = {
            modelFilename = context.flightBroker.filename,
            navigationHomes = { retained = true },
            legacyWidgetArmed = phase.legacy == "conflict" and index % 2 + 1 or phase.legacy == "one" and 1 or 0,
        }
        P.settingsMembers[index] = host
        context.flightBroker.members[host] = { modelFilename = host.modelFilename, declarations = {} }
    end
end

local actions
actions = {
    ["construction-parity"] = function(context, costOnly, reflow, reflowCost)
        local function load(relative)
            if relative == "lib/theme.lua" then
                return context.themeBuilder
            elseif relative == "lib/primitives.lua" then
                return context.primitives
            end
            return assert(loadScript("/WIDGETS/AeroGrid/" .. relative))()
        end
        local cases = assert(loadScript("/WIDGETS/AeroGrid/audit/construction_cases.lua"))()(
            load,
            context.themeBuilder,
            config.constructionKind
        )
        if reflow then
            local sameTree = assert(loadScript("/WIDGETS/AeroGrid/audit/panel_tree.lua"))()
            local recorder = assert(loadScript("/WIDGETS/AeroGrid/audit/native_construction.lua"))()
            P.construction = assert(loadScript("/WIDGETS/AeroGrid/audit/native_rx_reflow.lua"))()(
                context,
                cases,
                recorder,
                sameTree,
                reflowCost
            )
            assert(not reflowCost or P.construction.costOnly, "RX cost matrix must not record native trees")
        elseif costOnly then
            P.construction =
                assert(loadScript("/WIDGETS/AeroGrid/audit/native_construction_cost.lua"))()(context, cases)
        else
            local sameTree = assert(loadScript("/WIDGETS/AeroGrid/audit/panel_tree.lua"))()
            P.construction = assert(loadScript("/WIDGETS/AeroGrid/audit/native_construction.lua"))()(
                lvgl,
                cases,
                sameTree,
                context.page
            )
        end
    end,
    ["construction-cost"] = function(context)
        actions["construction-parity"](context, true)
    end,
    ["rx-reflow-matrix"] = function(context)
        actions["construction-parity"](context, false, true)
    end,
    ["rx-reflow-cost"] = function(context)
        actions["construction-parity"](context, false, true, true)
    end,
    ["construction-parity-step"] = function()
        P.construction.done = P.construction:step()
    end,
    ["construction-parity-check"] = function()
        assert(
            P.construction.done and P.construction.checked == P.construction.total,
            "native construction matrix did not finish"
        )
    end,
    ["lifecycle-app"] = function(context)
        P.lifecycleStarted = true
        P.lifecycleOriginals = {}
        for index, entry in ipairs(context.panels) do
            P.lifecycleOriginals[index] = entry
            entry.builtFullscreen = true
        end
        -- Reproduce fullscreen-created preview placements on an App-built page.
        -- The simulator stays visible so native callRefs continues to run.
        _G.lvgl = setmetatable({
            isFullScreen = function()
                return false
            end,
        }, { __index = lvgl })
        context.rootBuiltFullscreen, context.pageBuiltFullscreen = nil, nil
        context.fullScreen = false
    end,
    ["lifecycle-retire"] = function(context)
        P.lifecycleStarted = true
        P.lifecycleOriginals = P.lifecycleOriginals or {}
        if #P.lifecycleOriginals == 0 then
            for index, entry in ipairs(context.panels) do
                P.lifecycleOriginals[index] = entry
            end
        end
        P.lifecyclePage = context.page
        local phase = config.phases[phaseIndex]
        if phase and phase.recreateRoot then
            P.lifecycleRoot = context.root
            context.rootBuiltFullscreen, context.fullScreen = true, false
            _G.lvgl = setmetatable({
                isFullScreen = function()
                    return false
                end,
            }, { __index = lvgl })
        end
        context.reloadState = "clear"
    end,
    ["lifecycle-app-background"] = function(context)
        actions["lifecycle-app"](context)
        context.appRebuild = { entry = context.panels[1], index = 1 }
    end,
    ["lifecycle-cancel"] = function(context)
        assert(context.appRebuild and context.pendingConstruction, "cancel must interrupt actual partial construction")
        P.lifecyclePartial = context.pendingConstruction
        P.lifecyclePage = context.page
        context.reloadState = "clear"
    end,
    ["lifecycle-settings-drain"] = function(context)
        assert(
            context.modelSettingsUi and context.modelSettingsUi.saving,
            "retirement must interrupt an already confirmed settings save"
        )
        P.lifecycleStarted, P.lifecycleOriginals, P.lifecyclePage = true, {}, context.page
        for index, entry in ipairs(context.panels) do
            P.lifecycleOriginals[index] = entry
        end
        _G.AUDIT_LIFECYCLE_DRAIN = true
        context.reloadState = "clear"
    end,
    ["check-lifecycle-settings"] = function(context)
        assert(not context.modelSettingsUi)
        assert(context.flightBroker.document.revision == P.settingsRevision)
        assert(context.flightBroker.document.flight.motorReversed == P.settingsReversed)
        actions["check-lifecycle"](context)
    end,
    ["lifecycle-error-finish"] = function(context)
        assert(not context.appRebuild and not context.reloadState and not context.stage)
        P.lifecycleStarted = true
        context.errors = {}
        for index = 1, 128 do
            context.errors[index] = config.expectedError
        end
        context.appRebuild = { entry = context.panels[1], phase = "finish" }
    end,
    ["check-lifecycle-errors"] = function(context)
        assert(not context.appRebuild and context.errorLabel, "App finish must present accumulated errors")
        assert(#context.errors == 128 and context.errors[128] == config.expectedError)
    end,
    ["check-lifecycle"] = function(context)
        assert(not context.appRebuild and not context.pendingConstruction and not context.pageRetirement)
        assert(not context.reloadState and not context.stage, "lifecycle must reach the rebuilt dashboard")
        assert(#context.panels == #P.lifecycleOriginals)
        for index, entry in ipairs(context.panels) do
            local original = P.lifecycleOriginals[index]
            assert(entry ~= original and entry.placement.id == original.placement.id)
            assert(not entry.failed and entry.container)
            if not P.lifecyclePage then
                assert(entry.placement == original.placement and not entry.builtFullscreen)
            end
        end
        if P.lifecyclePage then
            assert(context.page ~= P.lifecyclePage)
        end
        if P.lifecycleRoot then
            assert(context.root and context.root ~= P.lifecycleRoot, "restart must recreate a discarded root")
        end
    end,
    ["open-location"] = function(context)
        local entry = assert(context.panels[1])
        assert(entry.module.id == "navigation" and entry.instance.feed.fix)
        local rect = context.dashboardLoader.panelRect(context, entry.placement)
        local point = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
        refreshFn(context, EVT_TOUCH_FIRST, point)
        refreshFn(context, EVT_TOUCH_TAP, point)
        assert(context.locationDetails and context.locationDetails.code)
    end,
    ["close-location"] = function(context)
        refreshFn(context, EVT_VIRTUAL_EXIT)
        assert(not context.locationDetails)
    end,
    ["open-menu"] = function(context)
        refreshFn(context, EVT_TOUCH_FIRST, { x = 10, y = 10 })
        refreshFn(context, EVT_TOUCH_TAP, { x = 10, y = 10 })
    end,
    ["check-menu"] = function(context)
        assert(context.aerogridMenu.open and context.aerogridMenu.screen)
    end,
    ["select-menu"] = function(context)
        refreshFn(context, EVT_ROT_RIGHT)
    end,
    ["close-menu"] = function(context)
        refreshFn(context, EVT_VIRTUAL_EXIT)
    end,
    ["open-log"] = function(context)
        local point
        for _, entry in ipairs(context.panels) do
            if entry.module.id == "host-diagnostics" and entry.settings.section == "log" then
                local rect = context.dashboardLoader.panelRect(context, entry.placement)
                point = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
            end
        end
        assert(point)
        refreshFn(context, EVT_TOUCH_FIRST, point)
        refreshFn(context, EVT_TOUCH_TAP, point)
        assert(context.logViewer, "native modal scenario must open log")
    end,
    ["check-log"] = function(context)
        local state = assert(context.logViewer)
        assert(not state.prepareIndex and not state.buildStage and not state.renderIndex, "log viewport must finish")
        assert(#state.entries == 256 and #state.rows > 0)
    end,
    ["scroll-log"] = function(context)
        refreshFn(context, EVT_ROT_LEFT)
    end,
    ["close-log"] = function(context)
        refreshFn(context, EVT_VIRTUAL_EXIT)
        assert(not context.logViewer)
    end,
    ["open-settings"] = function(context)
        context.aeroMenuHandlers.modelSettings()
        assert(context.modelSettingsUi)
    end,
    ["prepare-settings-source"] = function(context)
        local phase = config.phases[phaseIndex]
        local module = assert(loadScript(context.path .. "lib/model_settings_store.lua"))()
        local operations = assert(loadScript(context.path .. "lib/verified_file.lua"))().operations()
        local path = assert(module.path(context.path, context.flightBroker.filename))
        P.settingsSource, P.settingsSourcePath, P.settingsOriginal = phase.source, path, context.flightBroker.document
        if phase.source then
            write(path, phase.source)
        elseif operations.stat(path) then
            assert(operations.remove(path))
        end
        if phase.backup then
            write(path .. ".bak", phase.backup)
        elseif operations.stat(path .. ".bak") then
            assert(operations.remove(path .. ".bak"))
        end
        settingsMembers(context, phase)
    end,
    ["check-settings-open"] = function(context)
        local phase, state = config.phases[phaseIndex], context.modelSettingsUi
        if phase.closed then
            assert(not state)
            if phase.published then
                assert(
                    context.flightBroker.document.revision == phase.revision and not context.flightBroker.publication
                )
            else
                assert(context.flightBroker.document == P.settingsOriginal, "cancelled opening must not publish")
            end
            if config.expectedError then
                assert(context.errors[#context.errors] == config.expectedError)
            end
        else
            assert(state and not state.loading and not state.build)
            assert(state.revision == phase.revision and context.flightBroker.document.revision == phase.revision)
            assert(state.values.motorReversed == not not phase.reversed)
            assert(state.loadInfo.recovered == not not phase.recovered or phase.missing and state.loadInfo.missing)
            if phase.legacy then
                assert(string.find(P.settingsLegacyStatus, phase.legacy, 1, true))
            end
        end
        if P.settingsSource then
            local operations = assert(loadScript(context.path .. "lib/verified_file.lua"))().operations()
            local file = assert(operations.open(P.settingsSourcePath, "r"))
            local text = operations.read(file, operations.stat(P.settingsSourcePath).size)
            operations.close(file)
            assert(text == P.settingsSource, "opening must not rewrite edited settings")
        end
    end,
    ["fail-settings-identity"] = function(context)
        assert(context.modelSettingsUi.loading)
        context.modelSettingsUi.handlers.modelFilename = function()
            error("injected opening identity failure", 0)
        end
    end,
    ["retire-settings-member"] = function(context)
        local cursor = assert(context.modelSettingsUi.loading.cursor)
        context.flightBroker.members[cursor] = nil
    end,
    ["check-settings"] = function(context)
        assert(context.modelSettingsUi and not context.modelSettingsUi.build)
        if config.scenario == "modal-settings-reset" then
            local state = context.modelSettingsUi
            assert(state.armed == "L64" and state.sessionReset == "L03")
            assert(state.values.motorSource == "ch32" and state.values.flightSwitch == "L64")
        end
    end,
    ["edit-settings"] = function(context)
        local state = assert(context.modelSettingsUi)
        assert(not state.build and not state.saving)
        if config.scenario == "modal-settings-save-output" then
            model.setLogicalSwitch(62, { func = 17, v1 = 0, v2 = 0, v3 = 0, ["and"] = 0, delay = 0, duration = 0 })
            assert(model.getLogicalSwitch(62).func == 17, "fixture needs a dedicated Sticky output")
        end
        local phase = config.phases[phaseIndex]
        P.settingsState = state
        settingsMembers(context, phase)
        P.settingsRevision, P.settingsReversed = state.revision + 1, not state.values.motorReversed
        if phase.armed then
            P.settingsReversed = state.values.motorReversed
            P.settingsArmed = "L62"
            state.pending = { key = "armed", value = P.settingsArmed }
        else
            state.pending = { key = "motorReversed", value = P.settingsReversed }
        end
        if phase.reject then
            state.handlers.startSave = function()
                return nil, "injected save failure"
            end
        end
    end,
    ["check-settings-save"] = function(context)
        local state = assert(context.modelSettingsUi or P.settingsState)
        assert(not state.pending and not state.saving)
        assert(state.revision == P.settingsRevision and state.values.motorReversed == P.settingsReversed)
        assert(context.flightBroker.document.revision == state.revision)
        assert(context.flightBroker.document.flight.motorReversed == P.settingsReversed)
        if P.settingsArmed then
            assert(context.flightBroker.document.armed == P.settingsArmed)
            for _, host in ipairs(P.settingsMembers) do
                assert(host.modelArmingReload and host.reloadState == "clear" and next(host.navigationHomes) == nil)
            end
        end
    end,
    ["dismiss-settings"] = function(context)
        local phase, state = config.phases[phaseIndex], assert(context.modelSettingsUi)
        if phase.dismiss == "native" then
            state.dialog:clear()
            state.dialog = nil
            state.closing = true
        elseif phase.dismiss == "fullscreen" then
            P.settingsWindowLoss, P.settingsFullscreen = true, state.handlers.fullscreen
            state.handlers.fullscreen = function()
                return false
            end
        elseif phase.dismiss == "explicit" then
            assert(context.modelSettingsUiModule.close(context) == false)
        else
            context.modelSettingsUiModule.handle(context, EVT_VIRTUAL_EXIT)
        end
    end,
    ["replace-publication"] = function(context)
        local state = assert(context.modelSettingsUi)
        assert(state.saving and state.saving.phase == "publish")
        context.flightBroker:setDocument(context.flightBroker.document)
    end,
    ["check-settings-error"] = function(context)
        local state = assert(context.modelSettingsUi or P.settingsState)
        assert(not state.pending and not state.saving)
        assert(context.errors[#context.errors] == config.expectedError)
        assert(state.revision == context.flightBroker.document.revision)
        assert(
            state.revision
                == P.settingsRevision - (config.expectedError == "Model settings: injected save failure" and 1 or 0)
        )
    end,
    ["close-settings"] = function(context)
        refreshFn(context, EVT_VIRTUAL_EXIT)
        assert(not context.modelSettingsUi)
    end,
    ["open-editor"] = function(context)
        assert(context.editorController.openEditor(context), "native editor scenario must open the editor")
    end,
    ["check-editor"] = function(context)
        assert(
            context.editorUi and not context.editorUi.buildStage,
            "native editor scenario must reach a completed editor preview"
        )
    end,
    ["select-editor"] = function(context)
        refreshFn(context, EVT_ROT_RIGHT)
        assert(context.editorUi.renderStage, "ordinary editor input must queue bounded rendering")
    end,
    ["check-render"] = function(context)
        assert(context.editorUi and not context.editorUi.renderStage, "editor rendering must complete")
    end,
    ["open-drawer"] = function(context)
        refreshFn(context, EVT_VIRTUAL_ENTER)
        assert(context.editorUi and (context.editorUi.drawerOpen or context.editorUi.drawerBuild))
    end,
    ["prepare-editor-tap"] = function(context)
        local state = assert(context.editorUi)
        local rect = assert(state.controls[#state.session.draft.panels].rect)
        config.phases[phaseIndex].touch = {
            x = (context.left or 0) + rect.x + rect.w - 8,
            y = (context.top or 0) + rect.y + 8,
        }
    end,
    ["select-editor-add"] = function(context)
        context.editorUi.keyAdd = true
    end,
    ["check-drawer-cancelled"] = function(context)
        local state = assert(context.editorUi)
        assert(not state.drawerOpen and not state.nativeDrawer and state.mode == "menu")
    end,
    ["check-drawer"] = function(context)
        local state = assert(context.editorUi)
        assert(
            state.nativeDrawer and not state.drawerBuild and not state.drawerLayout and not state.renderStage,
            "native drawer construction must finish"
        )
        assert(#state.drawerControls == #state.drawerFields)
    end,
    ["open-entry-drawer"] = function(context)
        local state = assert(context.editorUi)
        for _, field in ipairs(state.drawerFields) do
            if field.action == "item" then
                context.editorDrawerModule.open(context, state, "configure", field.key, field.index, field.itemPath)
                return
            elseif field.action == "group" then
                context.editorDrawerModule.open(context, state, "configure", nil, nil, nil, field.drawerGroup)
                return
            end
        end
        error("native drawer scenario has no nested entry")
    end,
    ["write-drawer"] = function(context)
        local state, phase = assert(context.editorUi), config.phases[phaseIndex]
        assert(not state.drawerBuild and not state.drawerPending)
        for _, entry in ipairs(state.drawerControls) do
            local field = entry.field
            local value = state.session.draft.panels[state.session.selected].config[field.key]
            for _, key in ipairs(field.path or {}) do
                if type(value) == "table" then value = value[key] else value = nil end
            end
            if value == nil then value = field.value end
            if not field.action and field.type ~= "section" and value ~= nil and type(value) ~= "table"
                and (not phase.key or field.key == phase.key) then
                if field.choices then
                    for index, choice in ipairs(field.choices) do
                        if choice == value then value = field.choices[index % #field.choices + 1]; break end
                    end
                elseif field.type == "boolean" then
                    value = not value
                end
                P.drawerMutation = {
                    entry = entry, value = value, rejected = phase.reject or phase.nativeError, dirty = state.session.dirty,
                }
                state.drawerPending = {
                    action = phase.nativeError and "error" or "write", field = field, control = entry,
                    value = phase.reject and {} or value, message = "injected picker error",
                }
                return
            end
        end
        error("native mutation scenario has no scalar field")
    end,
    ["check-drawer-write"] = function(context)
        local state, mutation = assert(context.editorUi), assert(P.drawerMutation)
        assert(not state.drawerBuild and not state.drawerRefresh and not state.drawerPending and not state.renderStage)
        if mutation.rejected then
            assert(mutation.entry.errorShown and state.statusError and state.session.dirty == mutation.dirty)
            assert(context.errorLog and next(context.errorLog.messages), "validation failures must remain explicit")
        else
            assert(state.session.dirty and not mutation.entry.errorShown)
            local field = mutation.entry.field
            local value = state.session.draft.panels[state.session.selected].config[field.key]
            for _, key in ipairs(field.path or {}) do value = value[key] end
            assert(value == mutation.value)
        end
        for _, entry in ipairs(state.drawerControls) do
            if entry.object and entry.field.visibleWhen then
                assert(state.drawerBuildConfig == nil, "completed mutation releases its snapshot")
            end
        end
    end,
    ["close-editor"] = function(context)
        assert(context.editorUi and context.editorSession and not context.editorSession.dirty)
        context.editorUiModule.close(context, false)
        context.editorController.restorePreview(context)
        context.editorSession = nil
        assert(not context.editorUi, "native editor scenario must close the editor")
    end,
    ["edit-preview"] = function(context)
        local state = assert(context.editorUi)
        assert(not state.buildStage and not state.session.initializing)
        local entry = assert(context.panels[1])
        local key, value
        if entry.module.id == "navigation" then
            key, value = "showTape", not entry.settings.showTape
        elseif entry.module.id == "metric" then
            key, value = "visual", entry.settings.visual == "none" and "bar" or "none"
        else
            assert(entry.module.id == "chart")
            key, value = "smoothing", entry.settings.smoothing == "off" and "light" or "off"
        end
        assert(state.handlers.editor.setValue(state.session, key, value))
        state.auditSetting = { key = key, value = value }
        state.previewPending = true
    end,
    ["check-preview"] = function(context)
        local state = assert(context.editorUi)
        assert(not state.previewPending and not state.previewRefresh and not state.previewError)
        local entry = assert(context.panels[1])
        assert(entry.settings[state.auditSetting.key] == state.auditSetting.value)
        assert(context.editorPreviewChanged and not entry.failed)
    end,
    ["discard-editor"] = function(context)
        assert(context.editorUi).handlers.close(false)
        assert(not context.editorUi and not context.editorSession)
    end,
    reflow = function(context)
        local zone = context.zone
        context.zone = { w = zone.w - 8, h = zone.h, xabs = zone.xabs, yabs = zone.yabs }
    end,
    reload = function(context)
        context.reloadState = "clear"
    end,
}

for name, action in pairs(actions) do
    actions[name] = function(context, ...)
        local ok, message = pcall(action, context, ...)
        gate(ok, "action " .. name .. ": " .. tostring(message))
    end
end

local function callbackSurface(kind, context)
    if kind ~= "refresh" and not (kind == "background" and (context.modelSettingsUi or context.stage)) then
        return nil
    end
    local ui = context.editorUi
    if ui then
        if ui.session.initializing then
            return "editor-copy:" .. ui.session.initializing.phase
        end
        if ui.buildStage then
            return "editor-build:" .. tostring(ui.buildStage)
        end
        if ui.drawerOpen then
            return "editor-drawer:open:" .. ui.drawerOpen.mode
        end
        if ui.renderStage then
            return "editor-render:" .. tostring(ui.renderStage)
        end
        if ui.drawerRefresh then
            return "editor-drawer:" .. (ui.drawerLayout and "layout" or ui.drawerRefresh.phase)
        end
        if ui.drawerBuild then
            return "editor-drawer:"
                .. (ui.drawerLayout and "layout" or ui.drawerBuild <= #ui.drawerFields and "build" or "finish")
        end
        if ui.previewRefresh then
            local action = ui.previewRefresh.actions[ui.previewRefresh.index]
            local stage = not action and "finish"
                or not action.retired and "retire"
                or not action.preparedPlacement and "copy"
                or not action.prepared and "prepare"
                or "construct"
            return "editor-preview:" .. stage
        end
        if ui.drawerPending and context.editorDrawerModule.workBound(ui) then
            return "editor-drawer:" .. ui.drawerPending.action
        end
        for _, stage in ipairs({
            "saving",
            "drawerBuild",
            "drawerPending",
            "exitCommand",
            "previewPending",
            "previewRefresh",
        }) do
            if ui[stage] then
                return "editor:" .. stage
            end
        end
        return "editor-preview"
    end
    if context.logViewer then
        return "log-viewer:" .. context.logViewerModule.stageOf(context.logViewer)
    end
    if context.modelSettingsUi then
        return "settings:"
            .. context.modelSettingsUiModule.stageOf(context.modelSettingsUi)
            .. ":"
            .. tostring(context.modelSettingsUi.build or "idle")
    end
    if context.locationDetails then
        return "location"
    end
    if context.aerogridMenu and context.aerogridMenu.open then
        return "menu"
    end
    if context.stage then
        return "loader:" .. context.stage
    end
    return nil
end

local function runCallback(kind, context, fn, e, t)
    callbackIndex = callbackIndex + 1
    depth, topSum, top, topLabels = 0, 0, {}, {}
    local surface = callbackSurface(kind, context)
    P.editorInputSeen, P.editorInputAdmission = nil, nil
    P.lifecycleOperation, P.lifecycleAdmissionKind, P.lifecycleServiceOnly = nil, nil, nil
    local restarting = (kind == "refresh" or kind == "background") and context.reloadState == "rebuild"
    if restarting then
        P.lifecycleOperation = "restartLoading"
    end
    local c0 = count()
    fn(context, e, t)
    local c1 = count()
    pause(true)
    if restarting then
        gate(P.lifecycleAdmissionKind == "loader", "page restart must reserve service-only loader work")
    end
    if P.editorInputSeen or P.editorInputAdmission then
        surface = "editor-input"
    end
    if P.lifecycleOperation then
        surface = "lifecycle:" .. P.lifecycleOperation
        for _, label in ipairs(topLabels) do
            gate(
                not string.match(label, "^task:panel:")
                    and not string.match(label, "^panel:[^:]+:refresh")
                    and not string.match(label, "^panel:[^:]+:background")
                    and not string.match(label, "^chart:"),
                surface .. " refreshed a hidden panel: " .. label
            )
        end
    end
    local total = c1 - c0 - K_CALLBACK
    if P.lifecycleOperation then
        gate(total <= 15000, surface .. " exceeds the complete lifecycle callback ceiling: " .. total)
        if P.lifecycleServiceOnly then
            local fitted = math.ceil(((total - topSum) * 1.10 + 50) / 10) * 10
            gate(fitted <= 2400, surface .. " exceeds the service-only fixed overhead: " .. fitted)
        end
    end
    if surface and string.sub(surface, 1, 7) == "loader:" then
        gate(total <= 15000, surface .. " exceeds the complete loading callback ceiling: " .. total)
        for _, label in ipairs(topLabels) do
            gate(
                not string.match(label, "^task:panel:")
                    and not string.match(label, "^panel:[^:]+:refresh")
                    and not string.match(label, "^panel:[^:]+:background")
                    and not string.match(label, "^chart:"),
                surface .. " refreshed a hidden panel: " .. label
            )
        end
    end
    if string.match(config.scenario, "^lifecycle%-") then
        gate(total <= 15000, kind .. " exceeds the complete lifecycle callback ceiling: " .. total)
    end
    if string.match(config.scenario, "^migration%-tasks%-") then
        gate(total <= 15000, kind .. " exceeds the complete migration callback ceiling: " .. total)
    end
    if previewTasks or surface == "editor-preview" and string.match(config.scenario, "^editor%-preview%-") then
        gate(total <= 15000, kind .. " exceeds the complete preview callback ceiling: " .. total)
        if previewTasks and surface == "editor-preview" then
            for _, label in ipairs(topLabels) do
                gate(
                    not string.match(label, "^panel:") and not string.match(label, "^chart:"),
                    "scheduler-owned preview dispatched legacy work: " .. label
                )
            end
        end
    end
    local paintSurface = surface
        and (
            surface == "editor-input"
            or string.match(surface, "^editor%-render:[2-6]$")
            or string.match(surface, "^editor%-drawer:")
        )
    if
        (kind == "refresh" or kind == "background")
        and (paintSurface or string.sub(config.scenario, 1, 6) == "modal-" and surface)
    then
        gate(total <= 15000, surface .. " exceeds the complete callback ceiling: " .. total)
        for _, label in ipairs(topLabels) do
            gate(
                not string.match(label, "^panel:")
                    and not string.match(label, "^chart:")
                    and not string.match(label, "^task:panel:"),
                surface .. " refreshed a hidden panel: " .. label
            )
        end
    end
    local overhead = total - topSum
    local suffix = P.loaded and "" or "@load"
    if recording then
        record("callback:" .. kind .. suffix, total, overhead, 1)
        for _, item in ipairs(top) do
            local label, cost = string.match(item, "^(task:service:[^=]+)=(%d+)")
            if label then
                record("eligibility:" .. kind .. suffix .. ":" .. label, tonumber(cost), tonumber(cost), 1)
            end
        end
        if surface then
            record("surface:" .. surface .. ":" .. kind .. suffix, total, overhead, 1, table.concat(top, ","))
        end
        local phase = config.phases[phaseIndex]
        if P.loaded and phase and phase.name then
            record("phase:" .. phase.name .. ":" .. kind, total, overhead, 1)
        end
        local variant = #top == 0 and "idle" or "busy"
        record("overhead:" .. kind .. suffix .. ":" .. variant, overhead, overhead, 1)
        if #top == 1 then
            record("overhead:" .. kind .. suffix .. ":" .. topLabels[1], overhead, overhead, 1)
        end
    end
    kindCounts[kind] = (kindCounts[kind] or 0) + 1
    if P.loaded and recording then
        worst[#worst + 1] =
            { total = total, text = kind .. "|" .. total .. "|" .. overhead .. "|" .. table.concat(top, ",") }
        table.sort(worst, function(a, b)
            return a.total > b.total
        end)
        worst[9] = nil
    end
    local phase = config.phases[phaseIndex]
    if phase and phase.trace and #trace < (config.traceLimit or 3000) then
        trace[#trace + 1] =
            string.format("%s|%d|%d|%d|%s", kind, realTime() + P.offset, total, overhead, table.concat(top, ","))
    end
    pause(false)
    return total
end

local function advance(context)
    local phase = config.phases[phaseIndex]
    if not phase then
        return
    end
    phaseDone = phaseDone + 1
    if phase.untilConstruction and P.construction.done then
        phaseDone = phase.callbacks
    end
    if phase.untilSettings then
        local state = context.modelSettingsUi
        local reached = phase.untilSettings == "closed" and not state
            or state and context.modelSettingsUiModule.stageOf(state) == phase.untilSettings
        if reached and phase.untilSettingsCursor then
            reached = state.loading and state.loading.cursor ~= nil
        end
        if not reached and phaseDone < phase.callbacks then
            return
        end
        gate(reached, "settings phase not reached: " .. phase.untilSettings)
        if reached then
            phaseDone = phase.callbacks
        end
    end
    if phaseDone >= phase.callbacks then
        phaseIndex, phaseDone = phaseIndex + 1, 0
        if not config.phases[phaseIndex] then
            report(context)
        end
    end
end

function P.register(refresh, background)
    refreshFn, backgroundFn = refresh, background
end

-- The counter globals appear when the firmware first starts a callback.
local function connect()
    if not count and __count then
        count, pause = __count, __pause
        calibrate()
    end
    return count ~= nil
end

-- Known-length callbacks compare the exact counter with the firmware's getUsage.
local loopCounts, loopUsages = {}, {}
local function loopsEntry()
    local index = callbackIndex + 1
    local iterations = config.loops[index]
    if iterations == nil then
        write("/audit-results.json", json({ counts = loopCounts, usages = loopUsages }))
        write("/audit-ready.txt", "done")
        finished = true
        return
    end
    callbackIndex = index
    loopUsages[index] = getUsage()
    local c0 = count and count()
    local x = 0
    for i = 1, iterations do
        x = x + i
    end
    loopCounts[index] = count and count() - c0 or 0
end

local function entry(kind, context, fn, e, t)
    if finished then
        return
    end
    if config.loops then
        connect()
        return loopsEntry()
    end
    if not connect() then
        return fn(context, e, t)
    end
    install(context)
    if config.progress and callbackIndex % config.progress == 0 then
        write(
            "/audit-progress.txt",
            string.format(
                "kind=%s callbacks=%d phase=%d done=%d stage=%s panels=%d app=%s retire=%s errors=%s\n",
                kind,
                callbackIndex,
                phaseIndex,
                phaseDone,
                tostring(context.stage),
                #context.panels,
                tostring(context.appRebuild and context.appRebuild.phase),
                tostring(context.pageRetirement and context.pageRetirement.phase),
                table.concat(context.errors, ";")
            )
        )
    end
    local currentErrors = unexpectedErrors(context)
    if #currentErrors > 0 and not errorsSeen[1] then
        errorsSeen[1] = table.concat(currentErrors, "; ")
        if config.failOnError then
            report(context)
            return
        end
    end
    if not ready(context) then
        P.loaded = false
        recording = config.recordLoad ~= false
        runCallback(kind, context, fn, e, t)
        recording = true
        return
    end
    P.loaded = true
    if not P.diagnosticsSeeded then
        P.diagnosticsSeeded = true
        local telemetry = context.serviceRuntime and context.serviceRuntime.byId.telemetry
        for index = 1, config.diagnosticsSources or 0 do
            telemetry:subscribe(string.format("S%02d", index))
        end
        for index = 1, config.logEntries or 0 do
            context.diagnosticsLog:append(
                context,
                "audit",
                "message "
                    .. index
                    .. (string.sub(config.scenario, 1, 9) == "modal-log" and string.rep("long message ", 32) or ""),
                index * 100
            )
        end
    end
    local phase = config.phases[phaseIndex]
    if not phase then
        return
    end
    if phase.action and not phase.started then
        phase.started = true
        runCallback("action:" .. phase.action, context, assert(actions[phase.action], "unknown native action"))
        return
    end
    recording = phase.record ~= false
    local target = phase.advance and assert(actions[phase.advance], "unknown native advance")
        or phase.kind == "background" and backgroundFn
        or fn
    local callbackEvent = e
    if phase.event and not phase.eventSent then
        callbackEvent = assert(_G[phase.event], "unknown native event: " .. phase.event)
    end
    local callbackTouch = phase.touch or t
    local step = phase.step or 0
    if kind == "background" and phase.kind ~= "background" then
        runCallback(kind, context, fn, e, t)
    elseif step > 0 and kind == "refresh" then
        for _ = 1, phase.perCall or 1 do
            P.offset = P.offset + step
            runCallback(phase.kind or kind, context, target, callbackEvent, callbackTouch)
            if phase.event then
                phase.eventSent, callbackEvent = true, e
            end
            advance(context)
            if finished or config.phases[phaseIndex] ~= phase then
                break
            end
        end
    else
        runCallback(phase.kind or kind, context, target, callbackEvent, callbackTouch)
        if phase.event then
            phase.eventSent = true
        end
        advance(context)
    end
    recording = true
end

function P.entry(kind, context, fn, e, t)
    local ok, message = pcall(entry, kind, context, fn, e, t)
    if not ok then
        pause(false)
        write("/audit-error.txt", tostring(message) .. "\n")
        write("/audit-ready.txt", "failed")
        finished = true
    end
end

function P.plain(kind, fn, ...)
    if finished or not connect() then
        return fn(...)
    end
    local c0 = count()
    local result = fn(...)
    local c1 = count()
    pause(true)
    record("callback:" .. kind, c1 - c0 - K_CALLBACK, c1 - c0 - K_CALLBACK, 1)
    pause(false)
    return result
end

P.config = config
return P
