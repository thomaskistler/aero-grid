-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local primitives = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/primitives.lua"))()

local function testContentWidthRespectsPadding()
    local theme = { spacing = { padding = 8 } }
    assertions.assertEqual(primitives.contentWidth(theme, 120), 104)
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
    testChangedSkipsUnchangedRender()
end

run()
