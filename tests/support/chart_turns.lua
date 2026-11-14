-- SPDX-License-Identifier: GPL-2.0-only

-- Makes chart.refresh behave like the host's pair of chart tasks for unit
-- tests that call it directly: while finishing is pending the finishing task
-- runs, otherwise the refresh runs. The scheduler never offers a task less than
-- the minimum it declares: a denied task keeps its turn and gets at least that
-- minimum in the next callback, so a smaller test grant is raised to it.
local turns = {}

function turns.install(chart)
    local refresh = chart.refresh
    chart.refreshOnly = refresh

    --- Slots a chart's next task is really offered for a nominal `grant`.
    function chart.offered(panel, grant)
        local minimum = chart.finishPending(panel) and panel.finishMinCost or panel.refreshMinCost
        return math.min(8, math.max(grant or 8, minimum or 1))
    end

    chart.refresh = function(panel, creating, slots)
        if creating then
            return refresh(panel, creating, slots)
        end
        local offered = chart.offered(panel, slots)
        if chart.finishPending(panel) then
            local interval, unfinished, used = chart.finish(panel, false, offered)
            return interval or 1, unfinished, used
        end
        return refresh(panel, creating, offered)
    end
end

return turns
