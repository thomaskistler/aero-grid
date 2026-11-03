-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local Mipmap = fixture.module("lib/chart_mipmap.lua")
local Renderer = fixture.module("lib/chart_mipmap_renderer.lua")
local Oracle = assert(loadfile(root .. "/tests/support/mipmap_reading_oracle.lua"))()
local recorder = assert(loadfile(root .. "/tests/support/mipmap_recorder.lua"))(root)

for _, width in ipairs({ 226, 397, 398, 399, 400, 800 }) do
    fixture.reset()
    local record = recorder(3)
    local context = {
        area = { x = 4, y = 10, w = width, h = 90 },
        rect = { w = width + 20, h = 120 },
        geometryVersion = 1,
        session = record.session,
        plotRoot = lvgl.box({ x = 0, y = 0, w = width + 20, h = 120 }),
        series = {},
        mipmapConsumers = {},
    }
    local oracles = {}
    for series = 1, 3 do
        context.series[series] = { color = lcd.RGB(series * 70, 0, 0), low = -1, high = 2 }
        context.mipmapConsumers[series] = Mipmap.attach(record.history, record.feeds[series], width)
        oracles[series] = Oracle.new()
    end
    local renderer = Renderer.new(context)
    while not renderer:prepare() do
    end
    assert(#renderer.objects == width * 3 and #renderer.groups == 12, "native pool must remain physical-width bounded")
    local function sample(at, missing)
        local values = {}
        for series = 1, 3 do
            values[series] = (at * 17 + series * 13) % 70 / 10 - 2
        end
        record.sample(at, values, missing)
        for series, owner in ipairs(context.mipmapConsumers) do
            oracles[series]:sample(owner.map.at, missing and nil or values[series], false)
        end
    end
    local function finish()
        local turns = 0
        repeat
            turns = turns + 1
            assert(turns < 1000, "renderer failed to settle")
            fixture.lvglMock.settle()
        until renderer:step(24)
    end
    local function verify()
        for series, job in ipairs(renderer.published) do
            assert(job.revision == job.map.revision)
            for bucket = job.origin, job.origin + width - 1 do
                local low, high, gap = oracles[series]:column(width, job.level, bucket)
                local index = (series - 1) * width + bucket % width + 1
                assert(not not renderer.visible[index] == not gap, "visibility differs from independent oracle")
                if not gap then
                    local object = renderer.objects[index]
                    local properties = object.properties
                    local offset = renderer.offsets[renderer.membership[index]]
                    assert(properties.x + offset == job.left + bucket - job.origin, "incorrect grouped x")
                    local scale, bottom = job.height / (job.high - job.low), job.top + job.height
                    local top = math.max(job.top, math.min(bottom, math.floor(bottom - (high - job.low) * scale + 0.5)))
                    local last = math.max(job.top, math.min(bottom, math.floor(bottom - (low - job.low) * scale + 0.5)))
                    assert(properties.y == top and properties.h == last - top + 1, "incorrect clipped envelope")
                end
            end
        end
    end
    for at = 0, 5900, 5 do
        sample(at)
    end
    finish()
    verify()
    sample(6001)
    renderer:step(24)
    sample(6005)
    finish()
    verify()
    for _, item in ipairs(context.series) do
        item.low, item.high = -0.5, 0.5
    end
    finish()
    verify()
    local span = context.mipmapConsumers[1].map.levels[10].span
    for at = 6100, math.ceil(span * 3), 101 do
        sample(at)
    end
    finish()
    verify()
    for quarter = 9, 20 do
        sample(math.ceil(span + quarter * span / 4))
        finish()
        verify()
    end
    renderer:reset()
    for _, oracle in ipairs(oracles) do
        oracle.times, oracle.values, oracle.breaks = {}, {}, {}
    end
    local index = 1
    repeat
        index = record.history:resetSession(1000000, index)
    until not index
    sample(1000010)
    finish()
    verify()
    for _, owner in ipairs(context.mipmapConsumers) do
        owner:destroy()
    end
    renderer:destroy()
end
print("Production mipmap single-pool geometry matches independent input envelopes")
