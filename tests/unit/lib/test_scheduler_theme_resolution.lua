-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local load = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local theme = load("lib/theme.lua")
local fixture = assert(loadfile(root .. "/tests/support/theme_resolution_fixture.lua"))()
local reference = assert(loadfile(root .. "/tests/support/theme_resolution_reference.lua"))()
local catalog, requests, copy = fixture()
local yaml = load("lib/yaml.lua")
local shipped = assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, yaml)

local function equal(expected, actual, path)
    path = path or "theme"
    assert(type(expected) == type(actual), path .. ": different types")
    if type(expected) ~= "table" then
        assert(expected == actual, path .. ": " .. tostring(expected) .. " ~= " .. tostring(actual))
        return
    end
    for key, value in pairs(expected) do
        equal(value, actual[key], path .. "." .. tostring(key))
    end
    for key in pairs(actual) do
        assert(expected[key] ~= nil, path .. ": unexpected " .. tostring(key))
    end
end

equal(shipped.themes[1], catalog.themes[1], "dark fixture")
equal(shipped.themes[2], catalog.themes[2], "light fixture")
local unconfigured = load("lib/theme.lua")
assert(not pcall(unconfigured.beginBuild))
assert(not pcall(unconfigured.build))
local stages, corrections, criticalSearch, tintFallback = {}, {}, false, false
for _, convert in ipairs({
    function(value)
        return value
    end,
    function(value)
        return value ~ 0x1234
    end,
}) do
    lcd = { RGB = convert }
    assert(theme.setCatalog(catalog))
    local old = reference(assert(theme.validateCatalog(catalog)))
    for _, request in ipairs(requests) do
        local expected = old.build(request.mode)
        equal(expected, theme.build(request.mode), "legacy/synchronous")
        local work = theme.beginBuild(request.mode)
        local resolved, advances = nil, 0
        repeat
            stages[work.stage] = true
            if work.criticalIndex and work.criticalIndex > 1 then
                criticalSearch = true
            end
            assert(not work.result, "no partial theme is published")
            resolved = theme.advanceBuild(work)
            advances = advances + 1
            assert(advances < 300, "resolution must terminate")
        until resolved
        equal(expected, resolved, "legacy/asynchronous")
        assert(theme.advanceBuild(work) == resolved, "completed work is idempotent")
        for _, notice in ipairs(resolved.notices) do
            corrections[notice.text] = true
        end
        tintFallback = tintFallback or not resolved.alertRgb.warning
        for state, accent in pairs({ warning = "amber", critical = "critical", active = "blue" }) do
            equal(
                old.alertSurface(resolved.rgb, resolved.rgb[accent], nil, state ~= "active"),
                theme.alertSurface(resolved.rgb, resolved.rgb[accent], nil, state ~= "active"),
                "public tint search"
            )
        end
    end
end
for _, stage in ipairs({ "legibility", "chart", "alert", "display", "finalize" }) do
    assert(stages[stage], "missing stage " .. stage)
end
assert(criticalSearch, "exercise multiple critical surface candidates")
assert(tintFallback, "exercise exhausted tint searches")
assert(corrections["surface was shifted to keep critical visible"])
assert(corrections["canvas was moved to keep panels elevated"])
assert(corrections["chartCyan was corrected for contrast"])
assert(corrections["chartCyan was replaced for contrast"])

-- Pause at every boundary, change the catalog, interleave another widget, then
-- discard the paused resolution. Neither pending work nor finished output may leak.
lcd = {
    RGB = function(value)
        return value
    end,
}
local replacement = copy(catalog)
for _, definition in ipairs(replacement.themes) do
    definition.label = "Replacement " .. definition.name
    definition.spacing.padding = 97
    definition.colors.surface = 0x102030
end
local originalReference = reference(assert(theme.validateCatalog(catalog)))
local replacementReference = reference(assert(theme.validateCatalog(replacement)))
for _, request in ipairs(requests) do
    assert(theme.setCatalog(catalog))
    local pending = theme.beginBuild(request.mode)
    local original = originalReference.build(request.mode)
    local cancelledStages = {}
    local result
    repeat
        local before = copy(pending)
        assert(theme.setCatalog(replacement))
        local other = theme.beginBuild(request.mode)
        local otherResult
        repeat
            otherResult = theme.advanceBuild(other)
        until otherResult
        equal(replacementReference.build(request.mode), otherResult, "interleaved widget")
        otherResult.spacing.padding = 123
        otherResult.rgb.surface = 0
        equal(before, pending, "pending work is private")
        if not cancelledStages[pending.stage] then
            cancelledStages[pending.stage] = true
            -- Cancellation has no publication/release operation: simply drop work.
            local abandoned = theme.beginBuild(request.mode)
            while abandoned.stage ~= pending.stage do
                assert(not theme.advanceBuild(abandoned), "reach cancellation boundary before publication")
            end
            abandoned = nil
            equal(before, pending, "cancellation leaves other work unchanged")
            equal(replacementReference.build(request.mode), theme.build(request.mode), "after cancellation")
        end
        result = theme.advanceBuild(pending)
    until result
    equal(original, result, "captured catalog")
end
assert(theme.setCatalog(catalog))
local first, second = theme.beginBuild("modern-dark"), theme.beginBuild("modern-dark")
local resolved
repeat
    resolved = theme.advanceBuild(first)
until resolved
resolved.spacing.padding = 99
resolved.rgb.surface = 0
first.definition.label = "Private definition"
assert(first.definition ~= second.definition)
local untouched
repeat
    untouched = theme.advanceBuild(second)
until untouched
equal(originalReference.build("modern-dark"), untouched, "separate same-catalog results")
equal(originalReference.build("modern-dark"), theme.build("modern-dark"), "catalog remains unchanged")

print("bounded theme legacy parity, interleaving and cancellation passed")
