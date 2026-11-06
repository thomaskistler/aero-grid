-- SPDX-License-Identifier: GPL-2.0-only

-- Armed switch scheduling parity, shared-reader ownership, and no-room behavior.
local root = (... and ... ~= "" and ...) or "."
local parity = assert(loadfile(root .. "/tests/support/scheduler_parity.lua"))(root)
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local controlService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()
local armedService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/armed_service.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local function adapter()
    return {
        id = "service:armed",
        decl = armedService.decl,
        new = function()
            local box = { now = 0, values = { [1] = false, [2] = false } }
            local env = services.environment({
                getTime = function()
                    return box.now
                end,
                getSwitchIndex = function(name)
                    return name == "L01" and 1 or 2
                end,
                getSwitchValue = function(index)
                    return box.values[index]
                end,
            })
            local runtime = services.runtime(env)
            local control = controlService.new(env, services, runtime)
            runtime.byId.control = control
            local armed = armedService.new(env, services, runtime)
            runtime.byId.armed = armed
            control:displaySwitch("L01")
            local feeds = {
                armed:state("L01"),
                armed:state("L02"),
            }
            local task = armed.tasks.run
            task.id, task.count, task.due, task.revision = "armed", #armed.entries, 0, 0
            task.update = function(_, now)
                control:update(now)
            end
            task.box, task.service, task.feeds = box, armed, feeds
            return task
        end,
        feed = function(task, callback)
            task.box.now = callback.now
            task.box.values[1], task.box.values[2] = callback.values[1], callback.values[2]
        end,
        old = function(task, now)
            task.service.runtime.byId.control:update(now)
        end,
        snapshot = function(task)
            local values = {}
            for index, feed in ipairs(task.feeds) do
                values[index] = table.concat({
                    tostring(feed.value),
                    tostring(feed.available),
                    tostring(feed.fresh),
                    tostring(feed.status),
                    tostring(feed.revision),
                }, ":")
            end
            return table.concat(values, "|")
        end,
    }
end

local trace = {}
for index = 1, 240 do
    trace[index] = {
        now = index * 20,
        kind = index % 7 == 0 and "background" or "steady",
        values = {
            [1] = index % 9 < 4 and true or false,
            [2] = index % 13 < 6 and true or false,
        },
    }
end

local taskAdapter = adapter()
local expected = parity.golden(taskAdapter, trace)
parity.assertSame(expected, parity.extraction(taskAdapter, trace), "armed extraction")
local extraction = parity.extraction(taskAdapter, trace)
parity.assertSame(expected, parity.replay(taskAdapter, trace, extraction.schedule), "armed replay")
local ample = parity.budgeted(taskAdapter, trace)
parity.assertSame(expected, ample, "armed ample budget")
equal(ample.task.service.tasks.run.want, 2, "both unique arm conditions remain subscribed")

do
    local task = taskAdapter.new()
    equal(task.service.runtime.byId.control.tasks.critical.want, 0, "claimed arm inputs leave Control's task")
    equal(#task.service.runtime.byId.control.criticalEntries, 0, "an existing shared switch is transferred once")
    equal(task.service.runtime.byId.control.tasks.normal.want, 0, "the display subscription is transferred too")
    equal(#task.service.runtime.byId.control.normalEntries, 0, "the condition is never polled by both services")
    equal(task.want, 2, "the Armed task owns both boundary inputs")
    equal(task.decl.class, "critical")
    equal(task.decl.stages.run.maxUnits, 6)
    equal(scheduler.check(task.decl), nil, "the Armed declaration is usable")
end

do
    local task = taskAdapter.new()
    task.box.values[1] = true
    equal(task.step(task, 1, "run", 0), 1)
    equal(task.step(task, 1, "run", 1), 20)
    local arm = task.feeds[1]
    equal(arm.value, true)
    equal(arm.fresh, true)

    local s = scheduler.new({ steady = 1250, background = 1130 })
    local added, reason = s:add({ id = "service:armed", decl = task.decl, instance = task, due = 20 })
    assert(added, reason)
    task.box.now, task.box.values[1] = 200, false
    s:run("steady", 200, scheduler.CEILING)
    equal(s.lastPlan.ran, 0, "no room defers critical Armed work")
    equal(s:dueOf("service:armed"), 20, "a deferred release stays pending")
    equal(arm.value, true, "no room cannot manufacture a disarm edge")
    equal(arm.fresh, false, "an old sample expires without changing its value")
    assert(not s:takeErrors(), "no room is not a task failure")

    task.box.now = 201
    s:run("steady", 201)
    equal(arm.value, false, "the deferred task reads the current switch when room returns")
    equal(arm.fresh, true)
    assert(not s:takeErrors())
end

print("Scheduler Armed task parity passed")
