-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local profile = assert(loadfile(root .. "/tests/support/chart_instruction_profile.lua"))()
local native, output = 0, {}
__instructionCount = function()
    return native, native // 200, 200
end
local open, close, write = io.open, io.close, io.write
io.open = function()
    return {}
end
io.close = function() end
io.write = function(_, text)
    output[#output + 1] = text
end
local privateCalls = 0
local private = function()
    privateCalls = privateCalls + 1
    native = native + 40
end
local telemetry = {
    id = "telemetry",
    update = function()
        native = native + 300
        private()
        return 2
    end,
}
local history = {
    id = "history",
    update = function()
        native = native + 100
    end,
}
local chart = {
    series = { {} },
    mipmapRenderer = { step = function() native = native + 400; return false, 2000 end },
}
local originalStep = chart.mipmapRenderer.step
local module = {
    refresh = function(owner)
        local complete, estimated = owner.mipmapRenderer:step()
        assert(complete == false and estimated == 2000, "profiling must preserve renderer accounting")
        native = native + 100
        return 1, true, 3
    end,
}
local broker = {
    tick = function()
        native = native + 50
        private()
    end,
}
local context = {
    servicesModule = {},
    serviceRuntime = { order = { telemetry, history } },
    panels = { { module = module, instance = chart, placement = { id = "chart1" } } },
    flightFactory = { broker = broker },
    remainingSlots = 1,
}
local state = { profile = { pendingStage = "drawing" } }
profile.begin(context, state)
broker:tick()
assert(telemetry:update(0, 4) == 2)
assert(history:update(0, 1) == nil)
local interval, unfinished, used = module.refresh(chart, false, 4)
assert(interval == 1 and unfinished and used == 3)
profile.finish(context, state)
local row = state.instructionRows[1]
assert(row.total == 1030 and #row.charges == 4 and privateCalls == 2)
assert(row.charges[1].id == "flight_poll" and row.charges[1].instructions == 90)
assert(row.charges[2].id == "telemetry" and row.charges[2].instructions == 340 and row.charges[2].slots == 2)
assert(row.charges[3].id == "history" and row.charges[3].instructions == 100 and row.charges[3].slots == 1)
assert(row.charges[4].id == "chart1" and row.charges[4].instructions == 500 and row.charges[4].slots == 3)
assert(row.charges[4].detail.projection == 400 and row.charges[4].detail.grant == 4)
assert(row.charges[4].detail.series == 1 and chart.mipmapRenderer.step == originalStep)
broker:tick()
assert(#row.charges == 4, "work outside the measured region must not be attributed")
profile.write(state)
assert(string.find(table.concat(output), "TASK callback=1 id=telemetry instructions=340 slots=2", 1, true))
io.open, io.close, io.write = open, close, write
__instructionCount = nil
