-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()

edgetx.constants()
local grid = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/grid.lua"))()

local function run()
    local zone = { w = 480, h = 272 }
    local left = assert(grid.rect(zone, { col = 0, row = 0, colSpan = 2, rowSpan = 2 }, 4, 4, 4))
    local right = assert(grid.rect(zone, { col = 2, row = 0, colSpan = 2, rowSpan = 4 }, 4, 4, 4))

    assertions.assertEqual(left.x, 0)
    assertions.assertEqual(left.y, 0)
    assertions.assertEqual(left.w, 238)
    assertions.assertEqual(left.h, 134)
    assertions.assertEqual(right.x, 242)
    assertions.assertEqual(right.y, 0)
    assertions.assertEqual(right.w, 238)
    assertions.assertEqual(right.h, 272)
end

run()
