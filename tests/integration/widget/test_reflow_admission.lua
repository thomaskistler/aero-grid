-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local function loaded(kind)
    fixture.reset()
    fixture.lvglMock.setFullScreen(false)
    local context = fixture.createLoaded(nil, { Layout = "review-" .. kind, Theme = "modern-dark" })
    fixture.pump(context, 100, 10)
    assert(#context.errors == 0, table.concat(context.errors, "; "))
    return context
end

for _, kind in ipairs({
    "metric", "chart", "link-status", "rx-battery", "tx-battery", "navigation", "output",
    "state", "flight-timer", "flight-mode", "flight-counter", "model-identity", "trim-panel",
}) do
    local context = loaded(kind)
    local lifecycle, host = context.dashboardLifecycle, context.schedulerHost
    local runs, panelRuns = 0, 0
    local function task(id, kinds, due, step)
        assert(host.scheduler:add({
            id = id,
            decl = {
                class = "normal", kinds = kinds,
                stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
            },
            instance = { step = step }, due = due,
        }))
        return host.scheduler.byId[id]
    end
    local now = getTime()
    local service = task("service:reflow-probe", { loader = true }, now, function()
        runs = runs + 1
        return 15
    end)
    local future = task("service:reflow-future", { loader = true }, now + 100000, function()
        error("future service pulled forward")
    end)
    local futureDue = future.due
    local panel = task("panel:reflow-hidden", { steady = true, background = true }, now, function()
        panelRuns = panelRuns + 1
        return 10
    end)
    local panelDue = panel.due
    local begin, finish, dispatch = host.begin, host.finish, context.panelHost.dispatch
    local admission, reservation, expected
    host.begin = function(self, callbackKind)
        assert(callbackKind == "loader")
        local legacy = begin(self, callbackKind)
        reservation = legacy.spent
        return legacy
    end
    host.finish = function(self, callbackKind)
        assert(expected and not admission)
        assert(self.legacy.spent >= reservation + expected, "geometry must reserve before services run")
        admission = true
        return finish(self, callbackKind)
    end
    context.panelHost.dispatch = function(entry, event, ...)
        assert(event == "reflow" or event == "update", "geometry cannot dispatch hidden live panel work")
        assert(admission, "the enclosing reflow atom must be reserved before mutation")
        return dispatch(entry, event, ...)
    end
    local function call(background, operation)
        expected = lifecycle.workBound(context, operation)
        assert(expected and expected <= 4000, kind .. ": missing " .. operation .. " declaration")
        admission = false
        local due, before = service.due, runs
        fixture.tick(5)
        if background then
            definition.background(context)
        else
            definition.refresh(context)
        end
        fixture.lvglMock.settle()
        assert(admission, kind .. ": no service admission for " .. operation)
        if host.scheduler.elapsed(getTime(), due) < 0 then
            assert(service.due == due and runs == before, "future release must stay pending")
        elseif runs > before then
            assert(service.due == getTime() + 15, "execution alone advances the service deadline")
        end
        assert(future.due == futureDue and panel.due == panelDue and panelRuns == 0)
    end
    context.zone.w = context.zone.w + 20
    call(false, "beginReflow")
    assert(context.reflowIndex == 1 and not context.reflowEntry,
        "begin and panel advance must use separate callbacks")
    local stages = {}
    for turn = 1, 200 do
        if not context.reflowIndex then
            break
        end
        local index, entry = context.reflowIndex, context.reflowEntry
        local current = context.panels[index]
        local work = current and current.instance.reflowWork
        stages[work and work.stage or current and "begin" or "finish"] = true
        call(true, "waitReflow")
        assert(context.reflowIndex == index and context.reflowEntry == entry,
            "background waiting cannot advance geometry")
        if turn == 2 then
            context.zone.h = context.zone.h + 12
            call(false, "beginReflow")
            assert(context.reflowIndex == 1 and not context.reflowEntry)
        else
            call(false, "advanceReflow")
        end
    end
    host.begin, host.finish, context.panelHost.dispatch = begin, finish, dispatch
    assert(not context.reflowIndex and stages.finish and runs > 0)
    assert(#context.errors == 0, table.concat(context.errors, "; "))
end

do
    local context = loaded("metric")
    local lifecycle = context.dashboardLifecycle
    lifecycle.beginReflow(context)
    local panel = context.panels[1].module
    local declaration, callback = panel.reflowDecl, panel.reflow
    for _, invalid in ipairs({ {}, { callback = callback }, { callback = callback, bound = 4001 },
        { callback = callback, bound = -1 }, { callback = callback, bound = 1.5 },
        { callback = callback, bound = "4000" }, { callback = function() end, bound = 100 } }) do
        panel.reflowDecl = invalid
        assert(not lifecycle.workBound(context, "advanceReflow"))
        assert(not lifecycle.workBound(context, "waitReflow"))
    end
    panel.reflowDecl = declaration
    panel.reflow = function() return true end
    assert(not lifecycle.workBound(context, "advanceReflow"), "replaced callbacks invalidate measured proof")
    local host, runs = context.schedulerHost, 0
    assert(host.scheduler:add({
        id = "service:unproven-reflow",
        decl = {
            class = "normal", kinds = { loader = true },
            stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
        },
        instance = { step = function() runs = runs + 1; return 10 end },
        due = getTime(),
    }))
    local record = host.scheduler.byId["service:unproven-reflow"]
    local due, finish = record.due, host.finish
    host.finish = function()
        error("unknown geometry must not admit services")
    end
    for _, background in ipairs({ true, false }) do
        lifecycle.beginReflow(context)
        fixture.tick(5)
        if background then
            definition.background(context)
            assert(context.reflowIndex == 1 and not context.reflowEntry)
        else
            definition.refresh(context)
        end
        assert(runs == 0 and record.due == due, "an ineligible callback must preserve canonical releases")
    end
    host.finish = finish
    panel.reflow = callback
    context.reflowIndex = 1
    panel.reflowDecl = nil
    assert(not lifecycle.workBound(context, "advanceReflow"), "an ID is not a measured declaration")
    panel.reflowDecl = declaration
    assert(lifecycle.workBound(context, "advanceReflow") == declaration.bound)
    context.reflowIndex = #context.panels + 1
    context.errors = { string.rep("expected geometry error ", 128) }
    assert(lifecycle.workBound(context, "advanceReflow") == lifecycle.WORK_BOUNDS.reflowFinish)
    lifecycle.advanceReflow(context)
    assert(context.errorLabel and not context.reflowIndex)
    lifecycle.beginReflow(context)
    lifecycle.advanceReflow(context)
    assert(context.reflowEntry)
    context.reloadState = "clear"
    assert(not lifecycle.advanceReflow(context) and not context.reflowIndex and not context.reflowEntry)
end
print("Reflow admission: foreground geometry, background waiting, identity gates and canonical deadlines passed")
