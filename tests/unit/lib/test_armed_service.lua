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
equal(service.tasks.run.want, 2, "the Armed task owns each unique arm condition")
equal(control.tasks.critical.want, 0, "claimed arm conditions are removed from Control's task")
equal(#control.criticalEntries, 0, "a shared switch is transferred rather than double-polled")
equal(first.origin, "legacy")
equal(first.generation, 7)
service.tasks.run:step(2, "run", now)
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
service.tasks.run:step(2, "run", now)
equal(first.fresh, true)
values[1] = nil
now = 120
service.tasks.run:step(2, "run", now)
equal(first.available, false)
equal(first.fresh, false, "missing input is not a disarm event")
values[1] = true
service.tasks.run:step(2, "run", now)
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

local layout = load("lib/layout.lua")
local counter = layout.migratePanel({ type = "flight-counter" }, 3)
equal(counter.config.armSwitch, "SF^", "preserve old implicit Flight counter default")
local navigation = layout.migratePanel({ type = "navigation", config = { armSwitch = "SFv" } }, 3)
equal(navigation.config.homeMode, "first-arm")
local edge = layout.migratePanel({ type = "navigation", config = {} }, 3)
equal(edge.config.homeMode, "edgetx")

local _, failing = runtime()
local arm = failing:state("SFv")
local task = failing.tasks.run
task:step(1, "run", now)
equal(arm.available, true)
failing.entries[1].read = function()
    error("arm input failed", 0)
end
local ok, failure = pcall(task.step, task, 1, "run", now + 20)
equal(ok, false)
equal(failure, "arm input failed")
equal(failing.failed, true)
equal(failing.entries[1].state.available, false, "shared adapter runs Armed's invalidation hook")
equal(failing.entries[1].state.fresh, false)
equal(arm.available, false)
equal(arm.fresh, false)

for grant = 1, armedModule.decl.stages.run.maxUnits do
    for index = 1, 6 do
        ids[string.format("L%02d", index)], values[index] = index, index % 2 == 0
    end
    local _, armed, controls = runtime()
    local views = {}
    for index = 1, 6 do views[index] = armed:state(string.format("L%02d", index)) end
    armed.cursor = 6
    local before = reads
    armed.tasks.run:step(grant, "run", now)
    equal(reads - before, grant, "partial Armed grants read exactly the admitted conditions")
    equal(#controls.criticalEntries, 0, "all Armed conditions retain exclusive polling ownership")
    for offset = 0, 5 do
        local index = (5 + offset) % 6 + 1
        equal(views[index].available, offset < grant, "cursor wrap preserves unvisited Armed conditions")
    end
end
