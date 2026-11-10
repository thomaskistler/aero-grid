-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local trace = assert(loadfile(root .. "/tests/support/chart_runtime_trace.lua"))()
local prefix, prefixHash, events, eventHash = trace.expected(5990, 11, 6001)
assert(prefix == 3276 and prefixHash == 4097166, "horizontal initial history must remain frozen")
assert(events == 24 and eventHash == 13624132, "horizontal operation inputs must remain frozen")
assert(
    trace.digest(123, 6001, 1, 0.25, false) == trace.digest(123, 6001.0, 1, 0.25, false),
    "fingerprints must not depend on timestamp numeric subtype"
)
local times = {}
for batch = 1, trace.BATCHES do
    local at = 6001 + (batch - 1) * trace.PERIOD
    trace.emit(at, false, function(source, value, missing)
        assert(source >= 1 and source <= 6 and not missing)
        assert(value == trace.value(at, source))
        times[#times + 1] = at
    end)
end
assert(#times == 24 and times[1] == 6001 and times[24] == 6016)
