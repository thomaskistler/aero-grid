-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local a = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local map = fixture.module("panels/map-prototype.lua")
local definition = fixture.module("main.lua")
EVT_TOUCH_FIRST, EVT_TOUCH_SLIDE, EVT_TOUCH_BREAK, EVT_TOUCH_TAP, EVT_VIRTUAL_EXIT = 9101, 9102, 9103, 9104, 9106
local widgetPath = root .. "/build/test-widget-fixture/"
assert(
    os.execute(
        "'"
            .. root
            .. "/build/venv/bin/python' '"
            .. root
            .. "/tools/generate-map-test-pack.py' --output '"
            .. widgetPath
            .. "AEROGRID/maps' > /dev/null"
    )
)
local originalFstat = fstat
local mapAreasFolder = "/AEROGRID/maps/areas/$"
fstat = function(filename)
    if string.match(filename, mapAreasFolder) then
        return { size = 0 }
    end
    return originalFstat(filename)
end
fixture.reset()
local nativeButton = lvgl.button
lvgl.button = function(...)
    -- EdgeTX v2.12.0 api_colorlcd_lvgl.cpp: button calls luaLvglObjEx with fullscreenOnly=true.
    if not lvgl.isFullScreen() then
        return nil
    end
    return nativeButton(...)
end
local host = fixture.createLoaded(nil, { Layout = "review-map", Theme = "modern-dark" })
fixture.pump(host, 80)
a.assertEqual(#host.errors, 0, table.concat(host.errors, "\n"))
local context = assert(fixture.instanceOf(host, "map"))
context.feed = { known = true, fix = true, state = "normal", latitude = 25.9973, longitude = -97.1572 }
context.discovery, context.nextDiscovery = nil, nil
for _ = 1, 16 do
    map.refresh(context)
    if context.pack then
        break
    end
end
assert(
    context.pack,
    "automatic selection failed: "
        .. tostring(context.discoveryStatus)
        .. " at "
        .. tostring(context.host.layoutStore.sdRoot(context.host.path))
        .. " with feed "
        .. tostring(context.feed and context.feed.state)
)
a.assertEqual(context.pack.id, "synthetic")
a.assertEqual(context.pack.version, 2)
a.assertEqual(context.pack.name, "Synthetic test area")
context.automatic = false
local function pressControl(index)
    fixture.tick(20)
    local top = ({ 44, 76, 0, 112 })[index]
    local touch = { x = context.area.zoomX + 20, y = context.area.zoomY + top + 20 }
    map.event(context, EVT_TOUCH_FIRST, touch, { x = 0, y = 0 })
    map.event(context, EVT_TOUCH_BREAK, { x = 0, y = 0 }, { x = 0, y = 0 })
end
assert(context.following, "aircraft follow must start enabled")
context.following = false
map.move(context, (512 - context.area.w) / 2 - context.viewX, (512 - context.area.h) / 2 - context.viewY)
fixture.pump(host, 40)
a.assertEqual(#context.tiles, 9)
a.assertEqual(context.marker.properties.w, context.homeMarker.properties.w, "position and home icons must match width")
a.assertEqual(context.marker.properties.h, context.homeMarker.properties.h, "position and home icons must match height")
a.assertEqual(context.aircraft.root, context.marker)
local function assertFootprint(aircraft)
    local image = aircraft.root.properties
    a.assertEqual(image.w, image.h)
    assert(image.w == 52 or image.w == 24, "PNG canvases must stay native size")
    a.assertEqual(image.file(), aircraft.file, "source callback must return the selected orientation")
end
local function assertAircraftColors(aircraft, fill)
    a.assertContains(aircraft.file, fill == lcd.RGB(0xFFFFFF) and "map-follow.png" or ("map-" .. aircraft.style .. "-"))
end
assertFootprint(context.aircraft)
assertAircraftColors(context.aircraft, lcd.RGB(0x70D6F3))
a.assertEqual(context.pending, nil)
assert(context.tileLoads <= 6)
a.assertEqual(#context.controls, 0, "App mode must not construct fullscreen-only controls")
a.assertEqual(context.controlsHint, nil, "map must not create the fullscreen hint")
fixture.lvglMock.setFullScreen(true)
map.refresh(context)
a.assertEqual(#context.controls, 4, "entering fullscreen must create zoom, follow and GPS controls")
a.assertEqual(context.followIcon, context.followAircraft.root)
a.assertEqual(context.infoIcon.properties.file, context.assets .. "map-info.png")
a.assertEqual(context.infoIcon.properties.w, 24)
a.assertEqual(context.infoIcon.properties.h, 24)
a.assertEqual(context.infoIcon.properties.x, 8, "info icon must be centered in the control")
local infoButton, infoIcon = context.controls[4].properties, context.infoIcon.properties
a.assertEqual(infoIcon.x + infoIcon.w / 2, infoButton.x + infoButton.w / 2)
a.assertEqual(infoIcon.y + infoIcon.h / 2, infoButton.y + infoButton.h / 2)
assert(infoButton.y >= 112, "info button must have a visible gap below the zoom control")
for _, child in ipairs(context.controlsRoot.children) do
    assert(child.properties.text ~= "GPS", "GPS control must not use a text label")
end
assertFootprint(context.followAircraft)
assertAircraftColors(context.followAircraft, lcd.RGB(0xFFFFFF))
local mapRect = host.dashboardLoader.panelRect(host, fixture.entryById(host, "map").placement)
local gpsButton = { x = mapRect.x + context.area.zoomX + 20, y = mapRect.y + context.area.zoomY + 128 }
assert(definition.event(host, EVT_TOUCH_FIRST, gpsButton), "GPS control press must be consumed by the map")
assert(definition.event(host, EVT_TOUCH_BREAK, { x = 0, y = 0 }), "GPS control release must be consumed by the map")
assert(host.locationDetails, "dedicated GPS control must open the shared location QR overlay")
definition.event(host, EVT_VIRTUAL_EXIT)
a.assertEqual(host.locationDetails, nil)
local previousControls = context.controls
fixture.lvglMock.setFullScreen(false)
local previousLevel = context.levelIndex
pressControl(1)
a.assertEqual(context.levelIndex, previousLevel, "a queued control press must not act outside fullscreen")
pressControl(3)
a.assertEqual(context.following, false, "a queued target press must not resume follow outside fullscreen")
map.refresh(context)
a.assertEqual(#context.controls, 0, "fullscreen exit must release controls, not just hide focused buttons")
fixture.lvglMock.settle()
for _, control in ipairs(previousControls) do
    assert(control.invalid, "fullscreen exit must delete native buttons from the encoder group")
end
fixture.lvglMock.setFullScreen(true)
map.refresh(context)
a.assertEqual(#context.controls, 4, "fullscreen reentry must recreate controls")
assert(context.controls[1] ~= previousControls[1])
for _, control in ipairs(context.controls) do
    assert(not control.hidden, "controls must be visible on fullscreen reentry")
end
fixture.lvglMock.releaseClearedObjects()
local objects = #fixture.lvglMock.objects
local open, read = io.open, io.read
local fileReads = 0
io.read = function(...)
    fileReads = fileReads + 1
    return read(...)
end
io.open = function(...)
    fileReads = fileReads + 1
    return open(...)
end
context.feed = { known = true, fix = true, state = "normal", latitude = 25.9973, longitude = -97.1572 }
map.refresh(context)
assert(context.markerVisible, "documented sample GPS must be visible in the initial overview")
context.feed.home = true
context.feed.pilotLatitude, context.feed.pilotLongitude = 25.9971, -97.1564
map.refresh(context)
assert(context.homeVisible, "a valid in-view home must display a home pin")
local homeX = context.homeX
context.feed.pilotLongitude = -97.1559
map.refresh(context)
assert(context.homeX ~= homeX, "home-only changes must update even when aircraft GPS is unchanged")
a.assertEqual(context.homeDots, nil, "map must not create a home-to-aircraft connector")
context.feed.home = false
map.refresh(context)
a.assertEqual(context.homeVisible, false, "missing home must not display a fabricated home marker")
-- Place a synthetic valid position at the centre, without relying on fixture GPS.
local level = context.pack.levels[context.levelIndex]
local centreX = level.xMin + (context.viewX + context.area.w / 2) / 256
local centreY = level.yMin + (context.viewY + context.area.h / 2) / 256
local n = 2 ^ level.zoom
context.feed.longitude = centreX / n * 360 - 180
local mercator = math.pi * (1 - 2 * centreY / n)
context.feed.latitude = math.atan((math.exp(mercator) - math.exp(-mercator)) / 2) * 180 / math.pi
map.refresh(context)
assert(context.markerVisible)
local tileWrites, tileVisibility, sources = 0, 0, {}
local callbacks = {}
for index, slot in ipairs(context.tiles) do
    tileWrites = tileWrites + slot.image.writes
    tileVisibility = tileVisibility + slot.image.visibilityCalls
    sources[index] = slot.file
    callbacks[index] = slot.image.properties.file
    a.assertEqual(callbacks[index](), slot.file)
end
local tileLoads, views = context.tileLoads, context.viewChanges
local markerWrites = context.marker.writes
map.refresh(context)
a.assertEqual(context.marker.writes, markerWrites, "unchanged GPS must not move marker")
for index = 1, 1000 do
    context.feed.longitude = context.feed.longitude + 0.0000001
    map.refresh(context)
end
local writes, visibility = 0, 0
for index, slot in ipairs(context.tiles) do
    writes = writes + slot.image.writes
    visibility = visibility + slot.image.visibilityCalls
    a.assertEqual(slot.file, sources[index])
    a.assertEqual(slot.image.properties.file, callbacks[index])
end
a.assertEqual(writes, tileWrites, "GPS-only updates must not write tile geometry")
a.assertEqual(visibility, tileVisibility, "GPS-only updates must not change tile visibility")
a.assertEqual(fileReads, 0, "GPS-only updates must not access files")
a.assertEqual(context.tileLoads, tileLoads)
a.assertEqual(context.viewChanges, views)
a.assertEqual(#fixture.lvglMock.objects, objects)
assert(context.markerMoves > 1)

context.feed.state = "stale"
map.refresh(context)
a.assertEqual(context.markerVisible, false)
a.assertEqual(context.homeVisible, false)
a.assertEqual(context.statusText, "GPS STALE")
context.feed.state = "normal"
map.refresh(context)
assert(context.markerVisible)
context.feed.fix = false
map.refresh(context)
a.assertEqual(context.statusText, "NO FIX")
context.feed.fix = true
context.feed.latitude, context.feed.longitude = nil, nil
map.refresh(context)
a.assertEqual(context.statusText, "INVALID GPS")
context.feed.latitude, context.feed.longitude = 0, 0
map.refresh(context)
a.assertEqual(context.markerVisible, false)
assert(string.find(context.statusText, "OFF VIEW", 1, true))
io.open, io.read = open, read

local function settle()
    local steps = 0
    repeat
        local loads = context.tileLoads
        fixture.tick(25)
        map.refresh(context)
        assert(context.tileLoads - loads <= 1, "at most one new tile source per callback")
        steps = steps + 1
        assert(steps <= 24, "map transition did not settle")
    until not context.dirty and not context.pending and not context.followPan
end
local function nativeControlTap(index)
    fixture.tick(20)
    local y = context.area.zoomY + ({ 60, 92, 20 })[index]
    local rect = { x = 0, y = 0 }
    map.event(context, EVT_TOUCH_FIRST, { x = 1, y = 7 }, rect)
    map.event(context, EVT_TOUCH_BREAK, { x = 0, y = 0 }, rect)
    for _ = 1, 3 do
        map.event(context, EVT_TOUCH_TAP, { x = context.area.zoomX + 20, y = y }, rect)
    end
end
nativeControlTap(1)
settle()
a.assertEqual(context.levelIndex, 2, "native local press followed by screen-space TAP must zoom in")
nativeControlTap(2)
settle()
a.assertEqual(context.levelIndex, 1, "native TAP must zoom out without duplicate activation")
for _ = 1, 20 do
    -- Exercise actual button closures, not just a helper that bypasses the UI.
    pressControl(1)
    settle()
    a.assertEqual(context.levelIndex, 2)
    map.move(context, 128, 0)
    settle()
    map.move(context, 100000, 100000)
    settle()
    a.assertEqual(context.viewX, 1024 - context.area.w)
    a.assertEqual(context.viewY, 1024 - context.area.h)
    pressControl(2)
    settle()
end
a.assertEqual(#fixture.lvglMock.objects, objects, "pan/zoom must reuse image objects")
map.move(context, 0, 0, 1)
settle()
fixture.pump(host, 40)
local startX, startY = context.viewX, context.viewY
local loadsBeforeDrag = context.tileLoads
local slot = context.tiles[1]
local rect = host.dashboardLoader.panelRect(host, fixture.entryById(host, "map").placement)
local fingerX, fingerY = rect.x + context.area.x + 220, rect.y + context.area.y + 100
assert(
    definition.event(
        host,
        EVT_TOUCH_FIRST,
        { x = rect.x + context.area.zoomX + 20, y = rect.y + context.area.zoomY + 20 }
    ),
    "zoom control touches must not start a map drag"
)
a.assertEqual(context.drag, nil)
assert(definition.event(host, EVT_TOUCH_SLIDE, { x = fingerX, y = fingerY }))
assert(definition.event(host, EVT_TOUCH_BREAK, { x = 0, y = 0 }))
a.assertEqual(context.levelIndex, 2, "dragging off a control must cancel activation")
local visibilityBefore, filesBefore = {}, {}
for index, tile in ipairs(context.tiles) do
    visibilityBefore[index], filesBefore[index] = tile.image.visibilityCalls, tile.file
end
assert(definition.event(host, EVT_TOUCH_FIRST, { x = fingerX, y = fingerY }))
assert(definition.event(host, EVT_TOUCH_SLIDE, { x = fingerX + 10, y = fingerY }))
local previewX = slot.image.properties.x
local previewWrites = slot.image.writes
assert(definition.event(host, EVT_TOUCH_BREAK, { x = fingerX + 10, y = fingerY }))
a.assertEqual(slot.image.properties.x, previewX, "release must not snap pixels back")
map.refresh(context)
a.assertEqual(context.pending, nil, "a pan within tile coverage must not start a loading cycle")
a.assertEqual(slot.image.writes, previewWrites, "release must not rewrite retained tile geometry")
a.assertEqual(context.tileLoads, loadsBeforeDrag)
for index, tile in ipairs(context.tiles) do
    a.assertEqual(tile.image.visibilityCalls, visibilityBefore[index], "retained tiles must never flash")
end
map.move(context, 10, 0)
settle()
for index, tile in ipairs(context.tiles) do
    visibilityBefore[index] = tile.image.visibilityCalls
end
assert(not definition.event(host, EVT_TOUCH_SLIDE, { x = fingerX, y = fingerY }))
definition.refresh(host, EVT_TOUCH_FIRST, { x = fingerX, y = fingerY })
assert(context.drag)
local dragReads = 0
io.open = function(...)
    dragReads = dragReads + 1
    return open(...)
end
for delta = 1, 80 do
    local loads = context.tileLoads
    fixture.tick(2)
    definition.refresh(host, EVT_TOUCH_SLIDE, { x = fingerX + delta, y = fingerY })
    assert(context.tileLoads - loads <= 1, "live dragging must load at most one source per callback")
    assert(not host.editorUi, "a moving finger must not trigger the hold-to-edit gesture")
end
io.open = open
assert(dragReads > 0, "newly exposed tiles must load while the finger is still down")
assert(context.tileLoads > loadsBeforeDrag, "dragging must not defer loading until release")
a.assertEqual(context.viewX, startX - 80, "dragging must commit the viewport continuously")
assert(definition.event(host, EVT_TOUCH_BREAK, { x = fingerX + 80, y = fingerY }))
settle()
for index, tile in ipairs(context.tiles) do
    if tile.file ~= "" and tile.file == filesBefore[index] then
        a.assertEqual(tile.image.visibilityCalls, visibilityBefore[index], "overlapping tiles must remain visible")
    end
end
a.assertEqual(context.tileLoads - loadsBeforeDrag, 2, "crossing one column must load only two new tiles")
a.assertEqual(context.viewX, startX - 80)
a.assertEqual(context.viewY, startY)
assert(definition.event(host, EVT_TOUCH_FIRST, { x = fingerX, y = fingerY }))
assert(definition.event(host, EVT_TOUCH_SLIDE, { x = fingerX + 10000, y = fingerY + 10000 }))
a.assertEqual(context.viewX, 0, "drag must clamp to coverage")
a.assertEqual(context.viewY, 0)
map.refresh(context)
assert(definition.event(host, EVT_TOUCH_SLIDE, { x = fingerX - 10000, y = fingerY - 10000 }))
settle()
for _, tile in ipairs(context.tiles) do
    if tile.visible then
        assert(tile.file ~= "", "reversed drag must not reveal obsolete sources")
        local level = context.pack.levels[context.levelIndex]
        local x = level.xMin + (tile.x + context.viewX) / 256
        local y = level.yMin + (tile.y + context.viewY) / 256
        a.assertEqual(
            tile.file,
            context.directory .. string.format("%d/%d/%d.jpg", level.zoom, x, y),
            "reversed drag must display the source for its current tile position"
        )
    end
end
assert(definition.event(host, EVT_TOUCH_SLIDE, { x = fingerX + 10000, y = fingerY + 10000 }))
fixture.lvglMock.setFullScreen(false)
map.refresh(context)
a.assertEqual(context.drag, nil, "fullscreen exit must cancel an unfinished drag")
a.assertEqual(context.viewX, 0, "fullscreen exit must preserve the current viewport")
fixture.lvglMock.settle()
fixture.lvglMock.setFullScreen(true)
map.refresh(context)
settle()
fixture.lvglMock.releaseClearedObjects()
local homeLevel = context.pack.levels[context.levelIndex]
local homeN = 2 ^ homeLevel.zoom
local homeMercator = math.pi * (1 - 2 * (homeLevel.yMin + 100 / 256) / homeN)
context.feed = {
    known = true,
    fix = true,
    state = "normal",
    latitude = math.atan((math.exp(homeMercator) - math.exp(-homeMercator)) / 2) * 180 / math.pi,
    longitude = (homeLevel.xMin + 100 / 256) / homeN * 360 - 180,
    home = true,
}
context.feed.pilotLatitude, context.feed.pilotLongitude = context.feed.latitude, context.feed.longitude
map.refresh(context)
assert(context.homeVisible)
assert(definition.event(host, EVT_TOUCH_FIRST, { x = fingerX, y = fingerY }))
for _, delta in ipairs({ -600, -500, 0, -600, 0 }) do
    assert(definition.event(host, EVT_TOUCH_SLIDE, { x = fingerX + delta, y = fingerY }))
    local px, py = map.project(homeLevel, context.feed.pilotLatitude, context.feed.pilotLongitude, context.transform)
    px, py = math.floor(px - context.viewX + 0.5), math.floor(py - context.viewY + 0.5)
    a.assertEqual(context.homeMarker.properties.x, px - 26, "dragged home image must match its projected position")
    a.assertEqual(context.homeMarker.properties.y, py - 26, "home circle centre must stay geographically anchored")
    a.assertEqual(context.homeVisible, px >= 0 and py >= 0 and px < context.area.w and py < context.area.h)
    settle()
    map.refresh(context)
    a.assertEqual(context.homeMarker.properties.x, px - 26, "tile loading must not displace home")
    a.assertEqual(context.homeMarker.properties.y, py - 26)
end
assert(context.homeVisible, "home must reappear at the correct position after reversing a drag")
assert(definition.event(host, EVT_TOUCH_BREAK, { x = 0, y = 0 }))
context.following = true
local function positionAt(x, y)
    local level = context.pack.levels[context.levelIndex]
    local n = 2 ^ level.zoom
    local mercator = math.pi * (1 - 2 * (level.yMin + y / 256) / n)
    context.feed.latitude = math.atan((math.exp(mercator) - math.exp(-mercator)) / 2) * 180 / math.pi
    context.feed.longitude = (level.xMin + x / 256) / n * 360 - 180
end
map.move(context, 200 - context.viewX, 200 - context.viewY)
positionAt(context.viewX + context.area.w * 0.7, context.viewY + context.area.h * 0.5)
settle()
a.assertEqual(context.viewX, 200, "GPS inside the dead zone must not pan")
a.assertEqual(context.viewY, 200)
positionAt(context.viewX + context.area.w * 0.9, context.viewY + context.area.h * 0.9)
context.feed.state = "stale"
map.refresh(context)
a.assertEqual(context.viewX, 200, "stale coordinates must not trigger follow")
context.feed.state = "normal"
context.feed.fix = false
map.refresh(context)
a.assertEqual(context.viewX, 200, "missing fix must not trigger follow")
context.feed.fix = true
local savedLatitude = context.feed.latitude
context.feed.latitude = nil
map.refresh(context)
a.assertEqual(context.viewX, 200, "invalid coordinates must not trigger follow")
context.feed.latitude = savedLatitude
settle()
map.refresh(context)
assert(math.abs(context.markerX - context.area.w / 2) <= 1, "dead-zone breach must recenter horizontally")
assert(math.abs(context.markerY - context.area.h / 2) <= 1, "dead-zone breach must recenter vertically")
local followedX, followedY = context.viewX, context.viewY
local followedLoads = context.tileLoads
for _ = 1, 10 do
    map.refresh(context)
end
a.assertEqual(context.viewX, followedX, "recentered GPS must not cause follow jitter")
a.assertEqual(context.viewY, followedY)
a.assertEqual(context.tileLoads, followedLoads)
context.followSample = nil
positionAt(context.viewX + context.area.w * 0.85, context.viewY + context.area.h / 2)
map.refresh(context)
local slowPan = assert(context.followPan)
a.assertEqual(slowPan.duration, 300, "slow movement should get a three-second pan")
a.assertEqual(context.viewX, slowPan.x, "animation must not jump on its first frame")
fixture.tick(150)
map.refresh(context)
assert(context.viewX > slowPan.x and context.viewX < slowPan.targetX, "pan must interpolate between start and target")
a.assertEqual(context.followPan, slowPan, "transition must retain its original target")
settle()
a.assertEqual(context.viewX, slowPan.targetX)
map.move(context, 200 - context.viewX, 200 - context.viewY)
context.followSample = nil
positionAt(200 + context.area.w / 2, 200 + context.area.h / 2)
settle()
for step = 1, 5 do
    fixture.tick(20)
    positionAt(200 + context.area.w / 2 + step * 20, 200 + context.area.h / 2)
    map.refresh(context)
end
fixture.tick(20)
positionAt(200 + context.area.w * 0.85, 200 + context.area.h / 2)
map.refresh(context)
assert(context.followPan.duration < slowPan.duration, "faster screen-space movement must shorten the pan")
assert(context.followPan.duration >= 50, "adaptive duration must remain at least half a second")
settle()
positionAt(5000, 5000)
settle()
a.assertEqual(context.viewX, 1024 - context.area.w, "follow must clamp at coverage edges")
a.assertEqual(context.viewY, 1024 - context.area.h)
assert(definition.event(host, EVT_TOUCH_FIRST, { x = fingerX, y = fingerY }))
assert(definition.event(host, EVT_TOUCH_BREAK, { x = 0, y = 0 }))
assert(context.following, "a tap must not pause follow")
positionAt(100, 100)
map.refresh(context)
assert(context.followPan, "a new breach must start another transition")
assert(definition.event(host, EVT_TOUCH_FIRST, { x = fingerX, y = fingerY }))
assert(definition.event(host, EVT_TOUCH_SLIDE, { x = fingerX + 20, y = fingerY }))
assert(not context.following, "manual dragging must pause follow")
a.assertEqual(context.followPan, nil, "manual dragging must cancel an animated pan")
assert(definition.event(host, EVT_TOUCH_BREAK, { x = 0, y = 0 }))
followedX, followedY = context.viewX, context.viewY
positionAt(100, 100)
settle()
a.assertEqual(context.viewX, followedX, "follow must remain paused after release")
a.assertEqual(context.viewY, followedY)
pressControl(3)
assert(context.following, "target control must resume follow after dragging")
settle()
assert(context.viewX ~= followedX or context.viewY ~= followedY, "resuming follow must recenter after a breach")
context.following = false
objects = #fixture.lvglMock.objects
collectgarbage("collect")
collectgarbage("collect")
local memory = collectgarbage("count")
for _ = 1, 100 do
    map.move(context, 0, 0, 1)
    settle()
    map.move(context, 0, 0, -1)
    settle()
end
collectgarbage("collect")
collectgarbage("collect")
local growth = collectgarbage("count") - memory
assert(growth < 4, "repeated zoom must not retain growing Lua state: " .. growth .. " KiB")
a.assertEqual(#fixture.lvglMock.objects, objects)
for index, slot in ipairs(context.tiles) do
    a.assertEqual(slot.image.properties.file, callbacks[index], "file callbacks must not be replaced")
end

map.update(context, { x = 0, y = 0, w = 480, h = 252 })
settle()
assert(context.area.y + context.area.h <= 252)
a.assertEqual(#fixture.lvglMock.objects, objects)
-- A missing tile must escape to the host's standard retained-error path.
map.update(context, { x = 0, y = 0, w = 480, h = 272 })
map.move(context, 0, 0, 1)
settle()
map.move(context, 100 - context.viewX, 250 - context.viewY)
settle()
local visibleTiles = 0
for _, tile in ipairs(context.tiles) do
    if tile.visible then
        visibleTiles = visibleTiles + 1
    end
end
a.assertEqual(visibleTiles, 9, "full-height viewport must cover three partially visible tile rows")
a.assertEqual(context.area.x + context.area.w, 480)
a.assertEqual(context.area.h, 272)
for rows = 1, 4 do
    for columns = 1, 4 do
        local width, height = columns * 116, rows * 60
        map.update(context, { x = 0, y = 0, w = width, h = height })
        settle()
        assert(context.area.w <= width and context.area.h <= height)
        a.assertEqual(context.area.x, context.theme.spacing.accentWidth)
        a.assertEqual(context.area.y, 0)
        a.assertEqual(context.area.x + context.area.w, width, "map must reach the right panel edge")
        a.assertEqual(context.area.h, height, "map must reach the top and bottom panel edges")
        a.assertEqual(context.panel.width, width)
        a.assertEqual(context.panel.height, height)
        a.assertEqual(context.panel.accent.properties.w, context.theme.spacing.accentWidth)
        a.assertEqual(#context.controls, context.area.showZoom and 4 or 0)
        assert(context.viewX >= 0 and context.viewY >= 0)
        fixture.lvglMock.settle()
    end
end
map.update(context, { x = 0, y = 0, w = 480, h = 252 })
settle()
context.tiles[1].file = ""
context.directory = widgetPath .. "missing/"
context.dirty = true
local ok, message = pcall(map.refresh, context)
a.assertEqual(ok, false)
a.assertContains(message, "missing/")
-- Restore a valid directory but corrupt a header preflight result.
context.directory = widgetPath .. "AEROGRID/maps/tiles/companion-v1-jpeg-v1/"
context.pending, context.dirty = nil, true
io.read = function()
    return string.rep("x", 26)
end
ok, message = pcall(map.refresh, context)
io.read = read
a.assertEqual(ok, false)
a.assertContains(message, "256x256")

-- Bound complete host callbacks, including initial pack parsing and panel creation.
fixture.reset()
local measuredHost = definition.create(
    { x = 0, y = 0, w = 480, h = 272 },
    { Layout = "review-map", Theme = "modern-dark" },
    widgetPath
)
local worst = 0
fixture.lvglMock.setPropertyValidation(false)
fixture.lvglMock.setCallCounting(false)
fixture.lcdMock.setTextMeasurement(false)
for index = 1, 160 do
    fixture.lvglMock.setFullScreen(index >= 60)
    local entry = fixture.entryById(measuredHost, "map")
    if entry and index > 80 then
        entry.instance.feed = {
            known = true,
            fix = true,
            state = "normal",
            latitude = 25.9973,
            longitude = -97.1572 + index * 0.000001,
        }
        if index % 20 == 0 then
            map.move(entry.instance, 0, 0, entry.instance.levelIndex == 1 and 1 or -1)
        end
    end
    fixture.tick(25)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 200
    end, "", 200)
    local success, failure = pcall(definition.refresh, measuredHost)
    debug.sethook()
    assert(success, failure)
    worst = math.max(worst, instructions)
    assert(
        instructions < 15000,
        "map host callback exceeded reserved Lua instruction budget: " .. instructions .. " at " .. index
    )
end
fixture.lcdMock.setTextMeasurement(true)
fixture.lvglMock.setCallCounting(true)
fixture.lvglMock.setPropertyValidation(true)
a.assertEqual(#measuredHost.errors, 0, table.concat(measuredHost.errors, "\n"))
assert(fixture.instanceOf(measuredHost, "map").viewChanges > 1)
local entry = fixture.entryById(measuredHost, "map")
local services = measuredHost.dashboardLoader.buildServices(measuredHost, entry.placement)
local function selectAutomaticArea(instance, latitude, longitude)
    instance.feed = { known = true, fix = true, state = "normal", latitude = latitude, longitude = longitude }
    for _ = 1, 16 do
        fixture.tick(25)
        map.refresh(instance)
        if instance.pack then
            return
        end
    end
    error("automatic map selection did not find an installed area")
end
local captured = map.create(
    entry.container,
    { x = 0, y = 0, w = 480, h = 272 },
    { label = "MAP", source = "GPS", armSwitch = "SFv" },
    services
)
a.assertEqual(
    captured.feed,
    services.navigation:subscribe("GPS", "SFv"),
    "map must share the navigation subscription for the configured arm switch"
)
assert(captured.feed ~= services.navigation:subscribe("GPS"), "custom capture must not use the default EdgeTX home")
assert(captured.feed ~= services.navigation:subscribe("GPS", "SAv"), "different switches must keep separate homes")
selectAutomaticArea(captured, 25.9973, -97.1572)
local arrow = map.create(
    entry.container,
    { x = 0, y = 0, w = 480, h = 272 },
    { label = "MAP", source = "GPS", headingSource = "Hdg", positionMarker = "arrow", flightPath = "trail" },
    services
)
selectAutomaticArea(arrow, 25.9973, -97.1572)
arrow.headingFeed = { available = true, fresh = true, stale = false, value = 0 }
repeat
    fixture.tick(25)
    map.refresh(arrow)
until not arrow.dirty and not arrow.pending and #arrow.pathLines == arrow.pathCapacity
local arrowObjects = #fixture.lvglMock.objects
for _, degrees in ipairs({ 0, 45, 90, 180, 270, 359, 360, -90 }) do
    arrow.headingFeed.value = degrees
    map.refresh(arrow)
    local orientation = math.floor(degrees / 10 + 0.5) * 10 % 360
    a.assertContains(arrow.aircraft.root.properties.file(), string.format("map-arrow-%03d.png", orientation))
    a.assertEqual(arrow.marker.properties.x, arrow.markerX - 26)
    a.assertEqual(arrow.marker.properties.y, arrow.markerY - 26)
    assertFootprint(arrow.aircraft)
end
a.assertEqual(#fixture.lvglMock.objects, arrowObjects, "arrow rotation must reuse the same image object")
a.assertContains(arrow.followAircraft.file, "map-follow.png", "marker selection must not change the follow control")
a.assertEqual(#arrow.pathLines, 60, "arrow trail must have bounded split-segment capacity")
arrow.pathPoints = {
    { latitude = arrow.feed.latitude, longitude = arrow.feed.longitude - 0.003, time = getTime() },
    { latitude = arrow.feed.latitude, longitude = arrow.feed.longitude + 0.003, time = getTime() },
}
map.refresh(arrow)
assert(not arrow.pathLines[1].hidden and not arrow.pathLines[2].hidden, "crossing must retain both outside portions")
for index, line in ipairs(arrow.pathLines) do
    if not line.hidden then
        local pts = line.properties.pts
        local dx, dy = pts[2][1] - pts[1][1], pts[2][2] - pts[1][2]
        local length = dx * dx + dy * dy
        local t = length > 0
                and math.max(
                    0,
                    math.min(1, ((arrow.markerX - pts[1][1]) * dx + (arrow.markerY - pts[1][2]) * dy) / length)
                )
            or 0
        local distance = math.sqrt((pts[1][1] + t * dx - arrow.markerX) ^ 2 + (pts[1][2] + t * dy - arrow.markerY) ^ 2)
        assert(distance >= 26, "blue stroke and white edging must stay outside the marker circle")
        a.assertEqual(arrow.pathOutlines[index].properties.opacity, 170)
    end
end
fixture.tick(3001)
map.refresh(arrow)
for index, line in ipairs(arrow.pathLines) do
    assert(line.hidden and arrow.pathOutlines[index].hidden, "split segments must expire together")
end
local headed = map.create(
    entry.container,
    { x = 0, y = 0, w = 480, h = 272 },
    { label = "MAP", source = "GPS", headingSource = "Hdg" },
    services
)
a.assertEqual(headed.headingFeed, services.telemetry:subscribe("Hdg"), "heading must use shared telemetry")
headed.following = false
selectAutomaticArea(headed, 25.9973, -97.1572)
headed.headingFeed = { available = true, fresh = true, stale = false, value = 0 }
repeat
    fixture.tick(25)
    map.refresh(headed)
until not headed.dirty and not headed.pending
local headingLoads, headingObjects = headed.tileLoads, #fixture.lvglMock.objects
local headingTileWrites = {}
for index, slot in ipairs(headed.tiles) do
    headingTileWrites[index] = slot.image.writes
end
local headingFileReads = 0
io.open = function(...)
    headingFileReads = headingFileReads + 1
    return open(...)
end
for _, degrees in ipairs({ 0, 45, 90, 180, 270, 359, 360, -90, 91.4 }) do
    headed.headingFeed.value = degrees
    map.refresh(headed)
    a.assertEqual(headed.heading, degrees % 360, "telemetry heading must take precedence without GPS movement")
    local orientation = math.floor(degrees / 10 + 0.5) * 10 % 360
    a.assertEqual(headed.aircraft.heading, orientation)
    assertFootprint(headed.aircraft)
    a.assertContains(headed.aircraft.root.properties.file(), string.format("map-aircraft-%03d.png", orientation))
    a.assertEqual(headed.marker.properties.x, headed.markerX - 26, "PNG centre must anchor exactly at GPS")
    a.assertEqual(headed.marker.properties.y, headed.markerY - 26)
    assertAircraftColors(headed.aircraft, lcd.RGB(0x70D6F3))
end
io.open = open
a.assertEqual(headingFileReads, 0, "heading-only changes must not access files")
a.assertEqual(headed.tileLoads, headingLoads)
a.assertEqual(#fixture.lvglMock.objects, headingObjects, "turning must reuse existing objects")
for index, slot in ipairs(headed.tiles) do
    a.assertEqual(slot.image.writes, headingTileWrites[index], "turning must not update tile geometry")
end
a.assertEqual(headed.followAircraft.heading, 0, "re-follow glyph must remain fixed north-facing")
local markerWrites, aircraftFile = headed.marker.writes, headed.aircraft.file
map.refresh(headed)
a.assertEqual(headed.marker.writes, markerWrites, "unchanged heading must not rewrite the marker")
a.assertEqual(headed.aircraft.file, aircraftFile)
headed.headingFeed.value = 94.9
map.refresh(headed)
a.assertEqual(headed.aircraft.file, aircraftFile, "same 10-degree bucket must retain the source")
headed.headingFeed.value = 95
map.refresh(headed)
a.assertContains(headed.aircraft.file, "map-aircraft-100.png")
for _, invalid in ipairs({ 0 / 0, math.huge, -math.huge, "90", false }) do
    headed.headingFeed.value = invalid
    map.refresh(headed)
    a.assertEqual(headed.heading, nil)
    a.assertEqual(headed.statusText, "GPS")
    assert(not string.find(headed.statusText, "Z", 1, true), "status must omit zoom level")
    assertAircraftColors(headed.aircraft, lcd.RGB(0x70D6F3))
end
headed.headingFeed.value, headed.headingFeed.stale = 90, true
map.refresh(headed)
a.assertEqual(headed.heading, nil, "stale heading must not appear live")
headed.headingFeed.stale, headed.headingFeed.fresh = false, false
map.refresh(headed)
a.assertEqual(headed.heading, nil)
headed.headingFeed.fresh, headed.headingFeed.available = true, false
map.refresh(headed)
a.assertEqual(headed.heading, nil)
headed.headingFeed = nil
headed.feed.longitude = headed.feed.longitude + 0.001
map.refresh(headed)
a.assertEqual(headed.heading, nil, "configured but unavailable heading must not silently switch to GPS course")

headed.settings.headingSource = ""
map.refresh(headed)
a.assertEqual(headed.heading, nil, "one GPS position does not establish direction")
assertAircraftColors(headed.aircraft, lcd.RGB(0x70D6F3))
local baseline = headed.feed.longitude
headed.feed.longitude = baseline + 0.000001
map.refresh(headed)
a.assertEqual(headed.heading, nil, "sub-metre changes must accumulate without an arbitrary direction")
headed.feed.longitude = baseline + 0.00002
map.refresh(headed)
assert(math.abs(headed.heading - 90) < 0.01, "eastbound movement must point east")
assertAircraftColors(headed.aircraft, lcd.RGB(0x70D6F3))
map.refresh(headed)
assert(math.abs(headed.heading - 90) < 0.01, "stationary GPS must retain the last course")
headed.feed.latitude = headed.feed.latitude + 0.0001
map.refresh(headed)
assert(math.abs(headed.heading - 45) < 0.01, "GPS course must average the latest east and north segments")
headed.feed.latitude = headed.feed.latitude - 0.0002
map.refresh(headed)
assert(math.abs(headed.heading - 90) < 0.01, "opposing north/south segments must cancel in the circular mean")
headed.feed.longitude = headed.feed.longitude - 0.0001
map.refresh(headed)
assert(math.abs(headed.heading - 90) < 0.01, "ambiguous GPS course must retain the previous heading")
for _ = 1, 8 do
    headed.feed.longitude = headed.feed.longitude - 0.0001
    map.refresh(headed)
end
assert(math.abs(headed.heading - 270) < 0.01, "sustained movement must replace the old direction")
a.assertEqual(#headed.courseHistory, 5, "real GPS updates must retain at most five course samples")
local courseIndex = headed.courseIndex
map.refresh(headed)
a.assertEqual(headed.courseIndex, courseIndex, "repeated refreshes of one fix must not bias the mean")
for _, lost in ipairs({ "stale", "no-fix", "invalid", "no-source" }) do
    headed.feed.state = lost == "stale" and "stale" or "normal"
    headed.feed.fix = lost ~= "no-fix"
    headed.feed.known = lost ~= "no-source"
    local latitude = headed.feed.latitude
    if lost == "invalid" then
        headed.feed.latitude = nil
    end
    map.refresh(headed)
    headed.feed.state, headed.feed.fix, headed.feed.known = "normal", true, true
    headed.feed.latitude = latitude + 0.001
    map.refresh(headed)
    a.assertEqual(headed.heading, nil, "recovery must not derive a course across a GPS outage")
    a.assertEqual(headed.courseHistory, nil, "GPS recovery must discard pre-outage course samples")
end
do
    local options = map.create(entry.container, { x = 0, y = 0, w = 480, h = 272 }, {
        label = "MAP",
        source = "GPS",
        satelliteSource = "Sats",
        showCoordinates = true,
        flightPath = "trail",
    }, services)
    selectAutomaticArea(options, 25.9973, -97.1572)
    options.satellites = { available = true, fresh = true, stale = false, value = 5 }
    fixture.tick(100)
    map.refresh(options)
    a.assertEqual(options.coordinatesLabel.properties.text, "25.997300, -97.157200")
    a.assertEqual(options.coordinatesLabel.properties.font(), SMLSIZE, "coordinates must use the larger font")
    a.assertEqual(options.coordinatesLabel.properties.y, options.area.h - 28)
    a.assertEqual(options.satelliteLabel.properties.text, "5")
    a.assertEqual(options.badgeText, options.state("warning", "cyan").badge)
    options.primitives.setBadge(
        options,
        options.themeBuilder,
        options.badge,
        options.area.frame,
        options.fonts.badge,
        "WAITING FOR GPS",
        options.theme.color.amber
    )
    options.primitives.setSatelliteHeader(options, "5", options.state("normal", "cyan"))
    if options.showSatellites then
        local header = options.satelliteHeader.properties
        assert(header.x + header.w < options.badge.properties.x, "shared header must reserve the displayed GPS badge")
    end
    assert(#options.pathPoints >= 1)
    options.satellites.value = 2
    fixture.tick(100)
    map.refresh(options)
    a.assertEqual(options.badgeText, options.state("critical", "cyan").badge)
    options.feed.state = "stale"
    map.refresh(options)
    if options.showSatellites then
        local header = options.satelliteHeader.properties
        assert(header.x + header.w < options.badge.properties.x, "satellites must not overlap GPS status badges")
    end
    a.assertEqual(options.badgeText, options.state("stale", "cyan").badge)
    a.assertEqual(options.statusLabel.properties.text, "GPS STALE")
    options.feed.state = "normal"
    options.feed.longitude = options.feed.longitude + 0.0001
    fixture.tick(100)
    map.refresh(options)
    assert(options.pathPoints[#options.pathPoints].breakBefore, "GPS loss must split the flight path")
    a.assertEqual(options.pathLines[1].hidden, true, "GPS loss must not connect the flight path")
    options.feed.longitude = options.feed.longitude + 0.0001
    fixture.tick(100)
    map.refresh(options)
    a.assertEqual(options.pathLines[2].hidden, false, "continuous trail segments must render")
    for index = 1, 30 do
        options.feed.longitude = options.feed.longitude + 0.0001
        fixture.tick(100)
        map.refresh(options)
    end
    a.assertEqual(#options.pathPoints, 31)
    a.assertEqual(options.pathLines[1].properties.opacity, 0, "30-second-old trail must fade out")
    a.assertEqual(options.pathLines[30].properties.opacity, 247, "recent trail must remain bright")
    a.assertEqual(options.pathLines[30].properties.thickness, 5)
    a.assertEqual(options.pathLines[30].properties.color, lcd.RGB(0x328BEE))
    for index, outline in ipairs(options.pathOutlines) do
        a.assertEqual(outline.properties.thickness, 8)
        a.assertEqual(outline.properties.color, lcd.RGB(0xFFFFFF))
        a.assertEqual(
            outline.properties.opacity,
            math.floor(options.pathLines[index].properties.opacity * 170 / 255 + 0.5)
        )
        a.assertEqual(outline.hidden, options.pathLines[index].hidden)
        local outer, inner = outline.properties.pts, options.pathLines[index].properties.pts
        for endpoint = 1, 2 do
            a.assertEqual(outer[endpoint][1], inner[endpoint][1])
            a.assertEqual(outer[endpoint][2], inner[endpoint][2])
        end
    end
    for index = 2, 30 do
        assert(options.pathLines[index].properties.opacity > options.pathLines[index - 1].properties.opacity)
    end
    fixture.tick(1500)
    map.refresh(options)
    assert(#options.pathPoints <= 16, "stationary trail must expire by age rather than point count")
    options.feed.state = "stale"
    fixture.tick(1501)
    map.refresh(options)
    a.assertEqual(#options.pathPoints, 0, "trail must expire during GPS outages")
    for _, line in ipairs(options.pathLines) do
        assert(line.hidden, "expired trail must not remain visible")
    end
    for _, outline in ipairs(options.pathOutlines) do
        assert(outline.hidden, "expired trail outline must not remain visible")
    end
end
do
    local full = map.create(
        entry.container,
        { x = 0, y = 0, w = 480, h = 272 },
        { label = "MAP", source = "GPS", flightPath = "full", positionMarker = "arrow" },
        services
    )
    selectAutomaticArea(full, 25.9973, -97.1572)
    full.automatic = false
    local maximum = #full.pathPoints
    local start = full.pathPoints[1]
    local worstFull = 0
    fixture.lvglMock.setPropertyValidation(false)
    fixture.lvglMock.setCallCounting(false)
    fixture.lcdMock.setTextMeasurement(false)
    local function refreshFull()
        local instructions = 0
        debug.sethook(function()
            instructions = instructions + 200
        end, "", 200)
        local ok, failure = pcall(map.refresh, full)
        debug.sethook()
        assert(ok, failure)
        worstFull = math.max(worstFull, instructions)
        assert(instructions < 15000, "full history refresh exceeded instruction budget: " .. instructions)
    end
    for index = 1, 1100 do
        full.feed.longitude = -97.1572 + index * 0.0005
        fixture.tick(200)
        refreshFull()
        maximum = math.max(maximum, #full.pathPoints)
    end
    a.assertEqual(maximum, 1024, "full history must be independent of the 63-segment drawing budget")
    a.assertEqual(#full.pathPoints, 1024)
    a.assertEqual(#full.pathLines, 126)
    a.assertEqual(full.pathPoints[1], start, "history compaction must preserve the flight start")
    a.assertEqual(full.pathPoints[#full.pathPoints].longitude, full.feed.longitude)
    for index = 2, #full.pathPoints do
        assert(full.pathPoints[index].time > full.pathPoints[index - 1].time, "retained timestamps must stay ordered")
    end
    for _ = 1, 250 do
        refreshFull()
        if not full.pathJob then
            break
        end
    end
    assert(not full.pathJob, "bounded simplification must finish without further GPS movement")
    assert(#full.pathCache <= 63)
    local cached = full.pathCache
    refreshFull()
    a.assertEqual(full.pathCache, cached, "unchanged route/view must reuse simplified geometry")
    full.feed.latitude, full.feed.longitude = 25.9973, -97.1572
    full.following = false
    local cx, cy =
        map.project(full.pack.levels[full.levelIndex], full.feed.latitude, full.feed.longitude, full.transform)
    full.viewX, full.viewY = map.clampView(
        full.pack.levels[full.levelIndex],
        full.area.w,
        full.area.h,
        cx - full.area.w / 2,
        cy - full.area.h / 2
    )
    full.pathPoints = {}
    for index = 1, 1024 do
        full.pathPoints[index] = {
            latitude = full.feed.latitude + math.cos(index * 0.2) * 0.0006,
            longitude = full.feed.longitude + math.sin(index * 0.2) * 0.001,
            time = getTime() - 1024 + index,
            breakBefore = index == 1,
        }
    end
    full.pathLastTime = getTime()
    full.pathRevision = full.pathRevision + 1
    full.pathJob = nil
    for _ = 1, 5000 do
        refreshFull()
        if not full.pathJob then
            break
        end
    end
    assert(not full.pathJob, "complex visible routes must finish incremental simplification")
    assert(#full.pathCache > 0 and #full.pathCache <= 63)
    local visible = 0
    for index, line in ipairs(full.pathLines) do
        if not line.hidden then
            visible = visible + 1
            a.assertEqual(line.properties.opacity, 255, "full mode must not acquire the tail's age fade")
            a.assertEqual(full.pathOutlines[index].properties.opacity, 170)
        end
    end
    assert(visible > 0, "simplified full route must actually render")
    local oldCache = full.pathCache
    full.viewX = full.viewX + 1
    for _ = 1, 5000 do
        refreshFull()
        if not full.pathJob then
            break
        end
    end
    assert(full.pathCache ~= oldCache, "panning must recull and rebuild geometry")
    local oldTransform = full.transform
    local savedHistory = full.pathPoints
    map.move(full, 0, 0, full.levelIndex == 1 and 1 or -1)
    for _ = 1, 5000 do
        refreshFull()
        if not full.pathJob and full.pathCacheTransform == full.transform then
            break
        end
    end
    assert(full.transform ~= oldTransform, "zoom must change projection")
    a.assertEqual(full.pathCacheTransform, full.transform, "zoom must rebuild using the new projection")
    a.assertEqual(full.pathPoints, savedHistory, "pan and zoom must not simplify or replace stored history")
    fixture.lcdMock.setTextMeasurement(true)
    fixture.lvglMock.setCallCounting(true)
    fixture.lvglMock.setPropertyValidation(true)
    print("Full history worst panel callback: " .. worstFull .. " instructions (mock)")
    map.update(full, { x = 0, y = 0, w = 800, h = 480 })
    a.assertEqual(#full.tiles, 15, "editor maps must allocate enough native tile slots on larger radios")
    for _, slot in ipairs(full.tiles) do
        a.assertEqual(slot.image.parent, full.tileLayer, "resized tile slots must stay below paths and markers")
    end
    map.refresh(full)
    map.update(full, { x = 0, y = 0, w = 480, h = 272 })
    a.assertEqual(#full.tiles, 15, "shrinking must reuse rather than recreate the existing tile pool")
    map.refresh(full)
end
do
    local manifest = "format: aerogrid-map-area\nversion: 2\nid: nine-levels\n"
        .. 'name: "Nine levels"\n'
        .. "imagerySet: synthetic-v1-jpeg-q90\nprojection: EPSG:3857\n"
        .. "tileScheme: XYZ\ntileSize: 256\nimageFormat: jpeg\n"
        .. "selection:\n"
        .. "  bounds:\n"
        .. "    west: -97.158\n"
        .. "    south: 25.997\n"
        .. "    east: -97.157\n"
        .. "    north: 25.998\n"
        .. "  radio: tx16s\n"
        .. "  coverageMode: per-zoom-clamped\n"
        .. "levels:\n"
    for zoom = 11, 19 do
        local n = 2 ^ zoom
        manifest = manifest
            .. string.format(
                "  - zoom: %d\n    xMin: %d\n    xMax: %d\n    yMin: %d\n    yMax: %d\n",
                zoom,
                n - 1,
                n,
                n / 2,
                n / 2 + 1
            )
    end
    local originalStat = fstat
    local originalRead = services.host.layoutStore.readCandidate
    local reportedSize = #manifest
    local folder = services.host.layoutStore.sdRoot(services.host.path) .. "AEROGRID/maps/areas/"
    local manifestPath = folder .. "nine-levels.yaml"
    local manifestFile = assert(io.open(manifestPath, "w"))
    manifestFile:write(manifest)
    manifestFile:close()
    fstat = function(filename)
        if string.find(filename, "/areas/nine-levels.yaml", 1, true) then
            return { size = reportedSize }
        end
        return originalStat(filename)
    end
    services.host.layoutStore.readCandidate = function(filename)
        if string.find(filename, "/areas/nine-levels.yaml", 1, true) then
            return manifest
        end
        return originalRead(filename)
    end
    local instructions = 0
    fixture.lvglMock.setPropertyValidation(false)
    fixture.lvglMock.setCallCounting(false)
    fixture.lcdMock.setTextMeasurement(false)
    debug.sethook(function()
        instructions = instructions + 100
    end, "", 100)
    local okNine, nine = pcall(
        map.create,
        entry.container,
        { x = 0, y = 0, w = 480, h = 272 },
        { label = "MAP", source = "GPS" },
        services
    )
    assert(okNine, nine)
    nine.feed = { known = true, fix = true, state = "normal", latitude = 0, longitude = 179.9999 }
    nine.nextTileLoad = getTime() + 100000
    local loaded, loadError = true, nil
    for scanIndex = 1, 5 do
        loaded, loadError = pcall(map.refresh, nine)
        if not loaded or nine.pack then
            break
        end
    end
    debug.sethook()
    fixture.lcdMock.setTextMeasurement(true)
    fixture.lvglMock.setCallCounting(true)
    fixture.lvglMock.setPropertyValidation(true)
    assert(loaded, loadError)
    assert(
        instructions < 30000,
        "nine-level map discovery exceeded EdgeTX's 30,000-instruction budget: " .. instructions
    )
    a.assertEqual(#nine.pack.levels, 9)
    a.assertContains(nine.directory, "/tiles/synthetic-v1-jpeg-q90/")
    local sample = captured.pack.levels[1]
    local sampleFile = captured.directory .. string.format("%d/%d/%d.jpg", sample.zoom, sample.xMin, sample.yMin)
    local wrappedRead = false
    io.open = function(filename, mode)
        if string.find(filename, "/tiles/synthetic-v1-jpeg-q90/", 1, true) then
            local zoom, tileX = string.match(filename, "/(%d+)/(%d+)/%d+%.jpg$")
            assert(tonumber(tileX) < 2 ^ tonumber(zoom), "radio filenames must use canonical XYZ")
            wrappedRead = wrappedRead or tonumber(tileX) == 0
            return open(sampleFile, mode)
        end
        return open(filename, mode)
    end
    nine.nextTileLoad = nil
    for _ = 1, 10 do
        fixture.tick(25)
        map.refresh(nine)
    end
    io.open = open
    assert(wrappedRead, "date-line rendering must load the canonical zero column")
    reportedSize = #manifest + 1
    local incompleteContext = map.create(
        entry.container,
        { x = 0, y = 0, w = 480, h = 272 },
        { label = "MAP", source = "GPS" },
        services
    )
    incompleteContext.feed = { known = true, fix = true, state = "normal", latitude = 0, longitude = 179.9999 }
    incompleteContext.nextTileLoad = getTime() + 100000
    local complete, incomplete = true, nil
    for _ = 1, 3 do
        complete, incomplete = pcall(map.refresh, incompleteContext)
        if not complete then
            break
        end
    end
    a.assertEqual(complete, false)
    a.assertContains(incomplete, "incomplete map area read")
    reportedSize = 8193
    local oversizedContext = map.create(
        entry.container,
        { x = 0, y = 0, w = 480, h = 272 },
        { label = "MAP", source = "GPS" },
        services
    )
    oversizedContext.feed = { known = true, fix = true, state = "normal", latitude = 0, longitude = 179.9999 }
    oversizedContext.nextTileLoad = getTime() + 100000
    local oversized, tooLarge = true, nil
    for _ = 1, 3 do
        oversized, tooLarge = pcall(map.refresh, oversizedContext)
        if not oversized then
            break
        end
    end
    a.assertEqual(oversized, false)
    a.assertContains(tooLarge, "oversized map area")
    services.host.layoutStore.readCandidate = originalRead
    fstat = originalStat
    os.remove(manifestPath)
end
do
    local originalDir, originalStat = dir, fstat
    local originalRead = services.host.layoutStore.readCandidate
    local folder = services.host.layoutStore.sdRoot(services.host.path) .. "AEROGRID/maps/areas/"
    local manifests, names = {}, {}
    local scans, reads = 0, 0
    local function addArea(id, narrow, detail)
        local base = captured.pack
        local text = "format: aerogrid-map-area\nversion: 2\nid: "
            .. id
            .. '\nname: "Test area"'
            .. "\nimagerySet: "
            .. base.imagerySet
            .. "\nprojection: EPSG:3857\ntileScheme: XYZ\ntileSize: 256\nimageFormat: jpeg\n"
            .. "selection:\n"
            .. "  bounds:\n"
            .. "    west: -97.158\n"
            .. "    south: 25.997\n"
            .. "    east: -97.157\n"
            .. "    north: 25.998\n"
            .. "  radio: tx16s\n"
            .. "  coverageMode: per-zoom-clamped\n"
            .. "levels:\n"
        for _, level in ipairs(base.levels) do
            if not detail or level.zoom <= detail then
                local xMin, xMax, yMin, yMax = level.xMin, level.xMax, level.yMin, level.yMax
                if narrow and level == base.levels[#base.levels] then
                    local x, y = map.project(level, 25.9973, -97.1572)
                    xMin, yMin = level.xMin + math.floor(x / 256), level.yMin + math.floor(y / 256)
                    xMax, yMax = xMin, yMin
                end
                text = text
                    .. string.format(
                        "  - zoom: %d\n    xMin: %d\n    xMax: %d\n    yMin: %d\n    yMax: %d\n",
                        level.zoom,
                        xMin,
                        xMax,
                        yMin,
                        yMax
                    )
            end
        end
        manifests[id .. ".yaml"] = text
        names[#names + 1] = id .. ".yaml"
    end
    addArea("large", false)
    addArea("small", true)
    addArea("alpha", true)
    addArea("low-detail", false, 16)
    dir = function(path)
        a.assertEqual(path, folder)
        scans = scans + 1
        local index = 0
        return function()
            index = index + 1
            return names[index]
        end
    end
    fstat = function(path)
        if path == folder then
            return { size = 0 }
        end
        local name = string.sub(path, #folder + 1)
        if manifests[name] then
            return { size = #manifests[name] }
        end
        return originalStat(path)
    end
    services.host.layoutStore.readCandidate = function(path)
        local name = string.sub(path, #folder + 1)
        if manifests[name] then
            reads = reads + 1
            return manifests[name]
        end
        return originalRead(path)
    end
    local automatic = map.create(
        entry.container,
        { x = 0, y = 0, w = 480, h = 272 },
        { label = "AUTO", source = "GPS" },
        services
    )
    automatic.feed = { known = true, fix = false, state = "unavailable" }
    map.refresh(automatic)
    a.assertEqual(scans, 0, "GPS wait must not scan the SD card")
    a.assertEqual(automatic.statusText, "WAITING FOR GPS")
    a.assertEqual(automatic.badgeText, automatic.state("unavailable", "cyan").badge)
    a.assertEqual(automatic.statusLabel.properties.text, "WAITING FOR GPS")
    local status = automatic.statusLabel.properties
    assert(math.abs(status.x + status.w / 2 - (automatic.area.x + automatic.area.w / 2)) <= 1)
    assert(math.abs(status.y + automatic.themeBuilder.fontHeight(SMLSIZE) / 2 - automatic.area.h / 2) <= 1)
    a.assertEqual(#automatic.controls, 0)
    a.assertEqual(map.event(automatic, EVT_TOUCH_TAP, { x = 20, y = 20 }, { x = 0, y = 0 }), false)
    local originalFrame = automatic.themeBuilder.frame
    local reserved = { w = 40, h = 40 }
    automatic.themeBuilder.frame = function(...)
        local frame = originalFrame(...)
        frame.reserved = reserved
        return frame
    end
    map.update(automatic, { x = 0, y = 0, w = 120, h = 68 })
    assert(not automatic.statusLabel.hidden, "small panel should keep status when it fits below the menu")
    assert(automatic.statusLabel.properties.y >= reserved.h, "status must clear the reserved menu corner")
    reserved = { w = 40, h = 68 }
    map.update(automatic, { x = 0, y = 0, w = 240, h = 40 })
    assert(not automatic.statusLabel.hidden, "wide short panel should use space beside the menu")
    assert(automatic.statusLabel.properties.x >= reserved.w, "status beside the menu must clear its right edge")
    map.update(automatic, { x = 0, y = 0, w = 120, h = 40 })
    assert(automatic.statusLabel.hidden, "status must hide when neither safe region can fit the complete message")
    reserved = nil
    map.update(automatic, { x = 0, y = 0, w = 120, h = 68 })
    assert(not automatic.statusLabel.hidden, "fullscreen must restore an unchanged status")
    local smallStatus = automatic.statusLabel.properties
    assert(math.abs(smallStatus.y + automatic.themeBuilder.fontHeight(SMLSIZE) / 2 - 34) <= 1)
    automatic.themeBuilder.frame = originalFrame
    map.update(automatic, { x = 0, y = 0, w = 480, h = 272 })
    automatic.feed = { known = true, fix = true, state = "stale", latitude = 25.9973, longitude = -97.1572 }
    map.refresh(automatic)
    a.assertEqual(scans, 0, "a stale cached position cannot select an area")
    automatic.feed.state = "normal"
    for _ = 1, #names + 1 do
        local before = reads
        map.refresh(automatic)
        assert(reads - before <= 1, "discover at most one manifest per callback")
    end
    a.assertEqual(automatic.pack.id, "alpha", "detail, smallest coverage, then ID must break overlap ties")
    a.assertEqual(scans, 1)
    a.assertEqual(reads, 4)
    automatic.feed.state = "stale"
    map.refresh(automatic)
    a.assertEqual(automatic.pack.id, "alpha", "brief GPS loss must retain the selected area")
    a.assertEqual(automatic.statusText, "GPS STALE")
    automatic.feed.state = "normal"
    -- A newly added overlapping area must not displace the current selection.
    addArea("aaa", true)
    for _ = 1, 10 do
        fixture.tick(25)
        map.refresh(automatic)
    end
    a.assertEqual(automatic.pack.id, "alpha")
    a.assertEqual(scans, 1, "live GPS updates within coverage must not reread manifests")
    automatic.feed.latitude, automatic.feed.longitude = 0.1, 0.1
    for _ = 1, #names + 1 do
        map.refresh(automatic)
    end
    a.assertEqual(automatic.pack, nil)
    a.assertEqual(automatic.statusText, "NO MAP AT GPS")
    a.assertEqual(#automatic.controls, 0)
    for _, tile in ipairs(automatic.tiles) do
        assert(tile.image.hidden, "out-of-coverage selection must not display the old map")
    end
    local before = scans
    map.refresh(automatic)
    a.assertEqual(scans, before, "unmatched GPS must not trigger an unbounded rescan loop")
    fixture.tick(1000)
    automatic.feed.latitude, automatic.feed.longitude = 25.9973, -97.1572
    for _ = 1, #names + 1 do
        map.refresh(automatic)
    end
    a.assertEqual(automatic.pack.id, "aaa", "reacquisition must reconsider overlapping installed areas")
    local noMaps = map.create(
        entry.container,
        { x = 0, y = 0, w = 480, h = 272 },
        { label = "EMPTY", source = "GPS" },
        services
    )
    noMaps.feed = automatic.feed
    fstat = function(path)
        if path == folder then
            return nil
        end
        return originalStat(path)
    end
    map.refresh(noMaps)
    a.assertEqual(noMaps.statusText, "NO INSTALLED MAP")
    local invalid = map.create(
        entry.container,
        { x = 0, y = 0, w = 480, h = 272 },
        { label = "INVALID", source = "GPS" },
        services
    )
    invalid.feed = automatic.feed
    names, manifests = { "bad.yaml" }, { ["bad.yaml"] = "not: an area\n" }
    fstat = function(path)
        if path == folder then
            return { size = 0 }
        end
        local name = string.sub(path, #folder + 1)
        return manifests[name] and { size = #manifests[name] } or originalStat(path)
    end
    local success, failure = pcall(map.refresh, invalid)
    a.assertEqual(success, false, "invalid installed areas must fail explicitly")
    a.assertContains(failure, "unsupported map area")
    local limited = map.create(
        entry.container,
        { x = 0, y = 0, w = 480, h = 272 },
        { label = "LIMIT", source = "GPS" },
        services
    )
    limited.feed = automatic.feed
    names, manifests = {}, {}
    for index = 1, 65 do
        addArea("area-" .. index, false)
    end
    for _ = 1, 64 do
        map.refresh(limited)
    end
    success, failure = pcall(map.refresh, limited)
    a.assertEqual(success, false)
    a.assertContains(failure, "at most 64 installed areas")
    fstat = originalStat
    services.host.layoutStore.readCandidate = originalRead
    dir = originalDir
end
print("Map prototype worst host callback: " .. worst .. " instructions (mock; not native draw/decode time)")
