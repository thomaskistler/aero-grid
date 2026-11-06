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
    local themeBound = ({
        ["load:theme-read"] = 200,
        ["load:theme-tokenize"] = 3200,
        ["load:theme-parse"] = 900,
        ["load:theme-resolve-begin"] = 240,
    })[label]
    local resolution = string.match(label, "^load:theme%-resolve:(%a+)$")
    if resolution then
        themeBound = ({ legibility = 2400, chart = 1800, alert = 2200, display = 650, finalize = 180 })[resolution]
    elseif string.match(label, "^load:theme%-publish:") then
        themeBound = 500
    end
    if themeBound then
        gate(cost <= themeBound, label .. " exceeds its bounded theme-loading charge: " .. cost)
    end
    if label == "lifecycle:advanceReflow" then
        gate(cost <= 4000, "complete geometry advance exceeds the atom cap: " .. cost)
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
        local stage = tonumber(string.match(label, "^editor:advanceEditor:render:(%d+)$"))
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
        local settingsStage = string.match(label, "^modal:settings:advance:(%a+)")
        local settingsBound = settingsStage and P.settingsBounds and P.settingsBounds[settingsStage]
        if settingsBound then
            gate(cost <= settingsBound, label .. " exceeds the settings work charge: " .. cost)
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
        if stage == "theme-resolve" then
            return stage .. ":" .. tostring(context.themeBuildWork.stage)
        elseif stage == "theme-publish" then
            return stage .. ":" .. tostring(context.themePublication.phase)
        end
        local placement = context.pendingPlacement
        if stage == "panel-construct" and context.pendingConstruction then
            local label = stage .. ":" .. placement.type
            return (placement.type == "chart" or placement.type == "theme-showcase")
                    and label .. ":" .. tostring(context.pendingConstruction.instance.createStage)
                or label
        end
        if (stage == "panel-build" or stage == "panel-prepare" or stage == "panel-validate") and placement then
            return stage .. ":" .. tostring(placement.type)
        end
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
            if type(value) == "function" then
                lifecycle[key] = wrap("lifecycle:" .. key, value)
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
    P.editorRenderBounds = context.editorUiModule and context.editorUiModule.RENDER_BOUNDS
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
            elseif state.drawerBuild then
                return state.drawerBuild <= #state.drawerFields
                        and "build:" .. tostring(state.drawerFields[state.drawerBuild].type)
                    or "finish"
            end
            return "command"
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
                P.settingsBounds = module.WORK_BOUNDS
            end
            for _, name in ipairs({ "open", "advance", "handle", "close", "ensure" }) do
                wrapField(module, name, function(token, current)
                    if token then
                        return "modal:" .. surface[2] .. ":" .. name .. ":" .. token
                    end
                    local state = current[surface[3]]
                    if surface[2] == "settings" and state then
                        return module.stageOf(state) .. ":" .. tostring(state.build or "idle")
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

local function report(context)
    local errors = {}
    for _, message in ipairs(context and context.errors or errorsSeen) do
        errors[#errors + 1] = message
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
            callbacks = kindCounts,
            feeds = feeds(context),
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
    if config.fullscreen and not lvgl.isFullScreen() then
        return false
    end
    return not context.stage
        and not context.reloadState
        and #context.panels >= (config.expectedPanels or 1)
        and not context.runtimeFailed
end

local actions = {
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
    ["check-settings"] = function(context)
        assert(context.modelSettingsUi and not context.modelSettingsUi.build)
        if config.scenario == "modal-settings-reset" then
            local state = context.modelSettingsUi
            assert(state.armed == "L64" and state.sessionReset == "L03")
            assert(state.values.motorSource == "ch32" and state.values.flightSwitch == "L64")
        end
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
        assert(context.editorUi and context.editorUi.drawerBuild)
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
    actions[name] = function(context)
        local ok, message = pcall(action, context)
        gate(ok, "action " .. name .. ": " .. tostring(message))
    end
end

local function callbackSurface(kind, context)
    if kind ~= "refresh" then
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
        if ui.renderStage then
            return "editor-render:" .. tostring(ui.renderStage)
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
            .. tostring(context.modelSettingsUi.build or context.modelSettingsUi.pending and "pending" or "idle")
    end
    if context.locationDetails then
        return "location"
    end
    if context.aerogridMenu and context.aerogridMenu.open then
        return "menu"
    end
    return nil
end

local function runCallback(kind, context, fn, e, t)
    callbackIndex = callbackIndex + 1
    depth, topSum, top, topLabels = 0, 0, {}, {}
    local surface = callbackSurface(kind, context)
    local c0 = count()
    fn(context, e, t)
    local c1 = count()
    pause(true)
    local total = c1 - c0 - K_CALLBACK
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
        and (string.match(surface, "^editor%-render:[2-6]$") or string.match(surface, "^editor%-drawer:"))
    if kind == "refresh" and (paintSurface or string.sub(config.scenario, 1, 6) == "modal-" and surface) then
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
                "kind=%s callbacks=%d phase=%d done=%d stage=%s panels=%d errors=%s\n",
                kind,
                callbackIndex,
                phaseIndex,
                phaseDone,
                tostring(context.stage),
                #context.panels,
                table.concat(context.errors, ";")
            )
        )
    end
    if #context.errors > 0 and not errorsSeen[1] then
        errorsSeen[1] = table.concat(context.errors, "; ")
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
    local target = phase.kind == "background" and backgroundFn or fn
    local step = phase.step or 0
    if kind == "background" and phase.kind ~= "background" then
        runCallback(kind, context, fn, e, t)
    elseif step > 0 and kind == "refresh" then
        for _ = 1, phase.perCall or 1 do
            P.offset = P.offset + step
            runCallback(phase.kind or kind, context, target, e, t)
            advance(context)
            if finished or config.phases[phaseIndex] ~= phase then
                break
            end
        end
    else
        runCallback(phase.kind or kind, context, target, e, t)
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
