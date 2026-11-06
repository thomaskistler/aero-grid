-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local host = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
fixture.pump(host, 40)
assert(#host.errors == 0, table.concat(host.errors, "\n"))
local samples = assert(loadfile(root .. "/tests/support/construction_cases.lua"))()(fixture.module, host.themeBuilder)
local filtered = assert(loadfile(root .. "/tests/support/construction_cases.lua"))()(
    fixture.module,
    host.themeBuilder,
    "flight-timer"
)
assert(#samples == 1632 and #filtered == 136, "native matrices must be filtered before allocating other panel cases")
for _, sample in ipairs(filtered) do
    assert(sample.kind == "flight-timer")
end
local cases = {}
for _, sample in ipairs(samples) do
    if string.find(sample.name, "/modern-dark/2x2/", 1, true) then
        cases[#cases + 1] = sample
    end
end
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local parity = assert(loadfile(root .. "/tests/support/native_construction.lua"))()(lvgl, cases, sameTree, host.page)
local cost = assert(loadfile(root .. "/tests/support/native_construction_cost.lua"))()(host, cases)
local rxCases = {}
for _, case in ipairs(cases) do
    if case.kind == "rx-battery" then
        rxCases[#rxCases + 1] = case
    end
end
local reflow = assert(loadfile(root .. "/tests/support/native_rx_reflow.lua"))()(
    host,
    rxCases,
    assert(loadfile(root .. "/tests/support/native_construction.lua"))(),
    sameTree
)
local reflowCost = assert(loadfile(root .. "/tests/support/native_rx_reflow.lua"))()(host, rxCases, nil, nil, true)
assert(reflowCost.costOnly, "native reflow cost measurement must not record trees")
for _, runner in ipairs({ parity, cost, reflow, reflowCost }) do
    local done
    for _ = 1, 2000 do
        done = runner:step()
        if runner == cost and runner.phase == "advance" and not runner.resized then
            assert(runner.current.grid == host.grid, "complete atoms must retain production grid validation")
            local rect = assert(host.dashboardLoader.panelRect(runner.current, runner.placement))
            local expected = cases[runner.index].rect
            assert(rect.w == expected.w and rect.h == expected.h, "native matrix must preserve each requested span")
        end
        if done then
            break
        end
    end
    assert(done and runner.checked == runner.total, "native fixture must complete every case")
end
print("Native construction fixtures: real-API recorder, complete loader/lifecycle controllers and cleanup passed")
