-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local file = assert(io.open(root .. "/tools/scheduler-audit/probe.lua", "r"))
local source = file:read("*a")
file:close()
local first = assert(string.find(source, "local function core(", 1, true))
local last = assert(string.find(source, "local function wrapField(", first, true))
local prefix = [[
local depth, childSum, visits, childList = 0, {}, {}, {}
local LEAK_SPAN, LEAK_WRAP = 0, 0
local function pause() end
local function count() return 0 end
local function finish() depth = depth - 1 end
local _G = {}
]]
local probe = assert(
    load(
        prefix .. string.sub(source, first, last - 1) .. "\nreturn { span = span, wrap = wrap }",
        "@probe-forwarding",
        "t",
        { type = type }
    )
)()
local labelCalls, workCalls = 0, 0
local function check(a, b, c, d, e, f, g, h)
    assert(a == 1 and b == 2 and c == nil and d == 4 and e == 5)
    assert(f == 6 and g == 7 and h == 8, "audit wrappers must not drop lifecycle arguments")
end
local function work(...)
    check(...)
    workCalls = workCalls + 1
    return true, nil, "result", false
end
local function label(token, ...)
    check(...)
    labelCalls = labelCalls + 1
    if token == nil then
        return "token"
    end
    assert(token == "token")
    return "forwarding"
end
for _, call in ipairs({
    function()
        return probe.span(label, work, 1, 2, nil, 4, 5, 6, 7, 8)
    end,
    function()
        return probe.wrap(label, work)(1, 2, nil, 4, 5, 6, 7, 8)
    end,
}) do
    local a, b, c, d = call()
    assert(a == true and b == nil and c == "result" and d == false)
end
assert(workCalls == 2 and labelCalls == 4)

local fitStart = assert(string.find(source, "local function fit(", 1, true))
local fitEnd = assert(string.find(source, "local function gate(", fitStart, true))
local finishStart = assert(string.find(source, "local function finish(", 1, true))
local finishEnd = assert(string.find(source, "-- A labelled measurement window.", finishStart, true))
local gateProbe = assert(load(
    [[
local P, loaderDeclarations, config = {}, {}, { scenario = "" }
local depth, childSum, visits, childList = 1, { 0 }, { 0 }, { {} }
local top, topLabels, topSum = {}, {}, 0
local K, calibrating, recording, previewTasks = 0, false, false, false
local failures = {}
local function gate(ok, message) if not ok then failures[#failures + 1] = message end end
]]
        .. string.sub(source, fitStart, fitEnd - 1)
        .. string.sub(source, finishStart, finishEnd - 1)
        .. [[
return function(cost)
    depth, childSum, visits, childList, failures = 1, { 0 }, { 0 }, { {} }, {}
    finish("load:read", cost, 0)
    return failures
end
]],
    "@probe-loading-gate",
    "t",
    { math = math, string = string, table = table, type = type }
))()
assert(#gateProbe(630) == 0, "a fitted loading cost at its charge must pass")
local failures = gateProbe(700)
assert(#failures == 1 and string.find(failures[1], "700 -> ", 1, true),
    "a raw cost within its charge must still fail when its fitted cost exceeds it")
print("Scheduler audit probe: lifecycle arguments and return values preserved")
