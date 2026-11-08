-- SPDX-License-Identifier: GPL-2.0-only

return function(scheduler, run)
    local runDecl = { class = "normal", stages = { run = { fixed = 0, perUnit = 1, maxUnits = 1 } } }
    local skipDecl = {
        class = "normal",
        stages = { run = { fixed = 0, perUnit = 1, maxUnits = 1, quantum = 500 } },
        shared = { first = 6000, second = 6000 },
    }
    local function instance()
        return { step = function() return 1 end }
    end
    for examined = 1, 40 do
        for ran = 0, examined do
            local s = scheduler.new({ steady = 0 })
            for index = 1, scheduler.MAX_TASKS do
                local decl = index <= ran and runDecl or index <= examined and skipDecl or runDecl
                local ok, reason = s:add({
                    id = index, decl = decl, instance = instance(), due = index <= examined and 0 or 1000 + index,
                })
                assert(ok, reason)
            end
            local available = scheduler.CEILING - scheduler.MARGIN - scheduler.FIXED_COST
            local needed = examined * scheduler.EXAMINE_COST + ran * (scheduler.RUN_COST + 1)
                + (ran < examined and scheduler.RUN_COST + 1 or 0)
            local used = math.min(3000, available - needed - 1)
            assert(used >= 0)
            run(s, used, examined, ran)
            assert(s.lastPlan.examined == examined and s.lastPlan.ran == ran,
                "framework path fixture did not exercise " .. examined .. ":" .. ran
                    .. " (got " .. s.lastPlan.examined .. ":" .. s.lastPlan.ran .. ")")
        end
    end
end
