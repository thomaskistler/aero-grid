-- SPDX-License-Identifier: GPL-2.0-only

local recorder = {}
recorder.__index = recorder

local pack, unpack = table.pack, table.unpack

function recorder.hookCounter()
    assert(debug.gethook() == nil, "instruction recorder requires exclusive ownership of the debug hook")
    local counter, active = 0, false
    local function hook()
        counter = counter + 1
    end
    return function()
        return counter
    end, function(flag)
        local installed = debug.gethook()
        assert(installed == nil or installed == hook, "instruction recorder debug hook was replaced")
        if flag then
            debug.sethook()
            active = false
        elseif not active then
            debug.sethook(hook, "", 1)
            active = true
        end
    end
end

function recorder.new(count, pause, sink)
    local meta = getmetatable(sink)
    assert(type(sink) == "function" or type(meta) == "table" and type(meta.__call) == "function",
        "instruction recorder requires an observation sink")
    local self = setmetatable({
        count = count, pause = pause, depth = 0, children = {}, workChildren = {},
        floor = 0, leak = 0, failureLeak = 0, scenario = "unnamed", running = false, sink = sink,
        tasks = setmetatable({}, { __mode = "k" }), boundObservers = setmetatable({}, { __mode = "k" }),
    }, recorder)
    self:calibrate()
    return self
end

-- Parent raw counts include every descendant's wrapper. Propagate their
-- overhead, not their measured work, so each wrapper is removed exactly once.
function recorder:window(onCost, fn, ...)
    local pause, count = self.pause, self.count
    local running = self.running
    pause(true)
    self.running = false
    local token
    if type(onCost) == "table" then
        token = onCost.before(...)
    end
    local depth = self.depth + 1
    self.depth, self.children[depth], self.workChildren[depth] = depth, 0, 0
    local start = count()
    pause(false)
    self.running = true
    local results = pack(pcall(fn, ...))
    pause(true)
    self.running = false
    local raw = count() - start
    local cost = raw - self.floor - self.children[depth]
    self.depth = depth - 1
    if depth > 1 then
        local excluded = raw
        if running then
            local leak = results[1] and self.leak or self.failureLeak
            excluded = leak + self.children[depth]
            self.workChildren[depth - 1] = self.workChildren[depth - 1] + cost
        end
        self.children[depth - 1] = self.children[depth - 1] + excluded
    end
    if type(onCost) == "table" then
        onCost.after(cost, cost - self.workChildren[depth], token, results[1], results, ...)
    else
        onCost(cost, results[1], results, ...)
    end
    if running then
        pause(false)
        self.running = true
    end
    return results
end

function recorder:bound(selectBound, fn)
    local observer = self.boundObservers[selectBound]
    if not observer then
        if not self.boundAfter then
            self.boundAfter = function(cost, own, token, ok)
                if token then
                    self:sample("bound", token.name, token.stage, 0, token.exclusive and own or cost, ok)
                end
            end
        end
        observer = { before = selectBound, after = self.boundAfter }
        self.boundObservers[selectBound] = observer
    end
    return self:wrap(fn, observer)
end

function recorder:wrap(fn, onCost)
    return function(...)
        local results = self:window(onCost, fn, ...)
        if not results[1] then
            error(results[2], 0)
        end
        return unpack(results, 2, results.n)
    end
end

function recorder:calibrate()
    local measured
    local function keep(cost)
        measured = cost
    end
    local noop = function() end
    self:window(keep, noop)
    self.floor = measured - 1
    local wrapped = self:wrap(noop, function() end)
    -- Both closures have the same instruction shape and call arity.
    local function direct()
        noop()
    end
    local function nested()
        wrapped()
    end
    self:window(keep, direct)
    local baseline = measured
    self:window(keep, nested)
    self.leak = measured - baseline
    local failure = {}
    local failing = function()
        error(failure)
    end
    local failingWrapper = self:wrap(failing, function() end)
    local function directFailure()
        return pcall(failing)
    end
    local function nestedFailure()
        return pcall(failingWrapper)
    end
    self:window(keep, directFailure)
    local failureBaseline = measured
    self:window(keep, nestedFailure)
    self.failureLeak = measured - failureBaseline
    assert(self.floor >= 0 and self.leak >= 0, "invalid instruction recorder calibration")
    for _ = 1, 10 do
        self:window(keep, noop)
        assert(measured == 1, "unstable empty instruction window")
        self:window(keep, nested)
        assert(measured == baseline, "unstable nested instruction window")
        self:window(keep, nestedFailure)
        assert(measured == failureBaseline, "unstable failed nested instruction window")
    end
end

function recorder:sample(kind, name, stage, grant, cost, ok, scenario)
    assert(math.type(cost) == "integer" and cost >= 0, "invalid instruction observation")
    assert(math.type(grant) == "integer" and grant >= 0, "invalid instruction grant")
    self.sink(kind, name, stage, grant, cost, ok, scenario or self.scenario)
end

function recorder:task(name, fn)
    local cached = self.tasks[fn]
    if cached and cached[name] then
        return cached[name]
    end
    cached = cached or {}
    self.tasks[fn] = cached
    local wrapped = self:wrap(fn, function(cost, ok, _, instance, grant, stage)
        local taskName = type(name) == "function" and name(instance) or name
        assert(type(taskName) == "string", "instruction recorder has an unnamed task")
        self:sample("task", taskName, stage or "run", grant or 1, cost, ok)
    end)
    cached[name] = wrapped
    return wrapped
end

function recorder:callback(kind, fn, observer)
    return self:wrap(fn, {
        before = function(context)
            local token = observer and observer.before(context)
            if type(context) ~= "table" then return self.scenario end
            local phase = context.stage or context.reloadState
                or context.appRebuild and "app-rebuild"
                or context.reflowIndex and "reflow"
                or context.editorUi and "editor"
                or context.modelSettingsUi and "settings"
                or context.logViewer and "log"
                or "steady"
            if context.pendingPlacement and type(context.pendingPlacement.type) == "string" then
                phase = phase .. ":" .. context.pendingPlacement.type
            end
            return { scenario = self.scenario .. ":" .. phase, token = token }
        end,
        after = function(cost, own, scenario, ok)
            if type(scenario) == "table" then
                if observer then observer.after(cost, own, scenario.token, ok) end
                scenario = scenario.scenario
            end
            self:sample("callback", kind, self.scenario, 0, cost, ok, scenario)
        end,
    })
end

return recorder
