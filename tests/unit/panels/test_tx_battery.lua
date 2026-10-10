-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local battery = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/tx-battery.lua"))()
local primitives = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/primitives.lua"))()

local function testRangeAndEstimate()
    assertions.assertEqual(battery.hasRange({}), false)
    assertions.assertEqual(battery.hasRange({ packEmpty = 6.6 }), false)
    assertions.assertEqual(battery.hasRange({ packEmpty = 8.4, packFull = 6.6 }), false)
    assertions.assertEqual(battery.hasRange({ packEmpty = 6.6, packFull = 8.4 }), true)

    assertions.assertEqual(battery.fraction({}, 7.5, nil, primitives), 0)
    assertions.assertEqual(battery.fraction({ packEmpty = 6.6, packFull = 8.6 }, 7.6, nil, primitives), 0.5)
    assertions.assertEqual(battery.fraction({ packEmpty = 6.6, packFull = 8.6 }, 9.0, nil, primitives), 1)
    assertions.assertEqual(battery.fraction({ packEmpty = 6.6, packFull = 8.6 }, 6.0, nil, primitives), 0)
end

local function testStatesAndReading()
    local limits = { warning = 7.0, critical = 6.8 }
    assertions.assertEqual(battery.resolveState(limits, 7.9, false), "normal")
    assertions.assertEqual(battery.resolveState(limits, 6.9, false), "warning")
    assertions.assertEqual(battery.resolveState(limits, 6.7, false), "critical")
    assertions.assertEqual(battery.resolveState(limits, 7.9, true), "stale")
    assertions.assertEqual(battery.resolveState(limits, nil, false), "unavailable")
    assertions.assertEqual(battery.reading(7.9), "7.9")
    assertions.assertEqual(battery.reading(10.0), "10.0")
    assertions.assertEqual(battery.reading(nil), "--")
end

local function run()
    testRangeAndEstimate()
    testStatesAndReading()
end

run()
