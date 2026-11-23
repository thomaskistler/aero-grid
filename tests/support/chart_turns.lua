-- SPDX-License-Identifier: GPL-2.0-only

-- The scheduler never offers a task less than the minimum it declares: a denied
-- task keeps its turn and gets at least that minimum in the next callback, so a
-- smaller test grant to chart.refresh is raised to it.
local turns = {}

function turns.install(chart)
    local refresh = chart.refresh
    chart.refreshOnly = refresh

    --- Slots a chart's next task is really offered for a nominal `grant`.
    function chart.offered(panel, grant)
        local pending, minimum = chart.finishPending(panel)
        if not pending then
            minimum = panel.refreshMinCost or chart.refreshMinCost
        end
        return math.min(32, math.max(grant or 32, minimum or 1))
    end

    chart.refresh = function(panel, creating, slots)
        if creating then
            return refresh(panel, creating, slots)
        end
        return refresh(panel, creating, chart.offered(panel, slots))
    end
end

return turns
