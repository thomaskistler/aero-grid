-- SPDX-License-Identifier: GPL-2.0-only
-- Scheduler audit probe. Copied only into an isolated simulator SD image.
--
-- `__count` and `__pause` come from tools/audit-native.cpp. Every measurement
-- window reads the exact instruction counter; bookkeeping runs with the counter
-- paused, so recording a sample does not change what is recorded.

local config = assert(loadScript("/WIDGETS/AeroGrid/audit/config.lua"))()
local costs = assert(loadScript("/WIDGETS/AeroGrid/audit/costs.lua"))(nil, true)
local previewTasks = string.match(config.scenario, "^editor%-preview%-.+%-tasks$") ~= nil
local count, nativePause
local counterRunning = true
local function pause(flag)
    nativePause(flag)
    counterRunning = not flag
end
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
if config.deterministicClock then
    _G.getTime = function()
        return P.offset
    end
else
    _G.getTime = function()
        return realTime() + P.offset
    end
end

local stats, trace, errorsSeen, worst = {}, {}, {}, {}
local gateErrors = {}
local historySamples = {}
-- Exact ceil10(1.1 * cost), including on int32/float32 radio Lua.
local function fit(cost)
    return ((11 * cost + 99) // 100) * 10
end

local function gate(condition, message)
    if not condition then
        gateErrors[message] = true
    end
end
local depth, childSum, visits, childList = 0, {}, {}, {}
local childLeak, grants = {}, {}
local callbackLeak = 0
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
    assert(cost >= 0 and own >= 0, "invalid native instruction observation: " .. label)
    local entry = stats[label]
    if not entry then
        entry = { n = 0, sum = 0, max = 0, min = math.huge, selfMin = math.huge, selfMax = 0, units = {} }
        stats[label] = entry
    end
    entry.n = entry.n + 1
    entry.selfMin = math.min(entry.selfMin, own)
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
        bucket = { n = 0, min = cost, max = 0, selfMin = own, selfMax = 0 }
        entry.units[units] = bucket
    end
    bucket.n = bucket.n + 1
    bucket.min = math.min(bucket.min, cost)
    bucket.selfMin = math.min(bucket.selfMin, own)
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
    local cost = raw - K - childLeak[d]
    local own = cost - childSum[d]
    local children = table.concat(childList[d], ",")
    depth = d - 1
    if type(label) ~= "string" then
        label = "unlabelled"
    end
    local units = string.match(label, "^task:") and grants[d] or visits[d]
    if label == "scheduler:ready:settled" then
        P.settledReadyCost = cost
    elseif string.match(label, "^scheduler:finish:") then
        P.hostFinishCost = own
        P.hostCallbackKind = string.sub(label, #"scheduler:finish:" + 1)
    end
    if label == "flight:enableScheduler" then
        local fitted = fit(cost)
        gate(fitted <= 3600, "Flight handoff exceeds its one-time head reservation: " .. fitted)
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
    local loadStage = string.match(label, "^load:([%w%-]+)$")
    local loadBound = loaderDeclarations[label] or loadStage and costs.bounds["dashboard-loader"][loadStage]
    local resolution = string.match(label, "^load:theme%-resolve:(%a+)$")
    if resolution then
        loadBound = costs:bound("theme-resolution", resolution)
    elseif string.match(label, "^load:theme%-publish:") then
        loadBound = costs:bound("dashboard-loader", "theme-publish")
    end
    if loadBound then
        local fitted = fit(cost)
        gate(fitted <= loadBound, label .. " exceeds its bounded loading charge: " .. cost .. " -> " .. fitted)
    end
    local boundedReflow = string.match(label, "^lifecycle:advanceReflow:")
    if label == "lifecycle:advanceReflow" or boundedReflow then
        gate(cost <= 4000, "complete geometry advance exceeds the atom cap: " .. cost)
    end
    local loadingConstructor = string.match(label, "^load:panel%-build:([^:]+)$")
        or string.match(label, "^load:panel%-construct:([^:]+):")
    local loadingPreparation = string.match(label, "^load:panel%-prepare:")
    if
        string.match(label, "^lifecycle:advanceAppRebuild:")
        or string.match(label, "^lifecycle:retirePage:")
        or label == "lifecycle:rebuildPage"
        or label == "lifecycle:restartLoading"
        or loadingConstructor and boundedConstructors[loadingConstructor]
        or loadingPreparation
        or string.match(label, "^load:flight%-load%-wait:shared:")
        or boundedReflow
        or label == "lifecycle:advanceReflow"
        or label == "lifecycle:beginReflow"
    then
        local fitted = fit(cost)
        gate(fitted <= 4000, label .. " exceeds the fitted lifecycle atom cap: " .. cost .. " -> " .. fitted)
        local bound = label == "lifecycle:restartLoading" and 600
            or label == "lifecycle:rebuildPage" and 200
            or string.match(label, "^load:flight%-load%-wait:shared:") and loaderDeclarations[label]
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
        gate(not bound or fit(cost) <= bound, label .. " exceeds its declared modal charge: " .. cost .. " -> " .. fit(cost))
    end
    if string.sub(label, 1, 5) == "unit:" and depth >= 1 then
        visits[depth] = visits[depth] + 1
    end
    if depth >= 1 then
        childSum[depth] = childSum[depth] + cost
        childLeak[depth] = childLeak[depth] + leak + childLeak[d]
        local siblings = childList[depth]
        siblings[#siblings + 1] = label .. "=" .. cost
    elseif label == "flight:identity" then
        callbackLeak = callbackLeak + leak + childLeak[d]
        -- Runs in every callback: part of the fixed overhead, not a schedulable task.
    else
        topSum = topSum + cost
        callbackLeak = callbackLeak + leak + childLeak[d]
        top[#top + 1] = label .. "=" .. cost .. (units > 0 and "/" .. units or "")
        topLabels[#topLabels + 1] = label
    end
    if recording then
        record(label, cost, own, units > 0 and units or 1, children)
        if string.match(label, "^scheduler:ready:") then
            record("scheduler:ready", cost, own, units > 0 and units or 1, children)
            local fitted = fit(cost)
            gate(fitted <= 4000, "host readiness exceeds its fitted atom cap: " .. cost .. " -> " .. fitted)
            gate(fitted <= P.readinessBound, "host readiness exceeds its work charge: " .. cost .. " -> " .. fitted)
            local job = P.readinessHost and P.readinessHost.reconciliation
            if string.match(label, "^scheduler:ready:panel%-only:") or label == "scheduler:ready:begin" and job and job.panelOnly then
                local panelLabel = label == "scheduler:ready:begin" and "scheduler:ready:panel-only:begin" or label
                record(panelLabel, cost, own, units > 0 and units or 1, children)
                gate(fitted <= P.readinessHost.RECONCILE_COST,
                    panelLabel .. " exceeds its fitted reconciliation charge: " .. fitted)
            end
        end
        if string.match(label, "^editor:input:") then
            gate(cost <= 4000, label .. " exceeds the editor input atom cap: " .. cost)
            local bound = P.editorInputBounds and P.editorInputBounds[string.sub(label, #"editor:input:" + 1)]
            if bound then
                gate(fit(cost) <= bound, label .. " exceeds the editor input charge: " .. cost .. " -> " .. fit(cost))
            end
        end
        if boundedReflow then
            record("lifecycle:advanceReflow", cost, own, units > 0 and units or 1, children)
        end
        local stage = tonumber(string.match(label, "^editor:advanceEditor:render:(%d+)$"))
        local opening = string.match(label, "^editor:advanceEditor:drawer%-open:(%a+)$")
        if opening then
            gate(cost <= 4000, label .. " exceeds the drawer-open atom cap: " .. cost)
            gate(fit(cost) <= P.editorOpenBounds[opening], label .. " exceeds the drawer-open charge: " .. cost .. " -> " .. fit(cost))
        end
        local dragStage = string.match(label, "^editor:advanceEditor:drag:(%a+)$")
        if dragStage and P.editorDragBounds then
            gate(cost <= 4000, label .. " exceeds the drag atom cap: " .. cost)
            gate(fit(cost) <= P.editorDragBounds[dragStage], label .. " exceeds the drag charge: " .. cost .. " -> " .. fit(cost))
        end
        local layoutStep = string.match(label, "^editor:advanceEditor:layout:([%w_%-]+)$")
        if layoutStep then
            gate(fit(cost) <= 4000, label .. " exceeds the fitted layout atom cap: " .. cost .. " -> " .. fit(cost))
            local bound = P.editorLayoutBounds and P.editorLayoutBounds[layoutStep]
            if bound then
                gate(fit(cost) <= bound, label .. " exceeds the layout charge: " .. cost .. " -> " .. fit(cost))
            end
        end
        if stage and stage >= 2 and P.editorRenderBounds then
            gate(cost <= 4000, label .. " exceeds the editor paint atom cap: " .. cost)
            gate(
                fit(cost) <= P.editorRenderBounds[stage == 6 and "finish" or "rows"],
                label .. " exceeds the editor paint charge: " .. cost .. " -> " .. fit(cost)
            )
        end
        local drawerStage = string.match(label, "^editor:drawer:advance:([%w_%-]+)")
        if label == "editor:drawer:open" then
            gate(cost <= 4000, label .. " exceeds the drawer opening atom cap: " .. cost)
        end
        local drawerBound = drawerStage and P.editorDrawerBounds and P.editorDrawerBounds[drawerStage]
        if drawerBound then
            gate(cost <= 4000, label .. " exceeds the drawer atom cap: " .. cost)
            gate(fit(cost) <= drawerBound, label .. " exceeds the drawer work charge: " .. cost .. " -> " .. fit(cost))
        end
        local settingsStage = string.match(label, "^modal:settings:advance:([%w_%-]+)")
        local settingsBound = settingsStage and P.settingsBounds and P.settingsBounds[settingsStage]
        if settingsBound then
            gate(fit(cost) <= settingsBound, label .. " exceeds the settings work charge: " .. cost .. " -> " .. fit(cost))
        end
        local saveStage = string.match(label, "^modal:settings:store:([%w_]+)")
        local saveBound = saveStage and P.settingsStoreBounds and P.settingsStoreBounds[saveStage]
        if saveBound then
            gate(fit(cost) <= saveBound, label .. " exceeds the settings store charge: " .. cost .. " -> " .. fit(cost))
        end
        local loadStage = string.match(label, "^modal:settings:load:([%w_]+)")
        local loadBound = loadStage and P.settingsLoadBounds and P.settingsLoadBounds[loadStage]
        if loadBound then
            gate(cost <= 4000 and fit(cost) <= loadBound, label .. " exceeds the settings reader charge: " .. cost .. " -> " .. fit(cost))
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
    -- Label getters and audit setup are not application work. A wrapped call
    -- made there must stay paused and cannot become a child of the real span.
    if not counterRunning then
        return fn(a, b, c, d, e, f, g, h)
    end
    pause(true)
    depth = depth + 1
    childSum[depth], visits[depth], childList[depth] = 0, 0, {}
    childLeak[depth], grants[depth] = 0, b
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
    local declaration = rawget(owner, "reflowDecl")
    if
        (key == "reflow" or key == "update")
        and type(declaration) == "table"
        and rawget(declaration, "callback") == original
    then
        declaration.callback = owner[key]
    end
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
    K = calibrationRaw - 1
    local baseline = window(function()
        empty()
    end)
    local direct = window(function()
        span("calibrate", empty)
    end)
    local wrapped = wrap("calibrate", empty)
    local viaWrapper = window(function()
        wrapped()
    end)
    calibrating = false
    LEAK_SPAN = direct - baseline
    LEAK_WRAP = viaWrapper - baseline
    local shape = function() end
    local c0 = count()
    local c1 = count()
    local floor = c1 - c0
    c0 = count()
    shape(P, c0, c1)
    c1 = count()
    K_CALLBACK = c1 - c0 - floor
    local child = empty
    local function parent()
        local value = child()
        return value
    end
    span("calibration:parent", parent)
    child = wrap("calibration:child", empty)
    span("calibration:parent", parent)
    assert(stats["calibration:parent"].min == stats["calibration:parent"].max,
        "native nested instruction calibration changed the parent cost")
    local middle = parent
    local function grandparent()
        local value = middle()
        return value
    end
    span("calibration:grandparent", grandparent)
    middle = wrap("calibration:middle", parent)
    span("calibration:grandparent", grandparent)
    assert(stats["calibration:grandparent"].min == stats["calibration:grandparent"].max,
        "native instruction calibration subtracted descendants twice")
    local samples = stats["calibration:child"].n
    span(function(token)
        child()
        return token == nil and true or "calibration:bookkeeping"
    end, parent)
    assert(stats["calibration:bookkeeping"].min == stats["calibration:parent"].min,
        "native label bookkeeping changed the parent cost")
    assert(stats["calibration:child"].n == samples + 1,
        "native label bookkeeping was recorded as application work")
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

local function preparationPhase(work)
    if not work then
        return "module"
    end
    local phase = work.phase
    if phase == "settings" then
        local resolution = work.resolution
        phase = phase .. ":" .. resolution.phase
        if resolution.phase == "validation" then
            phase = phase .. ":" .. tostring(resolution.validation.phase)
        end
    end
    return phase
end

local function loadLabel(token, context)
    if token == nil then
        local stage = context.stage or "idle"
        local bound = context.dashboardLoader.workBound and context.dashboardLoader.workBound(context)
        if stage == "flight-load-wait" then
            local owner = context.flightLoading.owner
            local current = owner:loadingContext()
            if current and current.flightLoading and not owner.documentLoaded then
                local job = current.flightLoading.job
                stage = stage .. ":shared:" .. tostring(current.stage)
                    .. (job and ":" .. tostring(job.stage) or "")
                    .. (job and job.load and ":" .. tostring(job.load.stage) or "")
            end
        end
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
                if context.stage == "panel-prepare" then
                    stage = stage .. ":" .. preparationPhase(context.panelPreparation)
                end
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
    local dragStage = not ui.previewPending and not ui.previewRefresh and not ui.exitCommand
        and context.editorUiModule.dragStage(ui)
    if dragStage then
        return "drag:" .. dragStage
    end
    if ui.renderStage and not ui.previewPending and not ui.previewRefresh and not ui.exitCommand then
        if ui.renderStage == 1 and ui.handlers.layoutStep then
            return "layout:" .. (ui.layoutJob and ui.handlers.layoutStep(ui.layoutJob) or "visit")
        end
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
    local history = context.serviceRuntime and context.serviceRuntime.byId.history
    if config.deterministicClock and history and not historySamples[history] then
        local samples, sample = {}, history.sample
        historySamples[history] = samples
        history.sample = function(self, reading, now)
            local result = sample(self, reading, now)
            pause(true)
            if
                reading.fresh and reading.updatedAt == now and reading.kind == "number"
                and type(reading.value) == "number" and reading.value == reading.value
                and reading.value ~= math.huge and reading.value ~= -math.huge
            then
                for _, entry in ipairs(self.sources[reading.name] or {}) do
                    if entry.session.state.recording and entry.sampledAt == now then
                        local row = samples[entry]
                        if not row then
                            row = { count = 0, first = now, last = now, maxGap = 0 }
                            samples[entry] = row
                        end
                        row.maxGap = math.max(row.maxGap, now - row.last)
                        row.count, row.last = row.count + 1, now
                    end
                end
            end
            pause(false)
            return result
        end
    end
    local scheduling = context.schedulerHost
    if scheduling and not installed[scheduling] then
        installed[scheduling] = true
        wrapField(scheduling.scheduler, "run", function(token, current)
            if token then
                local plan = current.lastPlan
                return "scheduler:framework:" .. tostring(plan.examined) .. ":" .. tostring(plan.ran)
            end
            return true
        end)
        wrapField(scheduling, "ready", function(token)
            if token then
                P.readinessBound = math.max(scheduling.panelSetup, scheduling.RECONCILE_COST)
                P.readinessHost = scheduling
                return "scheduler:ready:" .. token
            end
            local job = scheduling.reconciliation
            if job then
                return (job.panelOnly and "panel-only:" or "") .. job.phase
            elseif
                scheduling.checked ~= context.panels
                or scheduling.registry ~= context.serviceRuntime
                or context.panelTasksDirty
            then
                return "begin"
            elseif scheduling.pendingPanels then
                return "panel-enroll"
            elseif scheduling.waiting[1] then
                return "service-enroll"
            end
            return "settled"
        end)
        wrapField(scheduling, "finish", function(token, _, kind)
            if token then
                local observation = P.flightAdmissionPending
                if observation then
                    local plan = scheduling.scheduler.lastPlan
                    observation.planKind, observation.used, observation.ran = plan.kind, plan.U, plan.ran
                    observation.dueAfter = scheduling.scheduler:dueOf("service:flight")
                    if observation.due and observation.dueAfter and observation.due <= observation.at
                        and observation.dueAfter > observation.due then
                        P.firstFlightRelease = observation.at
                    end
                    P.flightAdmission[#P.flightAdmission + 1] = observation
                    P.flightAdmissionPending = nil
                end
                local job = scheduling.reconciliation
                return "scheduler:finish:" .. (job and not job.servicesLive and "host-reconcile" or token)
            end
            if config.deterministicClock and not P.firstFlightRelease and scheduling.scheduler then
                P.flightAdmission = P.flightAdmission or {}
                P.flightAdmissionPending = {
                    at = getTime(),
                    kind = kind or "steady",
                    due = scheduling.scheduler:dueOf("service:flight"),
                    phase = scheduling.reconciliation and scheduling.reconciliation.phase,
                }
            end
            if kind == "editor-input" then
                P.editorInputAdmission = true
            end
            P.lifecycleAdmissionKind = kind
            if kind == "loader" and (context.reloadState or context.appRebuild or context.reflowIndex) then
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
    local registration = context.flightRegistration
    if registration and not installed[registration] then
        installed[registration] = true
        wrapField(registration, "begin", "registration:begin")
        wrapField(registration, "beginLoad", "registration:beginLoad")
        wrapField(registration, "advance", function(token, job)
            return token == nil and (job.done and "done" or job.stage)
                or "registration:advance:" .. token
        end)
    end
    local lifecycle = context.dashboardLifecycle
    if lifecycle and not installed[lifecycle] then
        installed[lifecycle] = true
        for key, value in pairs(lifecycle) do
            if type(value) == "function" and key ~= "workBound" then
                local name = key
                local label = "lifecycle:" .. name
                if name == "beginReflow" or name == "advanceReflow" then
                    label = function(token, current)
                        if token then
                            return token
                        end
                        local label = "lifecycle:" .. name
                        local entry = current.panels[current.reflowIndex or 0]
                        if name == "advanceReflow" and entry and not entry.failed then
                            local work = entry.instance.reflowWork
                            local stage = current.reflowEntry ~= entry or not work or work.invalidated
                            local prefix = current.recordingReflow and "recorded:lifecycle:advanceReflow:"
                                or "lifecycle:advanceReflow:"
                            label = prefix
                                .. entry.module.id
                                .. ":"
                                .. (not rawget(entry.module, "reflow") and "update" or stage and "begin" or work.stage)
                        elseif name == "advanceReflow" then
                            label = label .. (current.reflowIndex and not entry and ":finish" or ":skip")
                        end
                        P.lifecycleBounds = P.lifecycleBounds or {}
                        local bound = lifecycle.workBound(current, name)
                        P.lifecycleBounds[label] = bound
                        if not config.constructionParity then
                            P.lifecycleOperation = name
                            gate(
                                (bound ~= nil) == (P.lifecycleAdmissionKind == "loader"),
                                label .. " has incorrect geometry service admission"
                            )
                            P.lifecycleServiceOnly = bound ~= nil
                        end
                        return label
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
                            if job.phase == "prepare" then
                                phase = phase .. ":" .. preparationPhase(job.preparation)
                            end
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
        wrapField(store, "startLoad", "modal:settings:load:start")
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
    P.editorDragBounds = context.editorUiModule and context.editorUiModule.DRAG_BOUNDS
    P.editorLayoutBounds = context.editorUiModule and context.editorUiModule.LAYOUT_BOUNDS
    if context.editorUiModule then
        wrapField(context.editorUiModule, "handle", function(token, current, e)
            if token then
                return "editor:input:" .. token
            end
            P.editorInputSeen = true
            local state, stage = current.editorUi
            local bound = current.editorUiModule.inputWorkBound(current, e)
            if bound then
                if state.drawerOpen then
                    stage = "cancel"
                elseif state.mode ~= "menu" then
                    stage = "modal"
                else
                    for event, candidate in pairs({
                        EVT_VIRTUAL_ENTER = "open", EVT_TOUCH_TAP = "tap",
                        EVT_VIRTUAL_PREV = "select", EVT_VIRTUAL_NEXT = "select",
                        EVT_ROT_LEFT = "select", EVT_ROT_RIGHT = "select",
                        EVT_TOUCH_BREAK = "release", EVT_TOUCH_FIRST = "first", EVT_TOUCH_SLIDE = "slide",
                    }) do
                        if _G[event] ~= nil and e == _G[event] then stage = candidate; break end
                    end
                end
                assert(stage, "native editor input has a bound but no identified operation")
            end
            local name = stage and "bound:" .. stage
                or tostring(state and state.mode) .. ":" .. tostring(e)
            P.editorInputBounds = P.editorInputBounds or {}
            P.editorInputBounds[name] = bound
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
            if drawer.workBound(state) == nil then return "external-unbounded" end
            if state.drawerOpening then
                return state.drawerOpening.phase
            elseif state.drawerLayout then
                return "layout"
            elseif state.drawerRefresh then
                return state.drawerRefresh.phase
            elseif state.drawerBuild then
                return state.drawerBuild <= #state.drawerFields
                        and "build:" .. tostring(state.drawerFields[state.drawerBuild].type)
                    or "finish"
            end
            local action = state.drawerPending and state.drawerPending.action
            if action == "parent" or action == "group" or action == "item" then
                return "navigate:" .. action
            elseif action == "add" then
                return "add-" .. (state.drawerPending.phase or "module")
            end
            return action or "command"
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
            local original = support.poll
            support.poll = function(owner, cursorKey, remainingKey, entries, cap, grant, target, visit, now)
                local label = "unit:" .. tostring(owner and owner.id)
                return original(owner, cursorKey, remainingKey, entries, cap, grant, target, function(t, entry, at)
                    return core(LEAK_WRAP, label, visit or entry.read, t, entry, at)
                end, now)
            end
        end
        for _, instance in ipairs(runtime.order) do
            if not installed[instance] then
                installed[instance] = true
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
                    wrapField(task.instance, "step", function(token, current, _, stage)
                        return token == nil and stage or "task:" .. current.id .. ":" .. tostring(token)
                    end)
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
                for _, item in ipairs(instance.schedulerTasks or {}) do
                    wrapField(item.instance, "step", "flight-" .. name .. ":" .. item.id)
                end
            end
        end
    end
    if broker and not installed[broker] then
        installed[broker] = true
        wrapField(broker, "tick", "flight:tick")
        wrapField(broker, "enableScheduler", "flight:enableScheduler")
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
    local history = context and context.serviceRuntime and context.serviceRuntime.byId.history
    local samples = history and historySamples[history]
    for _, entry in ipairs(context and context.panels or {}) do
        for _, item in ipairs(entry.instance.series or {}) do
            local feed = item.feed
            if feed and feed.last then
                rows[#rows + 1] = {
                    first = feed.first,
                    last = feed.last,
                    full = feed.full == true,
                    panel = config.deterministicClock and entry.placement.id or nil,
                    source = config.deterministicClock and item.settings.source or nil,
                    samples = samples and samples[history.views[feed]],
                }
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
    if config.flightModelSwitch then
        gate(P.flightSwitchDone, "parked-owner model-switch loading did not complete")
    end
    if config.flightOwnerHandoff then
        gate(P.flightHandoffDone, "parked-owner Flight migration did not complete")
    end
    gate(not config.expectedError or P.expectedErrorSeen, "expected scenario error was not reported")
    if string.match(config.scenario, "^migration%-tasks%-") then
        local scheduling = context.schedulerHost
        gate(
            scheduling and not scheduling.reconciliation and not scheduling.pendingPanels,
            "host readiness never settled"
        )
        for _, name in ipairs({ "flight", "smart" }) do
            gate(stats["task:service:" .. name .. ":run"], "canonical task never ran: " .. name)
        end
        local telemetry = context.serviceRuntime and context.serviceRuntime.byId.telemetry
        for _, item in ipairs(telemetry and telemetry.schedulerTasks or {}) do
            if telemetry.count > 0 and item.instance.want > 0 then
                gate(stats[item.id], "Telemetry task never ran: " .. item.id)
            end
        end
        for _, entry in ipairs(context.panels) do
            if not entry.module.idle then
                local prefix, observed = "task:panel:" .. entry.module.id .. ":", false
                for label in pairs(stats) do
                    observed = observed or string.sub(label, 1, #prefix) == prefix
                end
                gate(observed, "panel task never ran: " .. entry.module.id)
            end
        end
    end
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
            selfMin = entry.selfMin,
            worstChildren = entry.worstChildren,
            units = units,
        }
    end
    write(
        "/audit-results.json",
        json({
            scenario = config.scenario,
            deterministicClock = config.deterministicClock == true,
            calibration = { K = K, leakWrap = LEAK_WRAP, leakSpan = LEAK_SPAN, callbackK = K_CALLBACK },
            panels = context and #context.panels or 0,
            errors = errors,
            expectedError = config.expectedError and { message = config.expectedError, observed = P.expectedErrorSeen },
            callbacks = kindCounts,
            feeds = feeds(context),
            firstFlightRelease = P.firstFlightRelease,
            flightAdmission = P.flightAdmission,
            construction = P.construction and {
                checked = P.construction.checked,
                total = P.construction.total,
                done = P.construction.done,
                costOnly = P.construction.costOnly == true,
                recordingTrees = P.construction.recordingTrees == true,
            },
            preparation = P.preparation and {
                checked = P.preparation.checked,
                total = P.preparation.total,
                done = P.preparation.done,
            },
            sharedFlight = config.sharedFlightLoad and {
                done = P.sharedFlightDone == true,
                hiddenLoaded = P.sharedFlightHidden and not P.sharedFlightHidden.stage,
            },
            flightModelSwitch = config.flightModelSwitch and { done = P.flightSwitchDone == true },
            flightOwnerHandoff = config.flightOwnerHandoff and { done = P.flightHandoffDone == true },
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

local function beginPanelReflow(context, costOnly)
    local function load(relative, ...)
        if relative == "lib/primitives.lua" then
            return context.primitives
        elseif relative == "lib/theme.lua" then
            return context.themeBuilder
        end
        local path = string.sub(relative, 1, 9) == "@support/"
                and "/WIDGETS/AeroGrid/audit/" .. string.sub(relative, 10)
            or "/WIDGETS/AeroGrid/" .. relative
        return costs:bind(relative, assert(loadScript(path))(...))
    end
    local cases = load("@support/reflow_cases.lua")(load, context, config.reflowKind)
    P.construction = load("@support/native_panel_reflow.lua")(
        context,
        cases,
        load("@support/native_construction.lua"),
        load("@support/panel_tree.lua"),
        costOnly
    )
    assert(not costOnly or P.construction.costOnly, "panel reflow cost matrix must not record trees")
    assert(costOnly or P.construction.recordingTrees, "panel reflow parity must record native trees")
end

local actions
actions = {
    ["preparation"] = function(context)
        P.preparation = assert(loadScript("/WIDGETS/AeroGrid/audit/native_preparation.lua"))()(context)
    end,
    ["preparation-step"] = function()
        local ok, message = pcall(P.preparation.step, P.preparation)
        if not ok then
            gate(false, "native preparation matrix failed: " .. tostring(message))
            P.preparation.done = true
        end
    end,
    ["preparation-check"] = function()
        assert(P.preparation.done and P.preparation.checked == P.preparation.total)
    end,
    ["panel-reflow-matrix"] = function(context)
        beginPanelReflow(context, false)
    end,
    ["panel-reflow-cost"] = function(context)
        beginPanelReflow(context, true)
    end,
    ["construction-parity"] = function(context, costOnly, reflow, reflowCost)
        local function load(relative)
            if relative == "lib/theme.lua" then
                return context.themeBuilder
            elseif relative == "lib/primitives.lua" then
                return context.primitives
            end
            return costs:bind(relative, assert(loadScript("/WIDGETS/AeroGrid/" .. relative))())
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
    ["lifecycle-menu-retire"] = function(context)
        assert(context.aerogridMenu and context.aerogridMenu.open, "menu-close capture requires the actual open menu")
        actions["lifecycle-retire"](context)
        context.nativeDialogsCreated = true
        _G.lvgl = setmetatable({
            isFullScreen = function()
                return false
            end,
        }, { __index = lvgl })
        context.fullScreen = false
    end,
    ["check-lifecycle-menu"] = function(context)
        assert(not context.aerogridMenu, "retirement must close the actual AeroGrid menu")
        actions["check-lifecycle"](context)
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
    ["flight-registration-error"] = function(context)
        assert(not context.stage and not context.reloadState, "registration-error scenario must start loaded")
        context.pendingFlightError = "expected registration rejection"
    end,
    ["check-flight-registration-error"] = function(context)
        assert(not context.pendingFlightError, "deferred Flight error was not published")
        assert(context.errorLabel, "Flight error must be visible")
        local found = false
        for _, message in ipairs(context.errors) do
            if message == config.expectedError then found = true end
        end
        assert(found, "Flight error disappeared before the next callback")
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
    ["prepare-editor-drag"] = function(context)
        local state = assert(context.editorUi)
        local phase = config.phases[phaseIndex]
        local rect = assert(state.controls[1].rect)
        local corner = phase.corner
        phase.touch = {
            x = (context.left or 0) + rect.x + (corner and rect.w - 4 or rect.w / 2),
            y = (context.top or 0) + rect.y + (corner and rect.h - 4 or rect.h / 2),
        }
    end,
    ["prepare-editor-slide"] = function(context)
        local state = assert(context.editorUi)
        local phase = config.phases[phaseIndex]
        local rect = assert(state.controls[#state.session.draft.panels].rect)
        if phase.far then
            rect = { x = 0, y = 0, w = context.zone.w, h = context.zone.h }
        end
        phase.touch = {
            x = (context.left or 0) + rect.x + rect.w - 4,
            y = (context.top or 0) + rect.y + rect.h - 4,
        }
    end,
    ["check-editor-drag"] = function(context)
        local state = assert(context.editorUi)
        assert(state.drag, "drag must have started")
        assert(not state.statusError, tostring(state.status))
    end,
    ["check-editor-dragged"] = function(context)
        local state = assert(context.editorUi)
        assert(not state.drag and not state.renderStage, "drag must finish")
        assert(not state.statusError or state.status == "", tostring(state.status))
    end,
    ["select-editor-add"] = function(context)
        context.editorUi.keyAdd = true
    end,
    ["queue-editor-add"] = function(context)
        local state = assert(context.editorUi)
        assert(not state.drawerPending and not state.drawerOpen and state.mode == "menu")
        P.addCount = #state.session.draft.panels
        -- Equivalent to the native panel picker's set callback.
        state.drawerPending = { action = "add", panelType = config.phases[phaseIndex].panelType }
    end,
    ["check-editor-add"] = function(context)
        local state, phase = assert(context.editorUi), config.phases[phaseIndex]
        assert(not state.drawerPending and not state.drawerAdd, "panel addition must finish")
        local panels = state.session.draft.panels
        if phase.full then
            assert(#panels == P.addCount and state.statusError
                and string.find(state.status, "no free grid cells", 1, true), "full grid must report its error")
            return
        end
        assert(#panels == P.addCount + 1 and state.session.selected == #panels)
        assert(panels[#panels].type == phase.panelType and state.session.dirty)
        assert(state.nativeDrawer and not state.drawerBuild and not state.drawerLayout and not state.drawerOpen,
            "added panel must open its Configure drawer")
    end,
    ["check-drawer-cancelled"] = function(context)
        local state = assert(context.editorUi)
        assert(not state.drawerOpen and not state.nativeDrawer and state.mode == "menu")
    end,
    ["check-drawer"] = function(context)
        local state = assert(context.editorUi)
        local phase = config.phases[phaseIndex]
        assert(
            state.nativeDrawer and not state.drawerBuild and not state.drawerLayout and not state.renderStage,
            "native drawer construction must finish"
        )
        assert(#state.drawerControls == #state.drawerFields)
        if phase.root then assert(not state.drawerListKey) end
        if phase.items then
            local count = 0
            for _, field in ipairs(state.drawerFields) do
                if field.action == "item" then
                    count = count + 1
                    assert(type(field.text) == "function", "item summaries retain their native getter contract")
                    if phase.summary and count == 1 then
                        local index = 0
                        for token in string.gmatch(field.text(), "State %d+") do
                            index = index + 1
                            assert(token == "State " .. index)
                        end
                        assert(index == 128, "all condition summaries must survive")
                    end
                end
            end
            assert(count == phase.items, "all oversized list rows must remain repairable")
        end
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
    ["command-drawer"] = function(context)
        local state, phase = assert(context.editorUi), config.phases[phaseIndex]
        assert(not state.drawerBuild and not state.drawerPending and not state.drawerOpen)
        for _, field in ipairs(state.drawerFields) do
            if field.action == phase.command then
                if phase.command == "item" then
                    P.drawerListCount = #state.session.draft.panels[state.session.selected].config[field.key]
                    P.drawerListKey = field.key
                end
                state.drawerPending = field
                return
            end
        end
        error("native drawer scenario has no " .. tostring(phase.command) .. " command")
    end,
    ["return-drawer"] = function(context)
        local state = assert(context.editorUi)
        lvgl.close(assert(state.nativeDrawer))
        assert(not state.nativeDrawer and state.drawerPending, "native Return must queue its navigation")
    end,
    ["pad-drawer-config"] = function(context)
        local config = assert(context.editorSession).draft.panels[context.editorSession.selected].config
        config.audit = {}
        for index = 1, 128 do config.audit[index] = { label = "row", nested = { index } } end
    end,
    ["pad-drawer-list"] = function(context)
        local phase, editor = config.phases[phaseIndex], context.editorModule
        local config = context.editorSession.draft.panels[context.editorSession.selected].config
        local items = phase.nested and config.entries[1].states or config[phase.key]
        if phase.first == 1 then P.drawerListTemplate = assert(items[1]) end
        local template = assert(P.drawerListTemplate)
        for index = phase.first, phase.first + 7 do
            items[index] = editor.clone(template)
            if phase.nested then items[index].text = "State " .. index
            else items[index].label = "Entry " .. index end
        end
    end,
    ["check-drawer-removed"] = function(context)
        local state = assert(context.editorUi)
        assert(state.session.selected == 0 and #state.session.draft.panels == 0 and state.session.dirty)
        assert(not state.nativeDrawer and not state.drawerPending and not state.drawerOpen)
    end,
    ["check-drawer-error"] = function(context)
        local state = assert(context.editorUi)
        assert(state.statusError and not state.session.dirty and not state.drawerPending)
        assert(context.errorLog and next(context.errorLog.messages))
    end,
    ["check-drawer-return"] = function(context)
        local state = assert(context.editorUi)
        assert(state.mode == "menu" and not state.nativeDrawer and not state.drawerPending and not state.drawerOpen)
    end,
    ["check-drawer-list"] = function(context)
        local state = assert(context.editorUi)
        assert(state.nativeDrawer and not state.drawerBuild and not state.drawerPending and not state.drawerOpen)
        local config = state.session.draft.panels[state.session.selected].config
        assert(#config[assert(P.drawerListKey)] == assert(P.drawerListCount) and state.session.dirty)
        assert(not state.statusError, tostring(state.status))
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
    ["save-editor"] = function(context)
        local state = assert(context.editorUi)
        assert(state.session.dirty and not state.saving, "save scenario needs an edited draft")
        local placement = state.session.draft.panels[1]
        P.savedEditorPlacement = {
            col = placement.col, row = placement.row,
            colSpan = placement.colSpan, rowSpan = placement.rowSpan,
        }
        P.savedEditorPanel = context.panels[1]
        state.exitCommand = { action = "save" }
    end,
    ["check-editor-saved"] = function(context)
        assert(not context.editorUi and not context.editorSession, "confirmed save must close the editor")
        assert(not context.flightRegistrationJob and not context.flightPublicationJob
            and not context.pendingFlightError, "saved layout registration must finish")
        for key, value in pairs(P.savedEditorPlacement) do
            assert(context.document.panels[1][key] == value, "saved layout must retain the edited geometry")
        end
        assert(context.panels[1] == P.savedEditorPanel, "geometry-only save must adopt the live preview")
        assert(context.layoutOrigin == "user" and #context.errors == 0, "saved layout must publish successfully")
    end,
    reflow = function(context)
        local zone = context.zone
        context.zone = { w = zone.w - 8, h = zone.h, xabs = zone.xabs, yabs = zone.yabs }
    end,
    ["check-reflow"] = function(context)
        assert(not context.reflowIndex and not context.reflowEntry, "ordinary reflow must finish")
        for _, entry in ipairs(context.panels) do
            assert(not entry.failed and not entry.instance.reflowWork, "geometry cannot remain partial")
        end
    end,
    ["reflow-errors"] = function(context)
        context.panels[1].failed = nil
        context.errors = { config.expectedError }
        context.reflowIndex, context.reflowEntry = #context.panels + 1, nil
    end,
    ["reflow-skip"] = function(context)
        context.panels[1].failed = true
        context.reflowIndex, context.reflowEntry = 1, nil
    end,
    ["check-reflow-errors"] = function(context)
        actions["check-reflow"](context)
        assert(context.errorLabel and context.errors[1] == config.expectedError)
    end,
    reload = function(context)
        context.reloadState = "clear"
    end,
}

local function linkPanel(context)
    for _, entry in ipairs(context.panels) do
        if entry.placement.id == "link" then return entry.instance end
    end
    error("missing link panel")
end

actions["link-off"] = function() _G.AUDIT_LINK_OFF = true end
actions["link-on"] = function() _G.AUDIT_LINK_OFF = false end
actions["check-link-loss"] = function(context)
    local link = linkPanel(context)
    assert(link.text == "NO LINK", "not disconnected: " .. tostring(link.text))
end
actions["check-link-recovery"] = function(context)
    local link = linkPanel(context)
    assert(link.text ~= "NO LINK" and link.stateName == "normal",
        "not recovered: " .. tostring(link.text) .. "/" .. tostring(link.stateName))
end

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
        if ui.drawerOpening then
            return "editor-drawer:" .. ui.drawerOpening.phase
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
    depth, topSum, top, topLabels, callbackLeak = 0, 0, {}, {}, 0
    P.settledReadyCost, P.hostFinishCost, P.hostCallbackKind = nil, nil, nil
    local surface = callbackSurface(kind, context)
    P.editorInputSeen, P.editorInputAdmission = nil, nil
    P.lifecycleOperation, P.lifecycleAdmissionKind, P.lifecycleServiceOnly = nil, nil, nil
    local restarting = (kind == "refresh" or kind == "background") and context.reloadState == "rebuild"
    local waitingReflow = kind == "background" and context.reflowIndex
    local reflowIndex, reflowEntry = context.reflowIndex, context.reflowEntry
    local waitingBound = waitingReflow and context.dashboardLifecycle.workBound(context, "waitReflow")
    if restarting then
        P.lifecycleOperation = "restartLoading"
    end
    local c0 = count()
    fn(context, e, t)
    local c1 = count()
    pause(true)
    if waitingReflow and not P.lifecycleOperation then
        P.lifecycleOperation = "waitReflow"
        gate(context.reflowIndex == reflowIndex and context.reflowEntry == reflowEntry,
            "background waiting advanced geometry")
        gate((waitingBound ~= nil) == (P.lifecycleAdmissionKind == "loader"),
            "background reflow has incorrect service admission")
        P.lifecycleServiceOnly = waitingBound ~= nil
    end
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
    local total = c1 - c0 - K_CALLBACK - callbackLeak
    if P.lifecycleOperation then
        gate(total <= 15000, surface .. " exceeds the complete lifecycle callback ceiling: " .. total)
        if P.lifecycleServiceOnly then
            local fitted = fit(total - topSum)
            gate(fitted <= 2400, surface .. " exceeds the service-only fixed overhead: " .. fitted)
        end
    end
    if surface and string.sub(surface, 1, 7) == "loader:" then
        gate(total <= 15000, surface .. " exceeds the complete loading callback ceiling: " .. total)
        if surface == "loader:flight-load-wait" then
            local fitted = fit(total - topSum)
            gate(fitted <= 2400, "shared Flight loading exceeds fitted service-only overhead: " .. fitted)
        end
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
    if string.match(config.scenario, "^lifecycle%-") or string.match(config.scenario, "^panel%-reflow%-") then
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
            or string.match(surface, "^editor%-render:[1-6]$")
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
        if P.hostCallbackKind then
            local hostCost = overhead + (P.settledReadyCost or 0) + P.hostFinishCost
            record("host:overhead:" .. P.hostCallbackKind, hostCost, hostCost, 1)
        end
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
            string.format("%s|%d|%d|%d|%s", kind, getTime(), total, overhead, table.concat(top, ","))
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
    if phase.untilPreparation and P.preparation.done then
        phaseDone = phase.callbacks
    end
    if phase.untilPartialConstruction then
        local reached = context.appRebuild and context.appRebuild.phase == "construct" and context.pendingConstruction
        if not reached and phaseDone < phase.callbacks then
            return
        end
        gate(reached ~= nil and reached ~= false, "App rebuild did not reach actual partial construction")
        if reached then
            phaseDone = phase.callbacks
        end
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

local createFn
function P.register(refresh, background, create)
    refreshFn, backgroundFn, createFn = refresh, background, create
end

-- The counter globals appear when the firmware first starts a callback.
local function connect()
    if not count and __count then
        count, nativePause = __count, __pause
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
    if config.flightOwnerHandoff and ready(context) and not P.flightHandoffDone then
        local owner = assert(context.flightBroker)
        local target = P.flightHandoffContext
        if not target then
            local flight, smart = context.scheduler.byId["service:flight"], context.scheduler.byId["service:smart"]
            if not flight or not smart then
                runCallback("background", context, backgroundFn)
                return
            end
            gate(owner:owningContext() == context, "handoff must start with the original canonical owner")
            P.flightHandoffFacade = owner.facade
            P.flightHandoffDue = { flight = getTime() + 100000, smart = getTime() + 100020 }
            flight.due, smart.due = P.flightHandoffDue.flight, P.flightHandoffDue.smart
            runCallback("create", context, function()
                P.flightHandoffContext = createFn(
                    context.zone, { Layout = context.layoutName, Theme = "modern-dark" }, context.path)
            end)
            return
        end
        install(target)
        -- Only the second widget advances while its original owner is parked.
        runCallback("background", target, backgroundFn)
        if not target.flightBroker then return end
        gate(target.flightBroker == owner, "handoff cannot create another Flight broker")
        if owner:owningContext() ~= target then return end
        local flight, smart = target.scheduler.byId["service:flight"], target.scheduler.byId["service:smart"]
        if not flight or not smart then return end
        gate(flight.due == P.flightHandoffDue.flight and smart.due == P.flightHandoffDue.smart,
            "parked-owner migration must preserve both canonical releases")
        gate(owner.facade == target.serviceRuntime.byId.flight
            and not P.flightHandoffFacade.schedulerTasks and P.flightHandoffFacade.count == 0,
            "migration must transfer the facade without leaving the old one scheduled")
        -- Reconcile the previous registry while keeping its replacement live.
        runCallback("background", context, backgroundFn)
        gate(owner:owningContext() == target, "a live replacement cannot be displaced during reconciliation")
        if context.scheduler.byId["service:flight"] or context.scheduler.byId["service:smart"] then return end
        gate(#context.errors == 0 and #target.errors == 0, "handoff must not report widget errors")
        P.flightHandoffDone = true
        return
    end
    if config.flightModelSwitch and ready(context) and not P.flightSwitchDone then
        local owner = context.flightBroker
        if not P.flightSwitchContext then
            local tasks = context.scheduler.byId
            if not owner.schedulerEnabled or not tasks["service:flight"] or not tasks["service:smart"] then
                P.flightSwitchEnrollment = (P.flightSwitchEnrollment or 0) + 1
                gate(P.flightSwitchEnrollment <= 256, "canonical Flight tasks were not enrolled before model switch")
                runCallback("background", context, backgroundFn)
                return
            end
            P.flightSwitchTasks = { tasks["service:flight"], tasks["service:smart"] }
            P.flightSwitchDue = {
                context.scheduler:dueOf("service:flight"),
                context.scheduler:dueOf("service:smart"),
            }
            local info = model.getInfo()
            local changed = {}
            for key, value in pairs(info) do
                changed[key] = value
            end
            changed.filename = "audit-switched.yml"
            model = setmetatable({
                getInfo = function()
                    return changed
                end,
            }, { __index = model })
            owner.env.getInfo = model.getInfo
            P.flightSwitchOwner = owner:owningContext()
            runCallback("action:model-switch-create", context, function()
                P.flightSwitchContext =
                    createFn(context.zone, { Layout = context.layoutName, Theme = "modern-dark" }, context.path)
            end)
            return
        end
        local initializer = P.flightSwitchContext
        if not P.flightSwitchObserver and initializer.stage ~= "flight-load" then
            install(initializer)
            runCallback("background", initializer, backgroundFn)
            return
        elseif not P.flightSwitchObserver then
            gate(owner:loadingContext() == initializer, "new-model member did not claim document initialization")
            runCallback("action:model-switch-observer", context, function()
                P.flightSwitchObserver =
                    createFn(context.zone, { Layout = context.layoutName, Theme = "modern-dark" }, context.path)
            end)
            return
        end
        local observer = P.flightSwitchObserver
        local target = not ready(observer) and observer or initializer
        install(target)
        runCallback("background", target, backgroundFn)
        gate(owner:owningContext() == P.flightSwitchOwner, "document initialization moved canonical ownership")
        for index, id in ipairs({ "service:flight", "service:smart" }) do
            gate(context.scheduler.byId[id] == P.flightSwitchTasks[index], "model initialization replaced canonical task")
            gate(context.scheduler:dueOf(id) == P.flightSwitchDue[index], "model initialization moved canonical release")
            gate(target.scheduler.byId[id] == nil, "model initializer enrolled duplicate canonical task")
        end
        if ready(initializer) and ready(observer) then
            gate(
                owner.documentLoaded and owner.document and owner.document.modelFilename == "audit-switched.yml",
                "new-model settings were not published"
            )
            gate(#initializer.errors == 0 and #observer.errors == 0, "new-model loader reported an error")
            P.flightSwitchDone = true
        end
        return
    end
    if not ready(context) then
        P.loaded = false
        recording = config.recordLoad ~= false
        local owner = config.sharedFlightLoad and context.flightFactory and context.flightFactory.broker
        if owner and not P.sharedFlightDone then
            if not P.sharedFlightHidden then
                gate(context.stage == "flight-identity" and not owner.documentLoaded and not owner.store,
                    "shared loading must park the creator before store initialization")
                runCallback("action:shared-flight-create", context, function()
                    P.sharedFlightHidden = createFn(
                        context.zone, { Layout = context.layoutName, Theme = "modern-dark" }, context.path
                    )
                end)
                return
            end
            local hidden = P.sharedFlightHidden
            install(hidden)
            runCallback("background", hidden, backgroundFn)
            gate(owner:owningContext() == context, "shared loading displaced its live owner")
            gate(not owner.documentLoaded or owner.document ~= nil or owner.loadError ~= nil,
                "shared loading published an incomplete document")
            if ready(hidden) then
                gate(owner.documentLoaded and not owner.loadError, "hidden widget did not load the shared document")
                gate(owner.document and owner.document.revision == config.sharedFlightRevision,
                    "hidden widget did not publish the persisted shared document")
                gate(#hidden.errors == 0, "hidden shared-loader widget failed")
                P.sharedFlightDone = true
            end
            return
        end
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
