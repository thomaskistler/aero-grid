-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 12)
local definition = fixture.module("main.lua")
local broker = assert(context.flightFactory.broker)
assert(broker.documentLoaded and broker.document)

local function enable(value)
    broker.document.flight = context.flightConfig.resolve({ liveDangerously = value })
end

local updates, grants
local function service(turns)
    updates, grants = 0, {}
    context.serviceRuntime = context.servicesModule.runtime({})
    context.servicesModule.register(context.serviceRuntime, {
        id = "busy",
        count = 1,
        interval = 0,
        revision = 0,
        updateCost = "variable",
        updateMinCost = 1,
        update = function(_, _, slots)
            updates = updates + 1
            grants[#grants + 1] = slots
            return slots, updates < turns
        end,
    }, 0)
    context.schedulerStats = { started = getTime(), callbacks = 0, used = 0, requested = 0, denied = 0, revision = 0 }
end

-- EdgeTX stops a callback with "CPU limit" after 20000 instructions.
local function callback(limited)
    fixture.tick(100)
    if limited then
        local hooks = 0
        debug.sethook(function()
            hooks = hooks + 1
            if hooks > 100 then
                debug.sethook()
                error("CPU limit")
            end
        end, "", 200)
    end
    local ok, message = pcall(definition.refresh, context)
    debug.sethook()
    assert(ok, message)
end

enable(false)
service(100)
callback(false)
assert(updates == 1 and context.remainingSlots == 0, "without the option a callback stays within its slots")
assert(context.schedulerStats.capacity == 8)

enable(true)
service(100)
callback(false)
assert(updates == 5, "the option adds four more segments: " .. updates)
assert(context.schedulerStats.capacity == 40 and context.schedulerStats.utilization == 100)
assert(not context.liveDangerouslyFailed)

service(100)
callback(true)
assert(updates == 5, "segments run past the instruction limit: " .. updates)
assert(not context.liveDangerouslyFailed and #context.errors == 0)

service(3)
callback(true)
assert(updates == 3, "unneeded segments are not run")
assert(context.schedulerStats.capacity == 24 and context.schedulerStats.utilization == 100)

enable(false)
service(100)
callback(true)
assert(updates == 1, "turning the option off restores one segment")

print("Live dangerously integration passed")
