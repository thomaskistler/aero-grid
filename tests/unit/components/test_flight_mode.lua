-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local flightMode = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/flight-mode.lua"))()

local function testIndexRequiresRoom()
    assertions.assertEqual(#flightMode.validateSettings({}, { rowSpan = 2 }, { showIndex = true }), 0)
    local errors = flightMode.validateSettings({}, { rowSpan = 1 }, { showIndex = true })
    assertions.assertEqual(#errors, 1)
    assertions.assertContains(errors[1], "showIndex needs a panel two rows tall")
    assertions.assertEqual(#flightMode.validateSettings({}, { rowSpan = 1 }, {}), 0)
end

local function testPresentation()
    assertions.assertEqual(flightMode.presentationFor(1, 1, false).showDetail, false)
    assertions.assertEqual(flightMode.presentationFor(2, 2, true).showDetail, true)
    assertions.assertEqual(flightMode.presentationFor(4, 1, true).showDetail, true)
end

local function run()
    testIndexRequiresRoom()
    testPresentation()
end

run()
