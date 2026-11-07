-- SPDX-License-Identifier: GPL-2.0-only

-- A case file supplies only stimulus for one task id (plans/scheduler-framework.md,
-- section 6). This one measures a stub step that spends about two instructions per
-- unit, so it works offline and in the native harness alike.
local decl = { class = "normal", stages = { run = { fixed = 0, perUnit = 100, maxUnits = 8 } } }

local function setup(seed)
    local instance = {
        step = function(_, grant)
            local total = 0
            for index = 1, grant * 10 + seed do
                total = total + index
            end
            return 5
        end,
    }
    return instance, seed * 100
end

return {
    id = "stub",
    decl = decl,
    cases = {
        { stage = "run", grant = 1, setup = setup },
        { stage = "run", grant = 8, setup = setup },
    },
}
