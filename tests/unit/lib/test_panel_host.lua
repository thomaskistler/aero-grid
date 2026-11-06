-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local panelHost = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
assert(type(panelHost.isIdle) == "function" and not panelHost.isIdle(nil))

local function testPanelContract()
    local valid = { id = "demo", apiVersion = 1, create = function() end }
    assert(panelHost.validateModule(valid, "demo"))

    local function rejects(module, typeName, pattern)
        local ok, err = panelHost.validateModule(module, typeName)
        assertions.assertEqual(ok, false)
        assert(string.match(err, pattern), err)
    end

    rejects("not a table", "demo", "must return a table")
    rejects({ id = "demo", apiVersion = 2, create = function() end }, "demo", "incompatible")
    rejects({ id = "../evil", apiVersion = 1, create = function() end }, "../evil", "invalid id")
    rejects({ id = "other", apiVersion = 1, create = function() end }, "demo", "does not match type")
    rejects({ id = "demo", apiVersion = 1 }, "demo", "no create function")
    rejects({ id = "demo", apiVersion = 1, create = function() end, refresh = 5 }, "demo", "refresh must be a function")
    rejects(
        { id = "demo", apiVersion = 1, create = function() end, construct = true },
        "demo",
        "construct must be a function"
    )
    rejects({ id = "demo", apiVersion = 1, create = function() end, supportedSpans = 5 }, "demo", "supportedSpans")
    for _, cost in ipairs({ 0, 7, 1.5, "6", 0 / 0 }) do
        rejects({ id = "demo", apiVersion = 1, create = function() end, refreshCost = cost }, "demo", "refreshCost")
    end
    local idle = { id = "demo", apiVersion = 1, create = function() end, idle = true }
    assert(panelHost.validateModule(idle, "demo") and panelHost.isIdle(idle))
    assert(not pcall(panelHost.task, { module = idle, instance = {} }))
    for _, key in ipairs({ "decl", "refresh", "step", "stageOf", "background" }) do
        idle[key] = key == "decl" and {} or function() end
        rejects(idle, "demo", "idle panel cannot declare periodic work")
        assert(not panelHost.isIdle(idle))
        idle[key] = nil
    end
    idle.idle = "true"
    rejects(idle, "demo", "idle must be a boolean")
    idle.idle = false
    assert(panelHost.validateModule(idle, "demo") and not panelHost.isIdle(idle))
end

local function testSupportedSpans()
    local restricted = { supportedSpans = { "1x1", "2x2" } }
    assertions.assertEqual(panelHost.supportsSpan(restricted, 1, 1), true)
    assertions.assertEqual(panelHost.supportsSpan(restricted, 2, 2), true)
    assertions.assertEqual(panelHost.supportsSpan(restricted, 4, 1), false)
    assertions.assertEqual(panelHost.supportsSpan({ supportedSpans = { "any" } }, 4, 4), true)
    assertions.assertEqual(panelHost.supportsSpan({}, 3, 2), true)
    assertions.assertEqual(panelHost.spanName(2, 3), "2x3")
end

local function testSettingsContinuation()
    local module = {
        settings = {
            false,
            { key = "visual", type = "string", choices = { "bar", "none" }, default = "none" },
            { key = "enabled", type = "boolean", default = true },
            { key = "caption", type = "string", default = "default" },
        },
        validateSettings = function(settings, span, config, modelArmed)
            assert(span.colSpan == 2 and config.enabled == "yes" and modelArmed == "L01")
            assert(settings.enabled and settings.visual == "none")
            return { "cross-setting warning", false, 42 }
        end,
    }
    local config = { visual = "bad", enabled = "yes" }
    for index = 1, 128 do
        config["future" .. index] = index
    end
    local span = { colSpan = 2, rowSpan = 1 }
    local expected, warnings = panelHost.resolveSettings(module, config, span, "L01")
    assert(#warnings == 134 and warnings[1] == "setting 1 is malformed")
    assert(warnings[2] == "visual must be one of bar, none, not bad")
    assert(warnings[3] == "enabled must be a boolean")
    assert(warnings[132] == "cross-setting warning" and warnings[133] == "false" and warnings[134] == "42")
    local work = panelHost.beginSettings(module, config, span, "L01")
    local turns = 0
    while not panelHost.advanceSettings(work) do
        turns = turns + 1
        assert(turns < 100)
    end
    assert(turns > 32 and work.proof.validator == module.validateSettings)
    for key, value in pairs(expected) do
        assert(work.settings[key] == value)
    end
    for index, value in ipairs(warnings) do
        assert(work.warnings[index] == value)
    end
    module.validateSettings = function()
        error("validation failure")
    end
    local _, failed = panelHost.resolveSettings(module, {})
    assert(string.find(failed[#failed], "validateSettings raised:", 1, true))
    assert(string.find(failed[#failed], "validation failure", 1, true))
    module.validateSettings = function() end
    local _, empty = panelHost.resolveSettings(module, {})
    assert(#empty == 1 and empty[1] == "setting 1 is malformed")
    module.beginSettingsValidation = function()
        return false
    end
    module.advanceSettingsValidation = function() end
    local _, invalid = panelHost.resolveSettings(module, {})
    assert(invalid[#invalid] == "validateSettings raised: beginSettingsValidation must return a table")
    module.beginSettingsValidation = function()
        return {}
    end
    _, invalid = panelHost.resolveSettings(module, {})
    assert(invalid[#invalid] == "validateSettings raised: advanceSettingsValidation must return a boolean")

    local spans = {}
    for index = 1, 128 do
        spans[index] = "1x1"
    end
    spans[129] = "2x1"
    local check = panelHost.beginSpanCheck({ supportedSpans = spans }, 2, 1)
    for _ = 1, 128 do
        assert(not panelHost.advanceSpanCheck(check))
    end
    assert(panelHost.advanceSpanCheck(check) and check.supported)
    assert(panelHost.supportsSpan({ supportedSpans = spans }, 2, 1))
end

local function testPreparationCompatibility()
    local panel = { id = "demo", apiVersion = 1, create = function() end, supportedSpans = {}, settings = {} }
    for index = 1, 128 do
        panel.supportedSpans[index] = "1x1"
        panel.settings[index] = { key = "setting" .. index, type = "number", default = index }
    end
    panel.supportedSpans[129] = "2x1"
    local calls = 0
    panel.validateSettings = function(settings, span, config, modelArmed)
        calls = calls + 1
        assert(settings.setting128 == 128 and span.colSpan == 2 and config.future == 42 and modelArmed == "L01")
        return { "custom validation warning" }
    end
    local loader = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/dashboard_loader.lua"))().new({
        loadModule = function()
            return panel
        end,
        addError = function(context, message)
            context.errors[#context.errors + 1] = message
        end,
    })
    local context = {
        panelHost = panelHost,
        modelArmed = "L01",
        page = {},
        panels = {},
        errors = {},
        rejected = {},
        grid = {
            rect = function()
                return { w = 100, h = 50 }
            end,
        },
        zone = {},
    }
    local placement = { id = "subject", type = "demo", colSpan = 2, rowSpan = 1, config = { future = 42 } }
    local work = loader.beginPreparation(context, placement)
    local turns = 0
    while not loader.advancePreparation(context, work) do
        turns = turns + 1
        assert(turns < 100)
    end
    assert(turns > 32 and calls == 1 and work.prepared.settings.future == 42)
    assert(context.errors[1] == "subject: future is not a setting of this panel")
    assert(context.errors[2] == "subject: custom validation warning")
    assert(loader.workBound({ stage = "panel-prepare", panelPreparation = work }) == nil)
    local prepared, reason = loader.preparePanel(context, placement, true)
    assert(not prepared and reason == "future is not a setting of this panel; custom validation warning")
    assert(#context.errors == 2 and #context.rejected == 0 and calls == 2)
    placement.colSpan = 3
    prepared, reason = loader.preparePanel(context, placement)
    assert(not prepared and reason == "panel does not support span 3x1")
    assert(#context.rejected == 1 and calls == 2, "span rejection must precede settings validation")
end

local function run()
    testPanelContract()
    testSupportedSpans()
    testSettingsContinuation()
    testPreparationCompatibility()
    local result
    local entry = {
        module = {
            refresh = function()
                return result
            end,
        },
        instance = {},
        interval = 20,
    }
    assert(panelHost.dispatch(entry, "refresh"))
    assertions.assertEqual(entry.interval, 20)
    for _, interval in ipairs({ 1, 5, 100, 6000 }) do
        result = interval
        assert(panelHost.dispatch(entry, "refresh"))
        assertions.assertEqual(entry.interval, interval)
    end
    entry.module.refresh = function()
        return 1, true
    end
    local ok, message, interval, unfinished = panelHost.dispatch(entry, "refresh")
    assert(ok and not message and interval == 1 and unfinished == true)
    entry.module.refresh = function()
        return result
    end
    for _, interval in ipairs({ 0, -1, 1.5, 6001, math.huge, 0 / 0 }) do
        result = interval
        entry.failed = false
        local ok, message = panelHost.dispatch(entry, "refresh")
        assert(not ok and entry.failed and string.find(message, "refresh interval", 1, true))
    end
end

run()
