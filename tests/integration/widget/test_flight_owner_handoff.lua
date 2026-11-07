-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setFullScreen(false)
local definition = fixture.module("main.lua")
local first = definition.create(
    { x = 0, y = 0, w = 480, h = 272 },
    { Layout = "review-metric", Theme = "modern-dark" },
    root .. "/build/test-widget-fixture/"
)
assert(fixture.pumpUntil(first, function(context)
    return not context.stage and not context.reloadState
end, 512, 10))
fixture.pump(first, 100, 10)
local owner, host = first.flightBroker, first.schedulerHost
assert(owner:owningContext() == first and owner.schedulerEnabled)
assert(first.serviceRuntime.byId.flight.schedulerTasks, "Flight tasks must run without a Flight panel subscriber")

local function advance(context, background)
    fixture.tick(10)
    if background then
        definition.background(context)
    else
        definition.refresh(context)
    end
    fixture.lvglMock.settle()
end

first.reloadState = "clear"
for _ = 1, 512 do
    advance(first)
    if not first.stage and not first.reloadState then
        break
    end
end
assert(not first.stage and not first.reloadState)
owner.document.sessionReset = ""
owner.resetRuntime, owner.resetFeed = nil, nil
owner.errors.reset = nil

local running, ticks = false, 0
local tick = owner.tick
owner.tick = function(self, ...)
    if self.schedulerEnabled then
        assert(running, "scheduled Flight cannot also run at the legacy head")
        ticks = ticks + 1
    end
    return tick(self, ...)
end
local function watchScheduling(context)
    local scheduler = context.schedulerHost.scheduler
    local run = scheduler.run
    scheduler.run = function(self, ...)
        running = true
        local result = run(self, ...)
        running = false
        return result
    end
end
watchScheduling(first)
for turn = 1, 150 do
    advance(first, turn % 2 == 0)
end
local flight = assert(host.scheduler.byId["service:flight"])
local smart = assert(host.scheduler.byId["service:smart"])
assert(ticks > 0 and not host.reconciliation)

local due = getTime() + 100000
flight.due, smart.due = due, due
first.reloadState = "clear"
assert(fixture.pumpUntil(first, function(context)
    return not context.stage and not context.reloadState and not host.reconciliation
end, 512, 10))
assert(host.scheduler.byId["service:flight"] == flight and host.scheduler.byId["service:smart"] == smart)
assert(flight.due == due and smart.due == due, "registry replacement must retain canonical releases")

local second = definition.create(first.zone, { Layout = "review-metric", Theme = "modern-dark" }, first.path)
assert(fixture.pumpUntil(second, function(context)
    return not context.stage and not context.reloadState
end, 512, 10))
assert(second.flightBroker == owner)
watchScheduling(second)
for _ = 1, 50 do
    advance(first)
    advance(second)
end
assert(owner:owningContext() == first, "another live widget cannot displace the canonical owner")
assert(not second.scheduler.byId["service:flight"] and not second.scheduler.byId["service:smart"])

local retiredFacade = owner.facade
assert(fixture.pumpUntil(second, function()
    return owner:owningContext() == second
end, 150, 10), "a parked owner must hand off to a live widget")
assert(owner:owningContext() == second and owner.facade == second.serviceRuntime.byId.flight)
assert(retiredFacade.count == 0 and not retiredFacade.schedulerTasks)
for _ = 1, 150 do
    advance(second)
end
assert(second.scheduler.byId["service:flight"] and second.scheduler.byId["service:smart"])
assert(second.scheduler.byId["service:flight"].due == due, "Flight release survives a parked owner")

assert(fixture.pumpUntil(first, function()
    return not host.reconciliation and not host.scheduler.byId["service:flight"]
        and not host.scheduler.byId["service:smart"]
end, 150, 10), "the old host must reconcile its simulated loss of ownership")
local flightDue, smartDue = getTime() + 100000, getTime() + 100020
second.scheduler.byId["service:flight"].due = flightDue
second.scheduler.byId["service:smart"].due = smartDue
local secondMember = second.flightFactory.members[second]
second.flightFactory.members[second] = nil
advance(first)
assert(owner:owningContext() == first, "a retired owner must not strand the shared Flight broker")
assert(not second.scheduler.byId["service:flight"] and not second.scheduler.byId["service:smart"])
assert(fixture.pumpUntil(first, function()
    return host.scheduler.byId["service:flight"] and host.scheduler.byId["service:smart"]
end, 150, 10), "the replacement host must enroll both canonical tasks")
assert(host.scheduler.byId["service:flight"].due == flightDue, "Flight release survives retirement")
assert(host.scheduler.byId["service:smart"].due == smartDue, "Smart release survives retirement")

second.flightFactory.members[second] = secondMember
host.scheduler:remove("service:flight")
host.scheduler:remove("service:smart")
host.resetReleases["service:flight"], host.resetOwners["service:flight"] = flightDue, owner.taskService
host.resetReleases["service:smart"], host.resetOwners["service:smart"] = smartDue, owner.taskService
first.flightFactory.members[first] = nil
advance(second)
assert(owner:owningContext() == second, "a pending retired owner must transfer")
assert(fixture.pumpUntil(second, function()
    return second.scheduler.byId["service:flight"] and second.scheduler.byId["service:smart"]
end, 150, 10), "the replacement host must enroll pending canonical tasks")
assert(second.scheduler.byId["service:flight"].due == flightDue, "pending Flight release survives retirement")
assert(second.scheduler.byId["service:smart"].due == smartDue, "pending Smart release survives retirement")
assert(#first.errors == 0 and #second.errors == 0)
print("Real Flight/Smart handoff preserves paired ownership and canonical releases")
