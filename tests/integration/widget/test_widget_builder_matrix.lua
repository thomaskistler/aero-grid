-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local fixtures = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testSharedBuilderContract()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "firmware", "builder fixture should provide radio constants")
    assertions.assertTableHasKey(fixture, "radio", "builder fixture should provide radio state")
    assertions.assertContains(
        fixtures.multiPanel,
        "type: metric",
        "shared multi-panel layout should exercise the metric builder"
    )
    assertions.assertContains(
        fixtures.multiPanel,
        "type: flight-mode",
        "shared multi-panel layout should exercise the flight-mode builder"
    )
end

local function testRepresentativeLayoutLoads()
    local fixture = WidgetFixture.new()
    assertions.assertEqual(type(fixture.createLoaded), "function", "widget fixture should expose createLoaded")
    assertions.assertEqual(type(fixture.pump), "function", "widget fixture should expose pump")
    assertions.assertEqual(type(fixture.entryById), "function", "widget fixture should expose entry lookup")
end

local function testRepresentativeDashboardBuilds()
    local fixture = WidgetFixture.new()
    local context = fixture.createLoaded()

    assertions.assertEqual(context.stage, nil, "staged loading should finish")
    assert(#context.components > 0, "builder did not create any dashboard components")
    assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

    for _, entry in ipairs(context.components) do
        assert(entry.container, "component is missing its host container")
        assert(entry.instance, "component is missing its instance")
        local bounds = entry.container.properties
        assert(bounds.w > 0 and bounds.h > 0, "builder created an empty panel")
    end
    fixture.assertNoOverlap(context)
end

local function testThemeFallbackAndReflow()
    local fixture = WidgetFixture.new()
    local context = fixture.createLoaded(nil, { DashID = "main", Theme = "not-a-theme" })
    assertions.assertEqual(context.theme.mode, "modern")

    local zone = context.zone
    zone.w = 320
    zone.h = 240
    assert(
        fixture.pumpUntil(context, function(value)
            return not value.reflowIndex
        end, 100),
        "builder reflow did not settle"
    )

    fixture.assertNoOverlap(context)
    zone.w = 480
    zone.h = 272
    assert(
        fixture.pumpUntil(context, function(value)
            return not value.reflowIndex
        end, 100),
        "builder second reflow did not settle"
    )
    fixture.assertNoOverlap(context)
end

local function testMissingWidgetPathFailsExplicitly()
    local fixture = WidgetFixture.new()
    local context = fixture.createLoaded(nil, { DashID = "main", Theme = "modern" }, "/path/does/not/exist/")
    assert(#context.errors > 0, "missing widget modules should be reported as errors")
    assertions.assertEqual(#context.components, 0)
end

local function run()
    testSharedBuilderContract()
    testRepresentativeLayoutLoads()
    testRepresentativeDashboardBuilds()
    testThemeFallbackAndReflow()
    testMissingWidgetPathFailsExplicitly()
end

run()
