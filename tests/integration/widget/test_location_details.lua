-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
fixture.reset()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "review-navigation", Theme = "modern-dark" })
fixture.pump(context, 40)

EVT_TOUCH_FIRST = 9101
EVT_TOUCH_SLIDE = 9102
EVT_TOUCH_TAP = 9103
EVT_VIRTUAL_EXIT = 9106

local function input(event, touch)
    definition.refresh(context, event, touch)
    fixture.lvglMock.settle()
end
local function tap()
    local entry = fixture.entryById(context, "compass")
    local rect = context.dashboardLoader.panelRect(context, entry.placement)
    local point = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
    input(EVT_TOUCH_FIRST, point)
    input(EVT_TOUCH_TAP, point)
end

tap()
assert(not context.locationDetails, "normal-mode touches must not open location details")
fixture.lvglMock.setFullScreen(true)
fixture.pump(context, 40)
tap()
local snapshot = assert(context.locationDetails, "fullscreen navigation tap must open details")
assert(snapshot.valid and not snapshot.stale)
assert(snapshot.url == "https://www.google.com/maps/search/?api=1&query=47.376900,8.541700", snapshot.url)
assert(snapshot.code.properties.data == snapshot.url)
assert(not context.locationOverlay.hidden)
assert(not context.editorUi, "navigation tap must not open editing")
assert(snapshot.panel.background.properties.color == context.theme.color.surface, "popup must use panel surface")
assert(snapshot.closeButton == nil, "popup must not have a Close button")
local function assertCentered(snapshot)
    local left = snapshot.code.properties.x - 8
    local right = 0
    for _, child in ipairs(snapshot.panel.root.children) do
        local properties = child.properties
        if child.kind == "label" and string.match(properties.text or "", "^LAT ") then
            assert(properties.font() == 0, "coordinates must use the next size above SMLSIZE")
        end
        if child.kind == "label" and properties.text == "SCAN FOR GOOGLE MAPS" then
            right = properties.x + properties.w
        end
    end
    assert(math.abs(left + right - snapshot.panel.width) <= 1, "QR and text must be centered as a group")
end
assertCentered(snapshot)
local panel = fixture.instanceOf(context, "compass")
local feed = {
    fix = true,
    home = true,
    known = true,
    source = "GPS",
    state = "normal",
    latitude = snapshot.latitude,
    longitude = snapshot.longitude,
}
panel.feed = feed
feed.latitude, feed.longitude = -33.8568, 151.2153
input(nil)
assert(context.locationDetails.url == snapshot.url, "the QR code must freeze while scanning")
assert(context.locationDetails.latitude == 47.3769, "the coordinate caption must freeze with the QR code")

input(EVT_VIRTUAL_EXIT)
assert(not context.locationDetails)
assert(context.locationOverlay.hidden)
tap()
assert(context.locationDetails, "overlay must reopen after Exit")
assert(context.locationDetails.url == "https://www.google.com/maps/search/?api=1&query=-33.856800,151.215300")
tap()
assert(not context.locationDetails, "any tap must dismiss without leaving fullscreen")
assert(lvgl.isFullScreen())
input(EVT_TOUCH_TAP, { x = 100, y = 80 })
assert(not context.locationDetails, "duplicate release taps must not reopen the overlay")

local overlay = context.locationOverlay
for _ = 1, 20 do
    tap()
    assert(context.locationOverlay == overlay, "repeated opens must reuse the registration host")
    input(EVT_VIRTUAL_EXIT)
end

feed.state = "stale"
feed.home = false
tap()
assert(context.locationDetails.stale, "a retained fix must be identified as last known")
assertCentered(context.locationDetails)
assert(context.locationDetails.badgeText == "STALE", "stale location must use the shared panel badge")
assert(context.locationDetails.url, "a stale but valid fix remains usable")
assert(context.locationDetails.longitude == 151.2153, "maps must not depend on a home position")
input(EVT_VIRTUAL_EXIT)

feed.fix = false
tap()
assert(not context.locationDetails, "a tap without a valid GPS position must do nothing")
assert(context.locationOverlay.hidden, "missing GPS must not reveal the overlay")

local entry = fixture.entryById(context, "compass")
local rect = context.dashboardLoader.panelRect(context, entry.placement)
local point = { x = rect.x + 20, y = rect.y + 30 }
input(EVT_TOUCH_FIRST, point)
input(EVT_TOUCH_SLIDE, point)
input(EVT_TOUCH_TAP, point)
assert(not context.locationDetails, "a drag must not open details on release")

feed.fix = true
tap()
assert(context.locationDetails)
fixture.lvglMock.setFullScreen(false)
input(nil)
assert(not context.locationDetails, "leaving fullscreen must dismiss the overlay")
fixture.pump(context, 50)
assert(not context.locationOverlay, "page retirement must drop the overlay reference")
assert(#context.errors == 0, table.concat(context.errors, "\n"))
print("Navigation location detail interaction tests passed")
