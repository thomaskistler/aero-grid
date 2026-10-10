-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local Fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local fixture = Fixture.new()
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local equal = assertions.assertEqual
local yaml = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/yaml.lua"))()
local themeCatalog = assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, yaml)

for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    fixture.reset()
    local host = fixture.createLoaded(nil, { Layout = "Palette", Theme = mode })
    equal(#host.errors, 0, table.concat(host.errors, "\n"))
    equal(#host.panels, 1)
    local instance = assert(fixture.instanceOf(host, "showcase"))
    equal(#instance.swatches, 14)
    equal(#instance.cards, 6)
    equal(#instance.bars, 4)
    equal(instance.theme, host.theme, "showcase must use the live host palette")
    for index, token in ipairs({
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
    }) do
        equal(instance.swatches[index].box.properties.color, host.theme.color[token])
        equal(instance.swatches[index].label.properties.text, token)
    end
    for _, card in ipairs(instance.cards) do
        local expected = instance.builder.state(host.theme, card.state)
        equal(card.panel.background.properties.color, expected.surface or host.theme.color.surface)
        equal(card.panel.accent.properties.color, expected.accent)
        equal(card.value.properties.color, expected.value)
        equal(card.badge.properties.text, expected.badge or "")
        equal(card.panel.border.hidden, expected.borderWidth == 0)
        equal(card.panel.border.hidden, true, "showcase must not display unused focus outlines")
    end
    equal(instance.cards[6].value.properties.text, "--")
    local module = host.panels[1].module
    for _, size in ipairs({ { 480, 272 }, { 480, 227 }, { 800, 480 } }) do
        module.update(instance, { x = 0, y = 0, w = size[1], h = size[2] })
        for _, card in ipairs(instance.cards) do
            local box = card.panel.root.properties
            assert(box.x >= 0 and box.y >= 0)
            assert(box.x + box.w <= size[1] and box.y + box.h <= size[2], "card outside showcase")
            assert(card.bar.fill.properties.w <= card.bar.width)
            local value = card.value.properties
            local badge = card.badge.properties
            assert(value.y + instance.builder.fontHeight(value.font()) <= badge.y + 2, "reading overlaps badge")
        end
        for _, swatch in ipairs(instance.swatches) do
            assert(instance.builder.fontHeight(TINSIZE) <= swatch.box.properties.h + 4, "swatch rows overlap")
        end
    end
    fixture.pump(host, 20)
    equal(#host.errors, 0)
    assert(not module.refresh and not module.background, "fixed samples must not poll telemetry")
end
fixture.reset()
local dashboard = fixture.createLoaded(nil, { Layout = "Default", Theme = 2 })
equal(dashboard.theme.mode, "modern-light", "native choice 2 must select Modern Light")
equal(#dashboard.errors, 0, table.concat(dashboard.errors, "\n"))
for _, entry in ipairs(dashboard.panels) do
    equal(entry.instance.theme, dashboard.theme, "every instrument must receive the light theme")
end
fixture.pump(dashboard, 20)
equal(#dashboard.errors, 0, table.concat(dashboard.errors, "\n"))
fixture.reset()
local host = fixture.createLoaded(nil, { Layout = "Palette", Theme = "modern-dark" })
local builder = host.themeBuilder
local customCatalog = assert(yaml.parse(assert(yaml.serialize(themeCatalog))))
local customDefinition = assert(yaml.parse(assert(yaml.serialize(customCatalog.themes[1]))))
customDefinition.name = "showcase-custom"
customDefinition.label = "Showcase Custom"
customDefinition.correctForContrast = true
customDefinition.accent = "green"
customDefinition.colors.canvas = 0x101820
customDefinition.colors.surface = 0x304050
customDefinition.colors.text = 0xFFF4DF
customCatalog.themes[#customCatalog.themes + 1] = customDefinition
assert(builder.setCatalog(customCatalog))
local custom = builder.build("showcase-custom")
local module = host.panels[1].module
local instance = module.create(lvgl.box({ x = 0, y = 0, w = 480, h = 272 }), {
    x = 0,
    y = 0,
    w = 480,
    h = 272,
}, {}, {
    theme = custom,
    themeBuilder = builder,
    primitives = host.primitives,
    state = function(state, accent)
        return builder.state(custom, state, accent)
    end,
})
equal(instance.theme, custom)
equal(instance.palette.accent.properties.color, custom.color.green)
equal(instance.swatches[1].box.properties.color, custom.color.canvas)
equal(instance.swatches[6].box.properties.color, custom.color.text)
equal(instance.cards[1].panel.accent.properties.color, custom.color.green)
fixture.reset()
