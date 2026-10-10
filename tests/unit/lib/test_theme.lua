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
    assertions.assertEqual(resolved.rgb.text, 0xF4F6F7)
    assertions.assertEqual(resolved.rgb.textMuted, 0xDCE2E6)
    assertions.assertEqual(resolved.rgb.textFaint, 0xC4CDD3)
    assertions.assertEqual(resolved.rgb.surface, 0x212830)
    assertions.assertEqual(resolved.rgb.canvas, 0x0A0C0E)
    local active = theme.state(resolved, "active")
    assertions.assertEqual(active.accent, resolved.color.blue)
    assertions.assertEqual(active.badge, "IN-FLIGHT")
    assertions.assertEqual(resolved.alertRgb.active, 0x365673)
    assert(active.surface and active.surface ~= resolved.color.surface, "active flights need a visible blue tint")
    assert(theme.contrast(resolved.rgb.text, resolved.alertRgb.active) >= 4.5)
    assert(theme.contrast(resolved.rgb.textMuted, resolved.alertRgb.active) >= 3.0)
    assert(theme.contrast(resolved.rgb.surface, resolved.alertRgb.active) >= 1.3)
    local frame = theme.frame(resolved, { w = 117, h = 134 }, { label = SMLSIZE, badge = SMLSIZE }, nil, "IN-FLIGHT")
    assert(frame.badgeWidth >= theme.measureText(SMLSIZE, "IN-FLIGHT"))
    assert(frame.labelHidden or frame.labelX + frame.labelWidth < frame.badgeX)
    for _, overrides in ipairs({
        { surface = 0xFFFFFF },
        { surface = 0x000000 },
        { surface = 0x205090 },
    }) do
        local derived = theme.build("custom", overrides)
        local surface = derived.alertRgb.active
        if surface then
            assert(theme.contrast(derived.rgb.text, surface) >= 4.5)
            assert(theme.contrast(derived.rgb.textMuted, surface) >= 3.0)
            assert(theme.contrast(derived.rgb.blue, surface) >= 2.5)
        end
    end
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
