-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local definition = fixture.module("main.lua")
local function prepare(context)
    for _ = 1, 200 do
        context.dashboardLifecycle.advanceAppRebuild(context)
        if context.appRebuild.phase ~= "prepare" then
            return
        end
        assert(not context.appRebuild.prepared and not context.pendingConstruction)
    end
    error("App preparation did not finish")
end
local function loaded(kind)
    fixture.reset()
    local context = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "review-" .. kind, Theme = "modern-dark" },
        root .. "/build/test-widget-fixture/"
    )
    assert(fixture.pumpUntil(context, function()
        return not context.stage
    end, 300, 10))
    return context
end
local function retire(context)
    local oldPage = context.page
    context.dashboardLifecycle.retirePage(context)
    assert(not context.reflowEntry and not context.reflowIndex and not context.pendingConstruction)
    for _ = 1, 1000 do
        if context.reloadState ~= "clear" then
            break
        end
        local count = #context.panels
        context.dashboardLifecycle.retirePage(context)
        assert(count - #context.panels <= 1, "retirement must release at most one placement per turn")
        assert(not context.dashboardLifecycle.advanceReflow(context), "retired geometry cannot resume")
        fixture.lvglMock.settle()
    end
    assert(context.reloadState == "rebuild" and not context.pageRetirement)
    assert(not context.page and not context.canvas and not context.appRebuild and #context.panels == 0)
    context.dashboardLifecycle.rebuildPage(context)
    assert(context.page ~= oldPage and not context.page.invalid)
    context.dashboardLoader.beginLoad(context)
    assert(fixture.pumpUntil(context, function()
        return not context.stage
    end, 300, 10))
    for _, entry in ipairs(context.panels) do
        assert(not entry.container.invalid and not entry.container.hidden)
    end
end

for _, kind in ipairs({
    "metric",
    "chart",
    "navigation",
    "output",
    "state",
    "rx-battery",
    "link-status",
    "tx-battery",
    "flight-timer",
    "flight-counter",
    "flight-mode",
    "model-identity",
    "trim-panel",
}) do
    local context = loaded(kind)
    local originals = {}
    for index, entry in ipairs(context.panels) do
        originals[index] = entry
    end
    for index, original in ipairs(originals) do
        local placement = original.placement
        if index % 2 == 1 then
            context.fullscreenContainers = context.fullscreenContainers or {}
            context.fullscreenContainers[original.container] = true
        end
        context.appRebuild = { entry = original, index = index }
        local job = context.appRebuild
        assert(context.dashboardLifecycle.workBound(context, "advanceAppRebuild"))
        context.dashboardLifecycle.advanceAppRebuild(context)
        fixture.lvglMock.settle()
        assert(job.phase == "prepare")
        assert(#context.panels == #originals - 1 and original.container.hidden)
        prepare(context)
        assert(job.prepared and job.phase == "build")
        local create, calls = job.prepared.module.create, 0
        job.prepared.module.create = function(...)
            calls = calls + 1
            return create(...)
        end
        for turn = 1, 100 do
            if not context.appRebuild then
                break
            end
            if turn == 2 and context.pendingConstruction then
                context.zone = { x = 0, y = 0, w = 640, h = 360 }
            end
            context.dashboardLifecycle.advanceAppRebuild(context)
            if context.pendingConstruction then
                assert(context.pendingConstruction.container.hidden)
                assert(#context.panels == #originals - 1, "partial builds cannot publish")
            end
            fixture.lvglMock.settle()
        end
        job.prepared.module.create = create
        assert(calls == 1 and not context.appRebuild and not context.pendingConstruction)
        local rebuilt = assert(context.panels[index])
        assert(rebuilt ~= original and rebuilt.placement == placement and rebuilt.module == job.prepared.module)
        assert(#context.panels == #originals and not rebuilt.container.invalid and not rebuilt.container.hidden)
        if index % 2 == 1 then
            assert(rebuilt.container ~= original.container, "fullscreen-native containers cannot be reused in App mode")
        else
            assert(rebuilt.container == original.container, "App-native containers retain their ownership")
        end
        assert(context.panelTasksDirty)
        local services = context.dashboardLoader.buildServices(context, placement)
        local rect = context.dashboardLoader.panelRect(context, placement)
        local expected = rebuilt.module.create(
            lvgl.box(context.page, { x = rect.x, y = rect.y, w = rect.w, h = rect.h }),
            { x = 0, y = 0, w = rect.w, h = rect.h },
            rebuilt.settings,
            services
        )
        if not rebuilt.module.idle then
            for _, instance in ipairs({ rebuilt.instance, expected }) do
                local task = context.panelHost.task({ module = rebuilt.module, instance = instance, interval = 20 })
                local completed = false
                for _ = 1, 2000 do
                    if task:step(task.want or 1, task.stage, getTime()) ~= 1 then
                        completed = true
                        break
                    end
                    if kind == "output" then
                        fixture.pump(context, 1, 10)
                    end
                end
                assert(completed, kind .. ": rebuilt panel task must finish (stage " .. tostring(task.stage) .. ")")
            end
        end
        sameTree(expected.root or expected.panel.root, rebuilt.instance.root or rebuilt.instance.panel.root, kind)
    end
    retire(context)
end

for _, phase in ipairs({ "retire", "prepare", "build", "construct", "finish" }) do
    for _, replacement in ipairs({ false, true }) do
        local context = loaded("chart")
        local entry = context.panels[1]
        context.appRebuild = { entry = entry, index = 1 }
        for _ = 1, 100 do
            if (context.appRebuild.phase or "retire") == phase then
                break
            end
            context.dashboardLifecycle.advanceAppRebuild(context)
            fixture.lvglMock.settle()
        end
        assert((context.appRebuild.phase or "retire") == phase)
        if replacement then
            context.dashboardLoader.beginLoad(context)
            context.dashboardLifecycle.advanceAppRebuild(context)
            assert(not context.appRebuild and not context.pendingConstruction)
            assert(#context.panels == 0, "a replacement load must not receive stale publication")
        else
            assert(context.dashboardLifecycle.workBound(context, "retirePage"))
            retire(context)
        end
    end
end

for _, failure in ipairs({ "prepare", "create", "construct", "destroy" }) do
    local context = loaded("chart")
    local entry = context.panels[1]
    local count = #context.panels
    context.appRebuild = { entry = entry, index = 1 }
    if failure == "create" or failure == "construct" then
        context.dashboardLifecycle.advanceAppRebuild(context)
        fixture.lvglMock.settle()
        prepare(context)
    end
    local target = failure == "prepare" and context.dashboardLoader
        or (failure == "destroy" and entry.module or context.appRebuild.prepared.module)
    local key = failure == "prepare" and "advancePreparation" or failure
    local original = target[key]
    target[key] = function()
        if failure == "prepare" then
            return true
        end
        error("expected lifecycle " .. failure .. " failure")
    end
    if failure == "destroy" then
        assert(
            not context.dashboardLifecycle.workBound(context, "advanceAppRebuild"),
            "unmeasured third-party destroy hooks cannot be co-admitted"
        )
    end
    for _ = 1, 100 do
        if not context.appRebuild then
            break
        end
        context.dashboardLifecycle.advanceAppRebuild(context)
        fixture.lvglMock.settle()
    end
    target[key] = original
    assert(not context.appRebuild and not context.pendingConstruction)
    if failure ~= "prepare" then
        assert(#context.errors > 0)
    end
    if failure ~= "destroy" then
        assert(#context.panels == count - 1)
    end
end

local context = loaded("metric")
fixture.lvglMock.setFullScreen(true)
assert(fixture.pumpUntil(context, function()
    return context.aeroMenuHandlers ~= nil
end, 100, 10))
context.aeroMenuHandlers.modelSettings()
assert(fixture.pumpUntil(context, function()
    return context.modelSettingsUi and not context.modelSettingsUi.build
end, 300, 10))
local state = context.modelSettingsUi
local revision = state.revision
state.pending = { key = "motorReversed", value = not state.values.motorReversed }
context.modelSettingsUiModule.advance(context)
assert(state.saving, "test requires an already confirmed store job")
local page, count = context.page, #context.panels
fixture.lvglMock.setFullScreen(false)
context.dashboardLifecycle.retirePage(context)
assert(context.pageRetirement.phase == "settings")
local settingsBound = context.dashboardLifecycle.workBound(context, "retirePage")
assert(settingsBound and settingsBound > context.modelSettingsUiModule.workBound(context))
assert(settingsBound <= context.dashboardLifecycle.WORK_BOUNDS.settingsDrain)
for _ = 1, 1000 do
    if not context.modelSettingsUi then
        break
    end
    context.dashboardLifecycle.retirePage(context)
    assert(not page.cleared and #context.panels == count, "confirmed save drains before any native destruction")
    fixture.lvglMock.settle()
end
assert(not context.modelSettingsUi and context.flightBroker.document.revision == revision + 1)
assert(context.flightBroker.document.flight.motorReversed == state.values.motorReversed)
retire(context)

context = loaded("metric")
local menuRoot = lvgl.box(context.root, { x = 0, y = 0, w = 24, h = 24 })
local menuScreen = lvgl.box(context.root, { x = 0, y = 0, w = context.zone.w, h = context.zone.h })
context.aerogridMenu = {
    root = menuRoot, screen = menuScreen, generation = 1, open = true, pending = true,
}
context.nativeDialogsCreated = true
context.dashboardLifecycle.retirePage(context)
for _ = 1, 100 do
    if context.pageRetirement.phase == "menu" then
        break
    end
    context.dashboardLifecycle.retirePage(context)
    fixture.lvglMock.settle()
end
assert(context.pageRetirement.phase == "menu")
assert(context.dashboardLifecycle.workBound(context, "retirePage") ==
    context.dashboardLifecycle.WORK_BOUNDS.menuClose)
context.dashboardLifecycle.retirePage(context)
assert(not context.aerogridMenu and menuRoot.hidden and menuScreen.hidden)

context = loaded("metric")
local customClosed = false
context.aeroMenuModule = {
    RUNTIME_API = 1,
    close = function()
        customClosed = true
    end,
}
context.aerogridMenu = { root = lvgl.box(context.root, { x = 0, y = 0, w = 24, h = 24 }) }
context.nativeDialogsCreated = true
context.dashboardLifecycle.retirePage(context)
for _ = 1, 100 do
    if context.pageRetirement.phase == "menu" then
        break
    end
    context.dashboardLifecycle.retirePage(context)
end
assert(not context.dashboardLifecycle.workBound(context, "retirePage"),
    "custom menu close callbacks remain ineligible")
context.dashboardLifecycle.retirePage(context)
assert(customClosed and not context.aerogridMenu)

context = loaded("metric")
context.pageRetirement = { phase = "settings" }
context.modelSettingsUi = { saving = { phase = "store" } }
context.modelSettingsUiModule = { RUNTIME_API = 1 }
assert(not context.dashboardLifecycle.workBound(context, "retirePage"),
    "settings without the measured drain continuation remain ineligible")

context = loaded("metric")
local oldPage = context.page
fixture.lvglMock.setDeferCleanup(true)
context.dashboardLifecycle.retirePage(context)
for _ = 1, 100 do
    if context.reloadState ~= "clear" then
        break
    end
    context.dashboardLifecycle.retirePage(context)
end
assert(context.reloadState == "rebuild")
context.dashboardLifecycle.rebuildPage(context)
context.dashboardLoader.beginLoad(context)
assert(fixture.pumpUntil(context, function()
    return not context.stage
end, 300, 10))
fixture.lvglMock.setDeferCleanup(false)
fixture.lvglMock.settle()
assert(context.page ~= oldPage and not context.page.invalid)
for _, entry in ipairs(context.panels) do
    assert(not entry.container.invalid, "deferred old-page cleanup cannot collect the replacement page")
end
print("Dashboard lifecycle: staged rebuild parity, bounded retirement, cancellation and confirmed save draining passed")
