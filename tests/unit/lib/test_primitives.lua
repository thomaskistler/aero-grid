-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local moduleLoader = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local primitives = moduleLoader("lib/primitives.lua")

local function testContentWidthRespectsPadding()
    local theme = { spacing = { padding = 8 } }
    assertions.assertEqual(primitives.contentWidth(theme, 120), 104)
end

local function testNumericHelpers()
    assertions.assertEqual(primitives.fraction(5, 0, 10), 0.5)
    assertions.assertEqual(primitives.fraction(-5, 0, 10), 0)
    assertions.assertEqual(primitives.fraction(15, 0, 10), 1)
    assertions.assertEqual(primitives.fraction(5, 10, 0), 0.5)
    assertions.assertEqual(primitives.fraction(5, 1, 1), 0)
end

local function testChangedSkipsUnchangedRender()
    local context = { scratch = {} }
    local renderCount = 0

    local render = function(ctx, out)
        renderCount = renderCount + 1
        out.x = 10
        out.y = 20
    end

    local changed, drawn = primitives.changed(context, render)
    assertions.assertEqual(changed, true)
    assertions.assertEqual(drawn.x, 10)

    local changedAgain, drawnAgain = primitives.changed(context, render)
    assertions.assertEqual(changedAgain, false)
    assertions.assertEqual(drawnAgain.x, 10)
    assertions.assertEqual(renderCount, 2)
end

local function run()
    testContentWidthRespectsPadding()
    testNumericHelpers()
    testChangedSkipsUnchangedRender()
end

run()
