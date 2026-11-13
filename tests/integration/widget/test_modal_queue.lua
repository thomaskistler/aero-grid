-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local noGrant = assert(loadfile(root .. "/tests/support/no_grant.lua"))()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 20)
context.flightFactory = nil
context.document.panels, context.emptyHint = { {} }, nil
context.serviceRuntime = context.servicesModule.runtime({})

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
        assert(task.cost == context.scheduler.capacity)
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
assert(steps == 0 and context.menuTask.ran == context.scheduler.callbacks, "menu transition gets its own grant")
noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    definition.background(context)
    assert(steps == 0 and inputs == 0 and context.modelSettingsUi.build == 3)
end)
definition.background(context)
assert(steps == 1 and inputs == 0, "hidden modal work must not handle foreground input")
local modelTask = context.uiTasks["model settings"]
assert(not modelTask.pending, "modal transitions must retain native callback separation")
definition.refresh(context)
definition.refresh(context)
assert(steps == 3 and not context.uiRequest and not context.modelSettingsUi.build)
definition.refresh(context, 991)
assert(not context.inputQueue and steps == 3 and context.modelSettingsUi.closing)
assert(context.inputTask.ran == context.scheduler.callbacks, "modal input gets a separate input grant")
definition.refresh(context)
assert(not context.modelSettingsUi and not context.inputQueue and steps == 4)
assert(not modelTask.ui, "closed modal objects must not stay reachable through a cached task")

context.logViewer = { width = context.zone.w - 16, height = context.zone.h, prepareIndex = 3 }
context.logViewerModule = {
    advance = function()
        local task = assert(context.uiTasks["log viewer"])
        assert(task.cost == context.scheduler.capacity)
        steps = steps + 1
        context.logViewer.prepareIndex = context.logViewer.prepareIndex > 1 and context.logViewer.prepareIndex - 1
            or nil
    end,
}
definition.refresh(context)
assert(context.uiRequest == "log viewer" and steps == 4)
definition.background(context)
assert(steps == 4, "hidden callbacks must not prepare log text")
definition.refresh(context)
assert(steps == 4 and context.uiRequest == "log viewer")

local broker, flightSteps = { documentLoaded = true, filename = context.aerogridMenu.modelFilename }, 0
context.flightFactory = { broker = broker }
context.flightTask = {
    broker = broker,
    step = function()
        flightSteps = flightSteps + 1
    end,
}
context.scheduler.cursor = 1
definition.refresh(context)
assert(flightSteps == 1 and steps == 4, "flight's charged turn must defer the full-capacity viewer")
definition.refresh(context)
assert(flightSteps == 1 and steps == 5, "the deferred viewer gets first turn next callback")
local viewerTask = context.uiTasks["log viewer"]
assert(viewerTask.pending)
context.inputPending = true
assert(not viewerTask.ready(viewerTask, getTime(), false), "input must preempt log preparation")
context.inputPending = false
context.flightFactory = nil
definition.refresh(context)
definition.refresh(context)
assert(steps == 7 and not context.uiRequest and not viewerTask.pending)

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
