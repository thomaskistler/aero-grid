-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local host = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
fixture.pump(host, 60)
local function load(relative, ...)
    if string.sub(relative, 1, 9) == "@support/" then
        return assert(loadfile(root .. "/tests/support/" .. string.sub(relative, 10)))(...)
    end
    return fixture.module(relative, ...)
end
local cases = load("@support/reflow_cases.lua")(load, host)
local sameTree = load("@support/panel_tree.lua")
local recorder = load("@support/native_construction.lua")
local clears = 0
local clearCase = {
    name = "clear-before-first-set",
    rect = { x = 0, y = 0, w = 100, h = 100 },
    settings = {},
    dependencies = function()
        return {}
    end,
    panel = {
        create = function(parent, rect)
            local object = lvgl.box(parent, rect)
            lvgl.rectangle(object, rect)
            object:clear()
            assert(#object.children == 0 and object.native.cleared)
            clears = clears + 1
            return { root = object }
        end,
        refresh = function() end,
    },
}
local clearing = recorder(lvgl, { clearCase }, sameTree, host.page, nil, true)
for _ = 1, 10 do
    if clearing:step() then
        break
    end
end
assert(clears == 2 and clearing.checked == 1, "clearing must forward before an object's first set")
local checked, kinds = 0, {}
local expected = {
    metric = 408,
    ["link-status"] = 272,
    ["tx-battery"] = 408,
    ["flight-timer"] = 136,
    navigation = 128,
    chart = 72,
    output = 128,
    ["theme-showcase"] = 8,
    ["flight-counter"] = 128,
    ["flight-mode"] = 128,
    ["model-identity"] = 128,
    state = 128,
    ["trim-panel"] = 128,
    ["host-diagnostics"] = 72,
    ["service-probe"] = 72,
}
for _, case in ipairs(cases) do
    kinds[case.kind] = (kinds[case.kind] or 0) + 1
end
for _, costOnly in ipairs({ false, true }) do
    local runner = load("@support/native_panel_reflow.lua")(host, cases, recorder, sameTree, costOnly)
    assert(not costOnly or runner.costOnly)
    local done
    for _ = 1, 10 * #cases do
        done = runner:step()
        if done then
            break
        end
    end
    assert(done and runner.checked == #cases, "every built-in reflow case must finish")
    checked = checked + runner.checked
end
local count = 0
for kind, total in pairs(kinds) do
    assert(total == expected[kind], kind .. ": every legal span, theme and variant must be retained")
    count = count + 1
end
assert(count == 15, "all built-ins except separately audited RX must be covered")
print(
    "Native panel reflow controllers: " .. #cases .. " cases across " .. count .. " kinds, " .. checked .. " completed"
)
