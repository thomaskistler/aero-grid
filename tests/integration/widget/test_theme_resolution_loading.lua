-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local yaml = fixture.module("lib/yaml.lua")
local function create(mode)
    return definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "review-metric", Theme = mode },
        root .. "/build/test-widget-fixture/"
    )
end
local function reach(context, predicate)
    assert(fixture.pumpUntil(context, predicate, 400, 10), "theme loading did not reach its continuation")
end

for _, mode in ipairs({ "modern-dark", "modern-light", "unknown", "" }) do
    fixture.reset()
    local context = create(mode)
    reach(context, function(value)
        return value.stage == "theme-resolve-begin"
    end)
    local previous = context.theme
    local expected = context.themeBuilder.build(context.themeMode)
    local serialized = assert(yaml.serialize(expected))
    for _ = 1, 400 do
        if context.stage == "services" then
            break
        end
        assert(context.theme == previous, "private resolver work must not publish a partial theme")
        context.dashboardLoader.advanceLoad(context)
    end
    assert(context.stage == "services" and context.themeSource == "option")
    assert(yaml.serialize(context.theme) == serialized, "loader resolution must preserve complete synchronous output")
    assert(not context.themeBuildWork and not context.themePublication)
    for index, notice in ipairs(expected.notices) do
        assert(context.notices[index].severity == notice.severity)
        assert(context.notices[index].text == "theme: " .. notice.text)
    end
    for index, warning in ipairs(expected.warnings) do
        assert(context.errors[index] == "theme: " .. warning)
    end
end

for _, phase in ipairs({ "legibility", "chart", "alert", "display", "finalize", "warnings", "notices", "commit" }) do
    fixture.reset()
    local context = create("modern-dark")
    if phase == "legibility" then
        reach(context, function(value)
            return value.stage == "theme-resolve-begin"
        end)
        local catalog = assert(loadfile(root .. "/tests/support/theme_resolution_fixture.lua"))()()
        catalog.themes[1].correctForContrast = true
        assert(context.themeBuilder.setCatalog(catalog))
    end
    reach(context, function(value)
        return value.themeBuildWork and value.themeBuildWork.stage == phase
            or value.themePublication and value.themePublication.phase == phase
    end)
    local cancelled = context.themeBuildWork or context.themePublication
    local previous = context.theme
    context.themeMode = "modern-light"
    context.dashboardLoader.beginLoad(context)
    assert(
        not context.themeBuildWork and not context.themePublication,
        "replacement loading must discard resolution and publication continuations"
    )
    assert(context.theme == previous, "cancellation cannot publish unfinished colors")
    reach(context, function(value)
        return value.stage == "services"
    end)
    assert(context.theme.mode == "modern-light" and context.theme ~= cancelled.theme)
    assert(not context.themeBuildWork and not context.themePublication)
end

fixture.reset()
local broken = create("modern-dark")
reach(broken, function(value)
    return value.stage == "theme-publish"
end)
local previous = broken.theme
broken.themePublication.phase = "invalid"
assert(broken.dashboardLoader.advanceLoad(broken))
assert(broken.stage == "load-error" and not broken.themeBuildWork and not broken.themePublication)
assert(broken.dashboardLoader.advanceLoad(broken))
assert(not broken.dashboardLoader.advanceLoad(broken) and not broken.stage)
assert(broken.theme == previous)
assert(string.find(broken.errors[#broken.errors], "unknown theme publication phase", 1, true))

print("Theme loading: private staged resolution, complete parity and cancellation at every phase passed")
