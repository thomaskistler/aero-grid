-- SPDX-License-Identifier: GPL-2.0-only

local probe = assert(loadScript("/WIDGETS/AeroGrid/chart-feasibility-probe.lua"))()
local recorded = false
local batchSize = 130
local sampleTicks = 20
local function load(path, ...)
    return assert(loadScript("/WIDGETS/AeroGrid/" .. path))(...)
end
local state = { operation = 0, prepared = false }
local operations = recorded and { "append", "horizontal", "vertical", "scroll", "resize" }
    or { "append", "resize", "horizontal", "vertical", "scroll" }

local function write(context, message)
    print("FEASIBILITY " .. message)
    local file = assert(io.open("/chart-feasibility.txt", "a"))
    io.write(file, message .. "\n")
    io.close(file)
end

local function ready()
    local file = assert(io.open("/capture-ready.txt", "w"))
    io.write(file, "feasibility workload finished; inspect results for failures")
    io.close(file)
    state.done = true
end

return function(context, refresh)
    if state.measurePrevious then
        local usage = getUsage()
        state.worstUsage = math.max(state.worstUsage or 0, usage)
        state.samples[#state.samples + 1] = {
            usage = usage,
            mapped = state.probe.mapped - state.previousMapped,
            work = state.probe.lastWork or 0,
        }
        state.measurePrevious = false
    end
    if state.done then
        return
    end
    if context.stage or #context.panels == 0 then
        refresh(context)
        return
    end
    if not state.probe then
        local entry = context.panels[1]
        if recorded then
            state.probe = load("tests/support/chart_mipmap_prototype.lua", load).new(entry.instance, 512)
        else
            state.probe = probe.new(entry.instance, { points = 512, chunkSize = 64, overlays = 12 })
        end
        state.entry = entry
        if recorded then
            state.probe.batch = batchSize
            state.probe.sampleTicks = sampleTicks
        end
        return
    end
    local item = state.probe
    if state.scrollPreparing then
        if item:prepareScroll() then
            state.scrollPreparing = false
            state.scrollPrepared = true
        end
        return
    end
    if not state.prepared then
        local batch = recorded and item.prepareIndex > item.width * #item.maps and 1 or 16
        for _ = 1, batch do
            state.prepared = item:prepare()
            if state.prepared then
                break
            end
            if recorded and item.prepareIndex > item.width * #item.maps then
                break
            end
        end
        if state.prepared then
            lvgl.hide(state.entry.instance.plotRoot)
            if state.entry.instance.backPlot then
                lvgl.hide(state.entry.instance.backPlot.plotRoot)
            end
            state.entry.module.refresh = function()
                return item:step()
            end
            context.refreshOwner = nil
        end
        return
    end
    if not item.active then
        if item.finishedAt then
            for turn, sample in ipairs(state.samples) do
                write(
                    context,
                    string.format(
                        "TURN op=%s turn=%d usage_percent=%d mapped=%d work=%d",
                        item.operation,
                        turn,
                        sample.usage,
                        sample.mapped,
                        sample.work
                    )
                )
            end
            write(
                context,
                string.format(
                    "op=%s points=%d series=%d turns=%d setter_complete_ms=%d mapped=%d native_sets=%d usage_percent=%d sample_updates=%d shifted=%d",
                    item.operation,
                    item.points or item.width,
                    item.seriesCount or #item.maps,
                    item.turns,
                    (item.finishedAt - item.startedAt) * 10,
                    item.mapped or 0,
                    item.submitted or 0,
                    state.worstUsage,
                    item.sampleUpdates or 0,
                    item.shifted or 0
                )
            )
            item.finishedAt = nil
            return
        end
        state.operation = state.operation + 1
        if not operations[state.operation] then
            ready()
            return
        end
        if recorded and operations[state.operation] == "scroll" and not state.scrollPrepared then
            state.operation = state.operation - 1
            state.scrollPreparing = true
            return
        end
        item:begin(operations[state.operation])
        state.worstUsage = 0
        state.samples, state.previousMapped = {}, item.mapped or 0
        state.entry.nextRefresh = getTime()
    end
    state.previousMapped = item.mapped or 0
    refresh(context)
    state.measurePrevious = true
    if #context.errors > 0 then
        write(context, "FAIL " .. table.concat(context.errors, "; "))
        ready()
    end
end
