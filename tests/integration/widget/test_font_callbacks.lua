-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { DashID = "aircraft-lite", Theme = "modern" })
local timer = assert(fixture.instanceOf(context, "flight-clock"))
local valueCallback = timer.value.properties.font
local headingCallback = timer.label.properties.font
local originalFont = valueCallback()
for second = 1, 3600 do
    fixture.radio.timers[0].value = second
    fixture.tick(100)
    definition.refresh(context)
    fixture.lvglMock.settle()
end
assert(#context.errors == 0, table.concat(context.errors, "\n"))
assert(timer.value.properties.font == valueCallback, "timer replaced its value font callback")
assert(timer.label.properties.font == headingCallback, "timer replaced its heading font callback")
assert(fixture.lvglMock.replacedFontRefCount() == 0, "timer updates leaked registry refs")

context.zone.w, context.zone.h = 320, 180
fixture.pump(context, 40)
assert(valueCallback() ~= originalFont, "persistent callback did not follow the smaller font")
assert(timer.value.properties.font == valueCallback)
assert(timer.label.properties.font == headingCallback)
context.zone.w, context.zone.h = 480, 272
fixture.pump(context, 40)
assert(valueCallback() == originalFont, "persistent callback did not restore the original font")
assert(fixture.lvglMock.replacedFontRefCount() == 0, "reflow leaked registry refs")

-- Prove the mock sees the firmware bug, rather than silently replacing refs.
local label = lvgl.label({
    text = "probe",
    font = function()
        return SMLSIZE
    end,
})
label:set({
    font = function()
        return MIDSIZE
    end,
})
assert(fixture.lvglMock.replacedFontRefCount() == 1, "mock failed to retain an overwritten font callback")
