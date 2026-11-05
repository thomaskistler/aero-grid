-- SPDX-License-Identifier: GPL-2.0-only

-- Legacy mode is the shipped behaviour and must not change while the new scheduler
-- is built. Each scenario below is an existing integration test; the host's
-- scheduling decisions during it are hashed and compared with the hash recorded
-- from the code before the host mode existed (tests/fixtures/scheduler-legacy-golden.txt).
-- Regenerate the file only for a deliberate change of the legacy scheduler:
--   AEROGRID_WRITE_GOLDEN=1 make test

local root = (... and ... ~= "" and ...) or "."
local hostIo = io
local trace = assert(loadfile(root .. "/tests/support/scheduler_trace.lua"))()
local recorder = trace.install()

local main = assert(hostIo.open(root .. "/src/WIDGETS/AeroGrid/main.lua", "r"))
local source = main:read("a")
main:close()
assert(string.find(source, 'local SCHEDULER_MODE = "legacy"', 1, true) or not string.find(source, "SCHEDULER_MODE", 1, true))

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
    assert(recorder.events > 0, name .. " made no scheduling decisions")
    lines[#lines + 1] = string.format("%s %d %08x", name, recorder.events, recorder.hash)
end
local actual = table.concat(lines, "\n") .. "\n"

local goldenPath = root .. "/tests/fixtures/scheduler-legacy-golden.txt"
if os.getenv("AEROGRID_WRITE_GOLDEN") then
    local file = assert(hostIo.open(goldenPath, "w"))
    file:write(actual)
    file:close()
end
local file = assert(hostIo.open(goldenPath, "r"))
local golden = file:read("a")
file:close()
assert(actual == golden, "legacy scheduling changed.\nexpected:\n" .. golden .. "actual:\n" .. actual)

print(string.format("Scheduler legacy parity passed (%d scenarios)", #SCENARIOS))
