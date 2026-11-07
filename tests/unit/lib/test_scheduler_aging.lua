-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local AGE = scheduler.AGE_TICKS
local CHARGE = scheduler.EXAMINE_COST + scheduler.RUN_COST

local function add(s, id, class, cost, due, log, extra)
    local decl = { class = class, stages = { run = { fixed = 0, perUnit = cost, maxUnits = 1 } } }
    for key, value in pairs(extra or {}) do
        decl[key] = value
    end
    local instance = {
        step = function(_, grant)
            log[#log + 1] = id
            equal(grant, 1)
            return 1
        end,
    }
    local ok, message = s:add({ id = id, decl = decl, instance = instance, due = due })
    assert(ok, message)
    return s.byId[id]
end

-- Sustained critical demand leaves too little room for a normal stage until
-- its release ages. Both queues then make progress, with no permanent promotion.
do
    local s, log = scheduler.new({ steady = 1000 }), {}
    local room = scheduler.CEILING - scheduler.MARGIN - scheduler.FIXED_COST - 1000
    local critical = room - scheduler.NORMAL_RESERVE - CHARGE - scheduler.EXAMINE_COST
    add(s, "critical", "critical", critical, 0, log)
    local record = add(s, "normal", "normal", 3070, 0, log)
    for now = 0, AGE do
        s:run("steady", now)
        equal(log[#log], "critical")
        equal(s:dueOf("normal"), 0)
    end
    local calls = {}
    s.byId.normal.instance.step = function(_, grant)
        calls[#calls + 1] = "normal"
        equal(grant, 1)
        return 1
    end
    s.byId.critical.instance.step = function()
        calls[#calls + 1] = "critical"
        return 1
    end
    s:run("steady", AGE + 1)
    equal(calls[1], "normal", "the aged release gets room before critical demand")
    equal(s:dueOf("normal"), AGE + 2)
    equal(record.list, s.lists[2], "promotion never changes the declared class")
    s:run("steady", AGE + 2)
    equal(calls[2], "critical", "the older critical release wins next callback")
    equal(s:dueOf("normal"), AGE + 2, "a fresh normal release is not promoted")
    assert(s.lastPlan.U <= scheduler.CEILING - scheduler.MARGIN)
end

-- One promoted release per callback; a normal backlog cannot outrank an older
-- critical release. Equal effective deadlines retain critical-first ordering.
do
    local s, log = scheduler.new({ steady = 0 }), {}
    add(s, "critical", "critical", 100, AGE, log)
    add(s, "first", "normal", 100, 0, log)
    add(s, "second", "normal", 100, 0, log)
    s:run("steady", AGE + 1)
    equal(table.concat(log, ","), "critical,first,second")
    log = {}
    s = scheduler.new({ steady = 0 })
    add(s, "critical", "critical", 100, AGE + 1, log)
    add(s, "first", "normal", 100, 0, log)
    add(s, "second", "normal", 100, 0, log)
    s:run("steady", AGE + 1)
    equal(table.concat(log, ","), "first,critical,second")
end

do
    local s, log = scheduler.new({ steady = 0 }), {}
    add(s, "aged", "normal", 100, 0, log, { shared = { common = 300 } })
    add(s, "critical", "critical", 100, AGE + 1, log, { shared = { common = 300 } })
    s:run("steady", AGE + 1)
    equal(table.concat(log, ","), "aged,critical")
    equal(s.lastPlan.U, s.lastPlan.charged + 500, "promotion shares costs with the ordinary passes")
end

-- Aging uses wrapped ticks, honors callback kinds, charges shared work once,
-- and preserves exclusive-task admission.
for _, base in ipairs({ 0, 0x7ffffff0, -16 }) do
    local s, log = scheduler.new({ steady = 0, background = 0 }), {}
    add(s, "ineligible", "normal", 100, base - 1, log, { kinds = { background = true } })
    add(s, "critical-hidden", "critical", 100, base, log, { kinds = { background = true } })
    add(s, "critical", "critical", 100, base + AGE + 1, log, { exclusive = true, shared = { common = 300 } })
    add(s, "aged", "normal", 3070, base, log, { exclusive = true, shared = { common = 300 } })
    s:run("steady", base + AGE + 1)
    equal(table.concat(log, ","), "aged")
    equal(s:dueOf("critical"), scheduler.elapsed(base + AGE + 1, 0))
    assert(s.lastPlan.U <= scheduler.CEILING - scheduler.MARGIN)
    s:run("steady", base + AGE + 2)
    equal(log[2], "critical")
end

-- Promotion never bypasses room checks, and invalid aged stages still retire.
do
    local s, log = scheduler.new({ steady = 0 }), {}
    local record = add(s, "aged", "normal", 3070, 0, log)
    s:run("steady", AGE, scheduler.CEILING)
    equal(#log, 0)
    equal(s:dueOf("aged"), 0)
    equal(s:takeErrors(), nil)
    record.instance.stage = "missing"
    s:run("steady", AGE + 1)
    equal(#log, 0)
    equal(s:takeErrors()[1].id, "aged")
    equal(s.count, 0)
end

print("Scheduler priority aging passed")
