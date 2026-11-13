-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local originalLoadScript = loadScript
local relative = "lib/scheduler.lua"
loadScript = function(filename)
    local chunk, message = originalLoadScript(filename)
    if chunk and string.sub(filename, -#relative) == relative then
        return function(...)
            local module = chunk(...)
            module.SLOTS = 12
            return module
        end
    end
    return chunk, message
end
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
loadScript = originalLoadScript
local definition = fixture.module("main.lua")
assert(context.scheduler.capacity == 12)
assert(context.servicesModule.SLOTS == 12 and context.servicesModule.INSTRUCTIONS_PER_SLOT == 2000)
assert(context.panelHost.SLOTS == 12)
assert(context.servicesModule.grant(12, 12) == 12)
assert(not pcall(context.servicesModule.grant, 13, 12))
local panel = { id = "test", apiVersion = 1, create = function() end, refreshCost = 12 }
assert(context.panelHost.validateModule(panel, "test"))
panel.refreshCost = 13
assert(not context.panelHost.validateModule(panel, "test"))

context.flightFactory = nil
context.serviceRuntime = context.servicesModule.runtime({})
local granted
context.servicesModule.register(context.serviceRuntime, {
    id = "test",
    count = 1,
    interval = 0,
    revision = 0,
    updateCost = "variable",
    update = function(_, _, slots)
        granted = slots
        return slots
    end,
}, 0)
context.schedulerStats = {
    started = getTime(),
    callbacks = 0,
    used = 0,
    requested = 0,
    denied = 0,
    revision = 0,
}
fixture.tick(100)
definition.refresh(context)
assert(granted == 12 and context.remainingSlots == 0)
assert(context.schedulerStats.capacity == 12 and context.schedulerStats.utilization == 100)
fixture.tick(10)
definition.background(context)
assert(granted == 12 and context.remainingSlots == 0, "hidden callbacks use the same capacity")
