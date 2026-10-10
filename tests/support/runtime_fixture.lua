-- SPDX-License-Identifier: GPL-2.0-only

local root = ...

--- The minimal EdgeTX surface the pure-Lua modules need.
---
--- Deliberately only `constants()` and `lcd()`. No `lvgl`, no `getValue`, no
--- `model`: that is what proves a lib module works without a host, and it only
--- proves it while the surface stays this small. If one call installed the
--- whole radio, a module that had quietly started reading a host global would
--- keep passing here and fail on hardware.
---
--- Every value in it is a claim about the radio carrying the firmware file and
--- symbol it came from; see `tests/support/edgetx.lua`.
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
local firmware = edgetx.firmware

edgetx.constants()
local lcdMock = edgetx.lcd()
local toRgb565 = lcdMock.toRgb565
local toLcdFlags = lcdMock.toLcdFlags

-- The minimal surface is the point, so it is asserted rather than assumed. A
-- lib module that quietly started reaching for a host global would otherwise
-- keep passing here, which is the whole reason this suite is separate.
for _, name in ipairs({
    "lvgl",
    "model",
    "getValue",
    "getFieldInfo",
    "getRSSI",
    "getTime",
    "getFlightMode",
    "fstat",
    "loadScript",
}) do
    assert(_G[name] == nil, "the unit suite installed " .. name .. ", which it is meant to do without")
end

local loadModule = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)

local grid = loadModule("lib/grid.lua")
local yaml = loadModule("lib/yaml.lua")
local layout = loadModule("lib/layout.lua")
local layoutStore = loadModule("lib/layout_store.lua")
local panelHost = loadModule("lib/panel_host.lua")
local theme = loadModule("lib/theme.lua")
local themeDocument = assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, yaml)
assert(theme.setCatalog(themeDocument))
local customThemeIndex = 0

local function buildCustomTheme(overrides)
    customThemeIndex = customThemeIndex + 1
    local base = themeDocument.themes[1]
    local definition = {
        version = 1,
        name = "runtime-custom-" .. customThemeIndex,
        label = "Runtime Custom " .. customThemeIndex,
        accent = overrides.accent or base.accent,
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
        if key == "accent" then
            definition.accent = value
        else
            definition.colors[key] = value
        end
    end
    themeDocument.themes[#themeDocument.themes + 1] = definition
    assert(theme.setCatalog(themeDocument))
    return theme.build(definition.name)
end
local primitives = loadModule("lib/primitives.lua")
local services = loadModule("lib/services.lua")
local telemetryService = loadModule("lib/telemetry_service.lua")
local modelService = loadModule("lib/model_service.lua")
local controlService = loadModule("lib/control_service.lua")
local extremaService = loadModule("lib/extrema_service.lua")
local navigationService = loadModule("lib/navigation_service.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

--- Compare font constants by name.
---
--- The real constants are LcdFlags, so a mismatch otherwise reads "expected
--- 1536, got 1280", which tells a reader nothing. Correcting the fixture to
--- the radio's values is only worth doing if a failure stays legible.
local function assertFont(actual, expected, message)
    if actual ~= expected then
        error(
            (message or "wrong font")
                .. ": expected "
                .. edgetx.fontName(expected)
                .. ", got "
                .. edgetx.fontName(actual),
            2
        )
    end
end

--- Build a telemetry environment whose sensors and link state a test controls.
local function telemetryHarness()
    local harness = {
        rssi = 80,
        fields = {
            RxBt = { id = 100, name = "RxBt", unit = 1 },
            Alt = { id = 103, name = "Alt", unit = 9 },
        },
        values = { [100] = 24.4, [103] = 0 },
        sensors = {
            [0] = { name = "RxBt", prec = 2 },
            [1] = { name = "Alt", prec = 1 },
        },
    }

    harness.env = services.environment({
        getFieldInfo = function(name)
            return harness.fields[name]
        end,
        getValue = function(id)
            return harness.values[id]
        end,
        getRSSI = function()
            return harness.rssi
        end,
        model = {
            getSensor = function(index)
                return harness.sensors[index]
            end,
        },
    })

    harness.service = telemetryService.new(harness.env, services)
    return harness
end

return {
    root = root,
    edgetx = edgetx,
    firmware = firmware,
    lcdMock = lcdMock,
    toRgb565 = toRgb565,
    toLcdFlags = toLcdFlags,
    loadModule = loadModule,
    grid = grid,
    yaml = yaml,
    layout = layout,
    layoutStore = layoutStore,
    panelHost = panelHost,
    theme = theme,
    themeDocument = themeDocument,
    customThemeIndex = customThemeIndex,
    buildCustomTheme = buildCustomTheme,
    primitives = primitives,
    services = services,
    telemetryService = telemetryService,
    modelService = modelService,
    controlService = controlService,
    extremaService = extremaService,
    navigationService = navigationService,
    assertEqual = assertEqual,
    assertFont = assertFont,
    telemetryHarness = telemetryHarness,
}
