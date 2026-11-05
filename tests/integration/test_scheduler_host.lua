-- SPDX-License-Identifier: GPL-2.0-only

-- The development scheduler host in the real widget: `mixed` and `new` modes, the
-- owner table, the legacy share, the call sites, the load errors, and the probe.
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

-- Starts a widget in `mode` on `layoutName` and loads it. Every panel dispatch is
-- logged as `{ tick, panel id, event }` in `context.dispatches`.
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

-- 0. The owner table and the declared bounds cover every service and panel type, so
-- a new one cannot be added without an owner and a bound (theme-showcase has no
-- bound: a layout with it cannot run in mixed).
do
    local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler_host.lua"))()
    local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
    local expected, boundsExpected = {}, {}
    for _, definition in ipairs(services.DEFINITIONS) do
        expected["service:" .. definition.id] = true
        assert(host.SERVICE_BOUNDS[definition.id], "service " .. definition.id .. " needs a declared bound")
    end
    local listingPath = root .. "/build/scheduler-panel-types.txt"
    os.execute("ls '" .. root .. "/src/WIDGETS/AeroGrid/panels' > '" .. listingPath .. "'")
    local listing = assert(hostIo.open(listingPath, "r"))
    for name in listing:lines() do
        local panel = string.match(name, "^(.+)%.lua$")
        if panel then
            expected["panel:" .. panel] = true
            boundsExpected[panel] = panel ~= "theme-showcase"
        end
    end
    listing:close()
    os.remove(listingPath)
    for key in pairs(expected) do
        assert(host.OWNERS[key] == "legacy", key .. " needs an owner, `legacy` until it migrates")
    end
    for key in pairs(host.OWNERS) do
        assert(expected[key], key .. " is in the owner table but is no service or panel")
    end
    for panel, wanted in pairs(boundsExpected) do
        equal(host.PANEL_BOUNDS[panel] ~= nil, wanted, "declared bound of panel " .. panel)
    end
end

-- 1. Mixed, every task legacy: the legacy loop stays inside its share and the plan
-- inside the budget, and every panel and service is still served.
do
    local definition, context = start("mixed", "host-light")
    local host = context.schedulerHost
    equal(host.mode, "mixed")
    assert(context.scheduler, "mixed builds a scheduler for the context")
    local served = 0
    callbacks(definition, context, 400, function(_, kind)
        local plan = context.scheduler.lastPlan
        equal(plan.kind, kind)
        assert(host.share.spent <= host.share.limit, "the legacy loop passed its share: " .. host.share.spent)
        assert(plan.U <= LIMIT, "plan over the budget: " .. plan.U)
        assert(
            plan.U >= host.overhead[kind] + host.head + host.share.spent + scheduler.FIXED_COST,
            "the plan must count the head work and the legacy share as used"
        )
        served = math.max(served, host.share.spent)
    end)
    assert(context.schedulerHost, "a layout the table covers stays on the host")
    assert(context.serviceRuntime.updates > 20, "services are still served")
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

-- 2. A chart takes the whole legacy share: one per callback, nothing else from legacy.
do
    local definition, context = start("mixed", "host-chart")
    local host = context.schedulerHost
    host.share.limit = 10190
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
                equal(host.share.spent, host.share.limit, "the chart is charged the whole share")
            end
        end
        assert(host.share.spent <= host.share.limit)
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

    -- Flip: the legacy loop skips it, the framework runs it.
    host.owners["service:standin"] = "new"
    host.checked = nil
    local added, reason = context.scheduler:add({
        id = "service:standin",
        decl = standin.decl,
        instance = task,
        due = getTime(),
    })
    assert(added, reason)
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

-- 4. Load errors: the host logs once and falls back to the plain legacy loop.
local function loadError(name, damage, expected)
    local definition, context = start("mixed", "host-light")
    damage(context.schedulerHost)
    callbacks(definition, context, 60)
    equal(context.schedulerHost, nil, name .. ": falls back to legacy")
    equal(context.scheduler, nil)
    assert(logged(context, "scheduler: " .. expected), name .. ": logs '" .. expected .. "'")
    assert(#refreshesIn(context, 1) > 5, name .. ": the legacy loop keeps serving")
    assert(context.serviceRuntime.updates > 5)
end
loadError("share too small", function(host)
    host.share.limit = 1000
end, "service:telemetry exceeds the legacy share")
loadError("no owner", function(host)
    host.owners["panel:metric"] = nil
end, "panel:metric has no owner")
loadError("no bound", function(host)
    host.panelBounds.metric = nil
end, "panel:metric has no declared bound")
loadError("owned but no task", function(host)
    host.owners["service:model"] = "new"
end, "service:model is owned by the scheduler but has no task")
loadError("an unbounded chart", function(host)
    host.owners["panel:flight-counter"] = "legacy"
    host.panelBounds["flight-counter"] = host.share.limit + 1
end, "panel:flight-counter exceeds the legacy share")

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
    local function dummy(key)
        runs[key] = 0
        local ok, reason = context.scheduler:add({
            id = key,
            decl = standin.decl,
            instance = {
                step = function(_, _, _, _)
                    runs[key] = runs[key] + 1
                    return 10
                end,
            },
            due = getTime(),
        })
        assert(ok, reason)
        host.owners[key] = "new"
    end
    for key in pairs(host.owners) do
        dummy(key)
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
    assert(runs["service:telemetry"] > 5 and runs["panel:metric"] > 5, "the framework runs the tasks")
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
    assert(first.schedulerHost.share ~= second.schedulerHost.share)
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

print("Scheduler host passed")
