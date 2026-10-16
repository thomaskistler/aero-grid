-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local panel = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/output.lua"))()
local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
local settings, errors = host.resolveSettings(panel, {})
equal(#errors, 0)
equal(settings.label, "CHANNEL OUTPUT")
equal(settings.accent, "cyan")
equal(settings.showNames, true)
equal(settings.showTrim, true)
equal(settings.firstChannel, 1)
equal(settings.channelCount, nil)
for _, invalid in ipairs({ 0, 33, 1.5, math.huge, 0 / 0 }) do
    local resolved, reported = host.resolveSettings(panel, { firstChannel = invalid, channelCount = invalid })
    equal(#reported, 2, "invalid channel ranges must be reported")
    equal(resolved.firstChannel, 1)
    equal(resolved.channelCount, nil)
end
equal(panel.valueText(nil), "--")
equal(panel.valueText({ available = false, fraction = 0 }), "--")
for _, sample in ipairs({
    { 0, "0%" },
    { 0.05, "+5%" },
    { -0.1, "-10%" },
    { 0.8, "+80%" },
    { -0.234, "-23%" },
    { -0.005, "-1%" },
    { 1.5, "+150%" },
    { -1.5, "-150%" },
}) do
    equal(panel.valueText({ available = true, fraction = sample[1] }), sample[2])
end

local fixture = assert(loadfile(root .. "/tests/support/runtime_fixture.lua"))(root)
local builder = fixture.theme
local context = {
    theme = builder.build("modern-dark"),
    themeBuilder = builder,
    fonts = builder.typography(1, 1),
}
for _, size in ipairs({ { 320, 240 }, { 480, 272 }, { 800, 480 } }) do
    for columns = 1, 4 do
        for rows = 1, 4 do
            local rect = assert(
                fixture.grid.rect(
                    { w = size[1], h = size[2] },
                    { col = 0, row = 0, colSpan = columns, rowSpan = rows },
                    4,
                    4,
                    4
                )
            )
            local area = panel.regionsFor(context, rect)
            assert(area.count > 0, "every unobstructed supported span must fit at least one channel")
            assert(area.top + area.count * area.pitch <= rect.h - area.frame.bottom)
            if area.count < 32 then
                assert(area.top + (area.count + 1) * area.pitch > rect.h - area.frame.bottom)
            end
            assert(area.barWidth >= 24)
            assert(area.captionWidth >= builder.measureText(area.font, "CH1"))
            if not area.stacked and area.showNames then
                assert(area.barWidth >= 64, "channel names must leave at least 64 pixels for the tape")
            end
            assert(area.barX + area.barWidth <= rect.w - area.frame.padRight)
        end
    end
end
equal(panel.regionsFor(context, { w = 800, h = 1000 }).count, 32)
local narrow = panel.regionsFor(context, { w = 120, h = 240 })
assert(not narrow.stacked)
assert(not narrow.showNames, "narrow side-by-side rows must prioritize the tape over names")
assert(not narrow.showValues, "narrow panels omit percentages to preserve useful tapes")
equal(narrow.valueWidth, 0)
equal(narrow.barX + narrow.barWidth, narrow.frame.pad + narrow.frame.content)
assert(panel.regionsFor(context, { w = 480, h = 240 }).showValues)
context.settings = { firstChannel = 9, channelCount = 4, showNames = false }
local selected = panel.regionsFor(context, { w = 800, h = 1000 })
equal(selected.count, 4)
equal(selected.firstChannel, 9)
assert(not selected.showNames)
context.settings = { firstChannel = 31, channelCount = 10 }
equal(panel.regionsFor(context, { w = 800, h = 1000 }).count, 2, "ranges stop at CH32")
context.settings = { firstChannel = 9, channelCount = 32 }
assert(panel.regionsFor(context, { w = 480, h = 100 }).count < 32, "configured ranges stop at available rows")
