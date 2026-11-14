-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local Columns = fixture.module("lib/chart_columns.lua")
local Renderer = fixture.module("lib/chart_columns_renderer.lua")
local recorder = assert(loadfile(root .. "/tests/support/chart_recorder.lua"))(root)
fixture.reset()

local SERIES = 3
local function build()
    local record = recorder(SERIES)
    local context = {
        area = { x = 4, y = 10, w = 120, h = 90 },
        rect = { w = 160, h = 120 },
        geometryVersion = 1,
        session = record.session,
        plotRoot = lvgl.box({ x = 0, y = 0, w = 160, h = 120 }),
        series = {},
        columnConsumers = {},
        version = 1,
    }
    for series = 1, SERIES do
        context.series[series] = { color = lcd.RGB(255, 0, 0), low = 0, high = 100 }
        context.columnConsumers[series] = Columns.attach(record.history, record.feeds[series], 120, {
            recording = { history = record.history, session = record.session },
        })
    end
    return record, context, Renderer.new(context)
end

local function queued(context)
    local total = 0
    for _, owner in ipairs(context.columnConsumers) do
        total = total + #owner.pending
    end
    return total
end

local function feed(record, from, to)
    for at = from, to, 20 do
        record.sample(at, { at % 90, (at + 30) % 90, (at + 60) % 90 })
    end
end

-- Without an allowance a call takes at most its fixed limit per series, as before.
local record, context, renderer = build()
record.sample(0, { 1, 2, 3 })
renderer:append()
feed(record, 20, 600)
local backlog = queued(context)
assert(backlog > SERIES * 10, "the test needs a backlog larger than one append can take")
local appended, _, used = renderer:append()
assert(appended > 0 and appended <= SERIES * 10 and used > 0)

-- A small allowance bounds the estimated cost and leaves the rest queued.
record, context, renderer = build()
record.sample(0, { 1, 2, 3 })
renderer:append()
feed(record, 20, 600)
local before = queued(context)
local allowance = 1500
local taken, painted
taken, painted, used = renderer:append(false, allowance)
assert(used <= allowance, "an append must stay within its allowance, used " .. used)
assert(taken > 0 and queued(context) > 0 and queued(context) == before - taken, "unfinished samples stay queued")

-- Nothing fits: no work, no charge, and no series is skipped for good.
local none
none, _, used = renderer:append(false, Renderer.SERIES_COST)
assert(none == 0 and used == 0)

-- A grant that fits one series' work at a time still serves every series in turn.
record, context, renderer = build()
record.sample(0, { 1, 2, 3 })
renderer:append()
feed(record, 20, 400)
local served = {}
local calls = 0
while queued(context) > 0 and calls < 400 do
    local per = {}
    for series, owner in ipairs(context.columnConsumers) do
        per[series] = #owner.pending
    end
    taken, _, used = renderer:append(false, Renderer.SERIES_COST + Renderer.SAMPLE_COST * 4 + Renderer.PAINT_COST * 4)
    assert(used <= Renderer.SERIES_COST + Renderer.SAMPLE_COST * 4 + Renderer.PAINT_COST * 4)
    for series, owner in ipairs(context.columnConsumers) do
        if #owner.pending < per[series] then
            served[series] = (served[series] or 0) + 1
        end
    end
    calls = calls + 1
end
assert(queued(context) == 0, "bounded appends must drain the backlog")
for series = 1, SERIES do
    assert(served[series] and served[series] > 1, "series " .. series .. " was starved by the others")
end

-- Bounded appends draw exactly what one unbounded append draws.
local recordA, contextA, rendererA = build()
local recordB, contextB, rendererB = build()
for _, record in ipairs({ recordA, recordB }) do
    record.sample(0, { 1, 2, 3 })
end
rendererA:append()
rendererB:append()
feed(recordA, 20, 600)
feed(recordB, 20, 600)
local guard = 0
while queued(contextA) > 0 and guard < 400 do
    rendererA:append()
    guard = guard + 1
end
guard = 0
while queued(contextB) > 0 and guard < 400 do
    rendererB:append(false, 1200)
    guard = guard + 1
end
for series = 1, SERIES do
    local a, b = contextA.columnConsumers[series].map, contextB.columnConsumers[series].map
    for slot = 1, 120 do
        assert(a.kinds[slot] == b.kinds[slot] and a.low[slot] == b.low[slot] and a.high[slot] == b.high[slot])
        assert(a.ends[slot] == b.ends[slot], "bounded append changed the data in column " .. slot)
    end
    assert(#contextB.columnConsumers[series].map.dirtyList == 0, "bounded append left columns undrawn")
end
