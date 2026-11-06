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
assert(owner:owningContext() == first and not owner.schedulerEnabled)
assert(first.serviceRuntime.byId.flight.count == 0, "handoff must not require a Flight panel subscriber")
host.owners = setmetatable({}, { __index = host.owners })

local function advance(context, background)
    fixture.tick(10)
    if background then
        definition.background(context)
    else
        definition.refresh(context)
    end
    fixture.lvglMock.settle()
end

host.owners["service:flight"], host.owners["service:smart"] = "new", "legacy"
advance(first)
assert(not owner.schedulerEnabled, "Flight and Smart must transfer together")
host.owners["service:flight"], host.owners["service:smart"] = "legacy", "new"
advance(first)
assert(not owner.schedulerEnabled, "Smart alone cannot transfer the shared broker")
host.owners["service:flight"] = "new"
host.mode = "legacy"
advance(first)
assert(not owner.schedulerEnabled, "legacy observation must not activate scheduled Flight")
host.mode = "mixed"

first.reloadState = "clear"
for _ = 1, 512 do
    advance(first)
    assert(not owner.schedulerEnabled, "initial handoff must wait for the settled dashboard")
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
first.flightDashboardDue = true
advance(first)
assert(owner.schedulerEnabled and not first.flightDashboardDue)
assert(
    not host.scheduler.byId["service:flight"] and not host.scheduler.byId["service:smart"],
    "handoff fixture must exercise pending canonical enrollment"
)
assert(host.head == host.headCosts.tick, "one-time handoff must retain its bounded head reservation")
for turn = 1, 150 do
    advance(first, turn % 2 == 0)
    assert(host.head == 0, "the legacy tick charge must stop after handoff")
    assert(not first.flightPolled, "legacy Smart reservation must not survive scheduled ownership")
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
second.schedulerHost.owners = setmetatable({
    ["service:flight"] = "new",
    ["service:smart"] = "new",
}, { __index = second.schedulerHost.owners })
watchScheduling(second)
for _ = 1, 50 do
    advance(second)
end
assert(owner:owningContext() == first, "another live widget cannot displace the canonical owner")
assert(not second.scheduler.byId["service:flight"] and not second.scheduler.byId["service:smart"])

local retiredFacade = owner.facade
owner.context = setmetatable({}, { __mode = "v" })
advance(second)
assert(owner:owningContext() == second and owner.facade == second.serviceRuntime.byId.flight)
assert(retiredFacade.count == 0 and not retiredFacade.schedulerTasks)
for _ = 1, 150 do
    advance(second)
end
assert(second.scheduler.byId["service:flight"] and second.scheduler.byId["service:smart"])
assert(second.scheduler.byId["service:flight"].due < due, "a collected owner has no transferable host releases")
assert(#first.errors == 0 and #second.errors == 0)
print("Real Flight/Smart handoff preserves paired ownership, canonical releases and nil-owner reclaim")
