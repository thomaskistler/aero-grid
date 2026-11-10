-- SPDX-License-Identifier: GPL-2.0-only

local profile = {}
local stages = {
    "setup",
    "rebuild",
    "renderer_setup",
    "reconstruction",
    "grid",
    "metadata",
    "drawing",
    "decoration",
    "decor_entry",
    "decor_flights",
    "decor_arms",
    "decor_breaks",
    "decor_resumes",
    "decor_connectors",
    "decor_publish",
    "decor_other",
}

function profile.reset(state)
    state.profile = {
        active = true,
        callbacks = 0,
        service = 0,
        owner_active = 0,
        owner_wait = 0,
        chart_dispatches = 0,
        panel_dispatches = 0,
    }
    for _, stage in ipairs(stages) do
        state.profile[stage] = 0
    end
end

local function stage(chart)
    if chart.mipmapSetup then
        return "setup"
    end

    for _, owner in ipairs(chart.mipmapConsumers or {}) do
        if owner.rebuildJob then
            return "rebuild"
        end
    end
    if not chart.mipmapPrepared then
        return "renderer_setup"
    end
    if chart.axisWork or chart.connectorWork or chart.viewWork then
        return "reconstruction"
    end
    if chart.gridVersion ~= chart.version then
        return "grid"
    end
    if chart.mipmapDecorating then
        return "decoration"
    end
    if chart.mipmapRenderer and chart.mipmapRenderer.jobs then
        return "drawing"
    end
    return "metadata"
end

profile.stage = stage

local function decorationState(chart)
    local result = {
        flightCursor = chart.flightCursor,
        flightRevision = chart.flightDrawnRevision,
        flightVersion = chart.flightDrawnVersion,
        armJob = chart.armMarkers and chart.armMarkers.job,
        armIndex = chart.armMarkers and chart.armMarkers.job and chart.armMarkers.job.index,
        armMarkerIndex = chart.armMarkers and chart.armMarkers.markerIndex,
        armPhase = chart.armMarkers and chart.armMarkers.markerPhase,
        armRevision = chart.armMarkers and chart.armMarkers.drawnRevision,
        resumeJob = chart.resumeMarkers and chart.resumeMarkers.job,
        resumeIndex = chart.resumeMarkers and chart.resumeMarkers.job and chart.resumeMarkers.job.index,
        resumeMarkerIndex = chart.resumeMarkers and chart.resumeMarkers.markerIndex,
        resumePhase = chart.resumeMarkers and chart.resumeMarkers.markerPhase,
        resumeRevision = chart.resumeMarkers and chart.resumeMarkers.drawnRevision,
        connectorWork = chart.connectorWork,
        connectorSeries = chart.connectorWork and chart.connectorWork.series,
        connectorIndex = chart.connectorWork and chart.connectorWork.index,
        breaks = {},
    }
    for index, item in ipairs(chart.series) do
        result.breaks[index] = {
            job = item.job,
            jobIndex = item.job and item.job.index,
            markerIndex = item.markerIndex,
            markerPhase = item.markerPhase,
            drawn = item.drawnBreak,
            version = item.drawnBreakVersion,
        }
    end
    return result
end

local function decorationStage(chart, before)
    if not chart.mipmapDecorating then
        return "decor_publish"
    end
    if
        chart.flightCursor ~= before.flightCursor
        or chart.flightDrawnRevision ~= before.flightRevision
        or chart.flightDrawnVersion ~= before.flightVersion
    then
        return "decor_flights"
    end
    local arm = chart.armMarkers
    if arm and (arm.job ~= before.armJob or arm.job and arm.job.index ~= before.armIndex
        or arm.markerIndex ~= before.armMarkerIndex or arm.markerPhase ~= before.armPhase
        or arm.drawnRevision ~= before.armRevision) then
        return "decor_arms"
    end
    for index, item in ipairs(chart.series) do
        local previous = before.breaks[index]
        if
            item.job ~= previous.job
            or item.job and item.job.index ~= previous.jobIndex
            or item.markerIndex ~= previous.markerIndex
            or item.markerPhase ~= previous.markerPhase
            or item.drawnBreak ~= previous.drawn
            or item.drawnBreakVersion ~= previous.version
        then
            return "decor_breaks"
        end
    end
    local resume = chart.resumeMarkers
    if resume and (resume.job ~= before.resumeJob or resume.job and resume.job.index ~= before.resumeIndex
        or resume.markerIndex ~= before.resumeMarkerIndex or resume.markerPhase ~= before.resumePhase
        or resume.drawnRevision ~= before.resumeRevision) then
        return "decor_resumes"
    end
    if
        chart.connectorWork ~= before.connectorWork
        or chart.connectorWork
            and (chart.connectorWork.series ~= before.connectorSeries or chart.connectorWork.index ~= before.connectorIndex)
    then
        return "decor_connectors"
    end
    return "decor_other"
end

function profile.install(context, state)
    if state.profileInstalled or not context.panelHost then
        return
    end
    local dispatch = context.panelHost.dispatch
    assert(type(dispatch) == "function", "panel dispatch unavailable for chart profiling")
    context.panelHost.dispatch = function(entry, method, ...)
        local current = state.profile
        local chart = entry and entry.instance
        local tracked = current and current.active and method == "refresh"
        if tracked then
            current.panel_dispatches = current.panel_dispatches + 1
        end
        local isChart = tracked and chart and entry.module and entry.module.id == "chart"
        local before, published, decoration
        if isChart then
            before = stage(chart)
            published = chart.mipmapRenderer and chart.mipmapRenderer.published
            decoration = decorationState(chart)
        end
        local first, second, third, fourth, fifth = dispatch(entry, method, ...)
        if isChart then
            local after = stage(chart)
            local wasDecorating = before == "decoration"
            if before == "metadata" and after ~= "metadata" then
                before = after
            elseif
                before == "metadata"
                and chart.mipmapRenderer
                and (chart.mipmapRenderer.jobs or chart.mipmapRenderer.published ~= published)
            then
                before = "drawing"
            end
            current[before] = current[before] + 1
            local callbackStage = before
            if wasDecorating then
                local substage = decorationStage(chart, decoration)
                current[substage] = current[substage] + 1
                callbackStage = substage
            elseif after == "decoration" then
                current.decor_entry = current.decor_entry + 1
            end
            current.chart_dispatches = current.chart_dispatches + 1
            current.callbackStage = callbackStage
        end
        return first, second, third, fourth, fifth
    end
    state.profileInstalled = true
end

function profile.beginCallback(state, context)
    local current = state.profile
    if not current or not current.active then
        return
    end
    current.ownerWasActive = context.refreshOwner ~= nil
    current.serviceAtStart = context.serviceRuntime.updates
    current.chart_dispatches_at_start = current.chart_dispatches
end

function profile.finishCallback(state, context)
    local current = state.profile
    if not current or not current.active then
        return
    end
    current.callbacks = current.callbacks + 1
    if context.serviceRuntime.updates ~= current.serviceAtStart then
        current.service = current.service + 1
    end
    if current.ownerWasActive or context.refreshOwner ~= nil then
        current.owner_active = current.owner_active + 1
        if current.chart_dispatches == current.chart_dispatches_at_start then
            current.owner_wait = current.owner_wait + 1
        end
    end
    current.pendingStage = current.callbackStage
        or current.ownerWasActive and "owner_wait"
        or "service_only"
    current.callbackStage = nil
end

function profile.recordUsage(state, usage)
    local current = state.profile
    if not current or not current.active or not current.pendingStage then
        return
    end
    local key = "max_" .. current.pendingStage
    current[key] = math.max(current[key] or 0, usage)
    current.pendingStage = nil
end

function profile.line(state)
    local current = state.profile
    if not current then
        return ""
    end
    local values = {}
    for key, value in pairs(current) do
        if key ~= "active" and key ~= "ownerWasActive" and key ~= "serviceAtStart"
            and key ~= "chart_dispatches_at_start" and key ~= "pendingStage" and key ~= "callbackStage" then
            values[#values + 1] = key .. "=" .. tostring(value)
        end
    end
    table.sort(values)
    return "PROFILE " .. table.concat(values, " ") .. "\n"
end

return profile
