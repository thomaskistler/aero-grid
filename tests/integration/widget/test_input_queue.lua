-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
EVT_TOUCH_FIRST, EVT_TOUCH_TAP, EVT_TOUCH_BREAK = 9301, 9302, 9303
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 30)
local broker = context.flightFactory.broker
local flights, calls, seen = 0, 0, {}
context.flightTask = {
    broker = broker,
    step = function()
        flights = flights + 1
    end,
}
context.editorController.editorEntryHit = function(_, value, _, held)
    assert(context.inputTask.cost == context.scheduler.capacity)
    return held and value == EVT_TOUCH_FIRST
end
context.panelHost.dispatch = function(entry, method, value)
    assert(method == "event" and context.inputTask.cost == context.scheduler.capacity)
    calls = calls + 1
    seen[#seen + 1] = { owner = entry, event = value }
    return true, nil, entry.consume
end
local first = { consume = true, placement = { type = "test" }, settings = {}, module = {} }
local second = { placement = { type = "test" }, settings = {}, module = {} }
context.panels = { first, second }
local function drain()
    for _ = 1, 60 do
        definition.refresh(context)
        if not context.inputQueue then
            return
        end
    end
    error("input did not receive its grant")
end
assert(definition.event(context, 9401))
assert(calls == 0 and #context.inputQueue == 1)
definition.background(context)
assert(calls == 0 and #context.inputQueue == 1, "hidden callbacks retain input")
context.scheduler.cursor = 1
definition.refresh(context, 9402)
assert(calls == 0 and #context.inputQueue == 2, "flight must defer the whole-capacity input turn")
local chargedFlights = flights
definition.refresh(context)
assert(calls == 1 and flights == chargedFlights and #context.inputQueue == 1)
assert(seen[1].event == 9401 and seen[1].owner == first, "consumed events cannot reach a later panel")
assert(not context.inputTask.pending, "one grant processes one event, not the whole backlog")
drain()
assert(calls == 2 and seen[2].event == 9402, "refresh and exported input share FIFO ordering")
first.consume = false
assert(definition.event(context, 9403))
drain()
assert(calls == 4 and seen[3].owner == first and seen[4].owner == second)

local start = getTime()
local touch = { x = 20, y = 30, startX = 1, startY = 2, slideX = 3, slideY = 4, tapCount = 2, swipeLeft = true }
assert(definition.event(context, EVT_TOUCH_FIRST, touch))
touch.x, touch.slideX = 200, 300
local input = context.inputQueue[1]
assert(input.now == start and input.touch.x == 20 and input.touch.slideX == 3 and input.touch.tapCount == 2)
assert(input.touch.swipeLeft, "firmware swipe flags must survive deferral")
fixture.tick(100)
assert(definition.event(context, EVT_TOUCH_BREAK))
drain()
assert(not context.editorPress and not context.editorTransitionRequest, "queued release prevents late hold activation")

assert(definition.event(context, EVT_TOUCH_FIRST, touch))
drain()
assert(context.editorPress and context.editorPress.started == getTime())
assert(definition.event(context, EVT_TOUCH_TAP, touch))
assert(definition.event(context, EVT_TOUCH_TAP, touch))
local before = calls
drain()
assert(calls == before + 2, "duplicate taps dispatch only once across callbacks")

assert(definition.event(context, 9404))
fixture.lvglMock.setFullScreen(false)
definition.refresh(context)
assert(not context.inputQueue and calls == before + 2, "fullscreen exit discards queued input")
assert(not definition.event(context, 9405), "App mode rejects input")
fixture.lvglMock.setFullScreen(true)
context.runtimeFailed = true
assert(not definition.event(context, 9406) and not context.inputQueue, "failed runtimes reject input")

local loading = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "Empty",
    Theme = "modern-dark",
}, context.path)
assert(loading.stage and definition.event(loading, 9407))
for _ = 1, 400 do
    definition.refresh(loading)
    if not loading.stage and not loading.inputQueue then
        break
    end
end
assert(not loading.stage and not loading.inputQueue and #loading.errors == 0, "retained input cannot deadlock loading")
