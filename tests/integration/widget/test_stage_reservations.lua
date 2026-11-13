-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 30)
local flights, steps, grants = 0, {}, {}
local broker = context.flightFactory.broker
context.flightTask = {
    name = "flight",
    owner = "flight",
    broker = broker,
    step = function()
        flights = flights + 1
    end,
}
local stages = { "header-migrate", "services", "panel-migrate", "panel-validate", "panel-build" }
context.dashboardLoader.advanceLoad = function()
    local stage = context.stage
    steps[#steps + 1] = stage
    grants[#grants + 1] = context.lifecycleTasks.load.cost
    context.stage = stages[#steps + 1]
end
context.stage, context.lifecycleRequest = stages[1], "load"
context.lifecycleTasks.load = nil
context.scheduler.cursor = 1
definition.refresh(context)
assert(flights == 1 and #steps == 2, "small loading stages can share flight's callback")
assert(grants[1] == 2 and grants[2] == 4)
assert(context.remainingSlots == 1 and context.stage == "panel-migrate")
local task = context.lifecycleTasks.load
assert(task.spent == 6 and task.cost == 2 and task.pending, "continuation uses the next stage's cost")
definition.refresh(context)
assert(#steps == 4 and context.stage == "panel-build" and task.cost == context.scheduler.capacity)
assert(grants[3] == 2 and grants[4] == 2 and task.spent == 10)
assert(task.refused == context.scheduler.callbacks, "expensive construction cannot use a leftover small grant")
definition.refresh(context)
assert(#steps == 5 and not context.stage and grants[5] == context.scheduler.capacity)
assert(task.spent == 10 + context.scheduler.capacity and not task.pending)
context.stage = "services"
broker.documentLoaded = false
assert(not task.ready(task, getTime(), false), "service construction must wait for the model document")
assert(not task.ready(task, getTime(), true), "hidden construction has the same model dependency")
broker.documentLoaded = true
assert(task.ready(task, getTime(), true))
context.stage = nil

context.lifecycleRequest = nil
context.aeroMenuModal = true
local editor = { buildStage = 1 }
context.editorUi = editor
context.editorController.advanceEditor = function()
    local cost = context.uiTasks.editor.cost
    if editor.buildStage then
        assert(cost == 3)
        editor.buildStage = nil
    else
        assert(cost == context.scheduler.capacity, "preview work cannot inherit a build reservation")
        editor.previewPending = nil
    end
end
context.uiRequest = "editor"
local before = flights
context.scheduler.cursor = 1
definition.refresh(context)
assert(flights == before + 1 and not editor.buildStage)
assert(context.remainingSlots == context.scheduler.capacity - 4)
editor.previewPending = true
context.uiRequest = "editor"
context.scheduler.cursor = 1
definition.refresh(context)
assert(editor.previewPending and context.uiTasks.editor.cost == context.scheduler.capacity)
definition.refresh(context)
assert(not editor.previewPending)
assert(#context.errors == 0, table.concat(context.errors, "\n"))

-- Check reduced task windows against their nominal grants in the mocked VM.
-- These guards are not a substitute for native-radio instruction measurement.
local measured, peaks = 0, {}
for _, layout in ipairs({ "Default", "review-navigation", "review-chart", "Diagnostics", "Empty" }) do
    local host = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
        Layout = layout,
        Theme = "modern-light",
    }, context.path)
    local add = host.scheduler.add
    local wrapped = {}
    host.scheduler.add = function(work)
        if not wrapped[work] then
            wrapped[work] = true
            local step = work.step
            work.step = function(task, now, slots, hidden)
                local name = task.name .. "/" .. tostring(host.stage or host.uiRequest or "")
                if task.ui then
                    name = name .. "/" .. tostring(task.ui.build or task.ui.buildStage)
                end
                local count = 0
                if slots > 0 and slots < host.scheduler.capacity and task.hostWork then
                    debug.sethook(function()
                        count = count + 100
                    end, "", 100)
                end
                local ok, used, again = pcall(step, task, now, slots, hidden)
                debug.sethook()
                assert(ok, used)
                if count > 0 then
                    measured = measured + 1
                    peaks[name] = math.max(peaks[name] or 0, count)
                    assert(count + 100 < slots * 2000, name .. " exceeds its reduced grant: " .. count)
                end
                return used, again
            end
        end
        add(work)
    end
    local function untilDone(done)
        for callback = 1, 400 do
            fixture.tick(20)
            definition.refresh(host)
            assert(#host.errors == 0, table.concat(host.errors, "\n"))
            if done() then
                return callback
            end
        end
        error("stage reservation workload timed out")
    end
    local startup = untilDone(function()
        return not host.initializing and not host.stage
    end)
    fixture.pump(host, 30)
    host.aeroMenuHandlers.modelSettings()
    local settings = untilDone(function()
        return host.modelSettingsUi and not host.modelSettingsUi.build
    end)
    host.modelSettingsUi.closing = true
    untilDone(function()
        return not host.modelSettingsUi
    end)
    fixture.pump(host, 10)
    host.aeroMenuHandlers.uiSetup()
    local editorBuild = untilDone(function()
        return host.editorUi and not host.editorUi.buildStage
    end)
    if layout == "Default" then
        assert(startup <= 75, "startup must improve on the old 121-callback path")
        assert(settings <= 24, "settings must improve on the old 28-callback path")
        assert(editorBuild <= 22, "editor construction must improve on the old full-budget path")
    end
    host.editorUiModule.close(host, true)
end
assert(measured > 100 and peaks["load/services"] and peaks["load/panel-validate"])
