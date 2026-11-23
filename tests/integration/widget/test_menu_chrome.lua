-- SPDX-License-Identifier: GPL-2.0-only

-- The AeroGrid button replaces EdgeTX's own in the same callback, and stays
-- while the layout editor is open without taking the editor's touches.
local root = assert(...)
EVT_TOUCH_FIRST, EVT_TOUCH_TAP = 9601, 9602
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Default", Theme = "modern-dark" })
fixture.pump(context, 40)

local function shown()
    local menu = context.aerogridMenu
    return not context.chromeRoot.hidden and not menu.root.hidden
end

local preloaded = assert(context.aerogridMenu, "the button must be built before the first fullscreen entry")
assert(context.chromeRoot.hidden and preloaded.root.hidden, "preloading must not cover the native App icon")
assert(not preloaded.screen, "preloading must not construct the menu popup")
assert(type(preloaded.image.properties.file) == "string", "the hidden PNG must not wait for a visible callback")
local children = #preloaded.root.children
-- Flight work spending the whole budget first must not delay the button.
local broker = { documentLoaded = true, filename = context.aerogridMenu.modelFilename }
function broker.tasks()
    return {}
end
context.flightFactory = { broker = broker }
context.flightTask = {
    broker = broker,
    cost = context.scheduler.budget.slots,
    step = function(_, _, slots)
        return slots, false
    end,
}
fixture.requeue(context)
-- EdgeTX calls update while entering fullscreen, before its next redraw.
fixture.lvglMock.setFullScreen(true)
definition.update(context, { Layout = "Default", Theme = "modern-dark" })
assert(shown(), "the button must appear before EdgeTX redraws")
assert(context.aerogridMenu == preloaded and #preloaded.root.children == children, "first entry only shows the icon")
fixture.lvglMock.setFullScreen(false)
definition.refresh(context)
assert(context.chromeRoot.hidden, "the button hides as fullscreen ends")
fixture.lvglMock.setFullScreen(true)
definition.refresh(context)
assert(shown(), "the button must appear in the first fullscreen callback")
context.flightFactory, context.flightTask = nil, nil
fixture.pump(context, 20)

context.openRequest = { kind = "editor", page = context.page, modelFilename = model.getInfo().filename }
fixture.pump(context, 30)
assert(context.editorUi and not context.editorUi.buildStage, "the editor must open")
assert(shown(), "the button stays while editing")

local handle, taken = context.aeroMenuModule.handle, 0
context.aeroMenuModule.handle = function(...)
    local handled = handle(...)
    taken = taken + (handled and 1 or 0)
    return handled
end
local touch = { x = 5, y = 5 }
for _, event in ipairs({ EVT_TOUCH_FIRST, EVT_TOUCH_TAP }) do
    definition.event(context, event, touch)
    fixture.pump(context, 10)
end
local menu = context.aerogridMenu
assert(taken == 0, "touches on the button must reach the editor")
assert(not menu.open and not menu.pending, "the button does nothing while editing")
assert(context.editorUi and shown())

fixture.lvglMock.setFullScreen(false)
local refreshOnly = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(refreshOnly, 20)
local refreshPreloaded = assert(refreshOnly.aerogridMenu)
assert(refreshOnly.chromeRoot.hidden and refreshPreloaded.root.hidden)
fixture.lvglMock.setFullScreen(true)
definition.refresh(refreshOnly)
assert(not refreshOnly.chromeRoot.hidden and not refreshPreloaded.root.hidden)
assert(refreshOnly.aerogridMenu == refreshPreloaded, "first refresh must show the preloaded icon even without update")
print("AeroGrid button follows fullscreen and stays while editing")
