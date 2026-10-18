-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local helpers = assert(loadfile(root .. "/tests/support/widget_helpers.lua"))()
fixture.reset()
local layoutFile = assert(io.open(root .. "/build/test-widget-fixture/layouts/review-diagnostics-log.yaml", "w"))
io.write(
    layoutFile,
    [[
version: 3
grid:
  columns: 4
  rows: 4
panels:
  - id: nav
    type: navigation
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      armSwitch: SFv
  - id: log
    type: host-diagnostics
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      section: log
      maxEntries: 256
]]
)
io.close(layoutFile)
local definition = fixture.module("main.lua")
local function create()
    return helpers.createLoaded(
        definition,
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "review-diagnostics-log", Theme = "modern-dark" },
        root .. "/build/test-widget-fixture/"
    )
end
local flight, diagnostics = create(), create()
assert(#flight.errors == 0 and #diagnostics.errors == 0)
assert(flight.diagnosticsLog == diagnostics.diagnosticsLog, "widget instances must share a script-owned log")
local flightLog = fixture.entryById(flight, "log")
flightLog.settings.section = "identity"
flightLog.instance.section = "identity"
local log = diagnostics.diagnosticsLog
local nav = flight.serviceRuntime.byId.navigation
local entry = nav.entries[1]
entry.capture.attempted, entry.capture.latitude, entry.capture.longitude = nil, nil, nil
entry.wasArmed = false
entry.arm = { available = true, fresh = true, value = true, updatedAt = getTime() }
entry.reading = {
    available = true,
    fresh = true,
    stale = false,
    updatedAt = getTime(),
    raw = { lat = 47, lon = 8, delay = 63 },
}
nav.due = 0
for _ = 1, 20 do
    definition.background(flight)
end
assert(log.count == 1, "hidden-screen services must record the first-arm outcome")
local capture = log:read()[1]
assert(capture.panel == "nav" and capture.host == "review-diagnostics-log#1")
assert(string.find(capture.text, "missed; now=", 1, true))
assert(string.find(capture.text, "available=true fresh=true stale=false", 1, true))
assert(string.find(capture.text, "delay=63 (160ms units) validPosition=true", 1, true))
assert(not string.find(capture.text, "47", 1, true))
assert(entry.capture.attempted and not entry.capture.latitude, "diagnostics must not loosen capture policy")

for index = 1, 300 do
    log:append(flight, "nav", "event " .. index .. " " .. capture.text, index * 100)
end
assert(log.count == 256)
local logEntry = fixture.entryById(diagnostics, "log")
logEntry.module.refresh(logEntry.instance)
assert(string.find(logEntry.instance.texts[logEntry.instance.visibleLines], "event 300", 1, true))

EVT_TOUCH_FIRST, EVT_TOUCH_SLIDE, EVT_TOUCH_TAP, EVT_TOUCH_BREAK = 9101, 9102, 9103, 9104
EVT_VIRTUAL_EXIT, EVT_ROT_LEFT, EVT_ROT_RIGHT = 9106, 9107, 9108
local worst = 0
local function input(event, touch)
    fixture.tick(20)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    definition.refresh(diagnostics, event, touch)
    debug.sethook()
    worst = math.max(worst, instructions)
    assert(instructions < 15000, "log viewer callback exceeded budget: " .. instructions)
    fixture.lvglMock.settle()
end
local point = { x = 360, y = 80 }
local function finishWrapping()
    for _ = 1, 20 do
        if not diagnostics.logViewer or not diagnostics.logViewer.prepareIndex then
            break
        end
        input(nil)
    end
    assert(not diagnostics.logViewer or not diagnostics.logViewer.prepareIndex, "viewport must finish promptly")
end
local function tap()
    input(EVT_TOUCH_FIRST, point)
    input(EVT_TOUCH_TAP, point)
    finishWrapping()
end
tap()
assert(not diagnostics.logViewer, "App mode must not open the viewer")
fixture.lvglMock.setFullScreen(true)
fixture.pump(diagnostics, 30)
input(EVT_TOUCH_FIRST, point)
input(EVT_TOUCH_SLIDE, point)
input(EVT_TOUCH_TAP, point)
assert(not diagnostics.logViewer, "drag release must not open a viewer")
tap()
local state = assert(diagnostics.logViewer)
assert(#state.entries == 256 and state.closeButton)
local newest = state.index
local newestOffset = state.offset
input(EVT_ROT_LEFT)
finishWrapping()
assert(state.index < newest or state.offset < newestOffset, "wheel must reveal older lines")
input(EVT_TOUCH_FIRST, { x = 200, y = 100 })
input(EVT_TOUCH_SLIDE, { x = 200, y = 220 })
finishWrapping()
input(EVT_TOUCH_BREAK)
local position = state.index
assert(position < newest or state.offset < newestOffset - 1, "drag down must reveal older lines")
input(EVT_ROT_RIGHT)
finishWrapping()
assert(state.index >= position)
for _, row in ipairs(state.rows) do
    assert(diagnostics.themeBuilder.measureText(SMLSIZE, row.properties.text) <= state.width)
end
for _ = 1, 1600 do
    if state.index == 1 and state.offset == 1 then
        break
    end
    input(EVT_ROT_LEFT)
    finishWrapping()
end
assert(state.index == 1 and state.offset == 1, "all retained history must be reachable")
for _ = 1, 1600 do
    if state.index == #state.entries and state.offset == #state.cache[state.index] then
        break
    end
    input(EVT_ROT_RIGHT)
end
assert(state.index == #state.entries and state.offset == #state.cache[state.index], "wheel must reach the newest line")
log:append(flight, "nav", "after opening", 40000)
assert(state.entries[#state.entries].text ~= "after opening", "viewer snapshot must stay stable while reading")
input(EVT_VIRTUAL_EXIT)
assert(not diagnostics.logViewer and diagnostics.logOverlay.hidden and lvgl.isFullScreen())
local overlay = diagnostics.logOverlay
for _ = 1, 10 do
    tap()
    assert(diagnostics.logOverlay == overlay, "reuse the overlay registration host")
    input(EVT_TOUCH_FIRST, { x = 440, y = 15 })
    input(EVT_TOUCH_TAP, { x = 440, y = 15 })
    assert(not diagnostics.logViewer)
end
tap()
state = assert(diagnostics.logViewer)
state.closeButton.properties.press()
fixture.lvglMock.settle()
assert(not diagnostics.logViewer, "native Close button must dismiss")
tap()
diagnostics.zone.w = 320
input(nil)
assert(not diagnostics.logViewer, "resizing must dismiss rather than retain obsolete geometry")
fixture.pump(diagnostics, 10)
diagnostics.zone.w = 480
fixture.pump(diagnostics, 10)
log:trim(0)
tap()
state = assert(diagnostics.logViewer)
assert(#state.entries == 0 and state.rows[1].properties.text == "No messages recorded")
input(EVT_VIRTUAL_EXIT)
tap()
fixture.lvglMock.setFullScreen(false)
input(nil)
assert(not diagnostics.logViewer, "leaving fullscreen must dismiss")
fixture.pump(diagnostics, 50)
assert(not diagnostics.logOverlay, "page retirement must drop the overlay")
assert(#diagnostics.errors == 0, table.concat(diagnostics.errors, "\n"))
local count = log.count
fixture.entryById(diagnostics, "log").failed = true
log:append(flight, "nav", "disabled", 0)
assert(log.count == count, "no active log panel means no recording")
print("Shared diagnostics integration passed; worst viewer callback: " .. worst .. " instructions")
