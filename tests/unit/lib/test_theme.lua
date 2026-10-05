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
    local resolved = theme.build("modern")
    local fonts = { label = SMLSIZE, badge = SMLSIZE }
    for span = 1, 4 do
        local rect = { w = 117 * span, h = 65 }
        local ordinary = theme.frame(resolved, rect, fonts)
        local frame = theme.frame(resolved, rect, fonts, { w = 47, h = 45, side = true })
        assertions.assertEqual(frame.top, ordinary.top)
        assertions.assertEqual(frame.pad, 51)
        assertions.assertEqual(frame.content, rect.w - frame.pad - frame.padRight)
        assert(frame.labelX >= 51)
        assertions.assertEqual(theme.readingRoom(frame, rect, 0, false), theme.readingRoom(ordinary, rect, 0, false))
    end
    local tall = theme.frame(resolved, { w = 238, h = 134 }, fonts, { w = 47, h = 45 })
    assert(tall.top >= 45)
    assert(tall.pad < 47)
    local rect = { w = 238, h = 65 }
    local frame = theme.frame(resolved, rect, fonts, { w = 47, h = 45, side = true })
    local function panel(forms, unit)
        return theme.panel(resolved, rect, fonts, {
            frame = frame,
            forms = forms,
            unit = unit,
            draws = { rows = false, visual = false },
        }, {})
    end
    local ordinary = theme.panel(resolved, rect, fonts, {
        frame = theme.frame(resolved, rect, fonts),
        forms = { "00:00" },
        draws = { rows = false, visual = false },
    }, {})
    local timer = panel({ "00:00" })
    assertions.assertEqual(timer.valueCentre, ordinary.valueCentre)
    assertions.assertEqual(timer.value, ordinary.value)
    assert(timer.frame.labelX >= 51, "normal primary position removed heading clearance")
    local wide = panel({ "888888888888" })
    assert(wide.valueCentre > ordinary.valueCentre, "overlapping sample was not inset")
    local withUnit = panel({ "88" }, "V")
    assertions.assertEqual(withUnit.valueCentre, ordinary.valueCentre)
end

run()
