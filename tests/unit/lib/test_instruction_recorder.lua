-- SPDX-License-Identifier: GPL-2.0-only

local root = ...
local module = assert(loadfile(root .. "/tests/support/instruction_recorder.lua"))()
local count, pause = module.hookCounter()
local recorder = module.new(count, pause)

local function measure(fn, ...)
    local cost
    local result = recorder:window(function(value)
        cost = value
    end, fn, ...)
    assert(result[1], tostring(result[2]))
    return cost, table.unpack(result, 2, result.n)
end

assert(measure(function() end) == 1, "empty function must include its RETURN instruction")
local function work()
    local sum = 0
    for index = 1, 10 do
        sum = sum + index
    end
    return sum
end
local cost, value = measure(work)
assert(value == 55 and cost > 10, "fresh VM instructions were not measured")

local child = work
local function parent()
    return child() + 1
end
local baseline = measure(parent)
child = recorder:wrap(work, function() end)
assert(measure(parent) == baseline, "child instrumentation changed its parent's count")
local middle = parent
local function grandparent()
    return middle() + 1
end
local deepBaseline = measure(grandparent)
middle = recorder:wrap(parent, function() end)
assert(measure(grandparent) == deepBaseline, "grandchildren were subtracted twice")
local bookkeeping = recorder:wrap(work, function()
    measure(work)
end)
child = work
baseline = measure(parent)
child = bookkeeping
assert(measure(parent) == baseline, "measurement bookkeeping leaked into parent work")

local function values(...)
    return select("#", ...), ...
end
local wrapped = recorder:callback("refresh", values)
local results = table.pack(wrapped(7, nil, 9))
assert(results.n == 4 and results[1] == 3 and results[2] == 7 and results[3] == nil and results[4] == 9)
wrapped = recorder:task("test", function()
    return 0
end)
for _ = 1, 10 do
    assert(wrapped({}, 3, "run", 0) == 0)
end
local observations = recorder:observations()
assert(#observations == 2)
local task = observations[2]
assert(task.kind == "task" and task.grant == 3 and task.n == 10 and task.min == task.max)
child = work
baseline = measure(parent)
child = recorder:task("nested", work)
assert(measure(parent) == baseline, "task windows changed their parent's count")

local failure = {}
local callback = recorder:callback("error", function()
    error(failure)
end)
local ok, message = pcall(callback)
assert(not ok and message == failure, "errors were swallowed or replaced")
assert(recorder.depth == 0 and debug.gethook() == nil, "failed window leaked counting state")
observations = recorder:observations()
assert(observations[1].failures == 1, "failed executions must remain in observations")

debug.sethook(function() end, "", 100)
ok, message = pcall(module.hookCounter)
debug.sethook()
assert(not ok and string.find(message, "exclusive ownership", 1, true), "existing debug hook was clobbered")
print("Instruction recorder calibration, nesting, samples and errors passed")
