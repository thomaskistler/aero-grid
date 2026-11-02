-- SPDX-License-Identifier: GPL-2.0-only

local function load(path, ...)
    return assert(loadScript("/WIDGETS/AeroGrid/" .. path))(...)
end
local Stress = load("tests/support/chart_mipmap_stress.lua", load)
local batchSize = 64
local state = { phase = "prepare" }
local function write(path, text, mode)
    local file = assert(io.open(path, mode or "w"))
    io.write(file, text)
    io.close(file)
end

return function(context, refresh)
    if state.measurePrevious then
        state.samples[#state.samples + 1] = {
            usage = getUsage(),
            chart = state.chart,
            mapped = state.mapped,
            inputs = state.inputs,
            service = state.workload.lastService,
            smart = state.workload.smartPolled and 1 or 0,
        }
        state.measurePrevious = false
    end
    if state.phase == "done" then
        return
    end
    if context.stage or #context.panels == 0 then
        refresh(context)
        return
    end
    state.workload = state.workload or Stress.new(context, 800, batchSize)
    local workload = state.workload
    if state.phase == "prepare" then
        if workload:prepare(refresh) then
            state.phase = "begin"
        end
    elseif state.phase == "scroll-prepare" then
        if workload:prepareScroll(refresh) then
            state.phase = "begin"
        end
    elseif state.phase == "begin" then
        local operation = Stress.operations[workload.operationIndex + 1]
        if not operation then
            write("/capture-ready.txt", "stress completed; inspect instruction, deadline and paint reports")
            state.phase = "done"
            return
        end
        if operation == "scroll" and not state.scrollPrepared then
            workload.scrollIndex, state.scrollPrepared, state.phase = 1, true, "scroll-prepare"
            return
        end
        if not workload:prepareOperation(refresh) then
            return
        end
        workload:begin(operation)
        write("/paint-phase.txt", string.format("%d %d 0\n", workload.operationIndex, workload.startedAt * 10))
        state.samples, state.phase = {}, "running"
    elseif state.phase == "running" then
        local turns, mapped, inputs = {}, {}, #workload.events
        for index, item in ipairs(workload.items) do
            turns[index], mapped[index] = item.turns, item.mapped
        end
        local complete = workload:step(refresh)
        state.chart, state.mapped = 0, 0
        for index, item in ipairs(workload.items) do
            if item.turns > turns[index] then
                state.chart, state.mapped = index, item.mapped - mapped[index]
            end
        end
        state.inputs, state.measurePrevious = #workload.events - inputs, true
        if #context.errors > 0 then
            write("/chart-feasibility.txt", "FAIL " .. table.concat(context.errors, "; ") .. "\n", "a")
            write("/capture-ready.txt", "stress failed; inspect errors")
            state.phase = "done"
        elseif complete then
            write(
                "/paint-phase.txt",
                string.format("%d %d %d\n", workload.operationIndex, workload.startedAt * 10, workload.finishedAt * 10)
            )
            state.phase = "report"
        end
    elseif state.phase == "report" then
        workload:verify(false)
        local row, usage = workload.rows[#workload.rows], 0
        for turn, sample in ipairs(state.samples) do
            usage = math.max(usage, sample.usage)
            write(
                "/chart-feasibility.txt",
                string.format(
                    "TURN op=%s turn=%d usage_percent=%d chart=%d mapped=%d inputs=%d service=%s smart=%d\n",
                    row.operation,
                    turn,
                    sample.usage,
                    sample.chart,
                    sample.mapped,
                    sample.inputs,
                    sample.service,
                    sample.smart
                ),
                "a"
            )
        end
        write(
            "/chart-feasibility.txt",
            string.format(
                "op=%s points=800 series=3 charts=2 turns=%d host_callbacks=%d setter_complete_ms=%d usage_percent=%d input_events=%d catchups=%d group_moves=%d oldest_source_ms=%d\n",
                row.operation,
                row.turns,
                row.callbacks,
                row.setter_complete_ms,
                usage,
                row.input_events,
                row.catchups,
                row.group_moves,
                row.oldest_source_ms
            ),
            "a"
        )
        state.phase = "paint-export"
    elseif state.phase == "paint-export" then
        if workload:exportPaint() then
            write("/paint-phase.txt", "0 0 0\n")
            state.phase = "begin"
        end
    end
end
