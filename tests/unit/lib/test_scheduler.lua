-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local module = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
assert(module.SLOTS == 32 and module.CAPACITY == 32 and module.INSTRUCTIONS_PER_SLOT == 500)

for _, capacity in ipairs({ false, 0, -1, 1.5, math.huge, 0 / 0, "8" }) do
    assert(not pcall(module.new, { capacity = capacity }), "invalid capacity must be rejected")
end

local function fixture(dependencies)
    local queue = module.new(dependencies)
    local calls = {}
    local function task(name, cost, steps)
        local instance = { name = name, cost = cost, turns = 0 }
        instance.step = function(self, now, slots, context)
            self.turns = self.turns + 1
            calls[#calls + 1] = name
            self.now, self.slots, self.context = now, slots, context
            return slots, self.turns < (steps or 1)
        end
        queue.add(instance)
        return instance
    end
    return queue, calls, task
end

do
    local queue, calls, task = fixture()
    local a = task("A", 2, 3)
    task("B", 1)
    task("C", 1)
    local context = {}
    local used, requested, denied = queue.run(12, 8, context)
    assert(table.concat(calls, ",") == "A,B,C,A,A")
    assert(used == 8 and requested == 5 and denied == 0)
    assert(queue.state(a).spent == 6 and not queue.state(a).pending)
    for _, key in ipairs({ "spent", "pending", "refused", "ran", "zeroTurns" }) do
        assert(rawget(a, key) == nil, "scheduler bookkeeping stays off the task: " .. key)
    end
    assert(a.now == 12 and a.context == context and a.slots == 2)
end

do
    local queue, calls, task = fixture()
    task("A", 1, 3)
    task("B", 1, 3)
    task("C", 1, 2)
    assert(queue.run(0, 8) == 8)
    assert(table.concat(calls, ",") == "A,B,C,A,B,C,A,B")
end

do
    local queue, calls, task = fixture()
    local a = task("A", 2, 3)
    local b = task("B", 1)
    local used, requested, denied = queue.run(0, 4)
    assert(table.concat(calls, ",") == "A,B")
    assert(used == 3 and requested == 3 and denied == 1 and queue.state(a).pending)
    a.due, b.due = 100, 100
    queue.clear()
    queue.add(a)
    queue.add(b)
    assert(queue.run(1, 4) == 4, "a re-enrolled pending task resumes despite its due tick")
    assert(table.concat(calls, ",") == "A,B,A,A" and not queue.state(a).pending)
end

do
    local queue, calls, task = fixture()
    local a = task("A", 1, 3)
    task("large", 8)
    task("small", 1)
    task("free", 0, 2)
    local used, requested, denied = queue.run(1, 8)
    assert(table.concat(calls, ",") == "A,free,free")
    assert(used == 1 and requested == 4 and denied == 3)
    assert(queue.state(a).pending and queue.count == 4)
    queue.run(2, 8)
    assert(calls[4] == "large", "a deferred whole-budget task gets the first turn")
    queue.run(3, 8)
    assert(calls[6] == "small", "repeating whole-budget work must not starve later tasks")
end

do
    local queue = module.new()
    local turns = { A = 0, B = 0, X = 0 }
    local function task(name, cost)
        return {
            name = name,
            cost = cost,
            step = function(_, _, slots)
                turns[name] = turns[name] + 1
                return slots, false
            end,
        }
    end
    local a, b, x = task("A", 8), task("B", 8), task("X", 0)
    queue.add(a)
    queue.add(b)
    for callback = 1, 20 do
        if callback % 2 == 0 then
            queue.add(x)
        else
            queue.remove(x)
        end
        queue.run(callback, 8)
    end
    assert(turns.A == 10 and turns.B == 10 and turns.X == 10, "deferred work stays fair as free tasks enter and leave")
end

do
    local queue = module.new()
    local turns = { A = 0, B = 0, X = 0 }
    local function task(name, cost)
        return {
            name = name,
            cost = cost,
            step = function(_, _, slots)
                turns[name] = turns[name] + 1
                return slots, false
            end,
        }
    end
    local a, b, x = task("A", 8), task("B", 8), task("X", 0)
    queue.add(a)
    queue.add(b)
    queue.run(0, 8)
    assert(queue.has(b))
    queue.remove(b)
    assert(not queue.has(b) and queue.count == 1)
    local retired = setmetatable({ b }, { __mode = "v" })
    b = nil
    collectgarbage()
    assert(retired[1] == nil, "the scheduler must not retain a withdrawn task")
    queue.add(x)
    queue.run(1, 8)
    assert(turns.A == 2 and turns.X == 1, "a withdrawn deferred task leaves no gap")
end

do
    local queue = module.new()
    local turns = { A = 0, B = 0, X = 0 }
    local function task(name, cost)
        return {
            name = name,
            cost = cost,
            step = function(_, _, slots)
                turns[name] = turns[name] + 1
                return slots, false
            end,
        }
    end
    local a, b, x = task("A", 8), task("B", 8), task("X", 0)
    queue.add(a)
    queue.add(b)
    queue.run(0, 16)
    assert(turns.A == 1 and turns.B == 1)
    queue.add(x)
    queue.run(1, 8)
    assert(turns.A == 2 and turns.B == 1 and turns.X == 1, "the task that ran least recently goes first")
    queue.run(2, 8)
    assert(turns.A == 2 and turns.B == 2)
end

do
    local queue, calls, task = fixture()
    local free = task("free", 0, 3)
    task("paid", 8)
    local used, requested, denied = queue.run(0, 8)
    assert(table.concat(calls, ",") == "free,paid,free,free")
    assert(used == 8 and requested == 1 and denied == 0)
    assert(queue.state(free).spent == 0 and not queue.state(free).pending)
end

do
    local queue, calls, task = fixture()
    local variable = task("variable", "variable", 2)
    variable.minCost = 1
    variable.step = function(self)
        calls[#calls + 1] = self.name
        self.turns = self.turns + 1
        return 0, self.turns == 1
    end
    task("fixed", 1)
    local used, requested, denied = queue.run(0, 8)
    assert(table.concat(calls, ",") == "variable,fixed,variable")
    assert(used == 1 and requested == 3 and denied == 0)
    assert(queue.state(variable).spent == 0 and not queue.state(variable).pending)
end

do
    local queue, calls, task = fixture()
    local reserved = task("reserved", 4)
    reserved.step = function()
        calls[#calls + 1] = "reserved"
        return 1, false
    end
    task("other", 3)
    local used, requested, denied = queue.run(0, 4)
    assert(table.concat(calls, ",") == "reserved,other")
    assert(used == 4 and requested == 2 and denied == 0 and queue.state(reserved).spent == 1)
end

do
    local queue, calls, task = fixture()
    local reserved = task("reserved", 2)
    reserved.step = function()
        calls[#calls + 1] = "reserved"
        return 0, false
    end
    task("other", 2)
    assert(queue.run(0, 2) == 2)
    assert(table.concat(calls, ",") == "reserved,other" and queue.state(reserved).spent == 0)
end

do
    local queue = module.new({ capacity = 2 })
    local turns = 0
    local reserved = {
        cost = 1,
        step = function()
            turns = turns + 1
            return 0, true
        end,
    }
    queue.add(reserved)
    assert(queue.run(0, 2) == 0 and turns == 2 and queue.state(reserved).pending)
    assert(queue.run(1, 2) == 0 and turns == 4 and queue.state(reserved).pending)
end

do
    local queue, calls, task = fixture()
    local a = task("A", 2, 2)
    a.step = function(self, _, slots)
        calls[#calls + 1] = self.name
        self.turns = self.turns + 1
        self.cost = 3
        return slots, self.turns == 1
    end
    assert(queue.run(0, 5) == 5)
    assert(table.concat(calls, ",") == "A,A" and queue.state(a).spent == 5)
end

do
    local charges = {}
    local queue, calls, task = fixture({
        charge = function(instance, spent)
            charges[#charges + 1] = instance.name .. ":" .. spent
        end,
    })
    local variable = task("variable", "variable", 2)
    variable.minCost = 1
    variable.step = function(self, _, slots)
        calls[#calls + 1] = self.name .. ":" .. slots
        self.turns = self.turns + 1
        return 2, self.turns == 1
    end
    task("fixed", 1)
    assert(queue.run(0, 8) == 5)
    assert(table.concat(calls, ",") == "variable:8,fixed,variable:5")
    assert(table.concat(charges, ",") == "variable:2,fixed:1,variable:2")
    assert(queue.state(variable).spent == 4)
end

do
    local failures = {}
    local queue, calls, task = fixture({
        fail = function(instance, message)
            failures[#failures + 1] = instance.name .. ":" .. message
        end,
    })
    local broken = task("broken", 2)
    broken.step = function()
        error("deliberate failure", 0)
    end
    task("healthy", 1)
    assert(queue.run(0, 8) == 3)
    assert(broken.failed and broken.error == "deliberate failure" and queue.state(broken).spent == 2)
    assert(table.concat(calls, ",") == "healthy")
    queue.run(1, 8)
    assert(#failures == 1 and #calls == 2)
end

for _, invalid in ipairs({ false, -1, 1.5, 33, math.huge, 0 / 0, "1" }) do
    local queue, _, task = fixture()
    local variable = task("invalid", "variable")
    variable.minCost = 1
    variable.step = function()
        return invalid, true
    end
    assert(queue.run(0, 8) == 8)
    assert(variable.failed and not queue.state(variable).pending and queue.state(variable).spent == 8)
    assert(variable.error == "consumption must be whole slots within the grant")
end

for _, invalid in ipairs({ false, -1, 1.5, 3, math.huge, 0 / 0, "1" }) do
    local queue, _, task = fixture()
    local fixed = task("invalid", 2)
    fixed.step = function()
        return invalid, true
    end
    assert(queue.run(0, 8) == 2)
    assert(fixed.failed and not queue.state(fixed).pending and queue.state(fixed).spent == 2)
    assert(fixed.error == "consumption must be whole slots within the grant")
end

do
    local queue, _, task = fixture()
    local variable = task("missing minimum", "variable")
    assert(queue.run(0, 8) == 0 and variable.failed)
    assert(variable.error == "invalid minimum slot cost")
end

for _, invalid in ipairs({ false, -1, 1.5, 33, math.huge, 0 / 0, "1" }) do
    local queue, calls, task = fixture()
    local instance = task("invalid", invalid)
    local used, requested, denied = queue.run(0, 8)
    assert(used == 0 and requested == 0 and denied == 0 and #calls == 0)
    assert(instance.failed and instance.error == "invalid slot cost")
end

do
    local queue = module.new({ capacity = 48 })
    local granted
    queue.add({
        name = "bounded",
        cost = "variable",
        minCost = 3,
        step = function(_, _, slots)
            granted = slots
            return slots, false
        end,
    })
    assert(queue.run(0, 48) == 32 and granted == 32, "one variable turn must never exceed thirty-two slots")
    queue.clear()
    assert(queue.count == 0 and next(queue.tasks) == nil)
    local used, requested, denied = queue.run(1, 48)
    assert(used == 0 and requested == 0 and denied == 0)
    queue.add({
        name = "replacement",
        step = function(_, _, slots)
            return slots, false
        end,
    })
    assert(queue.run(2, 48) == 1 and queue.count == 1)
end

do
    local queue = module.new({ capacity = 12 })
    local calls = {}
    queue.add({
        name = "small",
        cost = 2,
        step = function(_, _, slots)
            calls[#calls + 1] = "small:" .. slots
            return slots, false
        end,
    })
    queue.add({
        name = "minimum",
        cost = "variable",
        minCost = 5,
        step = function(_, _, slots)
            calls[#calls + 1] = "minimum:" .. slots
            return slots, false
        end,
    })
    local used, requested, denied = queue.run(0, 4)
    assert(used == 2 and requested == 2 and denied == 1)
    assert(table.concat(calls, ",") == "small:2", "variable tasks must not run below their minimum")
end

for _, minimum in ipairs({ false, 0, 1.5, 33, math.huge, 0 / 0, "1" }) do
    local queue, _, task = fixture()
    local variable = task("invalid minimum", "variable")
    variable.minCost = minimum
    assert(queue.run(0, 8) == 0)
    assert(variable.failed and variable.error == "invalid minimum slot cost")
end

do
    local queue, _, task = fixture()
    local fixed = task("missing usage", 2)
    fixed.step = function() end
    assert(queue.run(0, 8) == 2 and not fixed.failed and not queue.state(fixed).pending)
    assert(queue.state(fixed).spent == 2, "a fixed step without consumption used its grant")
end

do
    local queue, _, task = fixture()
    local variable = task("missing variable usage", "variable")
    variable.minCost = 1
    variable.step = function() end
    assert(queue.run(0, 8) == 8 and variable.failed)
    assert(variable.error == "consumption must be whole slots within the grant")
end

for _, continuation in ipairs({ 1, "yes" }) do
    local queue, _, task = fixture()
    local fixed = task("invalid continuation", 2)
    fixed.step = function(_, _, slots)
        return slots, continuation
    end
    assert(queue.run(0, 8) == 2 and fixed.failed)
    assert(fixed.error == "continuation must be boolean")
end

do
    local queue, _, task = fixture()
    local fixed = task("invalid continuation refund", 2)
    fixed.step = function()
        return 0, "bad"
    end
    assert(queue.run(0, 8) == 2 and fixed.failed)
    assert(queue.state(fixed).spent == 2, "an invalid continuation must not refund its grant")
end

-- Tasks stay enrolled in order of due tick; a run stops at the first task not due.
do
    local queue, calls, task = fixture()
    local late, early, never = task("late"), task("early"), task("never")
    late.due, early.due, never.due = 20, 10, module.NEVER
    queue.clear()
    queue.add(late)
    queue.add(never)
    queue.add(early)
    local function step(self, now)
        calls[#calls + 1] = self.name
        self.due = now + 30
        return 1, false
    end
    late.step, early.step, never.step = step, step, step
    assert(queue.run(5, 8) == 0 and #calls == 0)
    assert(queue.run(10, 8) == 1 and queue.run(20, 8) == 1 and queue.run(25, 8) == 0)
    assert(table.concat(calls, ",") == "early,late", "tasks not due are never examined")
    assert(queue.run(40, 8) == 1 and calls[3] == "early" and queue.count == 3)

    -- A source that makes a task due earlier moves it forward; later is left to the step.
    never.due = 50
    queue.reschedule(never)
    late.due = 60
    queue.reschedule(late)
    assert(queue.run(50, 8) == 1 and calls[4] == "never")
    queue.remove(early)
    assert(queue.run(1000, 8) == 2 and calls[5] == "late" and calls[6] == "never" and queue.count == 2)
end

-- A hold keeps due tasks waiting without retiring them.
do
    local queue, calls, task = fixture()
    local hold = { on = true }
    task("held").hold = hold
    assert(queue.run(0, 8) == 0 and #calls == 0)
    hold.on = false
    assert(queue.run(1, 8) == 1 and calls[1] == "held")
end

-- A step that makes another task due moves it into this run.
do
    local queue, calls, task = fixture()
    local waiting = task("waiting")
    waiting.due = 100
    queue.reschedule(waiting)
    local source = task("source")
    source.step = function(self, now)
        calls[#calls + 1] = self.name
        waiting.due = now
        queue.reschedule(waiting)
        self.due = now + 10
        return 1, false
    end
    assert(queue.run(0, 8) == 2 and table.concat(calls, ",") == "source,waiting")
end

do
    local queue, calls, task = fixture()
    task("A", 4)
    task("heavy", 8)
    local used, requested, denied = queue.run(0, 8)
    assert(
        table.concat(calls, ",") == "A" and used == 4 and requested == 2 and denied == 1,
        "a task that does not fit waits"
    )
    local stats = queue.stats()
    assert(stats.callbacks == 1 and stats.used == 4 and stats.available == 8 and stats.denied == 1)
end
