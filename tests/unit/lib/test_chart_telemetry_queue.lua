-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local trace = assert(loadfile(root .. "/tests/support/chart_runtime_trace.lua"))()
local Queue = assert(loadfile(root .. "/tests/support/chart_telemetry_queue.lua"))()
local queue = Queue.new(trace, 6001)
assert(#queue.events == 24)
assert(queue:take(1, 6000) == nil, "future input must not arrive early")
local first = queue:take(1, 6001)
assert(first.at == 6001 and first.value == trace.value(6001, 1))
assert(queue:take(1, 6005) == nil)
assert(queue:take(7, 7000) == nil, "uncontrolled sources must remain live")
for source = 6, 1, -1 do
    for batch = source == 1 and 2 or 1, trace.BATCHES do
        local event = assert(queue:take(source, 7000))
        local expected = 6001 + (batch - 1) * trace.PERIOD
        assert(
            event.at == expected and event.value == trace.value(expected, source),
            "delayed polling must retain every event in source order"
        )
    end

    assert(queue:take(source, 8000) == nil, "drained queues must not repeat readings")
end

local support = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local Telemetry = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/telemetry_service.lua"))()
queue = Queue.new(trace, 6001)
local active, delivered, polling = nil, {}, false
local telemetry = Telemetry.new(
    support.environment({
        getRSSI = function()
            return 80
        end,
        getFieldInfo = function(name)
            return { id = tonumber(string.match(name, "%d+")), name = name, unit = 1 }
        end,
        getValue = function()
            return active.value
        end,
    }),
    support
)
for source = 1, 6 do
    telemetry:subscribe("Q" .. source)
end
local poll = telemetry.poll
telemetry.poll = function(service, entry, now)
    local source = tonumber(string.match(entry.state.name, "%d+"))
    active = assert(queue:take(source, now))
    polling = true
    poll(service, entry, now)
end
telemetry.observers = {
    {
        sample = function(_, reading, now)
            assert(
                polling and reading.fresh and reading.updatedAt == now,
                "observer delivery must remain synchronous with actual polling"
            )
            assert(reading.value == active.value)
            delivered[#delivered + 1] = active
            active, polling = nil, false
        end,
    },
}
for _ = 1, 12 do
    local before = #delivered
    assert(telemetry:update(7000, 1) == 1)
    assert(#delivered - before == 2, "one slot must bound queue delivery to two real polls")
end
assert(#delivered == 24)
