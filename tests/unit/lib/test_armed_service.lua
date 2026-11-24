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
        local value = values[math.abs(index)]
        if index < 0 and type(value) == "boolean" then
            return not value
        end
        return value
    end,
}
local function runtime(modelArm)
    local registry = support.runtime(env)
    registry.modelArmed = modelArm
    registry.byId.control = controlModule.new(env, support)
    registry.byId.armed = armedModule.new(env, support, registry)
    return registry, registry.byId.armed, registry.byId.control
end
local _, unset = runtime()
local empty = unset:state()
equal(empty.configured, false)
equal(empty.fresh, false)
equal(empty.status, "unconfigured")
local registry, service, control = runtime("SFv")
local first = service:state()
assert(service:state() == first)
local second = control:switch("SAv")
assert(control:switch("SFv") == control.switches.SFv)
equal(control.count, 2, "conditions are polled once, including State subscriptions")
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
equal(first.fresh, true, "samples remain usable beyond one second")
now = 500
equal(first.fresh, true, "five-second boundary is inclusive")
now = 501
equal(first.available, true)
equal(first.fresh, false, "expired samples cannot remain fresh")
assert(first.revision > initialRevision, "freshness changes advance the published revision")
equal(first.status, "unavailable")
control:update(now)
equal(first.fresh, true)
values[1] = nil
now = 520
control:update(now)
equal(first.available, false)
equal(first.fresh, false, "missing input is not a disarm event")
values[1] = true
control:update(now)
equal(first.value, true)
control.failed = true
equal(first.fresh, false)
equal(first.available, false)
local _, numeric = runtime("ch5")
assert(not pcall(numeric.state, numeric), "legacy numeric sources need explicit replacement")

local _, native, nativeControl = runtime("L01")
local selected = native:state()
equal(selected.condition, "L01")
equal(nativeControl.count, 1)
equal(armedModule.name(1, control), "SFv")
equal(armedModule.name(-3, control), "!L01")
assert(not pcall(armedModule.name, 999, control), "unsupported switch kinds must be reported")
equal(registry.modelArmed, "SFv")
local _, disabled = runtime("")
equal(disabled:state().configured, false, "saved None disables arming")

local _, inverted, invertedControl = runtime("!L01")
local invertedState = inverted:state()
invertedControl:update(now)
equal(invertedState.value, true)
equal(invertedState.fresh, true, "negated false is a reliable reading")
values[3] = true
invertedControl:update(now)
equal(invertedState.value, false)
values[3] = nil
invertedControl:update(now)
equal(invertedState.available, false, "negation must not turn a missing reading into true")
equal(invertedState.fresh, false)
local unknown = invertedControl:switch("!L02")
invertedControl:update(now)
equal(unknown.known, false, "negation must not turn an unresolved switch into a known condition")
equal(unknown.available, false)

local layout = load("lib/layout.lua")
local counter = layout.migratePanel({ type = "flight-counter" }, 3)
equal(counter.config.armSwitch, "SF^", "preserve old implicit Flight counter default")
local navigation = layout.migratePanel({ type = "navigation", config = { armSwitch = "SFv" } }, 3)
equal(navigation.config.homeMode, "first-arm")
local edge = layout.migratePanel({ type = "navigation", config = {} }, 3)
equal(edge.config.homeMode, "edgetx")

local host = load("lib/panel_host.lua")
local switchNames = { "", "SF^", "SA-", "SFv" }
for number = 1, 64 do
    local name = string.format("L%02d", number)
    switchNames[#switchNames + 1] = name
    switchNames[#switchNames + 1] = "!" .. name
end
local invalidNames = { "L00", "!L00", "L65", "!L65", "L99", "!L99", "L4", "!L4", "!!L04", "SF", "!SFv", "ch5" }
local state = load("panels/state.lua")
local function settings(name)
    return { entries = { { label = "ARM", states = { { switch = name, text = "ARMED" } } } } }
end
for _, name in ipairs(switchNames) do
    assert(armedModule.valid(name))
    local _, warnings = host.resolveSettings(state, settings(name))
    equal(#warnings, 0, "state condition " .. name)
end
for _, name in ipairs(invalidNames) do
    assert(not armedModule.valid(name))
    local _, warnings = host.resolveSettings(state, settings(name))
    assert(#warnings > 0, "state accepted invalid condition " .. name)
end
