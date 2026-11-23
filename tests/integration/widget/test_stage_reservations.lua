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
    step = function(_, _, slots)
        flights = flights + 1
        return slots, false
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
fixture.requeue(context)
definition.refresh(context)
assert(flights == 1 and #steps == 4, "small loading stages can share flight's callback")
assert(grants[1] == 4 and grants[2] == 8 and grants[3] == 4 and grants[4] == 4)
assert(context.remainingSlots == 11 and context.stage == "panel-build")
local task = context.lifecycleTasks.load
assert(
    context.scheduler.state(task).spent == 20
        and task.cost == context.scheduler.budget.capacity
        and context.scheduler.state(task).pending
)
assert(
    context.scheduler.state(task).refused == context.scheduler.callbacks,
    "expensive construction cannot use a leftover small grant"
)
definition.refresh(context)
assert(#steps == 5 and not context.stage and grants[5] == context.scheduler.budget.capacity)
assert(
    context.scheduler.state(task).spent == 20 + context.scheduler.budget.capacity
        and not context.scheduler.state(task).pending
)
context.stage = "services"
broker.documentLoaded = false
assert(not task.open(task, getTime(), false), "service construction must wait for the model document")
assert(not task.open(task, getTime(), true), "hidden construction has the same model dependency")
broker.documentLoaded = true
assert(task.open(task, getTime(), true))
context.stage = nil

context.lifecycleRequest = nil
context.aeroMenuModal = true
local editor = { buildStage = 1 }
context.editorUi = editor
context.editorController.advanceEditor = function()
    local cost = context.uiTasks.editor.cost
    if editor.buildStage then
        assert(cost == 12)
        editor.buildStage = nil
    else
        assert(cost == context.scheduler.budget.capacity, "preview work cannot inherit a build reservation")
        editor.previewPending = nil
    end
end
context.uiRequest = "editor"
local before = flights
fixture.requeue(context)
definition.refresh(context)
assert(flights == before + 1 and not editor.buildStage)
assert(context.remainingSlots == context.scheduler.budget.capacity - 13)
editor.previewPending = true
context.uiRequest = "editor"
fixture.requeue(context)
definition.refresh(context)
assert(editor.previewPending and context.uiTasks.editor.cost == context.scheduler.budget.capacity)
definition.refresh(context)
assert(not editor.previewPending)
assert(#context.errors == 0, table.concat(context.errors, "\n"))

-- Model rows have separate fixture envelopes: their production grants come from
-- native simulator measurements, not Lua stand-ins for firmware text/API calls.
local modelMockLimits = { 4500, 4000, 1200, 1200, 1200, 1200, 1200, 1200, 3000, 13000, 7500, 2000 }
local measured, peaks = 0, {}
for _, layout in ipairs({ "Default", "review-navigation", "review-chart", "Diagnostics", "Empty" }) do
    local host = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
        Layout = layout,
        Theme = "modern-light",
    }, context.path)
    local add = host.scheduler.add
    local wrapped, modelRows, modelSlots = {}, 0, 0
    host.scheduler.add = function(work)
        if not wrapped[work] then
            wrapped[work] = true
            local step = work.step
            work.step = function(task, now, slots, hidden)
                local row = task.kind == "model settings" and task.ui.build
                if row then
                    assert(row == modelRows + 1, "contention must neither skip nor repeat drawer rows")
                    assert(slots == host.modelSettingsUiModule.cost(host), "each row needs its own reservation")
                    modelRows, modelSlots = row, modelSlots + slots
                end
                local name = task.name .. "/" .. tostring(host.stage or host.uiRequest or "")
                if task.ui then
                    name = name .. "/" .. tostring(task.ui.build or task.ui.buildStage)
                end
                local count = 0
                if
                    slots > 0
                    and slots < host.scheduler.budget.capacity
                    and type(task.owner) == "string"
                    and not task.broker
                then
                    debug.sethook(function()
                        count = count + 100
                    end, "", 100)
                end
                local ok, used, again = pcall(step, task, now, slots, hidden)
                debug.sethook()
                assert(ok, used)
                if row then
                    assert(
                        task.ui.build == row + 1 or row == 12 and not task.ui.build,
                        "one advancement must build only one row, even with slots left"
                    )
                end
                if count > 0 then
                    measured = measured + 1
                    peaks[name] = math.max(peaks[name] or 0, count)
                    local limit = row and modelMockLimits[row] or slots * host.scheduler.budget.instructionsPerSlot
                    assert(count + 100 < limit, name .. " exceeds its mock envelope: " .. count)
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
    assert(modelRows == 12 and modelSlots == 52, "drawer construction must reserve exactly 52 slots")
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
        -- The revised scheduler stays within one callback of the old path
        -- at this cadence, where every flight poll and decision is due.
        assert(settings <= 29, "settings must remain within one callback of the old path")
        assert(editorBuild <= 23, "editor construction must improve on the old full-budget path")
    end
    host.editorUiModule.close(host, true)
end
assert(measured > 100 and peaks["load/services"] and peaks["load/panel-validate"])
