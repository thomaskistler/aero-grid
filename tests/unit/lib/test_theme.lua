-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
local yaml = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/yaml.lua"))()
edgetx.constants()
_G.lcd = {
    RGB = function(value)
        return value
    end,
}
local theme = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/theme.lua"))()
local themes = assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, yaml)
assert(theme.setCatalog(themes))
local customIndex = 0

local function buildCustomTheme(overrides)
    customIndex = customIndex + 1
    local base = themes.themes[1]
    local definition = {
        version = 1,
        name = "theme-test-" .. customIndex,
        label = "Theme Test " .. customIndex,
        accent = "cyan",
        colors = {},
        spacing = {},
    }
    for key, value in pairs(base.colors) do
        definition.colors[key] = value
    end
    for key, value in pairs(base.spacing) do
        definition.spacing[key] = value
    end
    for key, value in pairs(overrides) do
        definition.colors[key] = value
    end
    themes.themes[#themes.themes + 1] = definition
    assert(theme.setCatalog(themes))
    return theme.build(definition.name)
end

local function testThemeVersionIsRequiredAndSupported()
    local document = assert(yaml.parse(assert(yaml.serialize(themes))))
    document.themes[1].version = nil
    local validated, err = theme.validateCatalog(document)
    assert(not validated and string.find(err, "modern-dark must have version 1", 1, true))

    document.themes[1].version = 2
    validated, err = theme.validateCatalog(document)
    assert(not validated and string.find(err, "modern-dark must have version 1", 1, true))
end

local function testModernThemeBuilds()
    local resolved = theme.build("modern-dark")
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
    for _, colors in ipairs({
        { surface = 0xFFFFFF },
        { surface = 0x000000 },
        { surface = 0x205090 },
    }) do
        local derived = buildCustomTheme(colors)
        local surface = derived.alertRgb.active
        if surface then
            assert(theme.contrast(derived.rgb.text, surface) >= 4.5)
            assert(theme.contrast(derived.rgb.textMuted, surface) >= 3.0)
            assert(theme.contrast(derived.rgb.blue, surface) >= 2.5)
        end
    end
    assertions.assertEqual(resolved.mode, "modern-dark")
    assertions.assertTableHasKey(resolved.color, "surface", "theme.result should expose a surface color")
    assertions.assertEqual(type(resolved.warnings), "table")
end

local function testContrastIsCalculated()
    local modern = theme.build("modern-dark")
    local ratio = theme.contrast(modern.color.text, modern.color.surface)
    assert(ratio >= 4.5, "text contrast should remain readable")
end

local function testModernLightTheme()
    local resolved = theme.build("modern-light")
    local tokens = resolved.rgb
    assertions.assertEqual(resolved.mode, "modern-light")
    assertions.assertEqual(tokens.canvas, 0xE5EAF0)
    assertions.assertEqual(tokens.surface, 0xFFFFFF)
    assertions.assertEqual(tokens.text, 0x17212B)
    assertions.assertEqual(tokens.critical, 0xC92D2D)
    assertions.assertEqual(#resolved.warnings, 0)
    assertions.assertEqual(#resolved.notices, 0, "designed light palette must not need correction or lose its tints")
    assert(theme.contrast(tokens.canvas, tokens.surface) >= 1.15)
    assert(theme.contrast(tokens.surface, tokens.surfaceRaised) >= 1.15)
    assert(theme.contrast(tokens.surface, tokens.track) >= 1.35)
    assertions.assertEqual(tokens.textMuted, 0x263642)
    assertions.assertEqual(tokens.textFaint, 0x3A4B58)
    assertions.assertEqual(resolved.alertRgb.warning, 0xFFF3D8)
    assertions.assertEqual(resolved.alertRgb.critical, 0xFAD0D0)
    assertions.assertEqual(resolved.alertRgb.active, 0xD0DEF5)
    for key, minimum in pairs({
        text = 4.5,
        textMuted = 3.0,
        textFaint = 1.8,
        cyan = 2.5,
        green = 2.5,
        amber = 2.5,
        orange = 2.5,
        blue = 2.5,
        critical = 2.5,
    }) do
        assert(theme.contrast(tokens.surface, tokens[key]) >= minimum, key .. " fails light surface contrast")
    end
    -- The TX16S framebuffer quantizes colors; check the pixels, not only RGB24.
    local function quantized(rgb)
        local r = math.floor(rgb / 65536) % 256
        local g = math.floor(rgb / 256) % 256
        local b = rgb % 256
        return theme.fromRgb565(math.floor(r / 8) * 2048 + math.floor(g / 4) * 32 + math.floor(b / 8))
    end
    for name, accent in pairs({ warning = "amber", critical = "critical", active = "blue" }) do
        local tint = assert(resolved.alertRgb[name], name .. " needs a distinct light tint")
        for _, convert in ipairs({
            function(v)
                return v
            end,
            quantized,
        }) do
            local surface = convert(tint)
            assert(theme.contrast(convert(tokens.surface), surface) >= 1.08, name .. " tint is too subtle")
            assert(theme.contrast(convert(tokens.canvas), surface) >= 1.08, name .. " tint disappears into canvas")
            assert(theme.contrast(convert(tokens.text), surface) >= 4.5)
            assert(theme.contrast(convert(tokens.textMuted), surface) >= 3.0)
            assert(theme.contrast(convert(tokens.textFaint), surface) >= 1.8)
            assert(theme.contrast(convert(tokens[accent]), surface) >= 2.5, name .. " badge loses contrast")
        end
    end
end

local function run()
    testThemeVersionIsRequiredAndSupported()
    testModernThemeBuilds()
    testModernLightTheme()
    testContrastIsCalculated()
    local resolved = theme.build("modern-dark")
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
