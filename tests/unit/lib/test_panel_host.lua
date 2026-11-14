-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local panelHost = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()

local function testPanelContract()
    local valid = { id = "demo", apiVersion = 1, create = function() end }
    assert(panelHost.validateModule(valid, "demo"))
    valid.refreshCost = "variable"
    valid.refreshMinCost = 1
    assert(panelHost.validateModule(valid, "demo"))
    valid.refreshCost = 8
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
    valid.refreshCost = 0
    valid.refreshMinCost = nil
    assert(panelHost.validateModule(valid, "demo"))
    rejects(
        { id = "demo", apiVersion = 1, create = function() end, refreshCost = "variable" },
        "demo",
        "requires refreshMinCost"
    )
    for _, minimum in ipairs({ 0, 1.5, 9, "1" }) do
        rejects({
            id = "demo",
            apiVersion = 1,
            create = function() end,
            refreshCost = "variable",
            refreshMinCost = minimum,
        }, "demo", "refreshMinCost")
    end
    for _, cost in ipairs({ -1, 9, 1.5, "6", 0 / 0 }) do
        rejects({ id = "demo", apiVersion = 1, create = function() end, refreshCost = cost }, "demo", "refreshCost")
    end
end

local function testFinishAndBackgroundContract()
    local function base(extra)
        local module = { id = "demo", apiVersion = 1, create = function() end }
        for key, value in pairs(extra) do
            module[key] = value
        end
        return module
    end
    local function rejects(module, pattern)
        local ok, err = panelHost.validateModule(module, "demo")
        assertions.assertEqual(ok, false)
        assert(string.match(err, pattern), err)
    end
    local function finish() end
    local function pending()
        return false
    end
    assert(panelHost.validateModule(base({ finish = finish, finishPending = pending, finishMinCost = 2 }), "demo"))
    rejects(base({ finish = finish, finishPending = pending }), "finish requires")
    rejects(base({ finish = finish, finishMinCost = 1 }), "finish requires")
    for _, minimum in ipairs({ 0, 1.5, 9, "1" }) do
        rejects(base({ finish = finish, finishPending = pending, finishMinCost = minimum }), "finishMinCost")
        rejects(base({ background = finish, backgroundMinCost = minimum }), "backgroundMinCost")
    end
    assert(panelHost.validateModule(base({ background = finish, backgroundMinCost = 8 }), "demo"))
    assert(panelHost.validateModule(base({ refreshContinuation = true }), "demo"))
    rejects(base({ refreshContinuation = "yes" }), "refreshContinuation")
end

local function testFinishDispatch()
    local result = { 20, true, 3 }
    local entry = {
        module = {
            id = "demo",
            finish = function()
                return table.unpack(result)
            end,
        },
        instance = {},
        interval = 50,
    }
    local ok, message, interval, unfinished, consumed = panelHost.dispatch(entry, "finish", false, 4)
    assert(ok and not message and interval == 20 and unfinished == true and consumed == 3)
    assertions.assertEqual(entry.interval, 20)
    result = { 0 }
    entry.failed = false
    ok, message = panelHost.dispatch(entry, "finish", false, 4)
    assert(not ok and entry.failed and string.find(message, "interval", 1, true))

    entry.module.finishPending = function()
        return true
    end
    entry.failed = false
    local pendingOk, pendingError, pending = panelHost.dispatch(entry, "finishPending")
    assert(pendingOk and not pendingError and pending == true)
    entry.module.finishPending = function()
        error("pending check failed")
    end
    entry.failed = false
    pendingOk, pendingError = panelHost.dispatch(entry, "finishPending")
    assert(not pendingOk and entry.failed and string.find(pendingError, "pending check failed", 1, true))
    entry.module.finishPending = function()
        return "yes"
    end
    entry.failed = false
    pendingOk, pendingError = panelHost.dispatch(entry, "finishPending")
    assert(not pendingOk and entry.failed and string.find(pendingError, "must return a boolean", 1, true))
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
    testFinishAndBackgroundContract()
    testFinishDispatch()
    testSupportedSpans()
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
        return 1, true, 3
    end
    local ok, message, interval, unfinished, consumed = panelHost.dispatch(entry, "refresh")
    assert(ok and not message and interval == 1 and unfinished == true and consumed == 3)
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
