-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local function load(relative)
    local path = string.sub(relative, 1, 9) == "@support/" and "/tests/support/" .. string.sub(relative, 10)
        or "/src/WIDGETS/AeroGrid/" .. relative
    return assert(loadfile(root .. path))()
end
local case = assert(loadfile(root .. "/tests/fixtures/scheduler-cases/host-readiness.lua"))()(load)
local support, telemetryModule = load("lib/services.lua"), load("lib/telemetry_service.lua")
local equal = load("@support/assertions.lua").assertEqual

do
    local service = { id = "single", count = 1 }
    local context = { panels = {}, serviceRuntime = { order = { service } } }
    local host = load("lib/scheduler_host.lua").attach(context, {
        mode = "mixed",
        load = load,
        api = {},
    })
    host.owners = { ["service:single"] = "new" }
    local id = "service:single"
    equal(host:verify(context), id .. " is owned by the scheduler but has no task")
    host.pendingServices[id], host.registeredTasks[id] = service, service
    equal(host:verify(context), nil, "a genuinely pending single-task service is accepted")
    host.pendingServices[id] = nil
    equal(host:verify(context), id .. " is owned by the scheduler but has no task")
    service.count = 0
    equal(host:verify(context), nil, "a service without demand does not need a task")
end

for _, item in ipairs(case.cases) do
    local task, now, state = item.setup()
    local host, scheduler = state.scheduling, state.scheduling.scheduler
    local added, removed, validated = 0, 0, 0
    local add, remove, isIdle = scheduler.add, scheduler.remove, state.context.panelHost.isIdle
    function scheduler:add(spec)
        added = added + 1
        equal(host.panelSetup, host.SERVICE_ENROLL_COST, "reserve service allocation before it runs")
        return add(self, spec)
    end
    function scheduler:remove(id)
        removed = removed + 1
        assert(host.panelSetup > 0, "retirement must be reserved before touching scheduler lists")
        return remove(self, id)
    end
    state.context.panelHost.isIdle = function(module)
        validated = validated + 1
        return isIdle(module)
    end
    equal(task:step(1, item.stage, now), 1)
    scheduler.add, scheduler.remove, state.context.panelHost.isIdle = add, remove, isIdle
    assert(added <= 1 and removed <= 1 and validated <= 1, "one ready call cannot traverse a registry or panel set")
    equal(scheduler:dueOf("service:flight"), 47)
    equal(scheduler:dueOf("service:smart"), 83)
    if state.action == "remove" then
        equal(scheduler.byId[state.removedId], nil)
    end
    state.reconciled()
    state.settle(state.context, host)
    assert(host:verify(state.context) == nil)
end

for _, total in ipairs({ 30, 128 }) do
    local state = case.prepare(total)
    local context, host, telemetry = state.context, state.scheduling, state.telemetry
    state.reconciled()
    assert(#host.waiting == total - 2, "all demanded real Telemetry tasks remain pending")
    assert(host:verify(context) == nil)
    local pending = host.waiting[1]
    host.pendingServices[pending.id] = nil
    assert(host:verify(context), "a scanned task without its pending marker is not legitimate waiting work")
    host.pendingServices[pending.id] = pending.instance
    for index in ipairs(telemetry.schedulerTasks) do
        host:resetServiceRelease(telemetry, 17, index)
    end
    local dormant = host.waiting[#host.waiting].task
    dormant.want = 0
    context.serviceRuntime = { order = { telemetry }, byId = { telemetry = telemetry } }
    state.reconciled()
    for _ = 1, total * 2 do
        state.ready(context, host)
    end
    equal(#host.waiting, 1, "dormant demand must not starve other enrollment")
    dormant.want = 1
    state.ready(context, host)
    equal(#host.waiting, 0)
    equal(host.scheduler.count, total)
    for _, item in ipairs(telemetry.schedulerTasks) do
        equal(host.scheduler:dueOf(item.id), 17, "queued resets survive reconciliation and registry replacement")
    end
    local flight, smart = host.scheduler.byId["service:flight"], host.scheduler.byId["service:smart"]
    local source = host.scheduler.byId[telemetry.schedulerTasks[2].id]

    -- No per-instance ownership marker exists during the first bounded scan.
    local entry = {
        placement = { id = "unscanned" },
        module = {
            id = "sample",
            decl = {
                class = "normal",
                kinds = { steady = true },
                stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
            },
            step = function(instance)
                instance.runs = instance.runs + 1
                return 10
            end,
        },
        instance = { runs = 0 },
        nextRefresh = 0,
    }
    context.panels[#context.panels + 1], context.panelTasksDirty = entry, true
    local ordinaryRuns, originalStep = 0, source.instance.step
    source.instance.step = function(...)
        ordinaryRuns = ordinaryRuns + 1
        return originalStep(...)
    end
    state.ready(context, host)
    assert(host.reconciliation and not entry.instance.schedulerOwned)
    local previousTime = getTime
    getTime = function()
        return 1200
    end
    host:begin("steady")
    host:finish("steady")
    equal(state.owner.session.arm.updatedAt, 1200, "the actual canonical poller continues during reconciliation")
    state.ready(context, host)
    host:begin("steady")
    host:finish("steady")
    equal(state.owner.smartRuntime.byId.smart.polledAt, 1200)
    equal(ordinaryRuns, 0, "ordinary tasks are not admitted before reconciliation establishes membership")
    equal(entry.instance.runs, 0)
    getTime = previousTime
    state.reconciled()
    equal(host.scheduler.byId["service:flight"], flight)
    equal(host.scheduler.byId["service:smart"], smart)
    equal(host.scheduler.byId[telemetry.schedulerTasks[2].id], source)
    assert(entry.instance.schedulerOwned and host.pendingPanels[entry])
    equal(source.due, 17, "safe canonical admission does not consume ordinary deadlines")
    context.panels = {}
    state.reconciled()
    state.settle(context, host)
    assert(not entry.instance.schedulerOwned and not host.scheduler.byId["panel:unscanned"])
    equal(entry.instance.runs, 0, "a placement retired before admission never executes")

    -- A replacement service may receive a reset before its first item is scanned.
    local replacement = telemetryModule.new(state.owner.env, support)
    replacement:subscribe("Replacement", false)
    context.serviceRuntime = { order = { replacement }, byId = { telemetry = replacement } }
    local target = replacement.schedulerTasks[2]
    host:resetServiceRelease(replacement, 23, 2)
    equal(source.due, 17, "a replacement reset cannot wake the previous owner of the same task id")
    state.reconciled()
    state.settle(context, host)
    equal(host.scheduler:dueOf(target.id), 23)
    equal(host.scheduler.byId[target.id].instance, target.instance)
    equal(host.scheduler.count, 4)
    equal(host.scheduler.byId["service:flight"], flight)

    -- Cancel a partially scanned replacement, keeping the canonical identity.
    context.serviceRuntime = { order = { telemetry }, byId = { telemetry = telemetry } }
    for _ = 1, 8 do
        state.ready(context, host)
    end
    assert(host.reconciliation)
    context.serviceRuntime = nil
    state.reconciled()
    state.settle(context, host)
    equal(host.scheduler.count, 2)
    equal(host.scheduler.byId["service:flight"], flight)
    equal(host.scheduler.byId["service:smart"], smart)
    equal(next(host.pendingServices), nil)
    equal(next(host.resetReleases), nil)
    equal(next(host.resetOwners), nil)
end

do
    local brokerCases = load("@support/scheduler_broker_registration.lua")(load)
    local _, _, state = brokerCases.cases[1].setup()
    local context, host = state.context, state.scheduling
    state.owner.tasks.smart.want = 0
    for _ = 1, 64 do
        state.ready(context, host)
    end
    assert(not host.reconciliation, "dormant canonical demand cannot pin reconciliation")
    equal(#host.waiting, 1)
    state.owner.tasks.smart.want = 1
    state.settle(context, host)
    equal(host.scheduler.count, 2)
end

do
    local state = case.prepare(30)
    local context, host = state.context, state.scheduling
    state.reconciled()
    state.settle(context, host)
    local idle = load("lib/smart_flight.lua").new(state.owner.env, support)
    context.serviceRuntime.order[#context.serviceRuntime.order + 1] = idle
    context.panelTasksDirty = true
    state.reconciled()
    equal(host.registeredTasks["service:smart"], state.stable, "a dormant dashboard facade cannot shadow Smart")
    local messages = {}
    host.api.log = function(_, message)
        messages[#messages + 1] = message
    end
    idle.count, context.panelTasksDirty = 1, true
    for _ = 1, 128 do
        if not host:ready(context) then
            break
        end
    end
    assert(messages[1] and string.find(messages[1], "service:smart is registered more than once", 1, true))
    idle.count, context.panelTasksDirty = 0, true
    state.reconciled()
    state.settle(context, host)
end

-- Dormant demand that appears after panel-only work began still gets a service scan.
do
    local state = case.prepare(30)
    local context, host = state.context, state.scheduling
    state.reconciled()
    state.settle(context, host)
    local idle = load("lib/smart_flight.lua").new(state.owner.env, support)
    context.serviceRuntime.order[#context.serviceRuntime.order + 1] = idle
    context.panelTasksDirty = true
    state.reconciled()
    state.settle(context, host)
    context.panelTasksDirty = true
    assert(host:ready(context))
    assert(host.reconciliation and host.reconciliation.panelOnly, "placement-only work skips services")
    local messages = {}
    host.api.log = function(_, message)
        messages[#messages + 1] = message
    end
    idle.count = 1
    for _ = 1, 128 do
        if not host:ready(context) then
            break
        end
    end
    assert(messages[1] and string.find(messages[1], "service:smart is registered more than once", 1, true),
        "late dormant demand replaces panel-only work")
    idle.count, context.panelTasksDirty = 0, true
    state.reconciled()
    state.settle(context, host)
end

do
    local state = case.prepare(30)
    local context, host = state.context, state.scheduling
    state.reconciled()
    state.settle(context, host)
    local reported = 0
    host.api.error = function()
        reported = reported + 1
    end
    host.api.show = function() end
    context.panels, context.panelTasksDirty = {}, true
    state.ready(context, host)
    state.owner.tasks.run.step = function()
        error("canonical readiness failure")
    end
    local previousTime = getTime
    getTime = function()
        return 1200
    end
    host:begin("steady")
    host:finish("steady")
    assert(host:report(context), "canonical task failures retain explicit host isolation")
    getTime = previousTime
    equal(reported, 1)
    equal(host.scheduler.byId["service:flight"], nil)
    equal(host.scheduler.byId["service:smart"], nil)
    assert(state.stable.failed)
    state.reconciled()
    state.settle(context, host)
    equal(host.scheduler.count, 28, "a failed canonical group cannot remove healthy dashboard readers")
end

do
    local state = case.prepare(30)
    local context, host = state.context, state.scheduling
    state.reconciled()
    state.settle(context, host)
    local entry = {
        placement = { id = "retiring" },
        module = {
            id = "sample",
            decl = {
                class = "normal",
                kinds = { steady = true, background = true },
                stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
            },
            step = function(instance)
                instance.runs = instance.runs + 1
                return 10
            end,
        },
        instance = { runs = 0 },
        nextRefresh = 0,
    }
    context.panels[#context.panels + 1], context.panelTasksDirty = entry, true
    state.reconciled()
    state.settle(context, host)
    assert(host.scheduler.byId["panel:retiring"])
    context.panels = {}
    state.ready(context, host)
    assert(host.reconciliation and entry.instance.schedulerOwned)
    local previousTime = getTime
    getTime = function()
        return 1200
    end
    host:begin("background")
    host:finish("background")
    getTime = previousTime
    equal(entry.instance.runs, 0, "a not-yet-retired panel cannot execute during the pending-marker interval")
    state.reconciled()
    equal(host.scheduler.byId["panel:retiring"], nil)
end

do
    local state = case.prepare(30)
    local context, host = state.context, state.scheduling
    local messages = {}
    host.api.log = function(_, message)
        messages[#messages + 1] = message
    end
    host.owners["service:telemetry"] = nil
    -- Per-source ownership is implicit, but an unknown ordinary service is not.
    context.serviceRuntime = { order = { { id = "unknown", count = 0 } }, byId = {} }
    for _ = 1, 32 do
        if not host:ready(context) then
            break
        end
    end
    assert(messages[1] and string.find(messages[1], "service:unknown has no owner", 1, true))
    context.serviceRuntime = nil
    state.reconciled()
    state.settle(context, host)
    equal(host.scheduler.count, 2, "validation failure cannot discard the retained canonical service")
end

do
    local release = assert(loadfile(root .. "/tests/fixtures/scheduler-cases/lifecycle-release.lua"))()(load)
    equal(#release.cases, 258)
    for _, index in ipairs({ 1, 217, 258 }) do
        local item = release.cases[index]
        local task, now = item.setup()
        task:step(1, item.stage, now)
        equal(#release.cases, 258, "native fixture setup cannot append more cases while being measured")
    end
end

print("Bounded shared-host readiness preserves 30/128-task identity, resets, safe admission and fairness")
