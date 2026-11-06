-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local function loaded()
    fixture.reset()
    fixture.lvglMock.setFullScreen(false)
    local context = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" })
    fixture.pump(context, 100, 10)
    return context
end

for _, case in ipairs({ "retirePage", "advanceAppRebuild", "advanceAppRebuildErrors" }) do
    local operation = case == "advanceAppRebuildErrors" and "advanceAppRebuild" or case
    for _, background in ipairs({ false, true }) do
        local context = loaded()
        local lifecycle, scheduling = context.dashboardLifecycle, context.schedulerHost
        local serviceRuns, panelRuns = 0, 0
        local function add(id, kinds, callback, due)
            assert(scheduling.scheduler:add({
                id = id,
                decl = {
                    class = "normal",
                    kinds = kinds,
                    stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
                },
                instance = { step = callback },
                due = due,
            }))
            return scheduling.scheduler.byId[id]
        end
        local now = getTime()
        local service = add("service:lifecycle-probe", { loader = true }, function(_, _, _, stamp)
            serviceRuns = serviceRuns + 1
            assert(stamp == getTime())
            return 15
        end, now)
        local future = add("service:lifecycle-future", { loader = true }, function()
            error("a future service release was pulled forward")
        end, now + 100000)
        local futureDue = future.due
        local panel = add("panel:lifecycle-probe", { steady = true, background = true }, function()
            panelRuns = panelRuns + 1
            return 10
        end, now)
        local panelDue = panel.due
        if operation == "retirePage" then
            context.reloadState = "clear"
        else
            context.appRebuild = { entry = context.panels[1], index = 1 }
            if case == "advanceAppRebuildErrors" then
                context.errors[1] = "expected lifecycle error"
            end
        end
        local seen, admittedPhases = {}, {}
        for _ = 1, 150 do
            if
                operation == "retirePage" and context.reloadState == "rebuild"
                or operation == "advanceAppRebuild" and not context.appRebuild
            then
                break
            end
            local job = operation == "retirePage" and context.pageRetirement or context.appRebuild
            local phase = job and job.phase or (operation == "retirePage" and "cancel" or "retire")
            local expected = lifecycle.workBound(context, operation)
            local advanced, admitted, reserved = false, false
            local advance, begin, finish = lifecycle[operation], scheduling.begin, scheduling.finish
            local dispatch = context.panelHost.dispatch
            lifecycle[operation] = function(...)
                advanced = true
                assert(admitted == (expected ~= nil), "admission must use the phase before mutation")
                return advance(...)
            end
            scheduling.begin = function(self, kind)
                assert(kind == "loader", "lifecycle must use the existing service-only loading kind")
                assert(not admitted)
                local legacy = begin(self, kind)
                reserved = legacy and legacy.spent
                return legacy
            end
            scheduling.finish = function(self, kind)
                admitted = true
                assert(self.legacy.spent >= reserved + expected, "lifecycle work must be reserved before services")
                return finish(self, kind)
            end
            context.panelHost.dispatch = function(entry, event, ...)
                assert(
                    event ~= "refresh" and event ~= "step" and event ~= "background",
                    "lifecycle callbacks cannot dispatch hidden live panels"
                )
                return dispatch(entry, event, ...)
            end
            local due, runs = service.due, serviceRuns
            fixture.tick(5)
            if background then
                definition.background(context)
            else
                definition.refresh(context)
            end
            fixture.lvglMock.settle()
            lifecycle[operation], scheduling.begin, scheduling.finish, context.panelHost.dispatch =
                advance, begin, finish, dispatch
            assert(advanced, "foreground and background must both advance lifecycle work")
            seen[phase] = true
            if admitted then
                admittedPhases[phase] = true
            end
            if not expected or scheduling.scheduler.elapsed(getTime(), due) < 0 then
                assert(
                    serviceRuns == runs and service.due == due,
                    "ineligible work and future releases must preserve the canonical service deadline"
                )
            elseif serviceRuns > runs then
                assert(service.due == getTime() + 15, "only execution releases the next service deadline")
            end
            assert(panelRuns == 0 and panel.due == panelDue, "hidden panel releases must remain pending")
            assert(future.due == futureDue, "admission cannot rewrite a future service release")
        end
        assert(serviceRuns > 0 and next(admittedPhases), "administrative stages must run due services")
        if operation == "retirePage" then
            assert(context.reloadState == "rebuild" and not context.pageRetirement)
            for _, phase in ipairs({ "cancel", "settings", "panel", "pending", "menu", "page", "finalize" }) do
                assert(admittedPhases[phase], phase .. " lost service-only admission")
            end
            local finish, called = scheduling.finish, nil
            scheduling.finish = function(self, kind, ...)
                called = kind
                assert(self.legacy.spent >= scheduling.panelSetup + 600, "restart must reserve the complete operation")
                return finish(self, kind, ...)
            end
            if background then
                definition.background(context)
            else
                definition.refresh(context)
            end
            scheduling.finish = finish
            assert(called == "loader" and context.stage, "page restart must admit services before beginning the load")
            assert(panelRuns == 0 and panel.due == panelDue, "page restart cannot release hidden panels")
            assert(future.due == futureDue, "page restart cannot pull future service deadlines forward")
        else
            assert(not context.appRebuild)
            assert(admittedPhases.retire and admittedPhases.finish)
            for _, phase in ipairs({ "prepare", "build", "construct" }) do
                assert(seen[phase] and not admittedPhases[phase], phase .. " must retain its unproven gate")
            end
        end
        if case == "advanceAppRebuildErrors" then
            assert(#context.errors == 1 and context.errors[1] == "expected lifecycle error")
            assert(context.errorLabel, "admitted App finish must present accumulated errors")
        else
            assert(#context.errors == 0, table.concat(context.errors, "; "))
        end
    end
end

for _, background in ipairs({ false, true }) do
    local context = loaded()
    context.zone.w = context.zone.w + 8
    context.dashboardLifecycle.beginReflow(context)
    local finish, called = context.schedulerHost.finish, false
    context.schedulerHost.finish = function(...)
        called = true
        return finish(...)
    end
    fixture.tick(5)
    if background then
        definition.background(context)
    else
        definition.refresh(context)
    end
    context.schedulerHost.finish = finish
    assert(not called and context.reflowIndex, "reflow remains a separate unproven admission gate")
end

do
    local context = loaded()
    local entry = context.panels[1]
    context.appRebuild = { entry = entry, phase = "retire" }
    entry.module.destroy = function() end
    assert(
        not context.dashboardLifecycle.workBound(context, "advanceAppRebuild"),
        "unmeasured custom destroy remains ineligible"
    )
end
print("Lifecycle foreground/background service-only admission preserves hidden-panel and service deadlines")
