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

local function run()
    testSubscribeReturnsLiveView()
    testLinkSubscriptionExists()
    testTransmitterLocalSourceIsNotLinkEvidence()
end

run()
