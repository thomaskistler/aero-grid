-- SPDX-License-Identifier: GPL-2.0-only

-- Shared adversarial catalog for output parity and native per-advance bounds.
return function()
    local function copy(value)
        if type(value) ~= "table" then
            return value
        end
        local result = {}
        for key, item in pairs(value) do
            result[key] = copy(item)
        end
        return result
    end
    local dark = {
        version = 1,
        name = "modern-dark",
        label = "Modern Dark",
        accent = "cyan",
        correctForContrast = false,
        colors = {
            canvas = 0x0A0C0E,
            surface = 0x212830,
            surfaceRaised = 0x2E3841,
            border = 0x3A434B,
            track = 0x545F6A,
            chartGrid = 0x545F6A,
            text = 0xF4F6F7,
            textMuted = 0xDCE2E6,
            textFaint = 0xC4CDD3,
            cyan = 0x70D6F3,
            blue = 0x72AEFF,
            green = 0x55D990,
            amber = 0xFFE000,
            orange = 0xFF762E,
            critical = 0xF05252,
            activeBg = 0x365673,
        },
        spacing = {
            outerMargin = 4,
            gutter = 4,
            padding = 8,
            paddingTight = 8,
            paddingRight = 4,
            paddingCompact = 6,
            radius = 8,
            accentWidth = 4,
            accentGap = 4,
            barHeight = 4,
            borderFocus = 2,
        },
    }
    local light = copy(dark)
    light.name, light.label, light.light, light.tintSeparation = "modern-light", "Modern Light", true, 1.08
    light.colors = {
        canvas = 0xE5EAF0,
        surface = 0xFFFFFF,
        surfaceRaised = 0xE5EAF0,
        border = 0xB7C3D0,
        track = 0xCED7E2,
        text = 0x17212B,
        textMuted = 0x263642,
        textFaint = 0x3A4B58,
        cyan = 0x167BA8,
        blue = 0x2354C8,
        green = 0x147642,
        amber = 0xFFB700,
        orange = 0xC65B12,
        critical = 0xC92D2D,
        chartCyan = 0x0066CC,
        chartGreen = 0x00702A,
        chartAmber = 0x9D6A00,
        chartOrange = 0xC04A00,
        chartGrid = 0xC2C2C2,
        warningBg = 0xFFF4B8,
        criticalBg = 0xFAD0D0,
        activeBg = 0xD0DEF5,
    }
    local catalog = { version = 1, themes = { dark, light } }
    local requests = {
        {},
        { mode = "" },
        { mode = " \t " },
        { mode = "unknown" },
        { mode = false },
        { mode = "modern-dark" },
        { mode = "modern-light" },
    }
    local function add(definition)
        definition.name = "custom-" .. #catalog.themes
        definition.label = definition.name
        catalog.themes[#catalog.themes + 1] = definition
        requests[#requests + 1] = { mode = definition.name }
    end
    for _, value in ipairs({ 0, 0x202020, 0x555555, 0x777777, 0x999999, 0xCCCCCC, 0xFFFFFF }) do
        local definition = copy(dark)
        definition.correctForContrast = true
        for key in pairs(definition.colors) do
            definition.colors[key] = value
        end
        definition.colors.chartCyan, definition.colors.chartGreen = value, value
        definition.colors.chartAmber, definition.colors.chartOrange = value, value
        definition.colors.warningBg, definition.colors.criticalBg = value, value
        add(definition)
    end
    for _, base in ipairs({ dark, light }) do
        local corrected = copy(base)
        corrected.correctForContrast = true
        add(corrected)
        local fallback = copy(base)
        fallback.colors.warningBg, fallback.colors.criticalBg, fallback.colors.activeBg = nil, nil, nil
        fallback.tintSeparation = 21
        add(fallback)
    end
    -- Int32-safe deterministic palettes exercise hue and repeated corrections.
    local state = 17
    for _ = 1, 16 do
        local definition = copy(dark)
        definition.correctForContrast = true
        for _, key in ipairs({
            "canvas",
            "surface",
            "surfaceRaised",
            "border",
            "track",
            "text",
            "textMuted",
            "textFaint",
            "cyan",
            "blue",
            "green",
            "amber",
            "orange",
            "critical",
            "chartCyan",
            "chartGreen",
            "chartAmber",
            "chartOrange",
            "chartGrid",
            "warningBg",
            "criticalBg",
            "activeBg",
        }) do
            state = (state * 75 + 74) % 65537
            definition.colors[key] = state * 255
        end
        add(definition)
    end
    return catalog, requests, copy
end
