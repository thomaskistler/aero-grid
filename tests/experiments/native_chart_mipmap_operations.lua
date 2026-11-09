-- SPDX-License-Identifier: GPL-2.0-only
-- Isolated diagnostic: normal chart versus the original direct-dispatch prototype.
local function load(path, ...)
    return assert(loadScript("/WIDGETS/AeroGrid/" .. path))(...)
end
local Mipmap = load("lib/chart_mipmap.lua")
local Renderer = load("lib/chart_mipmap_renderer.lua")
local Prototype = load("tests/support/chart_mipmap_prototype.lua", load)
local Oracle = load("tests/support/mipmap_reading_oracle.lua")
local Stress = load("tests/support/chart_mipmap_stress.lua", load)
local mode = "integrated"
local operation = "append"
local realTime = getTime
local state = {
    phase = "loading", logical = 100000, items = {}, oracles = {}, samples = {},
    seen = {}, firstRevision = {}, prefixHash = 1, prefixSamples = 0, events = 0,
}
getTime = function() return state.logical end

local function write(path, text)
    local file = assert(io.open(path, "w"))
    io.write(file, text)
    io.close(file)
end

local function view(chart, item)
    return mode == "prototype" and item or chart.mipmapRenderer
end

local function selection(at, width)
    local level = 0
    while level < 10 and at >= 6000 * (4 / 3) ^ level do
        level = level + 1
    end
    local span, origin = 6000 * (4 / 3) ^ level, 0
    if level == 10 and at >= span then
        origin = ((((at - span) / (span / 4)) // 1 + 1) * width / 4) // 1
    end
    return level, origin
end

local function ready(context, initial)
    for index, entry in ipairs(context.panels) do
        local chart, item = entry.instance, state.items[index]
        local active = view(chart, item)
        if mode == "prototype" then
            if item.active then return false end
        elseif active.jobs or chart.mipmapDecorating or chart.gridVersion ~= chart.version then
            return false
        end
        for series, owner in ipairs(chart.mipmapConsumers) do
            local job = active.published[series]
            local expected = state.firstRevision[index][series]
            if not job or not state.seen[index][series] or not expected or job.revision < expected then
                return false
            end
            if job.level ~= state.level or job.origin ~= state.origin then return false end
            if mode == "integrated" and (job.low ~= 0 or job.high ~= state.high) then return false end
            if not initial and job.revision ~= owner.map.revision then return false end
        end
    end
    return true
end

local function attach(context)
    state.seedEnd = operation == "scroll" and math.ceil(6000 * (4 / 3) ^ 10 * 1.25) - 20
        or operation == "vertical" and 6800 or operation == "horizontal" and 5990 or 5500
    state.target = operation == "horizontal" and 6001 or state.seedEnd + 20
    state.level, state.origin = selection(state.target, context.panels[1].instance.area.w)
    state.seedStep = math.max(5, (state.seedEnd / 500) // 1)
    state.high = operation == "vertical" and 4 / 3 or 1
    state.base = state.logical
    for index, entry in ipairs(context.panels) do
        local chart, item = entry.instance, state.items[index]
        state.oracles[index], state.seen[index], state.firstRevision[index] = {}, {}, {}
        chart.clock = getTime
        chart.mipmapRenderer:reset()
        for series, owner in ipairs(chart.mipmapConsumers) do
            owner.map:reset()
            owner.startedAt = chart.session.elapsed
            local oracle, original = Oracle.new(), owner.sample
            state.oracles[index][series] = oracle
            owner.sample = function(target, at, value, broken)
                if state.phase ~= "running" or state.forwarding then
                    local stamp = at - target.startedAt
                    oracle:sample(stamp, value, broken)
                    original(target, at, value, broken)
                    item.clock = target.map.at
                    if state.phase == "running" then
                        state.seen[index][series] = true
                        state.firstRevision[index][series] =
                            state.firstRevision[index][series] or target.map.revision
                        state.events = state.events + 1
                    else
                        state.prefixSamples = state.prefixSamples + 1
                        state.prefixHash = (state.prefixHash * 33 + stamp * 17
                            + math.floor((value or 0) * 1000) * 7
                            + index * 3 + series + (broken and 1 or 0)) % 16777213
                    end
                end
            end
        end
    end
    state.seedAt, state.phase = 0, "seed"
end

local function begin(context, now)
    state.logical = state.base + state.target
    context.matchedNow = state.logical
    context.matchedOperation = true
    state.startedAt, state.forwarding, state.callbacks = now, true, 0
    for _, entry in ipairs(context.panels) do
        local chart, item = entry.instance, entry.instance.operationPrototype
        for _, series in ipairs(chart.series) do series.settings.rangeMax = state.high end
        chart.rangesReady = false
        if mode == "prototype" then
            item:begin(operation)
            -- The actual history observer supplies the event; no synthetic admission.
            item.admitted, item.live = true, true
            item.clock = state.target
        end
        entry.nextRefresh = state.logical
    end
    context.refreshOwner = nil
    state.phase = "running"
    write("/paint-phase.txt", string.format("1 %d 0\n", now * 10))
end

local function reference(context)
    local entry = context.panels[state.referenceChart]
    local chart, item = entry.instance, state.items[state.referenceChart]
    local active, area = view(chart, item), chart.area
    if not state.referenceRoot then
        state.referenceRoot = lvgl.box(active.root, { x = 0, y = 0, w = chart.rect.w, h = chart.rect.h })
        lvgl.hide(state.referenceRoot)
        state.referenceSeries, state.referenceBucket = 1, 0
    end
    local series = state.referenceSeries
    for _ = 1, 8 do
        local bucket = state.origin + state.referenceBucket
        local low, high, gap = state.oracles[state.referenceChart][series]:column(area.w, state.level, bucket)
        local actualLow, actualHigh, actualGap = chart.mipmapConsumers[series].map:column(state.level, bucket)
        assert(gap == actualGap and (gap or low == actualLow and high == actualHigh), "input oracle differs")
        if not gap then
            local bottom = area.y + area.h
            local top = math.max(area.y, math.min(bottom, math.floor(bottom - high / state.high * area.h + 0.5)))
            local last = math.max(area.y, math.min(bottom, math.floor(bottom - low / state.high * area.h + 0.5)))
            lvgl.rectangle(state.referenceRoot, {
                x = area.x + state.referenceBucket, y = top, w = 1, h = last - top + 1,
                filled = true, thickness = 0, color = chart.series[series].color,
            })
        end
        state.referenceBucket = state.referenceBucket + 1
        if state.referenceBucket == area.w then
            state.referenceSeries, state.referenceBucket = series + 1, 0
            if state.referenceSeries > #chart.series then
                for _, group in ipairs(active.groups) do lvgl.hide(group) end
                lvgl.show(state.referenceRoot)
                state.referenceChart, state.referenceRoot = state.referenceChart + 1, nil
                return state.referenceChart > #context.panels
            end
            break
        end
    end
    return false
end

local function tick(context, refresh)
    if state.previous then
        state.samples[#state.samples + 1] = getUsage()
        state.previous = false
    end
    if state.phase == "done" then return end
    local now = realTime()
    if state.nextCallback and now < state.nextCallback then return end
    state.nextCallback = now + 5
    if state.debugPhase ~= state.phase and state.phase ~= "running" then
        state.debugPhase = state.phase
        write("/operation-progress.txt", state.phase .. " at " .. tostring(now) .. "\n")
    end
    if state.phase == "loading" or state.phase == "subscriptions" or state.phase == "warming"
        or state.phase == "armed-warm" then
        state.logical = state.logical + 5
    elseif state.phase == "running" then
        state.logical = state.logical + 5
    end
    context.matchedNow = state.logical
    context.chartMipmap, context.chartMipmapRenderer = Mipmap, Renderer
    if context.serviceRuntime then context.serviceRuntime.env.getTime = getTime end
    if context.flightBroker then context.flightBroker.env.getTime = getTime end
    if #context.errors > 0 then
        write("/chart-feasibility.txt", "FAIL " .. table.concat(context.errors, "; ") .. "\n")
        write("/capture-ready.txt", "operation failed")
        state.phase = "done"
        return
    end
    if state.phase == "loading" then
        refresh(context)
        if not context.stage and #context.panels == 2 then
            state.workload = Stress.new(context, 800, 120, true)
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
                entry.module.refresh = function(chart, ...)
                    if state.phase == "pools" or state.phase == "seed" or state.phase == "prototype-warm" then
                        return 1
                    end
                    if state.phase == "running" and mode == "prototype" then
                        lvgl.hide(chart.plotRoot)
                        lvgl.hide(chart.duration)
                        lvgl.hide(chart.durationBackground)
                        local item = chart.operationPrototype
                        lvgl.show(item.root)
                        item.batch = context.flightPolled and 75 or 120
                        return item:step()
                    end
                    return original(chart, ...)
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
        local complete = state.warming >= 160
        for _, entry in ipairs(context.panels) do
            complete = complete and entry.instance.mipmapPrepared
        end
        if complete then
            state.workload.armed = true
            state.phase, state.armedWarm = "armed-warm", 0
        end
    elseif state.phase == "armed-warm" then
        refresh(context)
        state.armedWarm = state.armedWarm + 1
        local complete = state.armedWarm >= 80
        for _, entry in ipairs(context.panels) do
            complete = complete and entry.instance.session.recording
        end
        if complete then state.phase, state.pool = "pools", 1 end
    elseif state.phase == "pools" then
        local chart = context.panels[state.pool].instance
        local item = state.items[state.pool]
        if not item then
            item = Prototype.new(chart, 800, chart.theme.color.surface)
            item.maps = {}
            for series, owner in ipairs(chart.mipmapConsumers) do item.maps[series] = owner.map end
            item.clock, item.groupedScroll = 5900, true
            state.items[state.pool], chart.operationPrototype = item, item
        end

        for _ = 1, item.prepareIndex <= item.width * #item.maps and 8 or 1 do
            if item:prepare() then
                lvgl.hide(item.root)
                state.pool = state.pool + 1
                if state.pool > #context.panels then attach(context) end
                break
            end
        end
    elseif state.phase == "seed" then
        state.logical = state.base + state.seedAt
        context.matchedNow = state.logical
        local control = context.serviceRuntime.byId.control
        for _, entry in ipairs(control.entries) do
            if entry.state.name == "SAv" then control:readSwitch(entry, state.logical) end
        end
        for source = 1, 6 do
            local missing = state.seedAt > 0 and (state.seedAt // state.seedStep) % 53 == 0
            state.workload.history:sample({
                name = "Q" .. source, fresh = not missing, kind = "number",
                value = ((state.seedAt * 17 + source * 13) % 97 + 1) / 100,
                updatedAt = state.logical, precision = 3, precisionKnown = true, unitText = "",
            }, state.logical)
        end
        if state.seedAt == state.seedEnd then
            state.phase = "normal-warm"
            for _, entry in ipairs(context.panels) do entry.instance.rangesReady = false end
        else
            state.seedAt = math.min(state.seedEnd, state.seedAt + state.seedStep)
        end
    elseif state.phase == "normal-warm" then
        for _, entry in ipairs(context.panels) do entry.nextRefresh = state.logical end
        refresh(context)
        local complete = true
        for _, entry in ipairs(context.panels) do
            local chart = entry.instance
            complete = complete and not chart.mipmapRenderer.jobs and not chart.mipmapDecorating
                and chart.gridVersion == chart.version
            for series, owner in ipairs(chart.mipmapConsumers) do
                local job = chart.mipmapRenderer.published[series]
                complete = complete and job and job.revision == owner.map.revision
            end
        end
        if complete then
            for _, item in ipairs(state.items) do
                item.active, item.admitted, item.live, item.preparedJobs = true, true, true, false
                item.operation, item.jobKind, item.batch = "initial", "refresh", 24
                item.turns, item.mapped, item.submitted, item.repairs, item.groupMoves = 0, 0, 0, 0, 0
                item.shifted = 0
            end
            state.phase, state.warmChart = "prototype-warm", 1
        end
    elseif state.phase == "prototype-warm" then
        local item = state.items[state.warmChart]
        item:step()
        lvgl.hide(item.root)
        if not item.active then state.warmChart = state.warmChart + 1 end
        if state.warmChart > #state.items then state.phase = "begin" end
    elseif state.phase == "begin" then
        begin(context, now)
    elseif state.phase == "running" then
        refresh(context)
        state.callbacks, state.previous = state.callbacks + 1, true
        if state.forwarding and ready(context, true) then state.forwarding = false end
        if not state.forwarding and ready(context, false) then
            state.finishedAt, state.phase, state.referenceChart = realTime(), "reference", 1
            write("/paint-phase.txt", string.format("1 %d %d\n", state.startedAt * 10, state.finishedAt * 10))
        end
        assert(state.callbacks < 180, "operation did not converge: " .. operation)
    elseif state.phase == "reference" then
        if reference(context) then
            state.phase = "report"
            write("/paint-phase.txt", "2 0 0\n")
        end
    elseif state.phase == "report" then
        local samples, regions = {}, {}
        for index, usage in ipairs(state.samples) do samples[index] = tostring(usage) end
        for _, entry in ipairs(context.panels) do
            local rect = context.grid.rect(context.zone, entry.placement, 4, 4, 4)
            regions[#regions + 1] = string.format("REGION %d %d %d %d\n",
                rect.x + (context.zone.xabs or 0), rect.y + (context.zone.yabs or 0), rect.w, rect.h)
        end
        write("/chart-feasibility.txt", string.format(
            "MATCHED mode=%s op=%s started_ms=%d submitted_ms=%d trigger=%d prefix_samples=%d prefix_hash=%d callbacks=%d events=%d period_ms=50 sources=24 columns=398,398\n",
            mode, operation, state.startedAt * 10, state.finishedAt * 10, state.target,
            state.prefixSamples, state.prefixHash, state.callbacks, state.events)
            .. "CALLBACK_USAGE " .. table.concat(samples, ",") .. "\n" .. table.concat(regions))
        write("/capture-ready.txt", "controlled operation complete; inspect painted comparison")
        state.phase = "done"
    end
end

return function(context, refresh)
    local ok, message = pcall(tick, context, refresh)
    if not ok then
        write("/chart-feasibility.txt", "FAIL " .. tostring(message) .. "\n")
        write("/capture-ready.txt", "controlled adapter failed")
        state.phase = "done"
    end
end
