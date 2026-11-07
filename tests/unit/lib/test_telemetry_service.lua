-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local telemetryService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/telemetry_service.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()

local function testSubscribeReturnsLiveView()
    local env = services.environment({
        getValue = function()
            return 12
        end,
    })
    local service = telemetryService.new(env, services)
    local view = service:subscribe("RxBt")
    assertions.assertEqual(view.name, "RxBt")
    assertions.assertEqual(type(view), "table")
end

local function testLinkSubscriptionExists()
    local env = services.environment({
        getRSSI = function()
            return 42
        end,
    })
    local service = telemetryService.new(env, services)
    local link = service:link()
    assertions.assertTableHasKey(link, "live", "link state should include a live flag")
end

local function testTransmitterLocalSourceIsNotLinkEvidence()
    local service = telemetryService.new(
        services.environment({
            getRSSI = function()
                return 0
            end,
            getFieldInfo = function(name)
                return { id = name == "RFMD" and 1 or 2, name = name, unit = 0 }
            end,
            getValue = function(id)
                return id == 1 and 27 or 100
            end,
        }),
        services
    )
    local link = service:link()
    local mode = service:subscribe("RFMD", false)
    assertions.assertEqual(service:subscribe("RFMD"), mode, "source identity remains shared")
    local task = service.entries[1].task
    task:step(task.want, "run", 10)
    assertions.assertEqual(mode.value, 27, "local data remains readable")
    assertions.assertEqual(link.live, false, "a second subscriber cannot turn local data into receiver evidence")
    service:subscribe("RQly")
    task = service.entries[2].task
    task:step(task.want, "run", 20)
    assertions.assertEqual(link.live, true, "receiver data can contradict the missing RSSI indicator")
end

local function testSchedulerPollsAllSources()
    local reads = {}
    local service = telemetryService.new(
        services.environment({
            getRSSI = function()
                return 42
            end,
            getFieldInfo = function(name)
                return { id = tonumber(name), name = name, unit = 0 }
            end,
            getValue = function(id)
                reads[id] = (reads[id] or 0) + 1
                return id
            end,
        }),
        services
    )
    for index = 1, 24 do
        service:subscribe(tostring(index))
    end
    local queue = scheduler.new({ steady = 0 })
    for _, entry in ipairs(service.entries) do
        local task = entry.task
        task.tickElapsed = scheduler.elapsed
        assert(queue:add({ id = task.id, decl = task.decl, instance = task, due = 0 }))
    end
    for now = 0, 9 do
        queue:run("steady", now, 0)
    end
    for index = 1, 24 do
        assertions.assertEqual(reads[index], 1, "each source must make progress before its next release")
    end
    assert(not queue:takeErrors())
end

local function testSharedSubscribersKeepTheFastestRequestedInterval()
    local reads = 0
    local service = telemetryService.new(
        services.environment({
            getFieldInfo = function(name)
                return { id = tonumber(name), name = name, unit = 1 }
            end,
            getValue = function()
                reads = reads + 1
                return reads
            end,
            getRSSI = function()
                return 42
            end,
        }),
        services
    )
    local feed = service:subscribe("1", nil, 25)
    assertions.assertEqual(service.interval, 25)
    service:subscribe("1", nil, 20)
    assertions.assertEqual(service.entries[1].interval, 20)
    assertions.assertEqual(service.interval, 20)
    local task = service.entries[1].task
    task.tickElapsed = scheduler.elapsed
    task:step(task.want, "run", 0)
    task:step(task.want, "run", 10)
    assertions.assertEqual(reads, 1, "a 20-tick consumer must not poll at tick 10")
    service:subscribe("1")
    assertions.assertEqual(service.entries[1].interval, 10, "omitted intervals retain the legacy rate")
    assertions.assertEqual(service.interval, 10, "the fastest same-source request controls polling")
    task:step(task.want, "run", 20)
    assertions.assertEqual(reads, 2)
    assertions.assertEqual(feed.value, 2)
end

local function testSourceTaskIdsRemainStableAsSubscriptionsGrow()
    local service = telemetryService.new(services.environment({}), services)
    service:subscribe("S01", nil, 20)
    local first = service.entries[1].task
    local firstId = first.id
    service:subscribe("S02", nil, 20)
    assertions.assertEqual(service.entries[1].task.id, firstId, "adding a source must not rename an existing task")
    service:subscribe("S01", nil, 15)
    assertions.assertEqual(service.entries[1].task.id, firstId, "updating a source must keep its task identity")
    assertions.assertEqual(
        service.entries[1].task.id == service.entries[2].task.id,
        false,
        "distinct sources need distinct task identities"
    )
end

local function testSchedulerPollsEachSourceWithItsObserversAtomically()
    local calls = {}
    local service = telemetryService.new(
        services.environment({
            getFieldInfo = function(name)
                return { id = tonumber(name), name = name, unit = 1 }
            end,
            getValue = function(id)
                return id
            end,
            getRSSI = function()
                return 42
            end,
        }),
        services
    )
    service:subscribe("1")
    service:subscribe("2")
    for index = 1, 3 do
        service:observe({
            sample = function(_, reading, now)
                calls[#calls + 1] = reading.name .. ":" .. now
            end,
        })
    end
    local first, second = service.entries[1].task, service.entries[2].task
    local delay = first:step(first.want, "run", 10)
    assertions.assertEqual(delay, 10)
    assertions.assertEqual(table.concat(calls, ","), "1:10,1:10,1:10")
    delay = second:step(second.want, "run", 11)
    assertions.assertEqual(delay, 10)
    assertions.assertEqual(table.concat(calls, ","), "1:10,1:10,1:10,2:11,2:11,2:11")
end

local function testSchedulerOwnedTelemetryHasNoLegacyEntryPoint()
    local runtime = services.runtime(services.environment({}))
    runtime.host = {}
    local service = telemetryService.new(runtime.env, services, runtime)
    assertions.assertEqual(service.update, nil, "scheduler-owned telemetry must not retain a production update path")
    assertions.assertEqual(service.decl.class, "critical")
end

local function run()
    testSubscribeReturnsLiveView()
    testLinkSubscriptionExists()
    testTransmitterLocalSourceIsNotLinkEvidence()
    testSchedulerPollsAllSources()
    testSharedSubscribersKeepTheFastestRequestedInterval()
    testSourceTaskIdsRemainStableAsSubscriptionsGrow()
    testSchedulerPollsEachSourceWithItsObserversAtomically()
    testSchedulerOwnedTelemetryHasNoLegacyEntryPoint()
end

run()
