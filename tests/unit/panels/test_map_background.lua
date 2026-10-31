-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local a = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local map = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/map.lua"))()
local navigation = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/navigation_service.lua"))()
local now = 0
getTime = function()
    return now
end

-- No UI or filesystem globals are provided: background sampling must only use GPS and history.
for _, mode in ipairs({ "off", "trail", "full" }) do
    now = 0
    local context = {
        settings = { flightPath = mode },
        navigation = navigation,
        feed = { known = true, fix = true, state = "normal", latitude = 26, longitude = -97 },
        pathPoints = {},
    }
    map.background(context)
    a.assertEqual(#context.pathPoints, mode == "off" and 0 or 1, "recording must not require a selected map")
    for index = 1, 40 do
        now = index * 100
        context.feed.longitude = -97 + index * 0.0001
        map.background(context)
        map.background(context)
    end
    local expected = mode == "off" and 0 or mode == "trail" and 31 or 41
    a.assertEqual(#context.pathPoints, expected, "background sampling must preserve rate and retention bounds")
    if mode ~= "off" then
        a.assertEqual(context.pathPoints[1].time, mode == "trail" and 1000 or 0)
        a.assertEqual(context.pathPoints[#context.pathPoints].time, 4000)
        local revision = context.pathRevision
        now = now + 50
        context.feed.longitude = context.feed.longitude + 0.0001
        map.background(context)
        a.assertEqual(context.pathRevision, revision, "background fixes must remain at least one second apart")
        now = now + 50
        context.feed.longitude = context.pathPoints[#context.pathPoints].longitude + 0.000001
        map.background(context)
        a.assertEqual(context.pathRevision, revision, "background fixes must remain at least five metres apart")
        context.feed.longitude = context.pathPoints[#context.pathPoints].longitude
        now = now + 3001
        map.background(context)
        a.assertEqual(#context.pathPoints, mode == "trail" and 1 or 41, "stationary trail must expire by age")
    end
end

for _, outage in ipairs({ "stale", "no-fix", "no-source", "missing", "nan", "infinite", "out-of-range" }) do
    now = 0
    local context = {
        settings = { flightPath = "full" },
        navigation = navigation,
        feed = { known = true, fix = true, state = "normal", latitude = 26, longitude = -97 },
        pathPoints = {},
    }
    map.background(context)
    context.feed.state = outage == "stale" and "stale" or "normal"
    context.feed.fix = outage ~= "no-fix"
    context.feed.known = outage ~= "no-source"
    if outage == "missing" then
        context.feed.latitude = nil
    elseif outage == "nan" then
        context.feed.latitude = 0 / 0
    elseif outage == "infinite" then
        context.feed.longitude = math.huge
    elseif outage == "out-of-range" then
        context.feed.longitude = 181
    end
    now = 50
    map.background(context)
    a.assertEqual(#context.pathPoints, 1, "unusable background GPS must not add a fix")
    context.feed = { known = true, fix = true, state = "normal", latitude = 26, longitude = -96.999 }
    now = 100
    map.background(context)
    assert(context.pathPoints[2].breakBefore, "recovery must not bridge a hidden GPS outage")
    context.feed.longitude = -96.998
    now = 200
    map.background(context)
    a.assertEqual(context.pathPoints[3].breakBefore, false, "continuous GPS must resume after the outage")
    context.settings.flightPath = "trail"
    context.feed.state = "stale"
    now = 3201
    map.background(context)
    a.assertEqual(#context.pathPoints, 0, "trail must expire even during a hidden GPS outage")
end

do
    now = 0
    local context = {
        settings = { flightPath = "full" },
        navigation = navigation,
        feed = { known = true, fix = true, state = "normal", latitude = 26, longitude = -97 },
        pathPoints = {},
    }
    map.background(context)
    local start = context.pathPoints[1]
    for index = 1, 1100 do
        now = index * 100
        context.feed.longitude = -97 + index * 0.0001
        map.background(context)
        assert(#context.pathPoints <= 1024, "hidden full history must remain bounded")
    end
    a.assertEqual(#context.pathPoints, 1024)
    a.assertEqual(context.pathPoints[1], start, "hidden compaction must preserve the session start")
    a.assertEqual(context.pathPoints[1024].longitude, context.feed.longitude)
    for index = 2, #context.pathPoints do
        assert(context.pathPoints[index].time > context.pathPoints[index - 1].time)
    end
end
