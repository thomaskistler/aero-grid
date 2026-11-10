-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local telemetryService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/telemetry_service.lua"))()

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
    service:update(10)
    assertions.assertEqual(mode.value, 27, "local data remains readable")
    assertions.assertEqual(link.live, false, "a second subscriber cannot turn local data into receiver evidence")
    service:subscribe("RQly")
    service:update(20)
    assertions.assertEqual(link.live, true, "receiver data can contradict the missing RSSI indicator")
end

local function testHostPollingBudgetKeepsRoundRobinProgress()
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
    service.pollCap = 4
    for step = 1, 6 do
        service:update(step * 10)
        assertions.assertEqual(service.cursor, step * 4 % 24 + 1)
    end
    for index = 1, 24 do
        assertions.assertEqual(reads[index], 1, "a reduced budget must still visit every source")
    end
    service.pollCap = nil
    service:update(70)
    assertions.assertEqual(service.cursor, 9, "normal polling capacity returns when Smart work is absent")
    service.pollCap = 100
    service:update(80)
    assertions.assertEqual(service.cursor, 17, "a host cannot raise the service's existing cap")
    local observed = 0
    service:observe({
        sample = function(_, reading, now)
            assert(reading.updatedAt == now)
            observed = observed + 1
        end,
    })
    local consumed = service:update(90, 1)
    assertions.assertEqual(consumed, 1)
    assertions.assertEqual(observed, 2, "one slot must bound polling and synchronous observers")
    assertions.assertEqual(service.cursor, 19, "slot grants preserve the polling cursor")
    consumed = service:update(100, 8)
    assertions.assertEqual(consumed, 4, "a capped poll batch returns unused slots")
    assertions.assertEqual(observed, 10)
end

local function testPrecisionSearchesResumeAfterIdle()
    local calls = {}
    local service = telemetryService.new(
        services.environment({
            getRSSI = function()
                return 42
            end,
            getFieldInfo = function(name)
                return { id = #name, name = name, unit = 1 }
            end,
            getValue = function()
                return 12
            end,
            model = {
                getSensor = function(index)
                    calls[#calls + 1] = index
                    if index == 0 then
                        return { name = "Early", prec = 1 }
                    end
                    if index == 59 then
                        return { name = "Late", prec = 3 }
                    end
                end,
            },
        }),
        services
    )
    local early, missing = service:subscribe("Early"), service:subscribe("Missing")
    service:update(10)
    assertions.assertEqual(early.precision, 1)
    assertions.assertEqual(service.precisionScans, 1)
    for tick = 20, 90, 10 do
        service:update(tick)
    end
    assertions.assertEqual(service.precisionScans, 0)
    assertions.assertEqual(missing.precisionKnown, true)
    local count, cursor = #calls, service.scanCursor
    for tick = 100, 140, 10 do
        service:update(tick)
    end
    assertions.assertEqual(#calls, count, "finished precision scans must stay idle")
    assertions.assertEqual(service.scanCursor, cursor)
    local late = service:subscribe("Late")
    service:update(150)
    assertions.assertEqual(service.precisionScans, 1, "late resolution must restart bounded scanning")
    assertions.assertEqual(late.precisionKnown, false)
    assertions.assertEqual(#calls - count, 8, "only one capped precision scan runs per update")
    for tick = 160, 220, 10 do
        service:update(tick)
    end
    assertions.assertEqual(service.precisionScans, 0)
    assertions.assertEqual(late.precision, 3)
    assertions.assertEqual(late.sensorIndex, 59)
    assertions.assertEqual(late.precisionKnown, true)

    service.env.getSensor = nil
    service:subscribe("NoAPI")
    service:update(230)
    assertions.assertEqual(service.precisionScans, 0, "missing firmware API must finish a scan")
    local entry = service.names.Early
    service:resolve(entry, 240)
    service:resolve(entry, 240)
    assertions.assertEqual(service.precisionScans, 1, "re-resolution must not double-enroll a search")
    service:scanPrecision(entry)
    assertions.assertEqual(service.precisionScans, 0)
    service:resolve(entry, 250)
    service.env.getFieldInfo = function()
        return { id = 1 }
    end
    service:resolve(entry, 250)
    assertions.assertEqual(service.precisionScans, 0, "local re-resolution must retire a pending sensor scan")
    assertions.assertEqual(entry.scanIndex, nil)
end

local function run()
    testSubscribeReturnsLiveView()
    testLinkSubscriptionExists()
    testTransmitterLocalSourceIsNotLinkEvidence()
    testHostPollingBudgetKeepsRoundRobinProgress()
    testPrecisionSearchesResumeAfterIdle()
end

run()
