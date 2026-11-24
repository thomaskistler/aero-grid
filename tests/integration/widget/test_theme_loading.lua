-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local addTheme = fixture.addTheme
local themeModule = fixture.module("lib/theme.lua")
local pump = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local function testLayoutSelectsLightTheme()
    local widgetPath = makeWidget(
        "light-theme",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: only
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: Light
]]
    )

    local context = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "main", Theme = "modern-light" },
        widgetPath
    )

    assertEqual(context.theme.mode, "modern-light")
    assertEqual(#context.panels, 1)

    local tokens = context.theme.rgb
    assertEqual(tokens.canvas, 0xE5EAF0)
    assertEqual(tokens.surface, 0xFFFFFF)
    assert(themeModule.contrast(tokens.surface, tokens.text) >= 4.5)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testCustomTheme()
    local widgetPath = makeWidget(
        "custom-theme",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: only
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: Custom
]]
    )
    addTheme(widgetPath, "custom", {
        accent = "green",
        colors = { canvas = 0x000000, surface = 0x101010, border = 0xFF00FF },
    })

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "main", Theme = "custom" }, widgetPath)

    assertEqual(context.theme.mode, "custom")
    assertEqual(context.theme.rgb.canvas, 0x000000)
    -- 0x101010 on a black canvas measures 1.11, and with no resting outline the
    -- fill is the only thing that makes a panel a panel, so the legibility pass
    -- lifts it exactly as it lifts a surface that would swallow text.
    assert(
        themeModule.contrast(context.theme.rgb.canvas, context.theme.rgb.surface) >= 1.30,
        "a named theme surface was left flat against its own canvas"
    )
    assertEqual(context.theme.accent, "green")
    assertEqual(context.theme.rgb.border, 0xFF00FF, "the full theme palette did not apply its border token")
    assert(
        themeModule.contrast(context.theme.rgb.surface, context.theme.rgb.border) >= 1.25,
        "the border vanished into the surface"
    )

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testChangingToNewTheme()
    local widgetPath = makeWidget("theme-option-change")
    addTheme(widgetPath, "new-theme", {
        correctForContrast = false,
        colors = { canvas = 0x102030 },
    })
    local context = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "Default", Theme = "modern-dark" },
        widgetPath
    )
    definition.update(context, { Layout = "Default", Theme = "new-theme" })
    pump(context, 100)
    assertEqual(context.theme.mode, "new-theme", "option changes load a previously unused theme")
    assertEqual(context.theme.rgb.canvas, 0x102030)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    definition.update(context, { Layout = "Default", Theme = "modern-light" })
    pump(context, 100)
    assertEqual(context.theme.mode, "modern-light", "theme changes also load the other built-in palette")
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testUserThemeOverridesShippedTheme()
    local widgetPath = makeWidget("theme-override")
    addTheme(widgetPath, "modern-dark", {
        correctForContrast = false,
        colors = { canvas = 0x102030 },
    })
    local context = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "Default", Theme = "modern-dark" },
        widgetPath
    )
    assertEqual(context.theme.mode, "modern-dark")
    assertEqual(context.theme.rgb.canvas, 0x102030)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testThemeAppearance()
    local widgetPath = makeWidget(
        "panel-opacity",
        [[
version: 5
grid:
  columns: 4
  rows: 4
panels:
  - id: only
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: Altitude
]]
    )
    local function appearance(context, canvasOpacity, panelOpacity)
        assertEqual(context.canvas.properties.opacity, canvasOpacity, "canvas opacity")
        assertEqual(context.theme.panelOpacity, panelOpacity, "resolved theme opacity")
        local instance = context.panels[1].instance
        local panel = instance.panel
        assertEqual(panel.background.properties.opacity, panelOpacity, "panel fill opacity")
        assertEqual(panel.root.properties.opacity, nil, "panel children must not be faded")
        assertEqual(instance.label.properties.opacity, nil, "heading must not be faded")
        assertEqual(panel.accent.properties.opacity, nil, "status accent must not be faded")
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    end
    local selected = { Layout = "Default", Theme = 3 }
    local solid = createLoaded(nil, { Layout = "Default", Theme = "modern-dark" }, widgetPath)
    appearance(solid, 255, 255)
    for _, sentinel in ipairs({ 0, -1, 999, 4294967295 }) do
        local defaults =
            createLoaded(nil, { Layout = "Default", Theme = sentinel, Backdrop = 2, PanelFill = sentinel }, widgetPath)
        appearance(defaults, 255, 255)
        assertEqual(defaults.radioBackground, false, "missing themes must select opaque Dark")
    end
    appearance(createLoaded(nil, { Layout = "Default", Theme = "modern-dark" }, widgetPath), 255, 255)
    assertEqual(definition.options[2][3], 1, "new widgets retain the Dark default")
    assertEqual(table.concat(definition.options[2][4], ","), "Dark,Light,Glass")
    assertEqual(#definition.options, 2, "appearance must use a single Theme setting")
    local context = definition.create(fixture.lvglMock.appZone(), selected, widgetPath)
    assertEqual(context.canvas.properties.opacity, 0, "startup must expose the radio background")
    pump(context, 100)
    appearance(context, 0, 204)
    assertEqual(context.theme.mode, "modern-dark", "unavailable images use dark glass")
    appearance(solid, 255, 255)
    for _, state in ipairs({ "warning", "critical", "active", "normal" }) do
        local presentation = context.themeBuilder.state(context.theme, state)
        context.primitives.stylePanel(context.panels[1].instance.panel, presentation)
        appearance(context, 0, 204)
        assertEqual(
            context.panels[1].instance.panel.background.properties.color,
            presentation.surface or context.theme.color.surface,
            state .. " must retain its surface tint"
        )
    end
    definition.update(context, selected)
    assertEqual(context.optionsRequest, nil, "unchanged appearance must not reload")
    fixture.lvglMock.setFullScreen(true)
    pump(context, 60)
    appearance(context, 0, 204)
    fixture.lvglMock.setFullScreen(false)
    context.zone.w, context.zone.h = 320, 240
    pump(context, 60)
    appearance(context, 0, 204)
    assertEqual(context.canvas.properties.w, 320, "transparent canvas must reflow")

    local oldPage = context.page
    definition.update(context, { Layout = "Default", Theme = 2 })
    pump(context, 100)
    assert(context.page ~= oldPage, "theme reload must replace the page")
    appearance(context, 255, 255)
    assertEqual(context.theme.mode, "modern-light")
    definition.update(context, selected)
    assert(context.optionsRequest, "Glass selection must be scheduled")
    assertEqual(context.canvas.properties.opacity, 255, "update must not draw outside the scheduler")
    pump(context, 100)
    appearance(context, 0, 204)
    definition.update(context, { Layout = "Default", Theme = 1 })
    pump(context, 100)
    appearance(context, 255, 255)
    definition.update(context, { Layout = "Default", Theme = 1, Backdrop = 2, PanelFill = 1 })
    assertEqual(context.optionsRequest, nil, "obsolete background settings must not reload the dashboard")
    definition.update(context, { Layout = "Default", Theme = 0 })
    pump(context, 100)
    appearance(context, 255, 255)
    definition.update(context, { Layout = "Default", Theme = -1 })
    assertEqual(context.optionsRequest, nil, "equivalent missing-value sentinels must not keep reloading")
    fixture.lvglMock.setAppMode(false)
    assertEqual(definition.translate("Theme"), "Theme")

    local analyzer = fixture.module("lib/glass.lua")
    local brightness, revision, decodes = 255, 1, 0
    local radio = "selectedTheme: EdgeTX Default\n"
    local env = {
        width = 480,
        height = 272,
        stat = function(path)
            if path == "/RADIO/radio.yml" then
                return { size = #radio }
            elseif path == "/THEMES/EdgeTX/background.png" then
                return { size = 256, time = { year = 2026, mon = 11, day = 17, hour = 20, min = 0, sec = revision } }
            end
        end,
        dir = function()
            error("the default theme does not require directory scanning")
        end,
        io = {
            open = function()
                return {}
            end,
            read = function()
                return radio
            end,
            close = function() end,
        },
        bitmap = {
            open = function()
                decodes = decodes + 1
                return {}
            end,
            getSize = function()
                return 16, 16
            end,
            resize = function(image)
                return image
            end,
            toMask = function()
                return string.char(16, 0, 16, 0) .. string.rep(string.char(255 - brightness), 256)
            end,
        },
    }
    local automatic = definition.create(fixture.lvglMock.appZone(), selected, widgetPath)
    automatic.glassModule = {
        new = function(builder, yaml, cache, persistent)
            return analyzer.new(builder, yaml, cache, persistent, env)
        end,
    }
    local cacheModule = fixture.module("lib/background_cache.lua")
    local disk, operations = assert(loadfile(root .. "/tests/support/memory_files.lua"))()()
    local cachePath = widgetPath .. "AEROGRID/cache/backgrounds.yml"
    automatic.backgroundCacheModule = {
        new = function(yaml, writer, filename)
            assertEqual(filename, cachePath, "background cache must live outside the installed widget")
            return cacheModule.new(yaml, writer, filename, operations)
        end,
    }
    pump(automatic, 100)
    local function autoAppearance(mode)
        assertEqual(automatic.theme.mode, mode)
        appearance(automatic, 0, automatic.themeBuilder.glassOpacity(automatic.theme, brightness * 65793))
        assertEqual(
            automatic.panels[1].instance.panel.background.properties.color,
            automatic.theme.color.surface,
            "panels must be constructed with the automatically selected palette"
        )
        definition.update(automatic, selected)
        assertEqual(automatic.optionsRequest, nil, "resolved Glass palettes must not change the selected option")
    end
    autoAppearance("modern-light")
    assertEqual(decodes, 1)
    definition.update(automatic, { Layout = "Default", Theme = 2 })
    pump(automatic, 100)
    appearance(automatic, 255, 255)
    definition.update(automatic, selected)
    pump(automatic, 100)
    autoAppearance("modern-light")
    assertEqual(decodes, 1, "switching away and back to Glass must reuse the sampled image")
    brightness, revision = 0, 2
    definition.update(automatic, { Layout = "Default", Theme = 1 })
    pump(automatic, 100)
    definition.update(automatic, selected)
    pump(automatic, 100)
    autoAppearance("modern-dark")
    assertEqual(decodes, 2, "a changed image must refresh both palette and opacity")
    assert(disk[cachePath], "Glass loading must save the sample to the shared cache")
    local nextInstance = definition.create(fixture.lvglMock.appZone(), selected, widgetPath)
    nextInstance.glassModule = automatic.glassModule
    nextInstance.backgroundCacheModule = automatic.backgroundCacheModule
    pump(nextInstance, 100)
    appearance(nextInstance, 0, automatic.panelOpacity)
    assertEqual(nextInstance.theme.mode, "modern-dark")
    assertEqual(decodes, 2, "new widget instances must load the sample without reopening the image")
end

testLayoutSelectsLightTheme()
testCustomTheme()
testChangingToNewTheme()
testUserThemeOverridesShippedTheme()
testThemeAppearance()
