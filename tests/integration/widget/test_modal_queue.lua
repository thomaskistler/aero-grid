-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local noGrant = assert(loadfile(root .. "/tests/support/no_grant.lua"))()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 20)
fixture.isolateWork(context)

local steps, inputs = 0, 0
context.modelSettingsUi = { build = 3 }
context.modelSettingsUiModule = {
    handle = function(_, event)
        inputs = inputs + 1
        if event == 991 then
            context.modelSettingsUi.closing = true
        end
    end,
    advance = function()
        local task = assert(context.uiTasks["model settings"])
        assert(task.cost == context.scheduler.budget.capacity)
        steps = steps + 1
        local state = context.modelSettingsUi
        if state.closing then
            context.modelSettingsUi = nil
        elseif state.build == 1 then
            state.build = nil
        else
            state.build = state.build - 1
        end
    end,
}
definition.refresh(context)
assert(
    steps == 0 and context.scheduler.state(context.menuTask).ran == context.scheduler.callbacks,
    "menu transition gets its own grant"
)
noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    definition.background(context)
    assert(steps == 0 and inputs == 0 and context.modelSettingsUi.build == 3)
end)
definition.background(context)
assert(steps == 1 and inputs == 0, "hidden modal work must not handle foreground input")
local modelTask = context.uiTasks["model settings"]
assert(context.scheduler.state(modelTask).pending, "settings fields continue when the grant is used up")
definition.refresh(context)
definition.refresh(context)
assert(steps == 3 and not context.uiRequest and not context.modelSettingsUi.build)
definition.refresh(context, 991)
assert(not context.inputQueue and steps == 3 and context.modelSettingsUi.closing)
assert(
    context.scheduler.state(context.inputTask).ran == context.scheduler.callbacks,
    "modal input gets a separate input grant"
)
definition.refresh(context)
assert(not context.modelSettingsUi and not context.inputQueue and steps == 4)
assert(not modelTask.ui, "closed modal objects must not stay reachable through a cached task")

local services = fixture.module("lib/services.lua")
context.serviceRuntime = services.runtime({})
local serviceUpdates, idleUiAdvances = 0, 0
local settingsUiModule = context.modelSettingsUiModule
services.register(context.serviceRuntime, {
    id = "modal progress",
    count = 1,
    interval = 0,
    revision = 0,
    update = function()
        serviceUpdates = serviceUpdates + 1
        return 0
    end,
}, 0)
context.modelSettingsUi = {
    modelFilename = context.flightFactory and context.flightFactory.broker.filename,
}
context.modelSettingsUiModule = {
    handle = function() end,
    advance = function()
        idleUiAdvances = idleUiAdvances + 1
        return false
    end,
}
definition.refresh(context, 992)
assert(not context.uiRequest, "ordinary modal input must not schedule a no-op UI turn")
assert(serviceUpdates > 0, "ordinary modal input must leave slots for subscribed services")
local updatesBeforeIdle = serviceUpdates
for _ = 1, 5 do
    fixture.tick(10)
    definition.refresh(context)
end
assert(serviceUpdates > updatesBeforeIdle, "an idle foreground settings modal must not starve subscribed services")
assert(idleUiAdvances == 0, "an idle modal must not reserve a host turn")
context.modelSettingsUi, context.modelSettingsUiModule = nil, settingsUiModule

context.logViewer = { width = context.zone.w - 16, height = context.zone.h, prepareIndex = 3 }
context.logViewerModule = {
    advance = function()
        local task = assert(context.uiTasks["log viewer"])
        assert(task.cost == context.scheduler.budget.capacity)
        steps = steps + 1
        context.logViewer.prepareIndex = context.logViewer.prepareIndex > 1 and context.logViewer.prepareIndex - 1
            or nil
    end,
}
definition.refresh(context)
assert(context.uiRequest == "log viewer" and steps == 5, "routing and preparation share a callback")
definition.background(context)
assert(steps == 5, "hidden callbacks must not prepare log text")

local broker = {
    documentLoaded = true,
    filename = context.aerogridMenu.modelFilename,
    tasks = function()
        return {}
    end,
}
local flightSteps = 0
context.flightFactory = { broker = broker }
context.flightTask = {
    broker = broker,
    step = function(_, _, slots)
        flightSteps = flightSteps + 1
        return slots, false
    end,
}
fixture.requeue(context)
definition.refresh(context)
assert(flightSteps == 1 and steps == 5, "flight's charged turn must defer the full-capacity viewer")
definition.refresh(context)
assert(flightSteps == 1 and steps == 6, "the deferred viewer gets first turn next callback")
local viewerTask = context.uiTasks["log viewer"]
assert(context.scheduler.state(viewerTask).pending)
context.flightFactory = nil
definition.refresh(context)
definition.refresh(context)
assert(steps == 7 and not context.uiRequest and not context.scheduler.state(viewerTask).pending)

-- A native close can invalidate a retained request before its next grant.
context.uiRequest = "log viewer"
context.logViewer = nil
definition.refresh(context)
definition.refresh(context)
assert(steps == 7 and not context.uiRequest)
assert(not viewerTask.ui, "a native close must release the cached viewer reference")

context.modelSettingsUi, context.reloadState = {}, "clear"
definition.refresh(context, 991)
assert(not context.inputQueue and context.modelSettingsUi.closing, "settings Exit precedes its pending reload")
definition.refresh(context)
assert(
    not context.modelSettingsUi and context.reloadState == "clear",
    "modal close has its own grant before retirement"
)
