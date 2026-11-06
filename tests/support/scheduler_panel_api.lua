-- SPDX-License-Identifier: GPL-2.0-only

local function noop() end
local function node()
    return { set = noop }
end
local native = {
    box = node,
    rectangle = node,
    label = node,
    image = node,
    triangle = node,
    arc = node,
    hline = node,
    vline = node,
    line = node,
    show = noop,
    hide = noop,
}
local screen = {
    RGB = function(value)
        return value
    end,
    sizeText = function(text)
        return #text * 10, 17
    end,
}
local function withApi(fn, ...)
    local oldLvgl, oldLcd = lvgl, lcd
    lvgl, lcd = native, screen
    local ok, a, b = pcall(fn, ...)
    lvgl, lcd = oldLvgl, oldLcd
    assert(ok, a)
    return a, b
end
return {
    node = node,
    withApi = withApi,
    theme = {
        accent = "cyan",
        rgb = { surface = 0x212830 },
        alertRgb = {},
        alertColor = {},
        color = {
            surface = 0x212830,
            text = 0xF4F6F7,
            textMuted = 0xDCE2E6,
            textFaint = 0xC4CDD3,
            border = 0x3A434B,
            cyan = 0x70D6F3,
            green = 0x55D990,
            amber = 0xE9BC55,
            critical = 0xED7979,
        },
        chartColor = { cyan = 0x70D6F3, orange = 0xEDAD79, green = 0x55D990, grid = 0x3A434B },
        spacing = {
            padding = 8,
            paddingTight = 8,
            paddingRight = 4,
            paddingCompact = 6,
            radius = 8,
            accentWidth = 4,
            barHeight = 4,
            borderFocus = 2,
        },
    },
}
