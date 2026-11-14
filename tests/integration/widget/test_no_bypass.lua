-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local noGrant = assert(loadfile(root .. "/tests/support/no_grant.lua"))()
fixture.reset()
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "Default",
    Theme = "modern-dark",
}, root .. "/build/test-widget-fixture/")
local enrolled = noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    definition.background(context)
    assert(context.initializing and context.root and context.canvas)
    assert(not context.flightFactory.members[context])
end)
assert(enrolled.initialize, "bootstrap must request an initialization task")
local schedulerRun, box = context.scheduler.run, lvgl.box
local caught, failure = pcall(noGrant, context, fixture.lvglMock.objects, function()
    definition.background(context)
    pcall(lvgl.box, {})
end)
assert(not caught and string.find(failure, "box ran without a scheduler grant", 1, true))
assert(context.scheduler.run == schedulerRun and lvgl.box == box, "the guard restores hooks after failure")
fixture.pump(context, 200)
assert(not context.stage and #context.errors == 0)

local function withheld(exercise)
    return noGrant(context, fixture.lvglMock.objects, function()
        exercise()
        for _ = 1, 3 do
            definition.refresh(context)
            definition.background(context)
        end
    end)
end
local dispatched = 0
local dispatch = context.panelHost.dispatch
context.panelHost.dispatch = function(...)
    dispatched = dispatched + 1
    return dispatch(...)
end
local flightStep = context.flightTask.step
local flights = 0
context.flightTask.step = function(...)
    flights = flights + 1
    return flightStep(...)
end
fixture.tick(100)
local updates = context.serviceRuntime.updates
enrolled = withheld(function() end)
assert(enrolled.flight and dispatched == 0 and flights == 0, "idle service/panel/flight work cannot bypass grants")
assert(context.serviceRuntime.updates == updates)
local services = 0
for _, instance in ipairs(context.serviceRuntime.order) do
    assert(enrolled[instance.id], "steady-state checks must enroll each live service")
    services = services + 1
end
assert(services > 0, "steady-state checks need live services")
local panelTasks = 0
for name in pairs(enrolled) do
    if string.find(name, ": refresh", 1, true) or string.find(name, ": background", 1, true) then
        panelTasks = panelTasks + 1
    end
end
assert(panelTasks > 0, "steady-state checks must actually enroll panels")

withheld(function()
    assert(definition.event(context, 9801))
end)
assert(context.inputQueue and #context.inputQueue == 1 and dispatched == 0)
fixture.pump(context, 60)
assert(not context.inputQueue and dispatched > 0 and flights > 0, "work resumes when grants return")

local oldWidth = context.width
withheld(function()
    context.zone.w = 320
end)
assert(context.width == oldWidth and not context.reflowIndex, "geometry changes cannot reflow before a grant")
fixture.pump(context, 100)
assert(context.width == 320 and not context.reflowIndex)

withheld(function()
    definition.update(context, { Layout = "Empty", Theme = "modern-light" })
end)
assert(context.optionsRequest and context.layoutName == "Default" and not context.reloadState)
fixture.pump(context, 200)
assert(context.layoutName == "Empty" and not context.reloadState and not context.stage)

local menu = context.aerogridMenu
enrolled = withheld(function()
    menu.pending = true
end)
assert(enrolled.menu and menu.pending and not menu.open)
fixture.pump(context, 30)
assert(menu.open and not menu.pending)
withheld(function()
    menu.dismiss = true
end)
assert(menu.open and menu.dismiss)
fixture.pump(context, 30)
assert(not menu.open)

withheld(function()
    context.aeroMenuHandlers.modelSettings()
end)
assert(context.modelSettingsRequest and not context.modelSettingsUi)
fixture.pump(context, 100)
assert(context.modelSettingsUi and not context.modelSettingsRequest)
local state = context.modelSettingsUi
local control = assert(state.controls.minMotorPercent)
local oldValue = control.properties.get()
local newValue = oldValue == 99 and 98 or oldValue + 1
withheld(function()
    control.properties.set(newValue)
    assert(control.properties.get() == oldValue, "native getters remain cached before a grant")
end)
assert(state.pending and state.pending.apply and state.values.minMotorPercent == oldValue)
fixture.pump(context, 100)
assert(not state.pending and control.properties.get() == newValue, "granted normalization and persistence resume")
withheld(function()
    state.closing = true
end)
assert(context.modelSettingsUi == state and state.closing)
fixture.pump(context, 100)
assert(not context.modelSettingsUi and #context.errors == 0)
