-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local trims = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/trim-panel.lua"))()

local function testSettings()
    local defaults = {}
    for _, setting in ipairs(trims.settings) do
        defaults[setting.key] = setting.default
    end
    assertions.assertEqual(#trims.settings, 7)
    assertions.assertEqual(defaults.trim1, "trim-ail")
    assertions.assertEqual(defaults.trim2, "trim-ele")
    assertions.assertEqual(defaults.trim4, "trim-rud")
    assertions.assertEqual(defaults.scale, "auto")
    assertions.assertEqual(defaults.readout, "percent")
    assertions.assertEqual(defaults.label, "TRIM")
    assertions.assertEqual(defaults.accent, "cyan")
    local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
    for _, key in ipairs({
        "indicators",
        "trim3",
        "orientation",
        "orientation1",
        "orientation2",
        "orientation3",
        "orientation4",
    }) do
        local _, warnings = host.resolveSettings(trims, { [key] = "single" })
        assertions.assertEqual(#warnings, 1)
        assertions.assertEqual(warnings[1], key .. " is not a setting of this panel")
    end
end

local function testCaptionsAndValues()
    assertions.assertEqual(trims.captionFor("trim-ail"), "AIL")
    assertions.assertEqual(trims.captionFor("trim-t5"), "T5")
    assertions.assertEqual(trims.captionFor("sa"), "SA")
    assertions.assertEqual(trims.captionFor(nil), "--")

    local right = {
        available = true,
        raw = 240,
        value = 30,
        fraction = 0.234375,
        centered = false,
        threePosition = false,
    }
    assertions.assertEqual(trims.valueText({ readout = "percent" }, right), "+23%")
    assertions.assertEqual(trims.valueText({ readout = "raw" }, right), "+30")
    assertions.assertEqual(trims.valueText({ readout = "none" }, right), "")

    local centered = { available = true, raw = 0, value = 0, fraction = 0, centered = true, threePosition = false }
    assertions.assertEqual(trims.valueText({ readout = "percent" }, centered), "0%")
    assertions.assertEqual(trims.valueText({ readout = "raw" }, centered), "0")
    assertions.assertEqual(trims.valueText({ readout = "percent" }, nil), "--")

    local toggle = {
        available = true,
        raw = 1024,
        value = 128,
        fraction = 1,
        centered = false,
        threePosition = true,
    }
    assertions.assertEqual(trims.valueText({ readout = "percent" }, toggle), "3P HI")
    toggle.raw, toggle.centered, toggle.fraction = 0, true, 0
    assertions.assertEqual(trims.valueText({ readout = "percent" }, toggle), "3P MID")
    toggle.raw, toggle.centered, toggle.fraction = -1024, false, -1
    assertions.assertEqual(trims.valueText({ readout = "raw" }, toggle), "3P LO")
end

local function run()
    testSettings()
    testCaptionsAndValues()
end

run()
