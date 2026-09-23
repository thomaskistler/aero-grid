-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local fixtures = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function assertNoOverlap(entries)
    for firstIndex = 1, #entries do
        local first = entries[firstIndex].container.properties
        for secondIndex = firstIndex + 1, #entries do
            local second = entries[secondIndex].container.properties
            local overlaps = first.x < second.x + second.w
                and second.x < first.x + first.w
                and first.y < second.y + second.h
                and second.y < first.y + first.h
            assert(not overlaps, "builder placed overlapping panels")
        end
    end
end

local function testSharedBuilderContract()
    local fixture = WidgetFixture.new()
    assertions.assertTableHasKey(fixture, "firmware", "builder fixture should provide radio constants")
    assertions.assertTableHasKey(fixture, "radio", "builder fixture should provide radio state")
    assertions.assertContains(fixtures.multiPanel, "type: metric", "shared multi-panel layout should exercise the metric builder")
    assertions.assertContains(fixtures.multiPanel, "type: flight-mode", "shared multi-panel layout should exercise the flight-mode builder")
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
    assertNoOverlap(context.components)
end

local function testThemeFallbackAndReflow()
    local fixture = WidgetFixture.new()
    local context = fixture.createLoaded(nil, { DashID = "main", Theme = "not-a-theme" })
    assertions.assertEqual(context.theme.mode, "modern")

    local zone = context.zone
    zone.w = 320
    zone.h = 240
    local passes = 0
    repeat
        fixture.pump(context, 1)
        passes = passes + 1
        assert(passes < 100, "builder reflow did not settle")
    until not context.reflowIndex

    assertNoOverlap(context.components)
    zone.w = 480
    zone.h = 272
    passes = 0
    repeat
        fixture.pump(context, 1)
        passes = passes + 1
        assert(passes < 100, "builder second reflow did not settle")
    until not context.reflowIndex
    assertNoOverlap(context.components)
end

local function run()
    testSharedBuilderContract()
    testRepresentativeLayoutLoads()
    testRepresentativeDashboardBuilds()
    testThemeFallbackAndReflow()
end

run()
