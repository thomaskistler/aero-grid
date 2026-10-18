-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local battery = fixture.module("panels/tx-battery.lua")

fixture.reset()
local context = fixture.createLoaded(nil, { Layout = "review-tx-battery", Theme = "modern-dark" })
fixture.pump(context, 40)
equal(#context.errors, 0, table.concat(context.errors, "\n"))

local tiny = fixture.instanceOf(context, "smallest")
local wide = fixture.instanceOf(context, "wide")
local narrow = fixture.instanceOf(context, "narrow")
local voltage = fixture.instanceOf(context, "warned")
local bar = fixture.instanceOf(context, "barred")
equal(tiny.settings.showPercent, true)
equal(tiny.detailLabel.hidden, true, "a compact panel must quietly shed the percentage")
equal(tiny.detail, "")

local function assertGlyph(panel, shown)
    equal(panel.glyphShown, shown)
    for _, part in ipairs({ panel.glyph.shell, panel.glyph.nub, panel.glyph.fill }) do
        equal(part.hidden, not shown)
    end
end

assertGlyph(tiny, true)
equal(tiny.value.hidden, false, "header clearance leaves room for the compact reading")
equal(tiny.unit.hidden, false)
for _, panel in ipairs({ narrow }) do
    assertGlyph(panel, true)
    equal(panel.value.hidden, true)
    equal(panel.unit.hidden, true)
    equal(
        panel.glyph.x,
        panel.area.pad + math.floor(panel.area.content / 2) - math.floor(panel.glyph.width / 2),
        "a lone glyph must be centered"
    )
end
assertGlyph(wide, true)
equal(wide.value.hidden, false)
equal(wide.unit.hidden, false)
equal(voltage.glyph, nil, "visual: none must never draw a glyph")
equal(voltage.value.hidden, false)
equal(voltage.unit.hidden, false)
equal(bar.barShown, true)
equal(bar.value.hidden, false)

local function assertPercentCentered(panel)
    local label = panel.detailLabel.properties
    local width = panel.themeBuilder.measureText(panel.fonts.label, label.text)
    equal(label.x, panel.area.pad + math.floor(panel.area.content / 2) - math.floor(width / 2))
    equal(label.w, math.max(1, width))
end

assertPercentCentered(narrow)
assertPercentCentered(fixture.instanceOf(context, "full"))
for _, value in ipairs({ 6.6, 8.4, 7.9 }) do
    fixture.radio.values[320] = value
    fixture.pump(context, 40)
    assertPercentCentered(narrow)
    assertPercentCentered(fixture.instanceOf(context, "full"))
end

-- Resize both directions without a telemetry change or refresh.
local original = { x = 0, y = 0, w = 117, h = 65 }
for _ = 1, 2 do
    battery.update(tiny, { x = 0, y = 0, w = 238, h = 134 })
    assertGlyph(tiny, true)
    equal(tiny.value.hidden, false)
    assertPercentCentered(tiny)
    battery.update(tiny, original)
    assertGlyph(tiny, true)
    equal(tiny.value.hidden, false)
    equal(tiny.unit.hidden, false)
    equal(tiny.detailLabel.hidden, true)
end

battery.update(narrow, { x = 0, y = 0, w = 117, h = 65 })
equal(narrow.detailLabel.hidden, true)
equal(narrow.detail, "")
battery.update(narrow, { x = 0, y = 0, w = 117, h = 134 })
equal(narrow.detailLabel.hidden, false)
assert(narrow.detail ~= "", "the percentage must return when space is restored")
assertPercentCentered(narrow)
for _, width in ipairs({ 190, 238, 117 }) do
    battery.update(narrow, { x = 0, y = 0, w = width, h = 134 })
    assertPercentCentered(narrow)
end

local feed, range = tiny.feed, tiny.range
tiny.settings.packEmpty, tiny.settings.packFull = nil, nil
tiny.range = { available = false }
battery.refresh(tiny)
assertGlyph(tiny, false)
equal(tiny.value.hidden, false, "no calibration must fall back to voltage")
equal(tiny.unit.hidden, false)
equal(tiny.value.properties.text, "7.9")
equal(tiny.detail, "")
battery.update(tiny, original)
assertGlyph(tiny, false)
equal(tiny.value.hidden, false)
equal(tiny.unit.hidden, false)

tiny.range = range
battery.refresh(tiny)
assertGlyph(tiny, true)
equal(tiny.value.hidden, false, "restored calibration must retain the compact reading")

tiny.feed = { available = false }
battery.refresh(tiny)
assertGlyph(tiny, false)
equal(tiny.value.hidden, false)
equal(tiny.unit.hidden, true)
equal(tiny.value.properties.text, "--")
equal(tiny.badge.properties.text, "N/A")
battery.update(tiny, original)
assertGlyph(tiny, false)
equal(tiny.value.hidden, false)
equal(tiny.unit.hidden, true)

tiny.feed = { available = true, value = 7.9, stale = true }
battery.refresh(tiny)
assertGlyph(tiny, true)
equal(tiny.value.hidden, false)
equal(tiny.badge.properties.text, "STALE")

tiny.feed = feed
tiny.settings.warning, tiny.settings.critical = 8.0, 7.8
battery.refresh(tiny)
equal(tiny.stateName, "warning")
equal(tiny.badge.properties.text, "WARN")
equal(tiny.glyph.shell.properties.color, context.theme.color.amber)
tiny.settings.critical = 8.0
battery.refresh(tiny)
equal(tiny.stateName, "critical")
equal(tiny.badge.properties.text, "CRIT")
for _, part in ipairs({ tiny.glyph.shell, tiny.glyph.nub, tiny.glyph.fill }) do
    equal(part.properties.color, context.theme.color.critical)
end

-- A glyph that could not be built initially must appear when space returns.
local small = fixture.createLoaded({ x = 0, y = 0, w = 120, h = 120 }, {
    Layout = "review-tx-battery",
    Theme = "modern-dark",
})
fixture.pump(small, 40)
equal(#small.errors, 0, table.concat(small.errors, "\n"))
local grown = fixture.instanceOf(small, "smallest")
equal(grown.glyph, nil)
battery.update(grown, original)
assertGlyph(grown, true)
equal(grown.value.hidden, false)
