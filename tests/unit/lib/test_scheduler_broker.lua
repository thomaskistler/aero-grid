-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local function load(relative)
    local path = string.sub(relative, 1, 9) == "@support/" and "/tests/support/" .. string.sub(relative, 10)
        or "/src/WIDGETS/AeroGrid/" .. relative
    return assert(loadfile(root .. path))()
end
local case = assert(loadfile(root .. "/tests/fixtures/scheduler-cases/broker-registration.lua"))()(load)
local support, model = load("lib/services.lua"), load("lib/model_service.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

for _, item in ipairs(case.cases) do
    local task, now, state = item.setup()
    local additions = 0
    local add = state.scheduling.scheduler.add
    function state.scheduling.scheduler:add(spec)
        additions = additions + 1
        equal(state.scheduling.panelSetup, 2300, "registration is charged before scheduler allocation")
        return add(self, spec)
    end
    equal(task:step(1, "run", now), 1)
    assert(additions <= 1, "a ready turn cannot enroll multiple service tasks")
    equal(next(state.scheduling.panelTasks), nil, "idle panels cannot share service allocation")
    state.scheduling.scheduler.add = add
    state.settle(state.context, state.scheduling)
    local owner, context, scheduling = state.owner, state.context, state.scheduling
    local scheduler = scheduling.scheduler
    local disabled = state.action == "disable"
    local initial = state.action == "enroll"
        or state.action == "enroll-next"
        or state.action == "extra-kinds"
        or state.action == "extra-kinds-final"
        or state.action == "handoff"
    equal(owner:schedulerService(context), not disabled and state.stable or nil)
    if disabled then
        equal(scheduler:dueOf("service:flight"), nil)
        equal(scheduler:dueOf("service:smart"), nil)
        equal(next(scheduling.registeredTasks), nil)
    else
        equal(scheduling.registeredTasks["service:flight"], state.stable)
        equal(scheduling.registeredTasks["service:smart"], state.stable)
        equal(#scheduling.waiting, 0, "the dashboard facade cannot duplicate canonical tasks")
        local count = 0
        for _ in pairs(scheduler.byId) do
            count = count + 1
        end
        equal(count, 2, "only the two actual broker tasks are enrolled")
        if not initial then
            equal(scheduler:dueOf("service:flight"), 47)
            equal(scheduler:dueOf("service:smart"), 83)
        else
            assert(scheduler:dueOf("service:flight") ~= nil)
            assert(scheduler:dueOf("service:smart") ~= nil)
        end
        equal(scheduler.byId["service:flight"].instance, owner.tasks.run)
        equal(scheduler.byId["service:smart"].instance, owner.tasks.smart)
        local flightDue, smartDue = scheduler:dueOf("service:flight"), scheduler:dueOf("service:smart")
        owner:enableScheduler(context)
        state.ready(context, scheduling)
        equal(scheduler:dueOf("service:flight"), flightDue, "same-owner activation preserves the Flight release")
        equal(scheduler:dueOf("service:smart"), smartDue, "same-owner activation preserves the Smart release")
        assert(scheduling:verify(context) == nil)
    end
    if state.action == "facade" then
        equal(state.facade.count, 0)
        equal(state.facade.schedulerTasks, nil)
        equal(state.replaced.count, 1)
        equal(state.replaced.schedulerTasks, state.stable.schedulerTasks)
    elseif state.action == "model-reset" then
        equal(owner.filename, "other.yml")
        equal(owner.runtime, nil)
        equal(owner.smartRuntime, nil)
        equal(owner.failed, nil)
        equal(state.stable.failed, nil)
        equal(owner.tasks.run.stage, "run")
    elseif state.action == "session-reset" then
        equal(owner.session.phase, "ground")
    elseif state.action == "handoff" then
        equal(state.previousScheduling.scheduler:dueOf("service:flight"), nil)
        equal(state.previousScheduling.scheduler:dueOf("service:smart"), nil)
        equal(next(state.previousScheduling.registeredTasks), nil)
        equal(owner:schedulerService(state.previous), nil)
        equal(state.facade.count, 0)
        assert(not pcall(owner.enableScheduler, owner, state.previous))
        local due = scheduler:dueOf("service:flight")
        owner:enableScheduler(context)
        state.ready(context, scheduling)
        equal(scheduler:dueOf("service:flight"), due, "idempotent activation cannot reset a release")
    end
    if state.action == "partial" then
        local ordinary = model.new(owner.env, support)
        ordinary:timer(0)
        context.serviceRuntime = { order = { ordinary }, byId = { model = ordinary } }
        state.settle(context, scheduling)
        assert(scheduler:dueOf("service:model") ~= nil)
        context.serviceRuntime = nil
        state.settle(context, scheduling)
        equal(scheduler:dueOf("service:model"), nil, "replaced dashboard services still retire")
        equal(scheduler:dueOf("service:flight"), 47)
        equal(scheduler:dueOf("service:smart"), 83)
    elseif state.action == "registry-gap" then
        scheduler:run("steady", 1200, 0)
        equal(owner.session.arm.updatedAt, 1200, "the real private arm poller runs without a dashboard registry")
        equal(owner.session.motor.updatedAt, 1200, "the real private motor poller runs without a dashboard registry")
        equal(owner.smartRuntime.byId.smart.polledAt, 1200, "the actual Smart task survives the registry gap")
        scheduler:run("background", 1300, 0)
        equal(owner.smartRuntime.byId.smart.polledAt, 1300, "background also advances the actual Smart task")
        equal(scheduler:takeErrors(), nil)
    end
end

do
    local _, _, state = case.cases[1].setup()
    state.settle(state.context, state.scheduling)
    local telemetry = load("lib/telemetry_service.lua").new(state.owner.env, support)
    for index = 1, 24 do
        telemetry:subscribe("Source" .. index, false)
    end
    state.context.serviceRuntime = { order = { telemetry }, byId = { telemetry = telemetry } }
    local scheduling = state.scheduling
    repeat
        state.ready(state.context, scheduling)
    until not scheduling.reconciliation
    assert(#scheduling.waiting > 1, "demanded services remain pending across callbacks")
    assert(scheduling:verify(state.context) == nil, "legitimate pending services satisfy verification")
    local pending = scheduling.waiting[1]
    scheduling.pendingServices[pending.id] = nil
    assert(scheduling:verify(state.context), "missing registrations cannot masquerade as pending work")
    scheduling.pendingServices[pending.id] = pending.instance
    for index in ipairs(telemetry.schedulerTasks) do
        scheduling:resetServiceRelease(telemetry, 17, index)
    end
    local dormant = scheduling.waiting[#scheduling.waiting].task
    dormant.want = 0
    state.context.serviceRuntime = { order = { telemetry }, byId = { telemetry = telemetry } }
    local add = scheduling.scheduler.add
    local additions = 0
    function scheduling.scheduler:add(spec)
        additions = additions + 1
        equal(scheduling.panelSetup, 2300, "bulk admission is charged before allocation")
        return add(self, spec)
    end
    for _ = 1, 160 do
        additions = 0
        state.ready(state.context, scheduling)
        assert(additions <= 1, "bulk service demand cannot create an unbounded enrollment atom")
    end
    equal(#scheduling.waiting, 1, "a dormant task cannot starve the other demanded tasks")
    dormant.want = 1
    state.ready(state.context, scheduling)
    equal(#scheduling.waiting, 0)
    for _, item in ipairs(telemetry.schedulerTasks) do
        equal(scheduling.scheduler:dueOf(item.id), 17, "pending resets retain their exact release")
    end
    scheduling:begin("steady")
    equal(scheduling.legacy.spent, 2300, "admission is reserved before scheduler allocation")
end
print("Actual broker registration preserves releases through registry gaps, resets and handoff")
