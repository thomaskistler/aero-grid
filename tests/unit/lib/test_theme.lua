-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
edgetx.constants()
_G.lcd = {
    RGB = function(value)
        return value
    end,
}
local theme = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/theme.lua"))()

local function testModernThemeBuilds()
    local resolved = theme.build("modern")
    assertions.assertEqual(resolved.mode, "modern")
    assertions.assertTableHasKey(resolved.color, "surface", "theme.result should expose a surface color")
    assertions.assertEqual(type(resolved.warnings), "table")
end

local function testContrastIsCalculated()
    local modern = theme.build("modern")
    local ratio = theme.contrast(modern.color.text, modern.color.surface)
    assert(ratio >= 4.5, "text contrast should remain readable")
end

local function run()
    testModernThemeBuilds()
    testContrastIsCalculated()
end

run()
