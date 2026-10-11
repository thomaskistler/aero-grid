-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local moduleLoader = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
local yaml = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/yaml.lua"))()
edgetx.constants()
_G.lcd = {
    RGB = function(value)
        return value
    end,
}
local theme = moduleLoader("lib/theme.lua")
local catalog = assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, yaml)
local definition = assert(yaml.parse(assert(yaml.serialize(catalog.themes[1]))))
definition.name = "explicit-backgrounds"
definition.label = "Explicit backgrounds"
definition.correctForContrast = false
definition.colors.amber = 0xFFB700
definition.colors.warningBg = 0xFFF4B8
definition.colors.criticalBg = 0xFFFFFF
definition.colors.activeBg = 0x000000
catalog.themes[#catalog.themes + 1] = definition
assert(theme.setCatalog(catalog))

local resolved = theme.build(definition.name)
assertions.assertEqual(resolved.rgb.amber, 0xFFB700)
for state, key in pairs({ warning = "warningBg", critical = "criticalBg", active = "activeBg" }) do
    assertions.assertEqual(resolved.alertRgb[state], definition.colors[key])
    assertions.assertEqual(resolved.alertColor[state], lcd.RGB(definition.colors[key]))
    assertions.assertEqual(theme.state(resolved, state).surface, lcd.RGB(definition.colors[key]))
end

definition.correctForContrast = true
assert(theme.setCatalog(catalog))
resolved = theme.build(definition.name)
for state, key in pairs({ warning = "warningBg", critical = "criticalBg", active = "activeBg" }) do
    assert(resolved.alertRgb[state] ~= definition.colors[key], state .. " must retain contrast correction")
end

definition.correctForContrast = false
definition.colors.warningBg = nil
definition.colors.criticalBg = nil
definition.colors.activeBg = nil
assert(theme.setCatalog(catalog))
resolved = theme.build(definition.name)
for state, accent in pairs({ warning = "amber", critical = "critical", active = "blue" }) do
    assertions.assertEqual(
        resolved.alertRgb[state],
        theme.alertSurface(resolved.rgb, resolved.rgb[accent], nil, state ~= "active")
    )
end

definition.colors.warningBg = "invalid"
local validated, err = theme.validateCatalog(catalog)
assert(not validated and string.find(err, "warningBg must be a 24-bit color", 1, true))

print("theme explicit alert background tests passed")
