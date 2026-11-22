-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local telemetryService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/telemetry_service.lua"))()

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

local function countingService(reads)
    return telemetryService.new(
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
end

local function testObserversReceiveOneBatchOfRecordedSamples()
    local reads = {}
    local service = countingService(reads)
    for index = 1, 6 do
        service:subscribe(tostring(index), nil, index % 2 == 0)
    end
    local batches, seen = 0, {}
    service:observe({
        samples = function(_, readings, count, now)
            batches = batches + 1
            for index = 1, count do
                assert(readings[index].updatedAt == now)
                seen[#seen + 1] = readings[index].name
            end
        end,
    })
    local failing = {
        samples = function()
            error("observer failed")
        end,
    }
    service:observe(failing)
    service:update(10)
    assertions.assertEqual(batches, 1, "an update hands observers a single batch")
    assertions.assertEqual(table.concat(seen, ","), "2,4,6", "only recorded sources reach observers")
    assert(string.find(failing.failure, "observer failed", 1, true), "an observer failure was lost")
    service:update(20)
    assertions.assertEqual(batches, 2)
    assertions.assertEqual(reads[1], 1, "a displayed source waits for its 5 Hz turn")
    assertions.assertEqual(reads[2], 2)
end

local function testDeferredUpdatePollsEverySourceInOneStep()
    local reads = {}
    local service = countingService(reads)
    for index = 1, 9 do
        service:subscribe(tostring(index), nil, true)
    end
    local queue = scheduler.new()
    local task = {
        name = "telemetry",
        due = 0,
        step = function(self, now)
            service.due = now + telemetryService.INTERVAL
            service:update(now)
            self.due, self.cost = service.due, service.updateCost
        end,
    }
    task.cost = service.updateCost
    local competing = {
        name = "competing",
        cost = 7,
        due = 50,
        step = function(self, now)
            self.due = now + 5
        end,
    }
    queue.add(competing)
    queue.add(task)
    local function tick(now)
        return queue.run(now, 8)
    end

    assertions.assertEqual(task.cost, 2, "nine sources are charged two slots")
    tick(40)
    assertions.assertEqual(task.due, 50)
    tick(50)
    assertions.assertEqual(reads[1], 1, "an update that does not fit waits whole")
    tick(55)
    for index = 1, 9 do
        assertions.assertEqual(reads[index], 2, "a deferred update polls every source once")
    end
    assertions.assertEqual(task.due, 60, "a deferred update keeps the 10 Hz grid")
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

local function testThresholdsFollowLayoutOrder()
    local service = telemetryService.new(services.environment({}), services)
    local equal = assertions.assertEqual
    equal(service:thresholds("Alt"), nil, "no layout means no thresholds")
    local placements = { { id = "a" }, { id = "b" }, { id = "c" } }
    service:setLayoutOrder(function()
        return placements
    end)
    local panel = {
        thresholds = function(settings)
            return settings.list
        end,
    }
    local function alt(warning)
        return { list = { { sensor = "Alt", warning = warning, falling = false } } }
    end
    service:registerPanel("b", panel, alt(50))
    service:registerPanel("a", panel, alt(100))
    service:registerPanel("c", panel, { list = { { sensor = "Alt" }, { sensor = "VCel", critical = 3.4 } } })
    equal(service:thresholds("Alt").warning, 100, "the first panel in layout order wins, not the first registered")
    local map = service:thresholdMap()
    equal(map.Alt.warning, 100)
    equal(map.VCel.critical, 3.4)
    equal(map.RxBt, nil)

    placements[1], placements[2] = placements[2], placements[1]
    equal(service:thresholds("Alt").warning, 50, "reordering the layout changes the winner")
    service:registerPanel("b", nil)
    equal(service:thresholds("Alt").warning, 100, "a cleared panel gives up its thresholds")
    local ok, message = service:registerPanel("a", {
        thresholds = function()
            error("broken panel")
        end,
    }, {})
    equal(ok, false)
    assert(string.find(message, "broken panel", 1, true), "the panel error was lost")
    equal(service:thresholds("Alt"), nil, "a failing panel and a sensor without thresholds set nothing")
    service:registerPanel("removed", panel, alt(10))
    equal(service:thresholds("Alt"), nil, "a panel outside the layout is ignored")
    service:registerPanel("a", panel, alt(100))
    service:clearThresholds()
    equal(service:thresholds("Alt"), nil)
end

local function testThresholdLevels()
    local level = telemetryService.level
    local rising = { warning = 50, critical = 80 }
    local falling = { warning = 3.6, critical = 3.4, falling = true }
    local below = { warning = 8, critical = 4, falling = true, strict = true }
    local cases = {
        { rising, 49, "normal" },
        { rising, 50, "warning" },
        { rising, 80, "critical" },
        { falling, 3.7, "normal" },
        { falling, 3.6, "warning" },
        { falling, 3.4, "critical" },
        { below, 8, "normal" },
        { below, 7, "warning" },
        { below, 4, "warning" },
        { below, 3, "critical" },
        { { critical = 10 }, 5, "normal" },
        { rising, nil, "normal" },
        { nil, 100, "normal" },
    }
    for index, case in ipairs(cases) do
        assertions.assertEqual(level(case[1], case[2]), case[3], "level case " .. index)
    end
end

local function run()
    testTransmitterLocalSourceIsNotLinkEvidence()
    testObserversReceiveOneBatchOfRecordedSamples()
    testDeferredUpdatePollsEverySourceInOneStep()
    testPrecisionSearchesResumeAfterIdle()
    testThresholdsFollowLayoutOrder()
    testThresholdLevels()
end

run()
