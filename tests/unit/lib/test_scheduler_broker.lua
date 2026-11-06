-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local function load(relative)
    return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. relative))()
end
local host = load("lib/scheduler_host.lua")
local panelHost = load("lib/panel_host.lua")
getTime = function()
    return 0
end
local function task(interval)
    return {
        interval = interval,
        want = 1,
        decl = { class = "normal", stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } } },
        step = function()
            return interval
        end,
    }
end
local flight, smart = task(20), task(100)
local source = {
    id = "flight",
    count = 1,
    interval = 20,
    schedulerTasks = {
        { id = "service:flight", instance = flight },
        { id = "service:smart", instance = smart },
    },
}
local enabled = true
local context = { panels = {}, panelHost = panelHost }
context.flightFactory = {
    broker = {
        schedulerService = function(_, owner)
            assert(owner == context)
            return enabled and source or nil
        end,
    },
}
local scheduling = host.attach(context, {
    mode = "mixed",
    load = load,
    api = {
        log = function(_, message)
            error(message)
        end,
    },
})
scheduling.owners = {}
for key, value in pairs(host.OWNERS) do
    scheduling.owners[key] = value
end
scheduling.owners["service:flight"], scheduling.owners["service:smart"] = "new", "new"
assert(scheduling:ready(context))
assert(scheduling.registeredTasks["service:flight"] == source)
assert(scheduling.registeredTasks["service:smart"] == source)
assert(scheduling.scheduler:reschedule("service:flight", 47))
assert(scheduling.scheduler:reschedule("service:smart", 83))
for _, registry in ipairs({
    { order = {}, byId = {} },
    { order = { { id = "flight", count = 1, schedulerTasks = source.schedulerTasks } }, byId = {} },
    { order = {}, byId = {} },
}) do
    context.serviceRuntime = registry
    assert(scheduling:ready(context))
    assert(scheduling.scheduler:dueOf("service:flight") == 47)
    assert(scheduling.scheduler:dueOf("service:smart") == 83)
    assert(#scheduling.waiting == 0, "facades must not duplicate canonical registrations")
end
context.serviceRuntime = nil
assert(scheduling:ready(context))
assert(scheduling.scheduler:dueOf("service:flight") == 47)
assert(scheduling.scheduler:dueOf("service:smart") == 83)
local ordinary = task(50)
ordinary.id, ordinary.count = "model", 1
context.serviceRuntime = { order = { ordinary }, byId = { model = ordinary } }
assert(scheduling:ready(context))
assert(scheduling.scheduler:dueOf("service:model") ~= nil)
context.serviceRuntime = nil
assert(scheduling:ready(context))
assert(scheduling.scheduler:dueOf("service:model") == nil, "old dashboard services must still retire")
assert(scheduling.scheduler:dueOf("service:flight") == 47)
assert(scheduling.scheduler:dueOf("service:smart") == 83)
enabled, context.panelTasksDirty = false, true
assert(scheduling:ready(context))
assert(scheduling.scheduler:dueOf("service:flight") == nil)
assert(scheduling.scheduler:dueOf("service:smart") == nil)
assert(next(scheduling.registeredTasks) == nil)
print("Scheduler broker registration survives registry gaps without resetting releases")
