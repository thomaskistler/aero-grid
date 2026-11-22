-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local controlService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()

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
        used, again = service:update(20)
        assert(used == 1)
    until not again
    assert(outputReads == 63 and metadataReads == 12, "each update samples outputs and polls metadata")
    assert(feeds[31].available and feeds[31].raw == 310)

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
        step = function(self, _, slots)
            turns[#turns + 1] = "other"
            self.due = 100
            return slots, false
        end,
    })
    assert(queue.run(0, 2) == 2 and queue.state(control).pending)
    assert(table.concat(turns, ",") == "control,other")
    assert(queue.run(1, 2) == 2 and queue.state(control).pending)
    assert(queue.run(2, 2) == 1 and not queue.state(control).pending)
    assert(table.concat(turns, ",") == "control,other,control,control,control")
end

local function run()
    testStandardRangeConstantsExist()
    testBoundedPolling()
    testPollingContinuationIsFair()
end

run()
