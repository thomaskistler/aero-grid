-- SPDX-License-Identifier: GPL-2.0-only

-- The debrief bottom bar stays until reset, hides while open, and supports
-- tapping or pulling up without taking the widget's App-mode long press.

local root = ... or "."
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
fixture.reset()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "review-navigation", Theme = 3 }, nil, definition)
local other = fixture.createLoaded(nil, { Layout = "review-navigation", Theme = 3 }, nil, definition)
fixture.pump(context, 40)
fixture.pump(other, 40)

EVT_TOUCH_FIRST, EVT_TOUCH_SLIDE, EVT_TOUCH_TAP, EVT_TOUCH_BREAK = 9101, 9102, 9103, 9104
EVT_VIRTUAL_EXIT = 9106

local LONG = "DEBRIEF READY (LONG-PRESS, THEN SCROLL UP)"
local SHORT = "DEBRIEF READY (SCROLL UP)"

local worst = 0
local current
local function callback(event, touch)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    definition.refresh(context, event, touch)
    debug.sethook()
    worst = math.max(worst, instructions)
    fixture.lvglMock.settle()
end
local function settle(count)
    for _ = 1, count or 5 do
        fixture.tick(5)
        callback()
    end
end
local function input(event, touch)
    fixture.tick(20)
    callback(event, touch)
    for _ = 1, 200 do
        if not (context.inputQueue or context.debriefRequest or context.uiRequest) then
            return
        end
        callback()
    end
    error("input did not settle")
end
local function build()
    for _ = 1, 1000 do
        local state = context.debrief
        if state and state.result == current and context.debriefModule.ready(state) then
            settle(2)
            return
        end
        fixture.tick(5)
        callback()
    end
    error("debrief view was not built")
end

local H = context.zone.h
local function touch(y, startY, extra)
    local point = { x = 240, y = y, startX = 240, startY = startY }
    for key, value in pairs(extra or {}) do
        point[key] = value
    end
    return point
end

--- The pill's visible text, or nil when no pill is on screen.
local function pill(host)
    host = host or context
    local ui = host.debriefPill and host.debriefPill.ui
    if not ui or host.pillLayer.hidden then
        return nil
    end
    local p = host.pillLayer.properties
    return ui.label.properties.text,
        {
            x = p.x,
            y = p.y + host.debriefOverlay.properties.y + host.debriefViewport.properties.y,
            w = p.w,
            h = p.h,
        }
end

local chartColumns = context.chartColumns
local function makeResult(title)
    local columns = chartColumns.new(100, 1000, nil, { passive = true })
    for at = 0, 1000, 5 do
        columns:sample(at, 4.2 - at / 1500, false, false, 0)
    end
    return {
        duration = 6000,
        flight = 7,
        model = "Edge 540",
        tiles = {
            {
                config = { title = title, colSpan = 4, rowSpan = 2 },
                series = {
                    {
                        config = { source = "RxBt", statistic = "min", unit = "V" },
                        value = 3.6,
                        level = "normal",
                        columns = columns,
                        levels = {},
                    },
                },
            },
        },
    }
end

local runtime = context.serviceRuntime
local realDebrief = runtime.byId.debrief
runtime.byId.debrief = {
    result = function()
        return current
    end,
}

-- Pure fit: long text, then the short one, then nothing.
local view = context.debriefModule or assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/debrief_view.lua"))()
local measure = context.themeBuilder.measureText
assert(view.pillFit(context, false, 480, 272) == LONG)
assert(view.pillFit(context, true, 480, 272) == SHORT)
local narrow = measure(SMLSIZE, "DEBRIEF READY") + 18
assert(view.pillFit(context, false, narrow, 272) == "DEBRIEF READY", "a narrow zone shows the short text")
assert(view.pillFit(context, false, narrow - 10, 272) == nil, "a too narrow zone shows no pill")
assert(view.pillFit(context, false, 480, 20) == nil, "a too short zone shows no pill")

-- The bar appears as soon as a result is available. A tap can wait for the
-- background build to finish before opening the complete view.
local page = context.page
assert(not context.pageBuiltFullscreen, "the page was built in App mode")
fixture.lvglMock.setFullScreen(true)
settle(20)
assert(context.page == page and not pill(), "no debrief, no pill")
current = makeResult("Pack")
settle(4)
assert(
    context.debrief and not context.debriefModule.ready(context.debrief) and pill() == SHORT,
    "the bar appears while the view builds"
)
input(EVT_TOUCH_FIRST, touch(H - 5, H - 5))
fixture.tick(20)
callback(EVT_TOUCH_BREAK, touch(H - 5, H - 5))
settle(2)
assert(context.debriefRequest and not context.debrief.shown, "a tap waits for the complete view")
build()
assert(context.debrief.shown and pill() == SHORT, "the queued tap opens with the same bar still visible")
assert(context.pillLayer.parent == context.debrief.ui.viewport, "the bar belongs to the scrolling debrief canvas")
assert(context.debriefOverlay.properties.y == 0, "the bar reaches the top when the sheet is open")
input(EVT_VIRTUAL_EXIT)
settle()
assert(pill() == SHORT, "fullscreen pill says swipe up: " .. tostring(pill()))

-- Leaving fullscreen keeps the page. A pill built in fullscreen would take
-- the long press there, so it is rebuilt outside fullscreen.
fixture.lvglMock.setFullScreen(false)
settle(20)
local text, box = pill()
assert(context.page == page and text == LONG, "outside fullscreen the pill says to long-press: " .. tostring(text))
assert(box.x == 0 and box.w == context.zone.w, "the bar spans the dashboard")
assert(box.y + box.h == H and box.y > H - 40, "the bar meets the bottom edge")
assert(not pill(other), "each dashboard shows its own pill")
local function builtOutside(object)
    if object.builtFullscreen then
        return false
    end
    for _, child in ipairs(object.children) do
        if not builtOutside(child) then
            return false
        end
    end
    return true
end
assert(
    #context.pillLayer.children > 0 and builtOutside(context.pillLayer),
    "no fullscreen-built pill outside fullscreen"
)

-- App mode is not widget fullscreen either.
fixture.lvglMock.setAppMode(true)
settle()
assert(pill() == LONG, "App mode keeps the long-press wording")
fixture.lvglMock.setAppMode(false)

-- Rebuilt panels land in the panel layer, below the pill; the page itself
-- gains nothing, however often its panels are replaced.
local function indexOf(object)
    for index, child in ipairs(page.children) do
        if child == object then
            return index
        end
    end
end
local pageObjects, containers = #page.children, context.panels[1].container
local pillWorst = worst
for _ = 1, 5 do
    for _, entry in ipairs(context.panels) do
        entry.builtFullscreen = true
    end
    settle(40)
    assert(not context.appRebuild, "panels rebuilt")
end
-- Rebuilding a panel is the loader's cost, not the pill's.
worst = pillWorst
assert(context.panels[1].container ~= containers, "panels got new containers")
assert(#page.children == pageObjects, "panel rebuilds left objects on the page: " .. #page.children)
assert(context.panels[1].container.parent == context.panelLayer, "panels sit in the panel layer")
assert(
    indexOf(context.panelLayer) < indexOf(context.debriefOverlay) and pill() == LONG,
    "the sheet stays above the panels"
)

fixture.lvglMock.setFullScreen(true)
settle(20)
assert(pill() == SHORT, "back in fullscreen the pill says swipe up")

-- A short pull that snaps closed restores the persistent bar.
input(EVT_TOUCH_FIRST, touch(H - 5, H - 5))
input(EVT_TOUCH_SLIDE, touch(H - 40, H - 5))
assert(context.debrief.shown and pill() == SHORT, "the leading bar stays visible during a pull")
local _, moving = pill()
assert(moving.y == context.debrief.travel - 35, "the bar moves by the same distance as the finger")
assert(context.debrief.ui.content.properties.y == moving.h, "the body starts below the leading bar")
assert(indexOf(context.panelLayer) < indexOf(context.debriefOverlay), "the debrief covers the panels")
input(EVT_TOUCH_BREAK, touch(H - 40, H - 5))
settle()
assert(not context.debrief.shown and pill() == SHORT, "the bar returns when a short pull closes")

-- A swipe up opens; closing and leaving fullscreen retain the same available
-- debrief until it is cleared.
input(EVT_TOUCH_FIRST, touch(H - 5, H - 5))
input(EVT_TOUCH_SLIDE, touch(H - 40, H - 5, { swipeUp = true }))
assert(context.debrief.shown and context.debrief.reveal == 35, "a swipe still follows the finger until release")
input(EVT_TOUCH_BREAK, touch(H - 40, H - 5))
assert(context.debrief.reveal == context.debrief.travel, "releasing an upward swipe opens the whole sheet")
local _, raised = pill()
assert(raised.y == 0, "the same bar stays at the top of the open sheet")
input(EVT_VIRTUAL_EXIT)
settle()
fixture.lvglMock.setFullScreen(false)
fixture.pump(context, 40)
build()
assert(pill() == LONG, "the bar survives viewing, leaving fullscreen and rebuilding")
input(EVT_TOUCH_FIRST, touch(H - 5, H - 5))
input(EVT_TOUCH_BREAK, touch(H - 5, H - 5))
assert(not context.debrief.shown and not context.debriefRequest, "a bar tap outside fullscreen cannot open the debrief")

-- The next flight's debrief brings a new pill; a session reset removes it.
current = makeResult("Next")
build()
assert(pill() == LONG, "a new debrief shows the pill again")
current = nil
settle()
assert(not pill(), "a session reset removes the pill")

assert(worst < 15000, "pill callback exceeded budget: " .. worst)
runtime.byId.debrief = realDebrief
print("Debrief pill integration passed; worst callback: " .. worst .. " instructions")
