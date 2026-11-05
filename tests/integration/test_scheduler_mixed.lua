-- SPDX-License-Identifier: GPL-2.0-only

-- Mixed mode keeps the remaining legacy-owned services and panels on their
-- existing loops while migrated tasks run through the scheduler. Hash the
-- scenarios to catch unintended changes to that coexistence behavior.
--   AEROGRID_WRITE_GOLDEN=1 make test

local root = (... and ... ~= "" and ...) or "."
local hostIo = io
local trace = assert(loadfile(root .. "/tests/support/scheduler_trace.lua"))()
local recorder = trace.install()

local main = assert(hostIo.open(root .. "/src/WIDGETS/AeroGrid/main.lua", "r"))
local source = main:read("a")
main:close()
-- Releases use mixed mode with the development probe off.
assert(string.find(source, 'local SCHEDULER_MODE = "mixed"', 1, true), "main.lua must enable mixed mode")
assert(string.find(source, "local SCHEDULER_PROBE = false", 1, true), "main.lua must ship without the probe")

local SCENARIOS = {
    "test_shared_flight",
    "test_shared_armed",
    "test_session_reset",
    "test_panel_reflow",
    "test_output_review",
    "test_metric_review",
    "test_flight_counter",
    "test_smart_chart_budget",
}

local lines = {}
for _, name in ipairs(SCENARIOS) do
    recorder.reset()
    assert(loadfile(root .. "/tests/integration/widget/" .. name .. ".lua"))(root)
    local events, hash = recorder.digest()
    assert(events > 0, name .. " made no scheduling decisions")
    lines[#lines + 1] = string.format("%s %d %08x", name, events, hash)
end
local actual = table.concat(lines, "\n") .. "\n"

local goldenPath = root .. "/tests/fixtures/scheduler-mixed-golden.txt"
if os.getenv("AEROGRID_WRITE_GOLDEN") then
    local file = assert(hostIo.open(goldenPath, "w"))
    file:write(actual)
    file:close()
end
local file = assert(hostIo.open(goldenPath, "r"))
local golden = file:read("a")
file:close()
assert(actual == golden, "mixed scheduling changed.\nexpected:\n" .. golden .. "actual:\n" .. actual)

print(string.format("Scheduler mixed parity passed (%d scenarios)", #SCENARIOS))
