-- SPDX-License-Identifier: GPL-2.0-only

local function load(path, ...)
    return assert(loadScript("/WIDGETS/AeroGrid/" .. path))(...)
end
local Mipmap = load("lib/chart_mipmap.lua")
local Renderer = load("lib/chart_mipmap_renderer.lua")
local Stress = load("tests/support/chart_mipmap_stress.lua", load)
local state = { phase = "loading", callbacks = 0, worst = 0, samples = {} }
local function write(path, text)
    local file = assert(io.open(path, "w"))
    io.write(file, text)
    io.close(file)
end

return function(context, refresh)
    context.chartMipmap, context.chartMipmapRenderer = Mipmap, Renderer
    if state.previous then
        local usage = getUsage()
        state.worst = math.max(state.worst, usage)
        state.samples[#state.samples + 1] = usage
        state.previous = false
    end
    if state.phase == "done" then
        return
    end
    if #context.errors > 0 then
        write("/chart-feasibility.txt", "FAIL " .. table.concat(context.errors, "; ") .. "\n")
        write("/capture-ready.txt", "integrated chart failed")
        state.phase = "done"
        return
    end
    if state.phase == "loading" then
        refresh(context)
        if not context.stage and #context.panels == 2 then
            state.workload = Stress.new(context, 800, 130, true)
            state.phase, state.source = "subscriptions", 7
        end
    elseif state.phase == "subscriptions" then
        for _ = 1, 3 do
            state.workload.history:subscribe("Q" .. state.source, { armSwitch = "SAv", precision = 3 })
            state.source = state.source + 1
            if state.source > 24 then
                state.phase, state.warming = "warming", 0
                break
            end
        end
        refresh(context)
    elseif state.phase == "warming" then
        refresh(context)
        local ready = true
        for _, entry in ipairs(context.panels) do
            local chart = entry.instance
            ready = ready and chart.mipmapPrepared and chart.mipmapConsumers[1].complete
        end
        state.warming = state.warming + 1
        if ready and state.warming >= 160 then
            for _, entry in ipairs(context.panels) do
                for _, owner in ipairs(entry.instance.mipmapConsumers) do
                    local sample = owner.sample
                    owner.sample = function(target, at, value, broken)
                        if at - target.startedAt >= 6000 and not state.expansionStartedAt then
                            state.expansionStartedAt = getTime()
                        end
                        return sample(target, at, value, broken)
                    end
                end
            end
            state.workload.armed = true
            state.phase, state.startedAt = "running", getTime()
            write("/paint-phase.txt", string.format("1 %d 0\n", state.startedAt * 10))
        end
    elseif state.phase == "running" then
        refresh(context)
        if state.expansionStartedAt and not state.expansionReadyAt then
            local ready = true
            for _, entry in ipairs(context.panels) do
                local chart = entry.instance
                local renderer = chart.mipmapRenderer
                ready = ready and renderer and chart.gridVersion == chart.version
                for series in ipairs(chart.mipmapConsumers) do
                    local job = renderer and renderer.published[series]
                    ready = ready and job and job.level >= 1 and job.geometry == chart.geometryVersion
                end
            end
            if ready then
                state.expansionReadyAt = getTime()
            end
        end
        state.callbacks = state.callbacks + 1
        if state.callbacks == 200 then
            local chart = context.panels[1].instance
            if chart.mipmapConsumers[1].map.at == nil then
                write(
                    "/chart-feasibility.txt",
                    string.format(
                        "FAIL integrated smoke received no readings: elapsed=%d count=%d recording=%s same_history=%s\n",
                        chart.session.elapsed,
                        chart.series[1].feed.count,
                        tostring(chart.session.recording),
                        tostring(state.workload.history == context.serviceRuntime.byId.history)
                    )
                )
                write("/capture-ready.txt", "integrated input coverage failed")
                state.phase = "done"
                return
            end
        end
        if state.callbacks >= 1500 then
            state.phase = "report"
        end
    elseif state.phase == "report" then
        local rendered, columns, objects, states = 0, {}, 0, {}
        for _, entry in ipairs(context.panels) do
            local chart = entry.instance
            local renderer = chart.mipmapRenderer
            assert(renderer and chart.backPlot == nil, "normal single-pool renderer was bypassed")
            for _ in pairs(renderer.published) do
                rendered = rendered + 1
            end
            columns[#columns + 1] = tostring(renderer.width)
            objects = objects + #renderer.objects
            local owner, job, pending =
                chart.mipmapConsumers[1], renderer.published[1], renderer.jobs and renderer.jobs[1]
            states[#states + 1] = string.format(
                "CHART level=%d origin=%d geometry=%d drawn_geometry=%d grid=%d version=%d pending=%d revision=%d drawn_revision=%d started_at=%d\n",
                job and job.level or -1,
                job and job.origin or -1,
                chart.geometryVersion,
                job and job.geometry or -1,
                chart.gridVersion or -1,
                chart.version,
                pending and pending.index or -1,
                owner.map.revision,
                job and job.revision or -1,
                owner.startedAt
            )
        end
        local samples = {}
        for index, usage in ipairs(state.samples) do
            samples[index] = tostring(usage)
        end
        write(
            "/chart-feasibility.txt",
            string.format(
                "INTEGRATED callbacks=%d usage_percent=%d runtime_ms=%d rendered_series=%d native_spans=%d sources=%d columns=%s expansion_initial_submission_ms=%d elapsed=%d samples_through=%d\n",
                #state.samples,
                state.worst,
                (getTime() - state.startedAt) * 10,
                rendered,
                objects,
                state.workload.history.count,
                table.concat(columns, ","),
                state.expansionReadyAt and (state.expansionReadyAt - state.expansionStartedAt) * 10 or 0,
                context.panels[1].instance.session.elapsed,
                context.panels[1].instance.mipmapConsumers[1].map.at or 0
            )
                .. "CALLBACK_USAGE "
                .. table.concat(samples, ",")
                .. "\n"
                .. table.concat(states)
        )
        write("/capture-ready.txt", "normal chart callback smoke completed; no independent native paint target")
        state.phase = "done"
    end
    state.previous = state.phase ~= "done"
end
