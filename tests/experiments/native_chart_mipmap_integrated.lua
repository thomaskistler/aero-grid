-- SPDX-License-Identifier: GPL-2.0-only

local function load(path, ...)
    return assert(loadScript("/WIDGETS/AeroGrid/" .. path))(...)
end
local Stress = load("tests/support/chart_mipmap_stress.lua", load)
local Assertions = load("tests/support/chart_assertions.lua")
local lifecycle = false
local longFlight = false
local rolling = false
local lateAttach = false
local firmwareTime = getTime
local longSpan = 6000 * (4 / 3) ^ 10
local state = { phase = "loading", callbacks = 0, worst = 0, samples = {} }
local function write(path, text)
    local file = assert(io.open(path, "w"))
    io.write(file, text)
    io.close(file)
end

local function tick(context, refresh)
    assert(context.chartMipmap and context.chartMipmapRenderer, "default runtime did not load mipmap modules")
    if state.previous then
        local usage = getUsage()
        state.worst = math.max(state.worst, usage)
        state.samples[#state.samples + 1] = usage
        state.previous = false
    end
    if state.phase == "done" then
        return
    end
    if longFlight then
        local real = firmwareTime()
        if state.nextCallback and real < state.nextCallback then
            return
        end
        state.nextCallback = real + 5
        state.logical = (state.logical or real) + 50
        context.matchedNow = state.logical
        getTime = function()
            return state.logical
        end
        if context.serviceRuntime then
            context.serviceRuntime.env.getTime = getTime
        end
        if context.flightBroker then
            context.flightBroker.env.getTime = getTime
        end
        for _, entry in ipairs(context.panels or {}) do
            entry.instance.clock = getTime
        end
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
            if longFlight then
                state.observations = {}
                for index in ipairs(context.panels) do
                    state.observations[index] = {}
                    for series = 1, 3 do
                        state.observations[index][series] = { levels = {}, scrolls = 0 }
                    end
                end
            end
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
        if lateAttach and state.callbacks == 900 then
            local old = context.panels[1]
            state.oldRenderer, state.oldMap = old.instance.mipmapRenderer, old.instance.mipmapConsumers[1].map
            state.oldCount = old.instance.series[1].feed.count
            old.module.destroy(old.instance)
            lvgl.hide(old.container)
            local replacement = assert(context.dashboardLoader.buildPanel(context, old.placement))
            context.panels[1], context.panels[#context.panels] = replacement, nil
            context.refreshOwner = nil
            state.attached = true
        elseif lifecycle and state.callbacks == 1100 then
            local first, sibling = context.panels[1].instance, context.panels[2].instance
            state.oldMap, state.siblingMap = first.mipmapConsumers[1].map, sibling.mipmapConsumers[1].map
            state.oldRenderer = first.mipmapRenderer
            local rect = first.rect
            context.panels[1].module.update(first, { x = rect.x, y = rect.y, w = rect.w - 30, h = rect.h })
            assert(first.mipmapConsumers[1].map ~= state.oldMap, "resize retained old map")
            assert(sibling.mipmapConsumers[1].map == state.siblingMap, "resize changed sibling map")
            state.resized = true
        elseif lifecycle and state.resized and not state.pausedAt and Assertions.finished(context.panels[1].instance) then
            local first = context.panels[1].instance
            assert(first.mipmapPrepared and next(first.mipmapRenderer.published), "resize did not republish")
            assert(first.backPlot == nil, "resize bypassed single pool")
            state.owner = first.mipmapConsumers[1]
            state.workload.armed = false
            state.pausedAt = state.callbacks
        elseif lifecycle and state.pausedAt and not state.resumed and state.callbacks >= state.pausedAt + 300 then
            assert(not context.panels[1].instance.session.recording, "pause was not observed")
            state.workload.armed = true
            state.resumed = true
        end
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
        if longFlight then
            for index, entry in ipairs(context.panels) do
                local renderer = entry.instance.mipmapRenderer
                for series = 1, 3 do
                    local job = renderer and renderer.published[series]
                    if job then
                        local observation = state.observations[index][series]
                        observation.levels[job.level] = true
                        if job.level == 10 and job.origin ~= observation.origin then
                            if observation.origin ~= nil then
                                assert(job.origin > observation.origin, "scroll origin went backwards")
                                observation.scrolls = observation.scrolls + 1
                            end
                            observation.origin = job.origin
                        end
                    end
                end
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
        if longFlight then
            local complete = context.panels[1].instance.session.elapsed >= longSpan * 2.5
            for _, observations in ipairs(state.observations) do
                for _, observation in ipairs(observations) do
                    complete = complete and observation.scrolls >= 6
                end
            end
            if complete then
                state.phase = "report"
            end
            assert(state.callbacks < 8000, "long flight did not publish six scrolls")
        elseif state.callbacks >= (lateAttach and 3000 or lifecycle and 3500 or 1500) then
            local ready = true
            if lateAttach or lifecycle then
                local first = context.panels[1].instance
                ready = Assertions.finished(first)
                if lifecycle then
                    ready = ready
                        and state.resumed
                        and first.session.resumeLast > 0
                        and state.owner.output
                        and #state.owner.output.connectors > 0
                end
                assert(state.callbacks < 6000, "rebuilt chart did not publish before the lifecycle deadline")
            end
            if ready then
                state.phase = "report"
            end
        end
    elseif state.phase == "report" then
        state.reportSamples = state.reportSamples or {}
        local first = #state.reportSamples + 1
        for index = first, math.min(first + 63, #state.samples) do
            state.reportSamples[index] = tostring(state.samples[index])
        end
        if #state.reportSamples < #state.samples then
            return
        end
        if longFlight then
            local checked = state.checkedLevels or 0
            if checked < 66 then
                local index = checked // 33 + 1
                local series = (checked % 33) // 11 + 1
                local level = checked % 11
                local map = context.panels[index].instance.mipmapConsumers[series].map
                local retained = map.levels[level]
                if level < map.level then
                    assert(retained == nil, "published fine level was not retired")
                else
                    assert(retained, "required coarse level was retired")
                    for slot in pairs(retained.tags) do
                        assert(slot >= 1 and slot <= map.width, "mipmap exceeded ring capacity")
                    end
                end
                state.checkedLevels = checked + 1
                return
            end
        end
        local longCoverage = ""
        if longFlight then
            for index, observations in ipairs(state.observations) do
                for series, observation in ipairs(observations) do
                    for level = 0, 10 do
                        assert(observation.levels[level], "long flight skipped a published level")
                    end
                    local chart = context.panels[index].instance
                    local map = chart.mipmapConsumers[series].map
                    assert(map.level == 10 and map:select(map.at) == 10, "long flight did not retire fine levels")
                    assert(chart.session.resumeLast == 0 and chart.session.recording, "flight was interrupted")
                end
            end
            longCoverage =
                "COVERAGE levels=11 scrolls_per_series=6 logical_step=50 admission_ms=50 uninterrupted=1 retired_levels_per_series=10\n"
        end
        if lifecycle then
            local first, sibling = context.panels[1].instance, context.panels[2].instance
            assert(state.resized and first.session.resumeLast > 0, "missing lifecycle transitions")
            assert(first.mipmapRenderer and sibling.mipmapRenderer, "resume lost the sole renderer")
            assert(state.owner.map ~= nil and first.series[1].feed.count > 0, "resume lost history")
            assert(state.owner.output and #state.owner.output.connectors > 0, "resume did not rebuild pause connectors")
            local samples = state.reportSamples
            write(
                "/chart-feasibility.txt",
                string.format(
                    "INTEGRATED callbacks=%d usage_percent=%d runtime_ms=%d resized=1 resumed=1 sole_renderer=1 sources=%d\n",
                    #state.samples,
                    state.worst,
                    (getTime() - state.startedAt) * 10,
                    state.workload.history.count
                )
                    .. "CALLBACK_USAGE "
                    .. table.concat(samples, ",")
                    .. "\n"
            )
            write("/capture-ready.txt", "native lifecycle callback gate complete")
            state.phase = "done"
            return
        end
        local inputCoverage = ""
        if rolling then
            for _, entry in ipairs(context.panels) do
                for _, owner in ipairs(entry.instance.mipmapConsumers) do
                    assert(
                        owner.map.lastLevel == 0 and owner.map.window == 6000,
                        "rolling did not use a fixed-span ring"
                    )
                    local _, origin = owner.map:select(owner.map.at)
                    assert(origin > 0, "rolling did not scroll past its first window")
                end
            end
            inputCoverage = "COVERAGE rolling=1 fixed_span=6000 scrolled=1 sole_renderer=1\n"
        elseif lateAttach then
            local chart = context.panels[1].instance
            assert(state.attached and chart.mipmapRenderer ~= state.oldRenderer, "late chart was not newly attached")
            assert(
                chart.mipmapConsumers[1].map ~= state.oldMap and chart.mipmapConsumers[1].complete,
                "late chart did not complete recorded-knot reconstruction"
            )
            assert(
                chart.series[1].feed.count >= state.oldCount and chart.mipmapRenderer.published[1],
                "late chart did not preserve and publish recorded history"
            )
            inputCoverage = "COVERAGE late_attach=1 rebuilt=1 retained_history=1 sole_renderer=1\n"
        end
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
        local samples = state.reportSamples
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
                .. longCoverage
                .. inputCoverage
                .. table.concat(states)
        )
        write("/capture-ready.txt", "normal chart callback smoke completed; no independent native paint target")
        state.phase = "done"
    end

    state.previous = state.phase ~= "done"
end

return function(context, refresh)
    local ok, message = pcall(tick, context, refresh)
    if not ok then
        write("/chart-feasibility.txt", "FAIL " .. tostring(message) .. "\n")
        write("/capture-ready.txt", "native runtime fixture failed")
        state.phase = "done"
    end
end
