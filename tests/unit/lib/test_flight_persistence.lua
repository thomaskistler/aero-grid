-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local support = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local control = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()
local modelService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/model_service.lua"))()
local equal = assertions.assertEqual
local stored, mode = 39, nil
local env = {
    getGlobalVariable = function(index, flightMode)
        equal(index, 8)
        equal(flightMode, 0)
        return stored
    end,
    setGlobalVariable = function(index, flightMode, value)
        equal(index, 8)
        mode, stored = flightMode, value
    end,
}
local service = control.new(env, support)
local feed = service:globalVariable(8, 0)
service:update(0)
equal(feed.raw, 39)
equal(service:incrementFlightCount(), 40)
equal(mode, 0)
equal(feed.raw, 40, "the published counter must update immediately")
stored = 50
equal(service:incrementFlightCount(), 51, "external count edits must not be overwritten with a stale count")
stored = 999
local ok, err = pcall(service.incrementFlightCount, service)
assert(not ok and string.find(err, "full", 1, true))
stored = 39
env.setGlobalVariable = function() end
ok, err = pcall(service.incrementFlightCount, service)
assert(not ok and string.find(err, "could not save", 1, true))
env.setGlobalVariable = nil
assert(not pcall(service.incrementFlightCount, service))

local selected, enabled = nil, false
local switches = control.new({
    charUp = string.char(192),
    charDown = string.char(193),
    getSwitchIndex = function(name)
        selected = name
        return name == "MISSING" and 0 or 7
    end,
    getSwitchValue = function(index)
        equal(index, 7)
        return enabled
    end,
}, support)
for _, pair in ipairs({
    { "SF^", "SF" .. string.char(192) },
    { "SA-", "SA-" },
    { "SBv", "SB" .. string.char(193) },
    { "L01", "L01" },
}) do
    local arm = switches:switch(pair[1])
    switches:update(100)
    equal(selected, pair[2])
    enabled = true
    switches:update(100)
    -- Update each subscribed switch regardless of the service slice limit.
    for _, entry in ipairs(switches.entries) do
        entry.read(switches, entry, 100)
    end
    equal(arm.value, true)
    equal(arm.updatedAt, 100)
    enabled = false
    for _, entry in ipairs(switches.entries) do
        entry.read(switches, entry, 120)
    end
    equal(arm.value, false)
    equal(arm.fresh, true)
end
local missing = switches:switch("MISSING")
switches:update(140)
assert(not missing.available and not missing.fresh, "unknown switch is unavailable, not disarmed")

local model = modelService.new({
    getInfo = function()
        return { name = "Model A", filename = "model1.yml" }
    end,
}, support)
assert(model.logFlight == nil and model.flightDate == nil, "model service must not expose CSV history")
assert(model.announceFlight == nil, "model service must not expose built-in flight announcements")
