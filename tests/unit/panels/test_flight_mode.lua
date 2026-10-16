-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local flightMode = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/flight-mode.lua"))()

local function testPresentation()
    assertions.assertEqual(flightMode.presentationFor(1, 1, false).showDetail, false)
    assertions.assertEqual(flightMode.presentationFor(2, 2, true).showDetail, true)
    assertions.assertEqual(flightMode.presentationFor(4, 1, true).showDetail, true)
end

local function run()
    testPresentation()
end

run()
