-- SPDX-License-Identifier: GPL-2.0-only

local function load(path, ...)
    return assert(loadScript("/WIDGETS/AeroGrid/" .. path))(...)
end
local Prototype = load("tests/support/chart_mipmap_prototype.lua", load)
local Oracle = load("tests/support/mipmap_reading_oracle.lua")
local Stress = load("tests/support/chart_mipmap_stress.lua", load)
local mode = "integrated"
local tracing = false
local realTime = getTime
local state = {
    phase = "loading",
    logical = 100000,
    samples = {},
    items = {},
    forwarding = true,
    events = 0,
    traces = {},
}

-- A common logical clock makes service deadlines and input values reproducible.
-- Only the isolated simulator copy loads this driver.
getTime = function()
    return state.logical
end

local function write(path, text)
    local file = assert(io.open(path, "w"))
    io.write(file, text)
    io.close(file)
end

local function traceRenderer(Renderer)
    local originalStep = Renderer.step
    function Renderer:step(quota)
        if state.turn then
            state.turn.draw, state.turn.quota = true, quota
            state.turn.before = self.jobs and self.jobs[1].index or -1
        end
        local complete = originalStep(self, quota)
        if state.turn then
            local job = self.jobs and self.jobs[1] or self.published[1]
            state.turn.after = job and job.index or -1
            state.turn.complete = complete and 1 or 0
        end
        return complete
    end
end

local function tracedRefresh(context, chart, original, ...)
    if not tracing or not state.startedAt then
        return original(chart, ...)
    end
    local turn = {
        chart = chart.matchedIndex,
        decorating = chart.mipmapDecorating,
        telemetry = context.servicesUpdatedAt == chart.clock() and context.updatedService == "telemetry",
        gridBefore = chart.gridCursor,
        versionBefore = chart.version,
        gridReadyBefore = chart.gridVersion,
    }
    state.turn = turn
    local interval, unfinished, consumed = original(chart, ...)
    state.turn = nil
    turn.reason = turn.draw and "draw"
        or turn.decorating and "decoration"
        or turn.telemetry and "telemetry"
        or chart.projectionTurn and "metadata"
        or "grid"
    turn.gridAfter, turn.versionAfter, turn.gridReadyAfter = chart.gridCursor, chart.version, chart.gridVersion
    turn.geometry, turn.window = chart.geometryVersion, chart.window
    turn.unfinished, turn.interval = unfinished and 1 or 0, interval
    state.dispatch = turn
    return interval, unfinished, consumed
end

local function published(chart, item)
    return mode == "prototype" and item.published or chart.mipmapRenderer.published
end

local function initialComplete(context)
    for index, entry in ipairs(context.panels) do
        local chart, item = entry.instance, state.items[index]
        if mode == "prototype" and item.active or mode == "integrated" and chart.mipmapDecorating then
            return false
        end
        for series in ipairs(chart.series) do
            local job = published(chart, item)[series]
            if not job or job.level ~= 1 then
                return false
            end
        end
    end
    return true
end

local function settled(context)
    if not initialComplete(context) then
        return false
    end
    for index, entry in ipairs(context.panels) do
        local chart, item = entry.instance, state.items[index]
        if mode == "prototype" and item.active or mode == "integrated" and chart.mipmapRenderer.jobs then
            return false
        end
        if mode == "integrated" and chart.gridVersion ~= chart.version then
            return false
        end
        for series, owner in ipairs(chart.mipmapConsumers) do
            if published(chart, item)[series].revision ~= owner.map.revision then
                return false
            end
        end
    end
    return true
end

local function install(context)
    for index, entry in ipairs(context.panels) do
        local chart, item = entry.instance, state.items[index]
        chart.clock = getTime
        item.clock, item.live = 0, true
        item.turns, item.mapped, item.submitted, item.repairs, item.groupMoves = 0, 0, 0, 0, 0
        item.oracles = {}
        for series, owner in ipairs(chart.mipmapConsumers) do
            local oracle, sample, reset = Oracle.new(), owner.sample, owner.reset
            oracle:sample(0, 0)
            item.oracles[series] = oracle
            owner.sample = function(target, at, value, broken)
                if state.forwarding then
                    if not state.startedAt then
                        state.prefixSamples = (state.prefixSamples or 0) + 1
                        state.prefixHash = (
                            (state.prefixHash or 1) * 33
                            + (at - target.startedAt) * 17
                            + math.floor((value or 0) * 1000) * 7
                            + index * 3
                            + series
                            + (broken and 1 or 0)
                        ) % 2147483647
                    end
                    oracle:sample(at - target.startedAt, value, broken)
                    sample(target, at, value, broken)
                    item.clock = target.map.at
                    state.events = state.events + 1
                    if at - target.startedAt >= 6000 and not state.startedAt then
                        state.startedAt, state.trigger = state.callbackStarted, state.logical
                        context.matchedOperation = true
                        state.events = 1
                        write("/paint-phase.txt", string.format("1 %d 0\n", state.startedAt * 10))
                    end
                end
            end
            owner.reset = function(target)
                oracle.times, oracle.values, oracle.breaks = {}, {}, {}
                reset(target)
            end
        end
        lvgl.hide(item.root)
    end
    state.workload.armed = true
    state.phase = "running"
end

local function exportReference(context)
    local entry = context.panels[state.referenceChart]
    local chart, item = entry.instance, state.items[state.referenceChart]
    local active = mode == "prototype" and item or chart.mipmapRenderer
    if not state.referenceRoot then
        state.referenceRoot = lvgl.box(active.root, { x = 0, y = 0, w = chart.rect.w, h = chart.rect.h })
        lvgl.hide(state.referenceRoot)
        state.referenceSeries, state.referenceBucket = 1, 0
    end
    local area, series = chart.area, state.referenceSeries
    for _ = 1, 8 do
        local bucket = state.referenceBucket
        local low, high, gap = item.oracles[series]:column(area.w, 1, bucket)
        local actualLow, actualHigh, actualGap = chart.mipmapConsumers[series].map:column(1, bucket)
        assert(
            gap == actualGap and (gap or low == actualLow and high == actualHigh),
            "matched input oracle differs from the retained summary"
        )
        if not gap then
            -- Independent timestamped inputs, fixed [0,1] range, no ring or
            -- published/native geometry is read to construct the reference.
            local top = math.max(area.y, math.min(area.y + area.h, math.floor(area.y + area.h - high * area.h + 0.5)))
            local bottom = math.max(area.y, math.min(area.y + area.h, math.floor(area.y + area.h - low * area.h + 0.5)))
            lvgl.rectangle(state.referenceRoot, {
                x = area.x + bucket,
                y = top,
                w = 1,
                h = bottom - top + 1,
                filled = true,
                thickness = 0,
                color = chart.series[series].color,
            })
        end
        state.referenceBucket = bucket + 1
        if state.referenceBucket == area.w then
            state.referenceSeries, state.referenceBucket = series + 1, 0
            if state.referenceSeries > #chart.series then
                -- Keep existing normal overlays in their original z-order.
                -- This verifies input-derived envelopes/compositing, not an
                -- independent oracle for the overlay algorithms themselves.
                for _, group in ipairs(active.groups) do
                    lvgl.hide(group)
                end
                lvgl.show(state.referenceRoot)
                state.referenceChart, state.referenceRoot = state.referenceChart + 1, nil
                return state.referenceChart > #context.panels
            end
            break
        end
    end
    return false
end

return function(context, refresh)
    if state.previous then
        local usage = getUsage()
        state.samples[#state.samples + 1] = usage
        if tracing then
            state.traces[#state.traces].usage = usage
        end
        state.previous = false
    end
    if state.phase == "done" then
        return
    end
    local now = realTime()
    if state.nextCallback and now < state.nextCallback then
        return
    end
    -- Warm pools/reference export are outside timing. Both measured paths use
    -- exactly the same 160ms admission schedule and 160ms logical service ticks.
    state.nextCallback = now + (state.startedAt and state.phase == "running" and 16 or 5)
    state.logical, state.callbackStarted = state.logical + 16, now
    context.matchedNow = state.logical
    assert(context.chartMipmap and context.chartMipmapRenderer, "default runtime did not load mipmap modules")
    if tracing and not state.rendererTraced then
        traceRenderer(context.chartMipmapRenderer)
        state.rendererTraced = true
    end
    if context.serviceRuntime then
        context.serviceRuntime.env.getTime = getTime
    end
    if context.flightBroker then
        context.flightBroker.env.getTime = getTime
    end
    if #context.errors > 0 then
        write("/chart-feasibility.txt", "FAIL " .. table.concat(context.errors, "; ") .. "\n")
        write("/capture-ready.txt", "matched chart failed")
        state.phase = "done"
        return
    end
    if state.phase == "loading" then
        refresh(context)
        if not context.stage and #context.panels == 2 then
            state.workload = Stress.new(context, 800, 130, true)
            local env = context.serviceRuntime.env
            local originalValue = env.getValue
            local value = function(id)
                if type(id) == "number" and id > 5000 and id <= 5024 then
                    return ((state.logical * 17 + id * 13) % 97 + 1) / 100
                end
                return originalValue(id)
            end
            env.getValue, context.flightBroker.env.getValue = value, value
            local gps = { lat = 1, lon = 2, delay = 0 }
            local source = function(id)
                local sensor = (id - 6000) / 3
                return sensor == 37 and gps or sensor == 59 and 8 or state.logical % 100 / 100, true, true
            end
            env.getSourceValue, context.flightBroker.env.getSourceValue = source, source
            for _, entry in ipairs(context.panels) do
                local original = entry.module.refresh
                entry.instance.matchedIndex = entry.placement.id
                entry.module.refresh = function(chart, ...)
                    if state.phase == "pools" or state.phase == "reference" or state.phase == "report" then
                        return 1, false, 0
                    end
                    if state.phase == "running" and state.startedAt and mode == "prototype" then
                        lvgl.hide(chart.plotRoot)
                        lvgl.hide(chart.duration)
                        lvgl.hide(chart.durationBackground)
                        lvgl.show(chart.matchedPrototype.root)
                        local service = context.updatedService
                        chart.matchedPrototype.batch = service == "telemetry" and 64
                            or context.flightPolled and 80
                            or 130
                        local interval, unfinished = chart.matchedPrototype:step()
                        local _, slots = ...
                        return interval, unfinished, slots or 8
                    end
                    return tracedRefresh(context, chart, original, ...)
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
        state.warming = state.warming + 1
        local ready = state.warming >= 160
        for _, entry in ipairs(context.panels) do
            ready = ready and entry.instance.mipmapPrepared
        end
        if ready then
            state.phase, state.pool = "pools", 1
        end
    elseif state.phase == "pools" then
        refresh(context)
        local chart = context.panels[state.pool].instance
        local item = state.items[state.pool]
        if not item then
            item = Prototype.new(chart, 800, chart.theme.color.surface)
            item.maps = {}
            for series, owner in ipairs(chart.mipmapConsumers) do
                owner.map:sample(0, 0)
                item.maps[series] = owner.map
            end
            item.clock, item.groupedScroll = 5900, true
            state.items[state.pool], chart.matchedPrototype = item, item
        end
        for _ = 1, item.prepareIndex <= item.width * #item.maps and 8 or 1 do
            if item:prepare() then
                state.pool = state.pool + 1
                if state.pool > #context.panels then
                    install(context)
                end
                break
            end
        end
    elseif state.phase == "running" then
        local startedBefore = state.startedAt
        state.dispatch = nil
        local ownerBefore = context.refreshOwner and context.refreshOwner.placement.id or "none"
        local due1, due2 = context.panels[1].nextRefresh, context.panels[2].nextRefresh
        if not state.startedAt then
            -- Establish the common measured cadence before the crossing.
            local chart = context.panels[1].instance
            if chart.session.elapsed >= 5500 then
                state.nextCallback = now + 16
            end
        end
        refresh(context)
        if not state.startedAt then
            -- Identical normal-chart warm-up in both runs. Maintain the other
            -- already-allocated pool outside the measured operation so the
            -- prototype also starts from the same populated level-0 history.
            for _, item in ipairs(state.items) do
                item.batch = 24
                item:step()
                lvgl.hide(item.root)
            end
        end
        if state.startedAt then
            if tracing then
                local turn = state.dispatch or { reason = "wait", chart = "none" }
                turn.service = context.servicesUpdatedAt == state.logical and context.updatedService or "idle"
                turn.smart = context.flightPolled and 1 or 0
                turn.ownerBefore = ownerBefore
                turn.ownerAfter = context.refreshOwner and context.refreshOwner.placement.id or "none"
                turn.logical, turn.real = state.logical, now * 10
                turn.due1, turn.due2 = due1 or -1, due2 or -1
                state.traces[#state.traces + 1] = turn
            end
            state.previous = true
            state.callbacks = (state.callbacks or 0) + 1
            if state.forwarding and initialComplete(context) then
                state.forwarding, state.fencedAt = false, now
            end
            if not state.forwarding and settled(context) then
                state.finishedAt, state.phase, state.referenceChart = realTime(), "reference", 1
                write("/paint-phase.txt", string.format("1 %d %d\n", state.startedAt * 10, state.finishedAt * 10))
            end
            if state.callbacks > 160 then
                local details = {}
                for index, entry in ipairs(context.panels) do
                    local chart, item = entry.instance, state.items[index]
                    local job = published(chart, item)[1]
                    details[#details + 1] = string.format(
                        "%d active=%s clock=%s map_at=%s map_level=%s published_level=%s published_revision=%s revision=%s jobs=%s session_elapsed=%s",
                        index,
                        tostring(item.active),
                        tostring(item.clock),
                        tostring(item.maps[1].at),
                        tostring(item.maps[1].level),
                        tostring(job and job.level),
                        tostring(job and job.revision),
                        tostring(item.maps[1].revision),
                        tostring(item.jobs[1] and item.jobs[1].index),
                        tostring(chart.session.elapsed)
                    )
                end
                write(
                    "/chart-feasibility.txt",
                    "FAIL matched expansion did not converge: " .. table.concat(details, "; ")
                )
                write("/capture-ready.txt", "matched convergence failure")
                state.phase = "done"
            end
        end
        if not startedBefore and state.startedAt then
            state.samples = {}
        end
    elseif state.phase == "reference" then
        refresh(context)
        if exportReference(context) then
            state.phase = "report"
            write("/paint-phase.txt", "2 0 0\n")
        end
    elseif state.phase == "report" then
        refresh(context)
        local samples, regions = {}, {}
        for index, usage in ipairs(state.samples) do
            samples[index] = tostring(usage)
        end
        for _, entry in ipairs(context.panels) do
            local rect = context.grid.rect(context.zone, entry.placement, 4, 4, 4)
            regions[#regions + 1] = string.format(
                "REGION %d %d %d %d\n",
                rect.x + (context.zone.xabs or 0),
                rect.y + (context.zone.yabs or 0),
                rect.w,
                rect.h
            )
        end
        local traces = {}
        for index, turn in ipairs(state.traces) do
            traces[#traces + 1] = string.format(
                "TRACE callback=%d chart=%s reason=%s service=%s smart=%d owner_before=%s owner_after=%s logical=%d real_ms=%d due1=%d due2=%d quota=%d index_before=%d index_after=%d complete=%d grid_before=%d grid_after=%d version_before=%d version_after=%d grid_ready_before=%d grid_ready_after=%d unfinished=%d interval=%d usage=%d\n",
                index,
                turn.chart,
                turn.reason,
                turn.service or "idle",
                turn.smart,
                turn.ownerBefore,
                turn.ownerAfter,
                turn.logical,
                turn.real,
                turn.due1,
                turn.due2,
                turn.quota or -1,
                turn.before or -1,
                turn.after or -1,
                turn.complete or -1,
                turn.gridBefore or -1,
                turn.gridAfter or -1,
                turn.versionBefore or -1,
                turn.versionAfter or -1,
                turn.gridReadyBefore or -1,
                turn.gridReadyAfter or -1,
                turn.unfinished or -1,
                turn.interval or -1,
                turn.usage
            )
        end
        write(
            "/chart-feasibility.txt",
            string.format(
                "MATCHED mode=%s started_ms=%d submitted_ms=%d trigger=%d prefix_samples=%d prefix_hash=%d callbacks=%d events=%d period_ms=160 sources=%d columns=%d,%d\n",
                mode,
                state.startedAt * 10,
                state.finishedAt * 10,
                state.trigger,
                state.prefixSamples,
                state.prefixHash,
                state.callbacks,
                state.events,
                state.workload.history.count,
                context.panels[1].instance.area.w,
                context.panels[2].instance.area.w
            )
                .. "CALLBACK_USAGE "
                .. table.concat(samples, ",")
                .. "\n"
                .. table.concat(regions)
                .. table.concat(traces)
        )
        write("/capture-ready.txt", "matched expansion reference ready")
        state.phase = "done"
    end
end
