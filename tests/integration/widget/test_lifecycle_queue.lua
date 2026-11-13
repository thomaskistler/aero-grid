-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 10)
context.flightFactory = nil
context.document.panels, context.emptyHint = { {} }, nil
context.serviceRuntime = context.servicesModule.runtime({})
local calls, loadSteps, reflowSteps = {}, 0, 0
local function record(kind)
    local task = assert(context.lifecycleTasks[kind])
    assert(task.cost == context.scheduler.capacity)
    calls[#calls + 1] = { kind = kind, callback = context.scheduler.callbacks }
end
context.dashboardLifecycle.retirePage = function()
    record("retire")
    context.reloadState = "rebuild"
end
context.dashboardLifecycle.rebuildPage = function()
    record("rebuild")
    context.reloadState = nil
end
context.dashboardLoader.beginLoad = function()
    context.stage = "probe"
end
context.dashboardLoader.advanceLoad = function()
    record("load")
    loadSteps = loadSteps + 1
    if loadSteps == 3 then
        context.stage = nil
    end
end
context.reloadState = "clear"
context.scheduler.cursor = 1
definition.refresh(context)
assert(#calls == 0 and context.lifecycleRequest == "retire", "host routing must not execute retirement")
definition.refresh(context)
assert(#calls == 1 and calls[1].kind == "retire" and context.lifecycleRequest == "rebuild")
assert(not context.lifecycleTasks.retire.pending, "retirement must not ask for a same-callback rebuild")
definition.background(context)
assert(#calls == 2 and calls[2].kind == "rebuild" and calls[2].callback > calls[1].callback)
assert(context.stage == "probe" and context.lifecycleRequest == "load")
local spentBefore = context.lifecycleTasks.load and context.lifecycleTasks.load.spent or 0
for index = 1, 3 do
    definition.background(context)
    assert(loadSteps == index, "one full-capacity stage runs per callback")
    assert(context.remainingSlots == 0)
    assert(context.lifecycleTasks.load.pending == (index < 3))
end
assert(not context.stage and not context.lifecycleRequest)
assert(context.lifecycleTasks.load.spent - spentBefore == 3 * context.scheduler.capacity)
context.stage = "probe"
local loadTask = context.lifecycleTasks.load
context.inputPending = true
assert(not loadTask.ready(loadTask, getTime(), false), "retained input takes priority over loader work")
assert(loadTask.ready(loadTask, getTime(), true), "hidden loading does not consume foreground input")
context.inputPending = false
context.editorPress = { started = getTime() }
assert(loadTask.ready(loadTask, getTime(), false))
fixture.tick(60)
assert(not loadTask.ready(loadTask, getTime(), false), "a due hold must return to input routing")
context.editorPress = nil
local previousMenu = context.aerogridMenu
context.aerogridMenu = { action = "probe" }
assert(not loadTask.ready(loadTask, getTime(), false), "native menu intents must preempt continued loading")
context.aerogridMenu = previousMenu
context.stage = nil

context.dashboardLifecycle.beginReflow = function()
    record("reflow")
    context.width, context.height = context.zone.w, context.zone.h
    context.reflowIndex = 1
end
context.dashboardLifecycle.advanceReflow = function()
    record("reflow")
    reflowSteps = reflowSteps + 1
    context.reflowIndex = reflowSteps < 2 and 2 or nil
end
context.zone.w = 320
context.lifecycleRequest = "reflow"
definition.background(context)
assert(reflowSteps == 0, "hidden callbacks must not advance reflow")
definition.refresh(context)
assert(context.lifecycleRequest == "reflow" and reflowSteps == 0)
definition.refresh(context)
assert(reflowSteps == 1 and context.lifecycleTasks.reflow.pending)
definition.refresh(context)
assert(reflowSteps == 2 and not context.lifecycleTasks.reflow.pending)

local retiredAt
context.appRebuild = { retired = false }
context.dashboardLifecycle.advanceAppRebuild = function()
    record("app rebuild")
    if not context.appRebuild.retired then
        context.appRebuild.retired = true
        retiredAt = context.scheduler.callbacks
    else
        assert(context.scheduler.callbacks > retiredAt, "panel reconstruction needs a later native callback")
        context.appRebuild = nil
    end
end
context.lifecycleRequest = "app rebuild"
definition.refresh(context)
assert(context.appRebuild.retired and not context.lifecycleTasks["app rebuild"].pending)
definition.background(context)
assert(context.appRebuild, "hidden callbacks must not advance App-mode reconstruction")
definition.refresh(context)
definition.refresh(context)
assert(not context.appRebuild and not context.lifecycleRequest)
