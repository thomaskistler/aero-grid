-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local controlService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()

local function testTrimNamespaceExists()
    local env = services.environment({
        getFieldInfo = function(name)
            return { id = 42 }
        end,
        getValue = function()
            return 128
        end,
    })
    local service = controlService.new(env, services)
    local trim = service:trim("trim-ail", "auto")
    assertions.assertEqual(type(trim), "table")
end

local function testStandardRangeConstantsExist()
    assertions.assertEqual(controlService.STANDARD_RANGE, 1024)
    assertions.assertEqual(controlService.EXTENDED_RANGE, 4096)
end

local function testBoundedPolling()
    local outputReads, metadataReads = 0, 0
    local service = controlService.new(
        services.environment({
            getOutputValue = function(index)
                outputReads = outputReads + 1
                return index * 10
            end,
            model = {
                getOutput = function()
                    metadataReads = metadataReads + 1
                    return { name = "Output" }
                end,
            },
        }),
        services
    )
    local feeds = {}
    for index = 0, 30 do
        feeds[index] = service:output(index)
    end
    local used, again = service:update(0)
    assert(used == 1 and again and outputReads == 8 and metadataReads == 2)
    feeds[31] = service:output(31)
    for turn = 2, 4 do
        local beforeOutputs, beforeMetadata = outputReads, metadataReads
        used, again = service:update(0)
        assert(used == 1 and again == (turn < 4))
        assert(outputReads - beforeOutputs <= 8 and metadataReads - beforeMetadata <= 2)
    end
    assert(outputReads == 31 and metadataReads == 6)
    assert(not feeds[31].available, "outputs added mid-cycle wait for the next cycle")
    for index = 0, 30 do
        assert(feeds[index].available and feeds[index].raw == index * 10)
    end
    repeat
        used, again = service:update(10)
        assert(used == 1)
    until not again
    assert(outputReads == 63 and metadataReads == 6, "output samples retain their faster cadence")
    assert(feeds[31].available and feeds[31].raw == 310)
    repeat
        used, again = service:update(20)
    until not again
    assert(metadataReads == 12, "metadata polling resumes on the ordinary cadence")

    local idle = controlService.new(services.environment({}), services)
    used, again = idle:update(0)
    assert(used == 0 and not again, "an empty cycle releases its reservation without repeating")
end

local function testPollingContinuationIsFair()
    local service = controlService.new(
        services.environment({
            getOutputValue = function(index)
                return index
            end,
        }),
        services
    )
    for index = 0, 31 do
        service:output(index)
    end
    local queue = scheduler.new({ capacity = 2 })
    local turns = {}
    local control = {
        cost = controlService.updateCost,
        step = function(_, now)
            turns[#turns + 1] = "control"
            return service:update(now)
        end,
    }
    queue.add(control)
    queue.add({
        cost = 1,
        step = function(self)
            turns[#turns + 1] = "other"
            self.due = 100
        end,
    })
    assert(queue.run(0, 2) == 2 and control.pending)
    assert(table.concat(turns, ",") == "control,other")
    assert(queue.run(1, 2) == 2 and control.pending)
    assert(queue.run(2, 2) == 1 and not control.pending)
    assert(table.concat(turns, ",") == "control,other,control,control,control")
end

local function run()
    testTrimNamespaceExists()
    testStandardRangeConstantsExist()
    testBoundedPolling()
    testPollingContinuationIsFair()
end

run()
