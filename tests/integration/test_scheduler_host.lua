-- SPDX-License-Identifier: GPL-2.0-only

-- The development scheduler host in the real widget: `mixed` and `new` modes, the
-- owner table, legacy accounting, call sites, load errors, and the probe.
-- Nothing here migrates a real task; a stand-in service shows the ownership flip.
local root = (... and ... ~= "" and ...) or "."
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local loadMain = assert(loadfile(root .. "/tests/support/scheduler_host_fixture.lua"))(root)
local standin = assert(loadfile(root .. "/tests/support/scheduler_standin.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()

local path = root .. "/build/test-widget-fixture/"
local LIMIT = scheduler.CEILING - scheduler.MARGIN

local function layout(name, text)
    local file = assert(hostIo.open(path .. "layouts/" .. name .. ".yaml", "w"))
    file:write(text)
    file:close()
end

layout(
    "host-light",
    [[
version: 4
grid:
  columns: 4
  rows: 4
panels:
  - id: altitude
    type: metric
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      metrics:
        - source: GAlt
  - id: flights
    type: flight-counter
    col: 1
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      armSwitch: SFv
      minFlightDuration: 1
      disarmDuration: 1
]]
)
layout(
    "host-chart",
    [[
version: 4
grid:
  columns: 4
  rows: 4
panels:
  - id: trace
    type: chart
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      armSwitch: SAv
      scaling: independent
      timeRange: rolling
      smoothing: medium
      metrics:
        - source: Q1
          precision: 1
        - source: Q2
          precision: 1
  - id: altitude
    type: metric
    col: 2
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      metrics:
        - source: GAlt
  - id: flights
    type: flight-counter
    col: 3
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      armSwitch: SFv
      minFlightDuration: 1
      disarmDuration: 1
]]
)

layout(
    "host-model",
    [[
version: 4
grid:
  columns: 4
  rows: 4
panels:
  - id: identity
    type: model-identity
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: mode
    type: flight-mode
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
  - id: timer
    type: flight-timer
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      timer: 0
  - id: battery
    type: tx-battery
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
]]
)

-- Starts a widget in `mode` on `layoutName` and loads it. Every panel dispatch is
-- logged as `{ tick, panel id, event }` in `context.dispatches`.
local function settleHost(host, context)
    if not host then
        return
    end
    for _ = 1, 1024 do
        assert(host:ready(context))
        if not host.reconciliation and not host.pendingPanels then
            return
        end
    end
    error("bounded host reconciliation did not finish")
end

local function start(mode, layoutName, probe)
    fixture.reset()
    for index = 1, 2 do
        local name = "Q" .. index
        fixture.radio.fields[name] = { id = 5000 + index, name = name, unit = 1 }
        fixture.radio.values[5000 + index] = index
    end
    fixture.radioMock.indexFields()
    local definition = loadMain(mode, probe)
    local context = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = layoutName, Theme = "modern-dark" },
        path
    )
    local guard = 0
    while context.stage do
        definition.refresh(context)
        guard = guard + 1
        assert(guard < 400, "staged load never finished")
    end
    if mode ~= "new" then
        settleHost(context.schedulerHost, context)
    end
    context.dispatches = {}
    local dispatch = context.panelHost.dispatch
    context.panelHost.dispatch = function(entry, event, ...)
        context.dispatches[#context.dispatches + 1] = { getTime(), entry.placement.id, event }
        return dispatch(entry, event, ...)
    end
    return definition, context
end

-- Callbacks three to seven ticks apart, as the radio's are not regular, a
-- background one every fourth time.
local seed = 7
local function callbacks(definition, context, count, after)
    for index = 1, count do
        seed = (seed * 1103515245 + 12345) & 0x7fffffff
        fixture.tick(3 + (seed >> 8) % 5)
        local background = index % 4 == 0
        if background then
            definition.background(context)
        else
            definition.refresh(context)
        end
        if after then
            after(index, background and "background" or "steady")
        end
    end
end

local function refreshesIn(context, from)
    local refreshes = {}
    for index = from, #context.dispatches do
        if context.dispatches[index][3] == "refresh" then
            refreshes[#refreshes + 1] = context.dispatches[index][2]
        end
    end
    return refreshes
end

local function logged(context, text)
    for message in pairs(context.errorLog and context.errorLog.messages or {}) do
        if string.find(message, text, 1, true) then
            return true
        end
    end
    return false
end

local function awaitService(host, context, id)
    for _ = 1, 1024 do
        assert(host:ready(context))
        if host.scheduler.byId[id] then
            return host.scheduler.byId[id]
        end
    end
    error(id .. " was not enrolled")
end

-- 0. The owner table and the declared bounds cover every service and panel type, so
-- a new one cannot be added without an owner and a bound (theme-showcase has no
-- bound: a layout with it cannot run in mixed).
do
    local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler_host.lua"))()
    local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
    local expected, boundsExpected = {}, {}
    for _, definition in ipairs(services.DEFINITIONS) do
        local key = "service:" .. definition.id
        expected[key] = true
        assert(host.OWNERS[key], key .. " needs an owner")
        if host.OWNERS[key] == "legacy" then
            assert(host.SERVICE_BOUNDS[definition.id], "legacy service " .. definition.id .. " needs a declared bound")
        end
    end
    local listingPath = root .. "/build/scheduler-panel-types.txt"
    os.execute("ls '" .. root .. "/src/WIDGETS/AeroGrid/panels' > '" .. listingPath .. "'")
    local listing = assert(hostIo.open(listingPath, "r"))
    for name in listing:lines() do
        local panel = string.match(name, "^(.+)%.lua$")
        if panel then
            expected["panel:" .. panel] = true
            boundsExpected[panel] = true
        end
    end
    listing:close()
    os.remove(listingPath)
    -- Migrated tasks; every other one is `legacy` until its migration.
    expected["service:control-normal"] = true
    expected["service:control-outputs"] = true
    local migrated = {
        ["service:telemetry"] = true,
        ["service:model"] = true,
        ["service:control"] = true,
        ["service:control-normal"] = true,
        ["service:control-outputs"] = true,
        ["service:armed"] = true,
        ["service:navigation"] = true,
        ["service:history"] = true,
    }
    for key in pairs(expected) do
        equal(host.OWNERS[key], migrated[key] and "new" or "legacy", key .. " needs an owner")
    end
    for key in pairs(host.OWNERS) do
        assert(expected[key], key .. " is in the owner table but is no service or panel")
    end
    for panel, wanted in pairs(boundsExpected) do
        equal(host.PANEL_BOUNDS[panel] ~= nil, wanted, "declared bound of panel " .. panel)
    end
end

-- Telemetry source tasks are rebuilt when History changes a source's observer
-- multiplicity, so the scheduler sees the declaration for the actual work.
do
    local definition, context = start("mixed", "host-light")
    local host = context.schedulerHost
    callbacks(definition, context, 2)
    local telemetry = context.serviceRuntime.byId.telemetry
    local history = context.serviceRuntime.byId.history
    local sourceTask = telemetry.entries[1].task
    equal(sourceTask.want, 1, "an unrecorded source requests one unit")
    awaitService(host, context, sourceTask.id)
    assert(host.scheduler.byId[sourceTask.id], "unrecorded source is enrolled")

    history:subscribe("GAlt", {
        armSwitch = "SFv",
        timeRange = "rolling",
        windowSeconds = 30,
    })
    awaitService(host, context, telemetry.entries[1].task.id)
    sourceTask = telemetry.entries[1].task
    equal(sourceTask.want, 1, "one recording remains a one-unit task")
    equal(sourceTask.decl.stages.run.perUnit, 740, "one recording uses its measured declaration")
    assert(host.scheduler.byId[sourceTask.id], "one-recorder task is re-enrolled")

    history:subscribe("GAlt", {
        armSwitch = "SFv",
        timeRange = "rolling",
        windowSeconds = 60,
    })
    awaitService(host, context, telemetry.entries[1].task.id)
    sourceTask = telemetry.entries[1].task
    equal(sourceTask.want, 2, "two recordings request both observer units")
    equal(sourceTask.decl.stages.run.perUnit, 320, "multiple recordings use their measured declaration")
    equal(sourceTask.decl.stages.run.maxUnits, 2, "the declaration tracks observer multiplicity")
    assert(host.scheduler.byId[sourceTask.id], "multi-recorder task is re-enrolled")
end

-- 1. Mixed, every task legacy: legacy work keeps its original cadence, its
-- declared cost is charged to the plan, and every panel and service is served.
do
    local definition, context = start("mixed", "host-light")
    local host = context.schedulerHost
    equal(host.mode, "mixed")
    assert(context.scheduler, "mixed builds a scheduler for the context")
    local served = 0
    callbacks(definition, context, 400, function(_, kind)
        local plan = context.scheduler.lastPlan
        equal(plan.kind, kind)
        assert(
            plan.U >= host.overhead[kind] + host.head + host.legacy.spent + scheduler.FIXED_COST,
            "the plan must count the head work and legacy cost as used"
        )
        if host.overhead[kind] + host.head + host.legacy.spent + scheduler.FIXED_COST > LIMIT then
            equal(plan.ran, 0, "negative room defers scheduled tasks without an error")
        else
            assert(plan.U <= LIMIT, "plan over the budget: " .. plan.U)
        end
        served = math.max(served, host.legacy.spent)
    end)
    assert(context.schedulerHost, "a layout the table covers stays on the host")
    assert(context.serviceRuntime.byId.telemetry.revision > 20, "scheduler-owned telemetry is still served")
    assert(served > 0, "the legacy loop charges what it runs")
    equal(#context.errors, 0, "no errors")
    local seen = {}
    for _, name in ipairs(refreshesIn(context, 1)) do
        seen[name] = true
    end
    assert(seen.altitude and seen.flights, "every panel is still refreshed")
    -- The head work reaches the plan: the flight tick runs in a steady callback.
    assert(host.head >= host.headCosts.tick, "the flight tick is passed as used")
end

-- 2. A chart keeps its exclusive legacy slot and its declared cost is charged.
do
    local definition, context = start("mixed", "host-chart")
    local host = context.schedulerHost
    local from, charts = 1, 0
    callbacks(definition, context, 300, function(_, kind)
        if kind == "steady" then
            local ran = refreshesIn(context, from)
            from = #context.dispatches + 1
            local chart = false
            for _, name in ipairs(ran) do
                chart = chart or name == "trace"
            end
            if chart then
                charts = charts + 1
                equal(#ran, 1, "a chart callback runs nothing else from the legacy loop")
                assert(host.legacy.spent >= host.PANEL_BOUNDS.chart, "the chart's declared cost is charged")
            end
        end
    end)
    assert(context.schedulerHost, "the chart layout loads with a share that covers the chart")
    assert(charts > 5, "the chart is still refreshed")
end

-- 3. The ownership flip on a stand-in service: one owner at a time, once per release.
do
    local definition, context = start("mixed", "host-light")
    local host = context.schedulerHost
    local task = standin.new({ due = getTime() })
    context.servicesModule.register(context.serviceRuntime, task, getTime())
    host.owners["service:standin"] = "legacy"
    host.serviceBounds.standin = standin.LEGACY_BOUND
    local calls = { legacy = 0, step = {} }
    local update, step = task.update, task.step
    task.update = function(self, now)
        calls.legacy = calls.legacy + 1
        return update(self, now)
    end
    task.step = function(self, grant, stage, now)
        calls.step[#calls.step + 1] = now
        return step(self, grant, stage, now)
    end
    local fed = 0
    local function feed()
        task.queue[#task.queue + 1] = 7
        fed = fed + 1
    end

    callbacks(definition, context, 80, feed)
    assert(calls.legacy >= 5, "a legacy-owned task is served by the legacy loop")
    equal(#calls.step, calls.legacy, "the extracted step is what the legacy loop calls")
    equal(context.scheduler.byId["service:standin"], nil)

    -- Flip: the legacy loop skips it, and the host registers its task.
    host.owners["service:standin"] = "new"
    host.checked = nil
    local legacyBefore, stepsBefore = calls.legacy, #calls.step
    local ranOn = {}
    callbacks(definition, context, 200, function(index, kind)
        feed(index)
        if #calls.step > stepsBefore + #ranOn then
            ranOn[#ranOn + 1] = kind
            assert(context.scheduler.lastPlan.ran >= 1)
        end
    end)
    assert(context.schedulerHost, "the flipped table still passes the load check")
    assert(context.scheduler.byId["service:standin"], "the host registered the task of the service it owns")
    equal(calls.legacy, legacyBefore, "a task owned by the framework is not run by the legacy loop")
    assert(#calls.step - stepsBefore >= 15, "the framework runs it")
    for index = stepsBefore + 2, #calls.step do
        assert(calls.step[index] - calls.step[index - 1] >= standin.INTERVAL, "one release at a time")
    end
    local background = 0
    for _, kind in ipairs(ranOn) do
        background = background + (kind == "background" and 1 or 0)
    end
    assert(background > 0, "services run in background callbacks too")
    equal(task.consumed + #task.queue, fed, "every sample is consumed once, by one owner")

    -- A failing task is retired and reported at the head of the next callback,
    -- which is consumed: no scheduler plan runs in it.
    task.step = function()
        error("stand-in failure")
    end
    local ranBefore = context.serviceRuntime.updates
    local failed = false
    callbacks(definition, context, 40, function()
        if not failed and context.scheduler.byId["service:standin"] == nil then
            failed = true
            context.scheduler.lastPlan.kind = "sentinel"
            fixture.tick(5)
            definition.refresh(context)
            equal(context.scheduler.lastPlan.kind, "sentinel", "the report callback is consumed")
        end
    end)
    assert(failed, "a failing task is retired")
    local reported = false
    for _, message in ipairs(context.errors) do
        reported = reported or string.find(message, "scheduler: service:standin: ", 1, true) ~= nil
    end
    assert(reported, "the failure is reported")
    assert(ranBefore <= context.serviceRuntime.updates)
end

-- 4. Invalid owner metadata is reported, but legacy work keeps running.
local function loadError(name, damage, expected)
    local definition, context = start("mixed", "host-light")
    damage(context.schedulerHost)
    context.panelTasksDirty = true
    callbacks(definition, context, 60)
    assert(context.schedulerHost, name .. ": retains the migrated scheduler task")
    assert(context.scheduler, name .. ": keeps the scheduler available")
    assert(logged(context, "scheduler: " .. expected), name .. ": logs '" .. expected .. "'")
    assert(#refreshesIn(context, 1) > 5, name .. ": legacy-owned panels keep serving")
end
loadError("no owner", function(host)
    host.owners["panel:metric"] = nil
end, "panel:metric has no owner")
loadError("no bound", function(host)
    host.panelBounds.metric = nil
end, "panel:metric has no declared bound")
loadError("owned but no task", function(host)
    host.owners["panel:metric"] = "new"
    local entry = host.context.panels[1]
    local module = {}
    for key, value in pairs(entry.module) do
        module[key] = value
    end
    module.step = nil
    entry.module = module
end, "panel:metric is owned by the scheduler but has no task")
loadError("Telemetry task missing step", function(host)
    local telemetry = host.context.serviceRuntime.byId.telemetry
    telemetry.tasks.maintenance.step = nil
    host.scheduler:remove("service:telemetry:maintenance")
    host.taskRevision = -1
end, "service:telemetry:maintenance: instance needs a step function")
do
    local definition, context = start("mixed", "host-light")
    context.schedulerHost.panelBounds.metric = context.schedulerHost.panelBounds.metric + 1000
    callbacks(definition, context, 60)
    assert(context.schedulerHost, "large legacy bounds do not invalidate mixed mode")
    equal(#context.errors, 0, "no-room handling is not an error")
    assert(#refreshesIn(context, 1) > 5, "legacy panels keep their original cadence")
end

-- 5. `new`: every loaded task must be owned by the framework, and there is no
-- legacy loop. Panel `background` hooks still run.
do
    local definition, context = start("new", "host-light")
    callbacks(definition, context, 5)
    equal(context.schedulerHost, nil, "legacy-owned tasks are a load error in new mode")
    assert(logged(context, "is not owned by the scheduler"))
end
do
    local definition, context = start("new", "host-light")
    local host = context.schedulerHost
    local runs = {}
    local function counting(key)
        runs[key] = 0
        return function(_, _, _, _)
            runs[key] = runs[key] + 1
            return 10
        end
    end
    -- The host registers the tasks of the services it owns, from their own declarations.
    for _, instance in ipairs(context.serviceRuntime.order) do
        local key = "service:" .. instance.id
        if instance.schedulerTasks then
            for _, item in ipairs(instance.schedulerTasks) do
                item.instance.decl = standin.decl
                item.instance.step = counting(item.id)
            end
        else
            instance.decl, instance.step = standin.decl, counting(key)
        end
        host.owners[key] = "new"
    end
    for _, entry in ipairs(context.panels) do
        local key = "panel:" .. entry.module.id
        entry.module.decl = {
            class = "normal",
            kinds = { steady = true },
            stages = standin.decl.stages,
        }
        entry.module.step = counting(key)
        entry.module.stageOf = nil
        host.owners[key] = "new"
    end
    callbacks(definition, context, 120)
    assert(context.schedulerHost, "every task owned by the framework passes")
    equal(context.serviceRuntime.updates, 0, "no legacy service update")
    equal(#refreshesIn(context, 1), 0, "no legacy panel refresh")
    local hooks = 0
    for _, dispatch in ipairs(context.dispatches) do
        hooks = hooks + (dispatch[3] == "background" and 1 or 0)
    end
    assert(hooks >= 60, "panel background hooks still run")
    local telemetryRuns = 0
    for key, count in pairs(runs) do
        if string.sub(key, 1, #"service:telemetry:") == "service:telemetry:" then
            telemetryRuns = telemetryRuns + count
        end
    end
    assert(telemetryRuns > 5 and runs["panel:metric"] > 5, "the framework runs the tasks")
end

-- 6. One scheduler per widget context.
do
    local definition, first = start("mixed", "host-light")
    local second = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "host-light", Theme = "modern-dark" },
        path
    )
    assert(first.scheduler and second.scheduler and first.scheduler ~= second.scheduler)
    assert(first.schedulerHost ~= second.schedulerHost)
    assert(first.schedulerHost.legacy ~= second.schedulerHost.legacy)
end

-- 7. Callbacks the head consumes run no plan (a session reset here), and modal
-- callbacks keep the legacy loop untouched.
do
    local definition, context = start("mixed", "host-light")
    callbacks(definition, context, 20)
    context.scheduler.lastPlan.kind = "sentinel"
    context.sessionResetPending = true
    local consumed = 0
    for _ = 1, 40 do
        fixture.tick(5)
        definition.refresh(context)
        if context.scheduler.lastPlan.kind == "sentinel" then
            consumed = consumed + 1
        end
    end
    assert(consumed > 0, "a consumed callback runs no scheduler")
    equal(context.sessionResetPending, nil, "the reset finishes")
    assert(context.scheduler.lastPlan.kind == "steady", "the scheduler runs again afterwards")
end

-- 8. The probe changes no behavior: the same scenario makes the same decisions
-- with and without it, in legacy mode.
local function decisions(probe)
    seed = 99
    local definition, context = start("legacy", "host-light", probe)
    local start = getTime()
    callbacks(definition, context, 200)
    local lines = {}
    for _, dispatch in ipairs(context.dispatches) do
        lines[#lines + 1] = table.concat({ dispatch[1] - start, dispatch[2], dispatch[3] }, ":")
    end
    return table.concat(lines, ","), context
end
do
    local plain = decisions(false)
    local probed, context = decisions(true)
    assert(probed == plain, "the probe changes no scheduling decision")
    local probe = context.probe
    assert(probe and context.schedulerHost.mode == "legacy")
    assert(#probe.differences > 0, "shadow mode notes where the planner would choose differently")
    assert(logged(context, "scheduler shadow"), "and logs it")
    equal(#probe.nearMisses, 0, "the tripwire is not armed by default")
end

-- 9. The tripwire flags usage above the previous callback's bound, and only then.
do
    local definition, context = start("mixed", "host-light", true)
    local probe = context.probe
    probe.armed = true
    local usage = 0
    probe.usage = function()
        return usage
    end
    callbacks(definition, context, 30)
    equal(#probe.nearMisses, 0, "usage under the bound is not flagged")
    local bound = context.scheduler.lastPlan.U
    usage = bound // 200
    callbacks(definition, context, 1)
    equal(#probe.nearMisses, 0, "usage at the bound is not flagged")
    usage = 75
    callbacks(definition, context, 4)
    assert(#probe.nearMisses > 0, "usage above the bound is flagged")
    assert(logged(context, "scheduler: near-miss"))
    -- A callback that skipped the scheduler leaves "no plan": nothing to compare.
    context.sessionResetPending = true
    fixture.tick(5)
    definition.refresh(context)
    equal(probe.record, nil, "a consumed callback records no plan")
    local flagged = #probe.nearMisses
    fixture.tick(5)
    definition.refresh(context)
    equal(#probe.nearMisses, flagged, "the callback after a consumed one is not compared")
end

-- 10. The model service is owned by the framework: the host registers its task once
-- something subscribes, the legacy loop leaves it alone, and it publishes as before.
do
    local definition, context = start("mixed", "host-model")
    local host, model = context.schedulerHost, context.serviceRuntime.byId.model
    equal(host.owners["service:model"], "new")
    equal(model.count, 5, "identity, flight mode, timer, TX voltage and battery range")
    local calls = { step = 0, grants = {} }
    local step = model.tasks.run.step
    model.tasks.run.step = function(self, grant, stage, now)
        calls.step = calls.step + 1
        calls.grants[grant] = true
        return step(self, grant, stage, now)
    end
    fixture.radio.flightMode = 2
    fixture.radio.flightModeNames[2] = "Sport"
    local first, revision = getTime(), model.revision
    callbacks(definition, context, 300, function(_, kind)
        assert(context.scheduler.lastPlan.U <= LIMIT, "plan over the budget")
        assert(context.schedulerHost, "the layout passes the load check")
    end)
    assert(context.scheduler.byId["service:model"], "the host registered the task")
    equal(model.tickElapsed, context.scheduler.elapsed, "uses the scheduler's wrap-safe tick helper")
    equal(model.update, nil, "the migrated service has no legacy update path")
    local releases = (getTime() - first) // model.interval
    assert(calls.step >= releases * 0.8 and calls.step <= releases + 1, "one release per interval: " .. calls.step)
    equal(model.revision - revision, calls.step, "every release counts as an update")
    equal(next(calls.grants), 4, "the grant is the cap, or what the subscriptions want")
    equal(model.flightModeView.index, 2, "values are published")
    equal(model.flightModeView.name, "Sport")
    equal(#context.errors, 0)

    -- Modal callbacks also run the migrated service through the scheduler.
    callbacks(definition, context, 3)
    model.due = getTime()
    context.scheduler.byId["service:model"].due = getTime()
    context.editorUi = {}
    local before = model.revision
    local previousSteps = calls.step
    local isFullScreen = lvgl.isFullScreen
    lvgl.isFullScreen = function()
        return true
    end
    for _ = 1, 10 do
        fixture.tick(1)
        definition.refresh(context)
        if calls.step > previousSteps then
            break
        end
    end
    lvgl.isFullScreen = isFullScreen
    context.editorUi = nil
    equal(model.update, nil, "the migrated service has no legacy update path")
    equal(calls.step, previousSteps + 1, "modal callback releases it through the scheduler")
    equal(model.revision, before + 1)

    -- A new layout or registry registers the tasks again, one task per service.
    host.checked = nil
    callbacks(definition, context, 3)
    awaitService(host, context, "service:model")
    assert(context.scheduler.byId["service:model"], "registered again")
    equal(context.scheduler.count, 1)

    -- A failing service is reported once and retired for good, here and in the legacy loop.
    model.facets[1].read = function()
        error("radio failure")
    end
    callbacks(definition, context, 60)
    equal(context.scheduler.byId["service:model"], nil, "retired")
    equal(model.failed, true, "marked failed for the legacy loop too")
    assert(logged(context, "radio failure"))
    local failures = 0
    for _, message in ipairs(context.errors) do
        failures = failures + (string.find(message, "radio failure", 1, true) and 1 or 0)
    end
    equal(failures, 1, "reported once")
    equal(model.update, nil, "the retired task still has no legacy update path")
end

-- Armed conditions have a distinct critical task; other switch readers stay on
-- Control's critical task. The flight broker's private runtime remains legacy.
do
    local definition, context = start("mixed", "host-light")
    local control = context.serviceRuntime.byId.control
    local armed = context.serviceRuntime.byId.armed
    assert(control.update == nil, "the dashboard control service is scheduler-only")
    callbacks(definition, context, 120)
    assert(context.scheduler.byId["service:armed"], "critical arm task is registered")
    equal(context.scheduler.byId["service:control"], nil, "armed inputs are not polled twice")
    assert(context.scheduler.byId["service:control-normal"], "normal entry task is registered")
    equal(context.scheduler.byId["service:control-outputs"], nil, "no output task without output subscriptions")
    equal(control.tasks.critical.decl.class, "critical")
    equal(control.tasks.normal.decl.class, "normal")
    assert(control.revision > 0, "scheduled control reads advance the shared revision")

    local feed
    for _, candidate in pairs(control.switches) do
        feed = candidate
        break
    end
    assert(feed and feed.available, "the Armed task publishes switch conditions")

    control.switchEntries.SFv.read = function()
        error("armed task failure")
    end
    for _ = 1, 20 do
        local task = context.scheduler.byId["service:armed"]
        if not task then
            break
        end
        task.due = getTime()
        fixture.tick(5)
        definition.refresh(context)
        if armed.failed then
            break
        end
    end
    assert(armed.failed, "the failed critical read retires the Armed service")
    fixture.tick(5)
    definition.refresh(context)
    equal(context.scheduler.byId["service:armed"], nil, "a failed Armed task is retired")
    assert(not control.failed, "an Armed failure does not retire unrelated control readers")
    equal(feed.available, false, "a failed Armed poll cannot leave a switch view available")
    assert(logged(context, "armed task failure"), "the failure is reported")
end

-- 11. A service nothing subscribes to has no task; demand queues bounded admission,
-- subscription, a panel the editor adds later included.
do
    local definition, context = start("mixed", "host-light")
    local model = context.serviceRuntime.byId.model
    equal(model.count, 0)
    callbacks(definition, context, 40)
    assert(context.schedulerHost, "an idle service passes the load check")
    equal(context.scheduler.byId["service:model"], nil, "nothing subscribes: no task")
    local voltage = model:txVoltage()
    callbacks(definition, context, 1)
    awaitService(context.schedulerHost, context, "service:model")
    assert(context.scheduler.byId["service:model"], "registered with the first subscription")
    callbacks(definition, context, 60)
    equal(voltage.available, true, "and read")
    equal(#context.errors, 0)
end

do
    local hostModule = fixture.module("lib/scheduler_host.lua")
    local service, backgroundOnly, hiddenPanel = standin.new(), standin.new(), standin.new()
    backgroundOnly.id = "background-only"
    backgroundOnly.decl = {
        class = "normal",
        kinds = { background = true },
        stages = standin.decl.stages,
    }
    service.queue, backgroundOnly.queue, hiddenPanel.queue = { 7 }, { 11 }, { 13 }
    local context = {
        panels = {},
        serviceRuntime = { order = { service, backgroundOnly }, byId = {} },
    }
    local scheduling = hostModule.attach(context, {
        mode = "mixed",
        load = fixture.module,
        api = {
            log = function(_, message)
                error(message)
            end,
        },
    })
    scheduling.owners = { ["service:standin"] = "new", ["service:background-only"] = "new" }
    assert(scheduling:ready(context))
    awaitService(scheduling, context, "service:standin")
    awaitService(scheduling, context, "service:background-only")
    for _, record in pairs(context.scheduler.byId) do
        record.due = getTime()
    end
    assert(context.scheduler:add({
        id = "panel:hidden",
        decl = standin.decl,
        instance = hiddenPanel,
        due = getTime(),
    }))
    context.scheduler:run("editor-build", getTime(), 3000)
    equal(service.consumed, 1, "services remain eligible during editor construction")
    equal(backgroundOnly.consumed, 0, "background-only services do not acquire foreground eligibility")
    equal(hiddenPanel.consumed, 0, "hidden panel tasks cannot run while editor construction owns the screen")
    equal(standin.decl.kinds, nil, "host eligibility must not mutate shared service declarations")
    equal(backgroundOnly.decl.kinds["editor-build"], nil)
    for _, kind in ipairs({
        "modal-log",
        "modal-settings",
        "modal-menu",
        "modal-location",
        "editor-render",
        "editor-drawer",
        "editor-input",
    }) do
        service.queue[#service.queue + 1] = 17
        context.scheduler:run(kind, getTime() + 50, 1500)
        equal(backgroundOnly.consumed, 0, "modal kinds do not admit background-only services")
        equal(hiddenPanel.consumed, 0, "modal kinds do not admit hidden panels")
        equal(backgroundOnly.decl.kinds[kind], nil)
        assert(service.consumed > 1, "measured modal kinds admit steady services")
    end
    context.scheduler:run("steady", getTime() + 100, 0)
    equal(hiddenPanel.consumed, 1, "ordinary panel eligibility remains unchanged")
    context.scheduler:run("background", getTime() + 200, 0)
    equal(backgroundOnly.consumed, 1, "background-only services retain their original kind")
end

do
    local _, context = start("mixed", "host-light")
    local host = context.schedulerHost
    local first, second = standin.new(), standin.new()
    local service = {
        id = "reset-test",
        count = 1,
        interval = 20,
        schedulerTasks = {
            { id = "service:reset-a", instance = first },
            { id = "service:reset-b", instance = second },
        },
    }
    host.owners["service:reset-a"], host.owners["service:reset-b"] = "new", "new"
    context.serviceRuntime.order[#context.serviceRuntime.order + 1] = service
    host:resync(context)
    awaitService(host, context, "service:reset-a")
    awaitService(host, context, "service:reset-b")
    local a, b = context.scheduler.byId["service:reset-a"], context.scheduler.byId["service:reset-b"]
    assert(context.scheduler:reschedule(a.id, getTime() + 1000))
    assert(context.scheduler:reschedule(b.id, getTime() + 2000))
    local nextIndex, message = host:resetServiceRelease(service, getTime(), 1)
    equal(nextIndex, 2)
    equal(message, nil)
    equal(context.scheduler:dueOf(a.id), getTime())
    equal(context.scheduler:dueOf(b.id), getTime() + 2000, "one release per callback")
    equal(host:resetServiceRelease(service, getTime(), nextIndex), nil)
    equal(context.scheduler:dueOf(b.id), getTime())
    equal(context.scheduler.byId[a.id], a)
    service.failed = true
    equal(host:resetServiceRelease(service, getTime(), 1), 2)
    equal(context.scheduler.byId[a.id], nil, "failed reset services cannot run")
    equal(context.scheduler.byId[b.id], b)
    host:resetServiceRelease(service, getTime(), 2)
    equal(context.scheduler.byId[b.id], nil)

    service.failed, service.count = nil, 0
    host:resync(context)
    assert(host:enroll() == nil)
    local resetTick = getTime()
    host:resetServiceRelease(service, resetTick, 1)
    host:resetServiceRelease(service, resetTick, 2)
    fixture.tick(100)
    service.count = 1
    awaitService(host, context, "service:reset-a")
    awaitService(host, context, "service:reset-b")
    equal(context.scheduler:dueOf(a.id), resetTick, "pending enrollment preserves reset release")
    equal(context.scheduler:dueOf(b.id), resetTick)
end

for _, scenario in ipairs({
    { kind = "refresh" },
    { kind = "background" },
    { kind = "refresh", reset = true },
    { kind = "background", reset = true },
    { kind = "refresh", fail = true },
}) do
    local kind = scenario.kind
    local definition, context = start("mixed", "host-light")
    local host, entry = context.schedulerHost, context.panels[1]
    host.owners["panel:metric"] = "new"
    context.panelTasksDirty = true
    settleHost(host, context)
    local task = assert(host.panelTasks[entry])
    entry.instance.refreshWork = { stage = "apply", drawn = {} }
    task.stage = "apply"
    assert(context.scheduler:reschedule(task.id, getTime() + 1000))
    local record = context.scheduler.byId[task.id]
    local module, resets, cancellations = {}, 0, 0
    for key, value in pairs(entry.module) do
        module[key] = value
    end
    if scenario.reset then
        module.resetSession = function()
            resets = resets + 1
            return nil, resets < 3
        end
    end
    module.cancelRefresh = function(instance)
        cancellations = cancellations + 1
        if scenario.fail then
            error("deliberate reset cancellation failure")
        end
        assert(not scenario.reset or resets == 3, "cancellation waits for the final reset stage")
        entry.instance.refreshWork = nil
        instance.rendered = nil
    end
    entry.module = module
    context.sessionResetPending = true
    for _ = 1, 200 do
        fixture.tick(1)
        definition[kind](context)
        if not context.sessionResetPending then
            break
        end
    end
    assert(not context.sessionResetPending, "reset finishes in " .. kind)
    equal(cancellations, 1)
    equal(resets, scenario.reset and 3 or 0)
    if scenario.fail then
        equal(entry.failed, true)
        equal(context.scheduler.byId[task.id], nil)
        assert(logged(context, "deliberate reset cancellation failure"))
    else
        equal(entry.instance.refreshWork, nil, "reset cancels captured frames even without a reset hook")
        equal(task.stage, "prepare", "cancelled task republishes its initial stage")
        equal(context.scheduler.byId[task.id], record)
        assert(context.scheduler.elapsed(getTime(), context.scheduler:dueOf(task.id)) >= 0)
        equal(#context.errors, 0)
    end
end

do
    local _, context = start("mixed", "host-light")
    local host, entry = context.schedulerHost, context.panels[1]
    host.owners["panel:metric"] = "new"
    local now = getTime()
    entry.instance.refreshWork = { stage = "render" }
    assert(not host:resetPanelRelease(entry, now))
    equal(entry.instance.refreshWork, nil)
    equal(entry.nextRefresh, now, "not-yet-enrolled panel retains the reset release")
    context.panelTasksDirty = true
    settleHost(host, context)
    equal(context.scheduler:dueOf(host.panelTasks[entry].id), now)
end

print("Scheduler host passed")
