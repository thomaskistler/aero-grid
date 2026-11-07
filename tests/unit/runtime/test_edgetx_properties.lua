-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
edgetx.constants()
edgetx.lcd()
local mock = edgetx.lvgl()

local function refuses(fn, message)
    local ok, failure = pcall(fn)
    assert(not ok and string.find(tostring(failure), message, 1, true), tostring(failure))
end

local color = lcd.RGB(17, 34, 51)
local parent = lvgl.box({ x = 0, y = 0, w = 100, h = 100 })
local label = lvgl.label(parent, { x = 1, y = 2, text = "before", color = color })
assert(label.properties.text == "before" and label.properties.color == color)
label:set({ text = "after", color = color })
assert(label.properties.text == "after" and label.properties.color == color)

refuses(function() lvgl.label(parent, { invalidProperty = 1 }) end, "Invalid property 'invalidProperty'")
refuses(function() lvgl.label(parent, { color = 0 }) end, "is not a colour lcd.RGB returned")
refuses(function() label:set({ invalidProperty = 1 }) end, "Invalid property 'invalidProperty'")
refuses(function() label:set({ color = "bad" }) end, "is not a colour lcd.RGB returned")
assert(label.properties.text == "after" and label.properties.color == color)

parent:clear()
mock.settle()
refuses(function() label:set({ text = "invalid" }) end, edgetx.firmware.INVALID_OBJECT_MESSAGE)
