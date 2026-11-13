-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local definition = fixture.module("main.lua")
local originalLoadScript = loadScript
local loaded = {}
loadScript = function(path)
    loaded[#loaded + 1] = path
    return originalLoadScript(path)
end
local objects = #fixture.lvglMock.objects
local context = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "Empty",
    Theme = "modern-dark",
}, root .. "/build/test-widget-fixture/")
assert(context.scheduler and context.initializing and context.stage == "initialize")
assert(not context.root and not context.page and not context.grid and not context.configureFlight)
assert(not context.flightFactory.members[context], "native create cannot enroll substantive flight membership")
assert(#fixture.lvglMock.objects == objects, "native create cannot construct dashboard objects")
for _, path in ipairs(loaded) do
    assert(string.match(path, "/lib/scheduler%.lua$"), "native create loaded more than its scheduler bootstrap")
end
loadScript = originalLoadScript
assert(context.initializationTask.cost == context.scheduler.capacity)
definition.background(context)
assert(not context.initializing and context.root and context.grid and context.configureFlight)
assert(context.flightFactory.members[context] and context.stage ~= "initialize")
assert(context.remainingSlots == 0 and not context.initializationTask.pending)
assert(context.initializationTask.spent == context.scheduler.capacity)
assert(#context.panels == 0, "initialization must not also construct panels")
fixture.pump(context, 100)
assert(not context.stage and #context.errors == 0, table.concat(context.errors, "\n"))

-- Options arriving before initialization remain intent-only and apply later.
local second = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "Default",
    Theme = "modern-dark",
}, context.path)
definition.update(second, { Layout = "Empty", Theme = "modern-light" })
assert(second.optionsRequest and not second.root)
definition.background(second)
assert(second.optionsRequest and second.layoutName == "Default")
fixture.pump(second, 150)
assert(not second.stage and not second.optionsRequest and not second.reloadState and #second.errors == 0)
assert(second.layoutName == "Empty" and second.themeMode == "modern-light")

-- A failed first native allocation still leaves a usable error page.
local failed = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "Empty",
    Theme = "modern-dark",
}, context.path)
local originalBox = lvgl.box
lvgl.box = function()
    lvgl.box = originalBox
    error("initialization allocation failed")
end
definition.refresh(failed)
assert(not failed.initializing and failed.runtimeFailed and failed.schedulerFailed)
assert(failed.root and failed.page and failed.canvas and failed.errorLabel)
assert(string.find(table.concat(failed.errors, "\n"), "initialization allocation failed", 1, true))
failed.zone.w = 320
definition.refresh(failed)
assert(failed.page.properties.w == 320 and failed.canvas.properties.w == 320)

local partial = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "Empty",
    Theme = "modern-dark",
}, context.path)
local allocations = 0
lvgl.box = function(...)
    allocations = allocations + 1
    if allocations == 2 then
        lvgl.box = originalBox
        error("initialization page allocation failed")
    end
    return originalBox(...)
end
definition.refresh(partial)
local member = assert(partial.flightFactory.members[partial])
assert(partial.runtimeFailed and not member.pending and member.error)
assert(partial.root and partial.page and partial.canvas)
definition.refresh(partial)
