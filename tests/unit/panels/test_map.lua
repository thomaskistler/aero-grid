-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local map = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/map.lua"))()
local a = assert(loadfile(root .. "/tests/support/assertions.lua"))()
do
    local yaml = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/yaml.lua"))()
    local handle = assert(io.open(root .. "/tests/fixtures/map-imagery/areas/companion-naip.yaml", "r"))
    local area = assert(yaml.parse(handle:read("*a")))
    handle:close()
    map.validatePack(area)
    assert(map.covers(area, 25.9973, -97.1572), "stored imagery must cover Companion GPS at every zoom")
end

local function angleError(a1, a2)
    return math.abs((a1 - a2 + 180) % 360 - 180)
end
local history = {}
for _, bearing in ipairs({ 359, 1, 358, 2, 0 }) do
    map.meanCourse(history, bearing)
end
assert(angleError(history.course, 0) < 0.001, "course mean must wrap correctly across north")
history = {}
for _, bearing in ipairs({ 70, 110, 75, 105, 90 }) do
    map.meanCourse(history, bearing)
end
assert(angleError(history.course, 90) < 0.001, "GPS jitter must average around the actual direction")
local previous = history.course
map.meanCourse(history, 85)
assert(angleError(history.course, previous) < 4, "a noisy sample must not cause an abrupt course change")
for _ = 1, 50 do
    map.meanCourse(history, 180)
end
a.assertEqual(#history.courseHistory, 5, "course history must remain bounded")
assert(angleError(history.course, 180) < 0.001, "sustained turns must replace old samples")
history = {}
map.meanCourse(history, 0)
map.meanCourse(history, 180)
a.assertEqual(history.course, 0, "ambiguous opposing directions must retain the previous course")

local function pack()
    return {
        format = "aerogrid-map-area",
        version = 2,
        id = "synthetic",
        name = "Synthetic test area",
        imagerySet = "companion-v1-jpeg-v1",
        projection = "EPSG:3857",
        tileScheme = "XYZ",
        tileSize = 256,
        imageFormat = "jpeg",
        selection = {
            bounds = { west = -97.158, south = 25.997, east = -97.157, north = 25.998 },
            radio = "tx16s",
            coverageMode = "per-zoom-clamped",
        },
        levels = {
            { zoom = 16, xMin = 15080, xMax = 15081, yMin = 27863, yMax = 27864 },
            { zoom = 17, xMin = 30160, xMax = 30163, yMin = 55726, yMax = 55729 },
        },
    }
end

a.assertEqual(map.validatePack(pack()).version, 2)
do
    local value = pack()
    value.imageFormat = "jpeg"
    a.assertEqual(map.validatePack(value).imageFormat, "jpeg")
    value.imageFormat = "webp"
    a.assertEqual(pcall(map.validatePack, value), false)
    value.imageFormat = "png"
    a.assertEqual(pcall(map.validatePack, value), false)
    local frame = "\255\216\255\192\0\17\8\1\0\1\0\3\1\34\0\2\17\1\3\17\1\255\218\0\12"
    a.assertEqual(map.jpegHeader(frame), true)
    a.assertEqual(map.jpegHeader(string.gsub(frame, "\255\192", "\255\194")), true)
    a.assertEqual(map.jpegHeader(string.gsub(frame, "\8\1\0", "\12\1\0")), false)
    a.assertEqual(map.jpegHeader(string.gsub(frame, "\1\0\1\0", "\2\0\1\0")), false)
    a.assertEqual(map.jpegHeader(string.gsub(frame, "\0\17", "\0\2")), false)
    a.assertEqual(map.jpegHeader("\255\216\255\225\0\2" .. string.sub(frame, 3)), false)
    a.assertEqual(map.jpegHeader("\255\216\255\224\255\255" .. string.sub(frame, 3)), false)
    for length = 0, #frame - 1 do
        if length < #frame - 2 then
            a.assertEqual(map.jpegHeader(string.sub(frame, 1, length)), false)
        end
    end
end
for _, mutate in ipairs({
    function(p)
        p.version = 1
    end,
    function(p)
        p.name = " "
    end,
    function(p)
        p.selection = nil
    end,
    function(p)
        p.selection.coverageMode = "unknown"
    end,
    function(p)
        p.selection.bounds.east = p.selection.bounds.west
    end,
    function(p)
        p.selection.bounds.south = math.huge
    end,
    function(p)
        p.tileScheme = "TMS"
    end,
    function(p)
        p.tileSize = 512
    end,
    function(p)
        p.levels[1].xMin = -1
    end,
    function(p)
        p.levels[1].yMax = math.huge
    end,
    function(p)
        p.levels[2].zoom = 19
    end,
    function(p)
        p.levels[2].xMax = 99999
    end,
    function(p)
        p.levels[3] = p.levels[2]
    end,
    function(p)
        p.imagerySet = "../escape"
    end,
    function(p)
        p.id = "Upper"
    end,
    function(p)
        p.levels = {}
    end,
}) do
    local value = pack()
    mutate(value)
    a.assertEqual(pcall(map.validatePack, value), false)
end
a.assertEqual(
    #map.settings,
    12,
    "panel options should include initial zoom, GPS, marker, satellite, coordinate and path controls"
)
a.assertEqual(
    (function()
        for _, setting in ipairs(map.settings) do
            if setting.key == "pack" then
                return 1
            end
        end
        return 0
    end)(),
    0
)
a.assertEqual(#map.validateSettings({}), 0)
do
    local bounds = { left = -10, top = -10, right = 110, bottom = 110 }
    local function simplify(points, view)
        local projections = 0
        local job = map.newPathJob(points, function(point)
            projections = projections + 1
            return point.x, point.y
        end, view or bounds)
        local steps = 0
        repeat
            local before = projections
            map.stepPathJob(job)
            assert(projections - before <= 16, "projection must be incrementally budgeted")
            steps = steps + 1
            assert(steps < 10000, "simplification must terminate")
        until job.result
        a.assertEqual(projections, #points, "points must be projected just once per rebuild")
        return job.result
    end
    local straight = {}
    for index = 0, 100 do
        straight[#straight + 1] = { x = index, y = 0, time = index * 100 }
    end
    local result = simplify(straight)
    a.assertEqual(#result, 1, "straight sections should need only one line")
    a.assertEqual(result[1].first.source, straight[1])
    a.assertEqual(result[1].last.source, straight[#straight])
    a.assertEqual(straight[50].time, 4900, "render simplification must not alter timestamps")
    local corner = simplify({ { x = 0, y = 0 }, { x = 50, y = 50 }, { x = 100, y = 0 } })
    a.assertEqual(#corner, 2, "significant turns must be retained")
    a.assertEqual(corner[1].last.x, 50)
    a.assertEqual(corner[1].last.y, 50)
    local gap = simplify({
        { x = 0, y = 0 },
        { x = 10, y = 0 },
        { x = 20, y = 0, breakBefore = true },
        { x = 30, y = 0 },
    })
    a.assertEqual(#gap, 2, "GPS gaps must never be simplified into a connecting line")
    a.assertEqual(gap[1].last.x, 10)
    a.assertEqual(gap[2].first.x, 20)
    local hidden = simplify({ { x = 200, y = 200 }, { x = 210, y = 210 } })
    a.assertEqual(#hidden, 0, "off-screen segments must not consume the line budget")
    local crossing = simplify({ { x = -100, y = 50 }, { x = 200, y = 50 } })
    a.assertEqual(#crossing, 1, "crossing lines must remain even if both endpoints are off-screen")
    local jitter = {}
    for index = 0, 100 do
        jitter[#jitter + 1] = { x = index, y = index % 2 * 0.5 }
    end
    a.assertEqual(#simplify(jitter), 1, "subpixel jitter should disappear at this zoom")
    for _, point in ipairs(jitter) do
        point.y = point.y * 10
    end
    assert(#simplify(jitter) > 1, "zooming in must restore visible detail")
    local turns = {}
    for index = 0, 200 do
        turns[#turns + 1] = { x = index / 2, y = index % 2 * 100 }
    end
    a.assertEqual(#simplify(turns), 63, "complex routes must respect the render budget")
    local manyGaps = {}
    for index = 0, 199 do
        manyGaps[#manyGaps + 1] = { x = index / 2, y = 0, breakBefore = index % 2 == 0 }
    end
    local limited = simplify(manyGaps)
    a.assertEqual(#limited, 63, "many disjoint runs must stay bounded without connecting gaps")
    for _, segment in ipairs(limited) do
        a.assertEqual(segment.last.x - segment.first.x, 0.5)
    end
    local history = {}
    for index = 1, 1024 do
        history[index] = { latitude = 26, longitude = index * 0.0001, time = index * 100 }
    end
    history[2].latitude = 26.01
    local start, turn, finish = history[1], history[2], history[#history]
    map.compactHistory(history, 0)
    a.assertEqual(#history, 1023)
    a.assertEqual(history[1], start)
    a.assertEqual(history[2], turn, "history compaction should favor straight samples over a sharp turn")
    a.assertEqual(history[#history], finish)
    for _, point in ipairs(history) do
        point.breakBefore = true
    end
    map.compactHistory(history, 0)
    assert(history[2].breakBefore, "compaction must never bridge an outage when no removable interior exists")
end
a.assertEqual(#map.validateSettings({ positionMarker = "plane" }), 0)
a.assertEqual(#map.validateSettings({ positionMarker = "arrow" }), 0)
a.assertEqual(#map.validateSettings({ positionMarker = "unknown" }), 1)
do
    local function clip(x1, y1, x2, y2, part, expected)
        local actual = { map.clipPathSegment(x1, y1, x2, y2, 0, 0, 10, part) }
        a.assertEqual(#actual, #expected)
        for index, value in ipairs(expected) do
            assert(math.abs(actual[index] - value) < 0.00001, "circle clipping must preserve the outside portion")
        end
    end
    clip(-20, 0, 20, 0, 1, { -20, 0, -10, 0 })
    clip(-20, 0, 20, 0, 2, { 10, 0, 20, 0 })
    clip(-20, 0, 0, 0, 1, { -20, 0, -10, 0 })
    clip(-20, 0, 0, 0, 2, {})
    clip(0, 0, 20, 0, 1, {})
    clip(0, 0, 20, 0, 2, { 10, 0, 20, 0 })
    clip(-5, 0, 5, 0, 1, {})
    clip(-5, 0, 5, 0, 2, {})
    clip(0, 20, 20, 20, 1, { 0, 20, 20, 20 })
    clip(0, 20, 20, 20, 2, {})
    clip(0, 0, 0, 0, 1, {})
    clip(20, 0, 20, 0, 1, { 20, 0, 20, 0 })
end
a.assertEqual(#map.validateSettings({ pack = "synthetic" }), 1, "area overrides must be rejected")
for _, settings in ipairs({
    { satelliteSource = false },
    { satelliteCritical = 9, satelliteWarning = 8 },
    { satelliteWarning = -1 },
    { showSatellites = 1 },
    { showCoordinates = 1 },
    { flightPath = "historic" },
}) do
    a.assertEqual(#map.validateSettings(settings), 1)
end
do
    local broad = pack()
    local narrow = pack()
    narrow.id = "narrow"
    narrow.levels[2].xMax = narrow.levels[2].xMin + 1
    assert(map.prefer(narrow, broad))
    assert(not map.prefer(broad, narrow))
    local detail = pack()
    detail.levels[3] = { zoom = 18, xMin = 60320, xMax = 60327, yMin = 111452, yMax = 111459 }
    assert(map.prefer(detail, narrow), "detail must outrank coverage size")
    a.assertEqual(map.covers(broad, 25.9973, -97.1572), true)
    a.assertEqual(map.covers(broad, 0.1, 0.1), false)
    a.assertEqual(map.covers(broad, 90, 0), false)
    a.assertEqual(map.covers(broad, 0 / 0, 0), false)
    local crossing = pack()
    crossing.levels = { { zoom = 16, xMin = 65535, xMax = 65536, yMin = 32767, yMax = 32768 } }
    assert(map.covers(crossing, 0, 179.999))
    assert(map.covers(crossing, 0, -179.999))
    assert(not map.covers(crossing, 0, 0))
end
do
    local value = pack()
    value.levels = { { zoom = 11, xMin = 0, xMax = 1999, yMin = 0, yMax = 0 } }
    map.validatePack(value)
    value.levels[1].xMax = 2000
    a.assertEqual(pcall(map.validatePack, value), false, "exactly 2001 tiles must fail")
    value.levels = {}
    for zoom = 11, 19 do
        value.levels[#value.levels + 1] = { zoom = zoom, xMin = 0, xMax = 1, yMin = 0, yMax = 1 }
    end
    map.validatePack(value)
    value.levels[10] = { zoom = 20, xMin = 0, xMax = 1, yMin = 0, yMax = 1 }
    a.assertEqual(pcall(map.validatePack, value), false)
end
for _, source in ipairs({ "", "Hdg", "Yaw" }) do
    a.assertEqual(#map.validateSettings({ headingSource = source }), 0)
end
for _, source in ipairs({ false, 42 }) do
    a.assertEqual(#map.validateSettings({ headingSource = source }), 1)
end
for _, arm in ipairs({ "", "SF^", "SA-", "SFv", "L01" }) do
    a.assertEqual(#map.validateSettings({ armSwitch = arm }), 0)
end
for _, arm in ipairs({ "SF", "SFx", "L1", 42, false }) do
    a.assertEqual(#map.validateSettings({ armSwitch = arm }), 1)
end

local level = { zoom = 1, xMin = 1, xMax = 1, yMin = 1, yMax = 1 }
local x, y = map.project(level, 0, 0)
assert(math.abs(x) < 0.00001 and math.abs(y) < 0.00001)
x, y = map.project(level, -66.513260443, 90)
assert(math.abs(x - 128) < 0.00001 and math.abs(y - 128) < 0.00001)
for _, coords in ipairs({ { 90, 0 }, { -90, 0 }, { 0, 181 }, { 0 / 0, 0 }, { 0, math.huge } }) do
    a.assertEqual(map.project(level, coords[1], coords[2]), nil)
end
a.assertEqual(map.project(level, nil, nil), nil)
do
    local crossing = { zoom = 16, xMin = 65535, xMax = 65536, yMin = 32767, yMax = 32768 }
    local westX = map.project(crossing, 0, 179.999)
    local eastX = map.project(crossing, 0, -179.999)
    assert(westX < 256 and eastX > 256 and eastX - westX < 100)
    local view = {
        pack = { levels = { crossing, { zoom = 17, xMin = 0, xMax = 1, yMin = 65534, yMax = 65537 } } },
        levelIndex = 1,
        viewX = 32,
        viewY = 32,
        area = { w = 480, h = 272 },
    }
    map.move(view, 0, 0, 1)
    assert(view.viewX >= 0 and view.viewX <= 32, "zoom must use the nearby world copy")
end
local low, high = pack().levels[1], pack().levels[2]
local lx, ly = map.project(low, 25.9973, -97.1572)
local hx, hy = map.project(high, 25.9973, -97.1572)
assert(math.abs(hx - lx * 2) < 0.00001 and math.abs(hy - ly * 2) < 0.00001)
x, y = map.clampView(low, 480, 220, -1000, 10000)
a.assertEqual(x, 0)
a.assertEqual(y, 292)
x, y = map.clampView(level, 480, 272, 1000, -1000)
a.assertEqual(x, -112)
a.assertEqual(y, -8)

local context = {
    pack = pack(),
    levelIndex = 1,
    viewX = 16,
    viewY = 146,
    area = { w = 480, h = 220 },
}
map.move(context, 0, 0, 1)
a.assertEqual(context.levelIndex, 2)
a.assertEqual(context.viewX, 272)
a.assertEqual(context.viewY, 402)
map.move(context, 0, 0, -1)
a.assertEqual(context.viewX, 16)
a.assertEqual(context.viewY, 146)
map.move(context, -10000, -10000)
a.assertEqual(context.viewX, 0)
a.assertEqual(context.viewY, 0)
context.pending = {}
map.move(context, 10000, 10000, 1)
a.assertEqual(context.levelIndex, 1)
a.assertEqual(context.viewX, 0)
