-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local loadModule = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
edgetx.constants()
edgetx.lcd()
edgetx.lvgl()

local theme = loadModule("lib/theme.lua")
local primitives = loadModule("lib/primitives.lua")
local yaml = loadModule("lib/yaml.lua")
assert(theme.setCatalog(assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, yaml)))

local function definedIn(callback, filename)
    local source = debug.getinfo(callback, "S").source
    assert(string.sub(source, -#filename) == filename, source .. " should end with " .. filename)
end

definedIn(theme.build, "theme.lua")
definedIn(theme.measureText, "typography.lua")
definedIn(theme.panel, "panel_layout.lua")
definedIn(primitives.value, "primitives.lua")
definedIn(primitives.centreReading, "reading.lua")
definedIn(primitives.changed, "reading.lua")

-- Fresh composition must not share mutable vocabulary or font state.
local otherTheme = loadModule("lib/theme.lua")
theme.BADGES.stale = "OLD"
assert(otherTheme.BADGES.stale == "STALE")
local otherPrimitives = loadModule("lib/primitives.lua")
primitives.SENTINELS["missing"] = true
assert(otherPrimitives.SENTINELS["missing"] == nil)

local resolved = theme.build("modern-dark")
local area = { valueX = 12, valueY = 20, valueWidth = 70, value = DBLSIZE, unitFont = SMLSIZE }
local parent = lvgl.box({ x = 0, y = 0, w = 120, h = 65 })
local value, unit = primitives.reading(parent, resolved, area, { value = resolved.color.text }, "")
assert(value.properties.x == area.valueX and value.properties.w == area.valueWidth)
assert(value.properties.text == "--")
assert(unit.properties.text == "")
local context = { value = value, unit = unit, showUnit = true, unitText = "V" }
primitives.reflowReading(context, theme, area, area.value, "--", true)
assert(context.unitDrawn == false, "reflow must not reveal an unresolved unit")
context.text = "12"
unit:set({ text = "V" })
primitives.reflowReading(context, theme, area, area.value, "12", true)
assert(context.unitDrawn == true, "a resolved reading must regain its unit")
assert(unit.properties.text == "V")
