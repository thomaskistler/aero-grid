-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 12)
local definition = fixture.module("main.lua")
local broker = assert(context.flightFactory.broker)
assert(broker.documentLoaded and broker.document)
context.liveDangerouslyFailed = nil

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
end

-- EdgeTX stops a callback with "CPU limit" after 20000 instructions.
-- Scheduler counters for the last callback.
local last
local function callback(limited)
    local totals = context.scheduler.stats()
    local used, available, denied = totals.used, totals.available, totals.denied
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
    last = { used = totals.used - used, available = totals.available - available, denied = totals.denied - denied }
end

enable(false)
service(100)
callback(false)
assert(updates == 1 and context.remainingSlots == 0, "without the option a callback stays within its slots")
assert(last.available == 32)

enable(true)
service(100)
callback(false)
assert(updates == 5, "the option adds four more segments: " .. updates)
assert(last.available == 160 and last.used == 160)
assert(last.denied > 0, "work left over after the last segment is deferred")
assert(not context.liveDangerouslyFailed)

service(100)
callback(true)
assert(updates == 5, "segments run past the instruction limit: " .. updates)
assert(not context.liveDangerouslyFailed and #context.errors == 0)

service(3)
callback(true)
assert(updates == 3, "unneeded segments are not run")
assert(last.available == 160 and last.used == 96)
assert(last.denied == 0, "work that finished within the callback is not deferred")

enable(false)
service(100)
callback(true)
assert(updates == 1, "turning the option off restores one segment")

print("Live dangerously integration passed")
