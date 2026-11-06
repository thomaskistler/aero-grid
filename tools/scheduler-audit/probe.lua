-- SPDX-License-Identifier: GPL-2.0-only
-- Scheduler audit probe. Copied only into an isolated simulator SD image.
--
-- `__count` and `__pause` come from tools/audit-native.cpp. Every measurement
-- window reads the exact instruction counter; bookkeeping runs with the counter
-- paused, so recording a sample does not change what is recorded.

local config = assert(loadScript("/WIDGETS/AeroGrid/audit/config.lua"))()
local count, pause
local P = { offset = 0 }

local realTime = getTime
_G.getTime = function()
    return realTime() + P.offset
end

local stats, trace, errorsSeen, worst = {}, {}, {}, {}
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
    end
end

-- A labelled measurement window. `label` is a string, or a function that is
-- called before the work (returning a token) and after it (returning the label).
local function core(leak, label, fn, a, b, c, d, e)
    pause(true)
    depth = depth + 1
    childSum[depth], visits[depth], childList[depth] = 0, 0, {}
    local token
    if type(label) == "function" then
        token = label(nil, a, b, c, d, e)
    end
    pause(false)
    local c0 = count()
    local r1, r2, r3, r4 = fn(a, b, c, d, e)
    local c1 = count()
    pause(true)
    if type(label) == "function" then
        label = label(token, a, b, c, d, e)
    end
    finish(label, c1 - c0, leak)
    pause(false)
    return r1, r2, r3, r4
end

-- Direct spans: patched call sites in the isolated copy call this.
local function span(label, fn, a, b, c, d, e)
    return core(LEAK_SPAN, label, fn, a, b, c, d, e)
end
_G.AUDIT_SPAN = span

-- Wrapper spans: installed over existing functions at run time.
local function wrap(label, fn)
    return function(a, b, c, d, e)
        return core(LEAK_WRAP, label, fn, a, b, c, d, e)
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

local function panelLabel(token, entry, event)
    local module = entry and entry.module
    local id = module and rawget(module, "id") or "unknown"
    local instance = entry and entry.instance
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
        local placement = context.pendingPlacement
        if (stage == "panel-build" or stage == "panel-prepare" or stage == "panel-validate") and placement then
            return stage .. ":" .. tostring(placement.type)
        end
        return stage
    end
    return "load:" .. token
end

local function install(context)
    pause(true)
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
    end
    local runtime = context.serviceRuntime
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
                -- A task the new scheduler owns runs from `step`, not from `update`.
                if instance.schedulerTasks then
                    for _, task in ipairs(instance.schedulerTasks) do
                        wrapField(task.instance, "step", task.id)
                    end
                else
                    wrapField(instance, "step", "service:" .. tostring(instance.id))
                end
                wrapField(instance, "resetSession", "reset:" .. tostring(instance.id))
                if instance.id == "telemetry" then
                    wrapField(instance, "scanPrecision", "telemetry:scan")
                    wrapField(instance, "poll", "telemetry:poll")
                    wrapField(instance, "publishLink", "telemetry:link")
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
            errors = context and context.errors or errorsSeen,
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
    return not context.stage
        and not context.reloadState
        and #context.panels >= (config.expectedPanels or 1)
        and not context.runtimeFailed
end

local actions = {
    reflow = function(context)
        local zone = context.zone
        context.zone = { w = zone.w - 8, h = zone.h, xabs = zone.xabs, yabs = zone.yabs }
    end,
    reload = function(context)
        context.reloadState = "clear"
    end,
}

local function runCallback(kind, context, fn, e, t)
    callbackIndex = callbackIndex + 1
    depth, topSum, top, topLabels = 0, 0, {}, {}
    local c0 = count()
    fn(context, e, t)
    local c1 = count()
    pause(true)
    local total = c1 - c0 - K_CALLBACK
    local overhead = total - topSum
    local suffix = P.loaded and "" or "@load"
    if recording then
        record("callback:" .. kind .. suffix, total, overhead, 1)
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
    local phase = config.phases[phaseIndex]
    if not phase then
        return
    end
    if phase.action and not phase.started then
        phase.started = true
        actions[phase.action](context)
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
