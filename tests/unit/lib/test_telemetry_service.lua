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
        local _, again = service:update(step * 10)
        assertions.assertEqual(service.cursor, step * 4 % 24 + 1)
        assertions.assertEqual(again, step < 6, "only an unfinished round asks to continue")
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
    assertions.assertEqual(consumed, 3, "the current round returns its unused slots")
    assertions.assertEqual(observed, 8)
end

local function testContinuationPollsEachSourceOncePerRound()
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
    for index = 1, 12 do
        service:subscribe(tostring(index))
    end
    local turns, again = 0, true
    while again do
        _, again = service:update(10, 8)
        turns = turns + 1
    end
    assertions.assertEqual(turns, 2, "twelve sources need two turns of at most eight")
    for index = 1, 12 do
        assertions.assertEqual(reads[index], 1, "a continuation must not poll a source twice in one callback")
    end
end

local function testContendedRoundSurvivesCallbacksAndSubscriptionChanges()
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
    for index = 1, 8 do
        service:subscribe(tostring(index))
    end
    local queue = scheduler.new()
    local task = {
        name = "telemetry",
        cost = 1,
        due = 0,
        step = function(self, now, slots)
            local used, again = service:update(now, slots)
            self.due = now + 20
            return used, again
        end,
    }
    local competing = {
        name = "competing",
        cost = 7,
        step = function(_, _, slots)
            return slots, false
        end,
    }
    local function tick(now)
        queue.clear()
        queue.add(task)
        queue.add(competing)
        queue.run(now, 8)
    end

    tick(50)
    assert(queue.state(task).pending, "telemetry keeps its unfinished round pending")
    service:subscribe("9")
    for _, now in ipairs({ 70, 90, 110 }) do
        tick(now)
    end
    assert(not queue.state(task).pending, "the round must finish as callback time and subscriptions change")
    for index = 1, 8 do
        assertions.assertEqual(reads[index], 1, "an in-progress round polls each original source once")
    end
    assertions.assertEqual(reads[9], nil, "a new subscription joins the next periodic round")
    tick(120)
    assertions.assertEqual(reads[9], nil, "a completed round still observes its periodic due time")
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
    testHostPollingBudgetKeepsRoundRobinProgress()
    testContinuationPollsEachSourceOncePerRound()
    testContendedRoundSurvivesCallbacksAndSubscriptionChanges()
    testPrecisionSearchesResumeAfterIdle()
    testThresholdsFollowLayoutOrder()
    testThresholdLevels()
end

run()
