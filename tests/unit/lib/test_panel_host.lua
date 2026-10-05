-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local panelHost = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()

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
    rejects({ id = "demo", apiVersion = 1, create = function() end, supportedSpans = 5 }, "demo", "supportedSpans")
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

local function run()
    testPanelContract()
    testSupportedSpans()
end

run()
