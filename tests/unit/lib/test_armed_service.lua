-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local load = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local support, controlModule, armedModule =
    load("lib/services.lua"), load("lib/control_service.lua"), load("lib/armed_service.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local now, reads = 0, 0
local values = { [1] = false, [2] = true, [3] = false }
local ids = { SFv = 1, SAv = 2, L01 = 3 }
local env = {
    charUp = "^",
    charDown = "v",
    getTime = function()
        return now
    end,
    getSwitchIndex = function(name)
        return ids[name] or 0
    end,
    getSwitchValue = function(index)
        reads = reads + 1
        return values[index]
    end,
}
local function runtime(modelArm)
    local registry = support.runtime(env)
    registry.modelArmed, registry.armGeneration = modelArm, 7
    registry.byId.control = controlModule.new(env, support)
    registry.byId.armed = armedModule.new(env, support, registry)
    return registry, registry.byId.armed, registry.byId.control
end
local registry, service, control = runtime()
local empty = service:state()
equal(empty.configured, false)
equal(empty.fresh, false)
equal(empty.status, "unconfigured")
local first, second = service:state("SFv"), service:state("SAv")
assert(first ~= second, "unsaved model Armed must preserve distinct legacy switches")
assert(service:state("SFv") == first)
assert(control:switch("SFv") == control.switches.SFv)
equal(control.count, 2, "conditions are polled once, including State subscriptions")
equal(first.origin, "legacy")
equal(first.generation, 7)
control:update(now)
equal(reads, 2)
equal(first.value, false)
equal(first.fresh, true, "disarmed is a reliable reading")
local initialRevision = first.revision
equal(second.value, true)
assert(not pcall(function()
    first.value = true
end), "published arm state must be immutable")
now = 101
equal(first.available, true)
equal(first.fresh, false, "expired samples cannot remain fresh")
assert(first.revision > initialRevision, "freshness changes advance the published revision")
equal(first.status, "unavailable")
control:update(now)
equal(first.fresh, true)
values[1] = nil
now = 120
control:update(now)
equal(first.available, false)
equal(first.fresh, false, "missing input is not a disarm event")
values[1] = true
control:update(now)
equal(first.value, true)
control.failed = true
equal(first.fresh, false)
equal(first.available, false)
assert(not pcall(service.state, service, "ch5"), "legacy numeric sources need explicit replacement")

local _, native, nativeControl = runtime("L01")
local selected = native:state()
equal(selected.condition, "L01")
equal(selected.origin, "model")
assert(native:state("SFv") == selected and native:state("ch5") == selected, "model Armed overrides legacy")
equal(nativeControl.count, 1)
equal(armedModule.name(1, control), "SFv")
assert(not pcall(armedModule.name, 999, control), "unsupported switch kinds must be reported")
equal(registry.modelArmed, nil, "legacy resolution must not save model settings")
local _, disabled = runtime("")
assert(disabled:state("SFv") == disabled:state("SAv"))
equal(disabled:state("SFv").configured, false, "saved None disables every legacy condition")

local extrema = load("lib/extrema_service.lua").new(env, support, registry)
registry.byId.control.failed = nil
local a, b = extrema:flight("SFv"), extrema:flight("SAv")
assert(a ~= b)
local ta, tb = extrema:sessionExtrema("Alt", "SFv"), extrema:sessionExtrema("Alt", "SAv")
assert(ta ~= tb, "legacy extrema consumers must not silently reconfigure one session")
local nativeRegistry = support.runtime(env)
nativeRegistry.modelArmed = "L01"
nativeRegistry.byId.control = nativeControl
nativeRegistry.byId.armed = native
local unified = load("lib/extrema_service.lua").new(env, support, nativeRegistry)
assert(unified:flight("SFv") == unified:flight("SAv"), "model condition unifies extrema sessions")

local layout = load("lib/layout.lua")
local counter = layout.migratePanel({ type = "flight-counter" }, 3)
equal(counter.config.armSwitch, "SF^", "preserve old implicit Flight counter default")
local navigation = layout.migratePanel({ type = "navigation", config = { armSwitch = "SFv" } }, 3)
equal(navigation.config.homeMode, "first-arm")
local edge = layout.migratePanel({ type = "navigation", config = {} }, 3)
equal(edge.config.homeMode, "edgetx")

local trackingRegistry, _, trackingControl = runtime()
local reading = { value = 10, fresh = true }
trackingRegistry.byId.telemetry = {
    subscribe = function()
        return reading
    end,
}
local tracking = load("lib/extrema_service.lua").new(env, support, trackingRegistry)
local tracks = {}
for index = 11, 18 do
    local name = string.format("L%02d", index)
    ids[name], values[index] = index, true
    tracks[#tracks + 1] = tracking:sessionExtrema("Alt", name)
end
trackingControl:update(now)
trackingControl:update(now)
tracking:update(now)
tracking:update(now)
local sampleCount = tracks[8].samples
values[18], reading.value, now = false, 999, now + 20
trackingControl:update(now)
trackingControl:update(now)
tracking.sessionCursor, tracking.cursor = 1, 8
tracking:update(now)
equal(tracks[8].samples, sampleCount, "a track must observe disarm before its session's next round-robin turn")
assert(tracks[8].max ~= 999)
