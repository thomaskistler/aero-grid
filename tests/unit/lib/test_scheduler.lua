-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local module = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
assert(module.SLOTS == 8 and module.INSTRUCTIONS_PER_SLOT == 2000)

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
    assert(a.spent == 6 and not a.pending)
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
    assert(used == 3 and requested == 3 and denied == 1 and a.pending)
    assert(queue.cursor == 1)
    a.due, b.due = 100, 100
    queue.clear()
    queue.add(a)
    queue.add(b)
    assert(queue.run(1, 4) == 4)
    assert(table.concat(calls, ",") == "A,B,A,A" and not a.pending)
end

do
    local queue, calls, task = fixture()
    local a = task("A", 1, 3)
    task("large", 8)
    task("small", 1)
    task("free", 0, 2)
    local used, requested, denied = queue.run(0, 8)
    assert(table.concat(calls, ",") == "A,free,free")
    assert(used == 1 and requested == 4 and denied == 3)
    assert(queue.cursor == 2 and a.pending)
    queue.run(1, 8)
    assert(calls[4] == "large", "a deferred whole-budget task gets the first turn")
    queue.run(2, 8)
    assert(calls[6] == "small", "repeating whole-budget work must not starve later tasks")
end

do
    local queue, calls, task = fixture()
    local free = task("free", 0, 3)
    task("paid", 8)
    local used, requested, denied = queue.run(0, 8)
    assert(table.concat(calls, ",") == "free,paid,free,free")
    assert(used == 8 and requested == 1 and denied == 0)
    assert(free.spent == 0 and not free.pending)
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
    assert(variable.spent == 0 and not variable.pending)
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
    assert(used == 4 and requested == 2 and denied == 0 and reserved.spent == 1)
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
    assert(table.concat(calls, ",") == "reserved,other" and reserved.spent == 0)
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
    assert(queue.run(0, 2) == 0 and turns == 2 and reserved.pending)
    assert(queue.run(1, 2) == 0 and turns == 4 and reserved.pending)
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
    assert(table.concat(calls, ",") == "A,A" and a.spent == 5)
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
    assert(variable.spent == 4)
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
    assert(broken.failed and broken.error == "deliberate failure" and broken.spent == 2)
    assert(table.concat(calls, ",") == "healthy")
    queue.run(1, 8)
    assert(#failures == 1 and #calls == 2)
end

for _, invalid in ipairs({ false, -1, 1.5, 9, math.huge, 0 / 0, "1" }) do
    local queue, _, task = fixture()
    local variable = task("invalid", "variable")
    variable.minCost = 1
    variable.step = function()
        return invalid, true
    end
    assert(queue.run(0, 8) == 8)
    assert(variable.failed and not variable.pending and variable.spent == 8)
    assert(variable.error == "step consumption must be whole slots within the grant")
end

for _, invalid in ipairs({ false, -1, 1.5, 3, math.huge, 0 / 0, "1" }) do
    local queue, _, task = fixture()
    local fixed = task("invalid", 2)
    fixed.step = function()
        return invalid, true
    end
    assert(queue.run(0, 8) == 2)
    assert(fixed.failed and not fixed.pending and fixed.spent == 2)
    assert(fixed.error == "step consumption must be whole slots within the grant")
end

do
    local queue, _, task = fixture()
    local variable = task("missing", "variable")
    variable.minCost = 1
    variable.step = function() end
    assert(queue.run(0, 8) == 8 and variable.failed)
end

do
    local queue, _, task = fixture()
    local variable = task("missing minimum", "variable")
    assert(queue.run(0, 8) == 0 and variable.failed)
    assert(variable.error == "invalid minimum slot cost")
end

for _, invalid in ipairs({ false, -1, 1.5, 9, math.huge, 0 / 0, "1" }) do
    local queue, calls, task = fixture()
    local instance = task("invalid", invalid)
    local used, requested, denied = queue.run(0, 8)
    assert(used == 0 and requested == 0 and denied == 0 and #calls == 0)
    assert(instance.failed and instance.error == "invalid slot cost")
end

do
    local queue, calls, task = fixture()
    local future = task("future")
    future.due = 10
    local hidden = task("hidden")
    hidden.ready = function(_, _, context)
        return context.hidden
    end
    assert(queue.run(0, 8, { hidden = false }) == 0)
    assert(queue.run(1, 8, { hidden = true }) == 1)
    assert(queue.run(10, 8, { hidden = false }) == 1)
    assert(table.concat(calls, ",") == "hidden,future")
end

do
    local queue, calls, task = fixture()
    local a = task("A", 1, 2)
    a.ready = function(self)
        return self.turns == 0
    end
    assert(queue.run(0, 8) == 1 and a.pending)
    assert(#calls == 1, "a pending task must still obey its readiness gate")
    a.ready = nil
    assert(queue.run(1, 8) == 1 and not a.pending)
end

do
    local queue = module.new({ capacity = 12 })
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
    assert(queue.run(0, 12) == 8 and granted == 8, "one variable turn must never exceed eight slots")
    queue.clear()
    assert(queue.count == 0 and next(queue.tasks) == nil)
    local used, requested, denied = queue.run(1, 12)
    assert(used == 0 and requested == 0 and denied == 0)
    queue.cursor = 20
    queue.add({
        name = "replacement",
        step = function(_, _, slots)
            return slots, false
        end,
    })
    assert(queue.run(2, 12) == 1 and queue.cursor == 1)
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

for _, minimum in ipairs({ false, 0, 1.5, 9, math.huge, 0 / 0, "1" }) do
    local queue, _, task = fixture()
    local variable = task("invalid minimum", "variable")
    variable.minCost = minimum
    assert(queue.run(0, 8) == 0)
    assert(variable.failed and variable.error == "invalid minimum slot cost")
end

do
    local queue, _, task = fixture()
    local fixed = task("missing usage", 2)
    fixed.step = function()
        return nil, false
    end
    assert(queue.run(0, 8) == 2 and fixed.failed)
    assert(fixed.error == "step consumption must be whole slots within the grant")
end

do
    local queue, _, task = fixture()
    local fixed = task("missing continuation", 2)
    fixed.step = function(_, _, slots)
        return slots
    end
    assert(queue.run(0, 8) == 2 and fixed.failed)
    assert(fixed.error == "step continuation must be boolean")
end

for _, continuation in ipairs({ 1, "yes" }) do
    local queue, _, task = fixture()
    local fixed = task("invalid continuation", 2)
    fixed.step = function(_, _, slots)
        return slots, continuation
    end
    assert(queue.run(0, 8) == 2 and fixed.failed)
    assert(fixed.error == "step continuation must be boolean")
end

do
    local queue, _, task = fixture()
    local fixed = task("too large", 9)
    assert(queue.run(0, 8) == 0 and fixed.failed)
    assert(fixed.error == "invalid slot cost")
end

do
    -- A callback continues with new slots: only tasks that asked for another
    -- step or did not fit run again, and a task that already ran is not rerun.
    local queue, calls, task = fixture()
    task("A", 4, 3)
    task("B", 4)
    task("C", 4)
    task("D", 1)
    local used, requested, denied = queue.run(0, 8)
    assert(table.concat(calls, ",") == "A,B" and used == 8 and requested == 5 and denied == 3)
    assert(queue.more(0), "pending and deferred tasks remain")
    local before = queue.callbacks
    used, requested, denied = queue.resume(0, 8)
    assert(queue.callbacks == before, "a continuation stays in the same callback")
    assert(table.concat(calls, ",") == "A,B,C,D" and used == 5 and requested == 3 and denied == 1)
    assert(queue.more(0))
    used = queue.resume(0, 8)
    assert(table.concat(calls, ",") == "A,B,C,D,A,A" and used == 8)
    assert(not queue.more(0), "nothing is left to continue")
    assert(queue.resume(0, 8) == 0, "an idle continuation runs nothing")
    assert(#calls == 6)
end

do
    local queue, calls, task = fixture()
    task("A", 1)
    task("B", 1)
    queue.run(0, 8)
    assert(not queue.more(0) and queue.resume(0, 8) == 0 and #calls == 2, "ran tasks do not repeat")
    local free = task("free", 0, 100)
    queue.clear()
    queue.add(free)
    queue.run(1, 8)
    assert(free.pending and free.refused == queue.callbacks)
    assert(not queue.more(1), "a task stopped after repeated free turns waits for the next callback")
end

do
    local queue = module.new()
    queue.add({
        name = "heavy",
        cost = 8,
        step = function()
            return 8, false
        end,
    })
    queue.run(0, 4)
    assert(queue.more(0), "a deferred task continues")
    assert(queue.resume(0, 8) == 8)
    assert(not queue.more(0))
end

do
    -- EdgeTX raises "CPU limit" from its count hook after 100 hooks of 200
    -- instructions, and an xpcall message handler runs with hooks disabled.
    local function limit()
        local hooks = 0
        debug.sethook(function()
            hooks = hooks + 1
            if hooks > 100 then
                error("CPU limit")
            end
        end, "", 200)
    end
    local function heavy()
        local total = 0
        for index = 1, 60000 do
            total = total + index % 7
        end
        return total
    end
    limit()
    local ok, result = module.cross(function()
        return heavy()
    end)
    debug.sethook()
    assert(ok and result ~= nil, "the work ran past the limit")

    local finished
    limit()
    ok = module.cross(function()
        finished = heavy()
    end)
    debug.sethook()
    assert(ok and finished ~= nil, "work after the limit completes without being cut off")

    -- Without a limit the burn finishes and the work runs directly.
    local ran = false
    assert(module.cross(function()
        ran = true
    end))
    assert(ran)

    -- A failing job reports its error and the callback survives.
    limit()
    ok, result = module.cross(function()
        error("job failed", 0)
    end)
    debug.sethook()
    assert(not ok and result == "job failed")

    local queue = module.new()
    assert(queue.cross == module.cross)
end
