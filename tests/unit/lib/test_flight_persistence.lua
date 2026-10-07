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
    local arm = switches:armSwitch(pair[1])
    equal(selected, pair[2])
    enabled = true
    switches:update(100)
    -- Update each subscribed switch regardless of the service slice limit.
    for _, entry in ipairs(switches.entries) do
        entry.read(switches, entry, 100)
    end
    equal(arm.value, 1)
    equal(arm.updatedAt, 100)
    enabled = false
    for _, entry in ipairs(switches.entries) do
        entry.read(switches, entry, 120)
    end
    equal(arm.value, 0)
    equal(arm.fresh, true)
end
assert(not pcall(switches.armSwitch, switches, "MISSING"))

local content, tones, numbers = nil, {}, {}
env = {
    getInfo = function()
        return { name = 'Model, "A"', filename = "model1.yml" }
    end,
    getDateTime = function()
        return { year = 2026, mon = 10, day = 6, hour = 16, min = 8 }
    end,
    fileOpen = function(filename, access)
        equal(filename, "/flights-history.csv")
        if access == "r" then
            return content and {} or nil
        end
        content = content or ""
        return {}
    end,
    fileClose = function() end,
    fileWrite = function(_, text)
        content = content .. text
    end,
    playTone = function(frequency)
        tones[#tones + 1] = frequency
    end,
    playNumber = function(count)
        numbers[#numbers + 1] = count
    end,
}
local model = modelService.new(env, support)
equal(model:flightDate(), "2026-10-06 16:08")
model:logFlight(model:flightDate(), 62.5, 40)
assertions.assertContains(content, "flight_date,model_name,flight_count,duration,model_id\n# api_ver=1\n")
assertions.assertContains(content, '2026-10-06 16:08,"Model, ""A""",40,62,model1.yml\n')
local previous = content
model:logFlight(model:flightDate(), 70, 41)
equal(string.sub(content, 1, #previous), previous)
local _, headers = string.gsub(content, "flight_date", "")
equal(headers, 1)
model:announceFlight(40, false)
model:announceFlight(40, true)
equal(tones[1], 1200)
equal(tones[2], 800)
equal(numbers[1], 40)
equal(numbers[2], 40)
env.fileOpen = function()
    return nil, "card unavailable"
end
ok, err = pcall(model.logFlight, model, model:flightDate(), 70, 41)
assert(not ok and string.find(err, "card unavailable", 1, true))
local closed = false
env.fileOpen = function()
    return {}
end
env.fileClose = function()
    closed = true
end
env.fileWrite = function()
    error("card full")
end
ok, err = pcall(model.logFlight, model, model:flightDate(), 70, 41)
assert(not ok and string.find(err, "card full", 1, true))
assert(closed, "a failed write must still close the file")
