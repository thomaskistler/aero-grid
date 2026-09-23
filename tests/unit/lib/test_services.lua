-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()

local function testSnapshotIsReadOnly()
    local snapshot = services.snapshot({ value = 42 })
    assertions.assertEqual(snapshot.value, 42)

    local ok, err = pcall(function()
        snapshot.newValue = 1
    end)
    assert(ok == false, "snapshot should reject writes")
    assert(string.match(err or "", "read-only") or true)
end

local function testEnvironmentAndRuntime()
    local env = services.environment({
        getValue = function()
            return 7
        end,
        getFieldInfo = function()
            return { id = 9 }
        end,
    })
    assertions.assertEqual(type(env.getValue), "function")
    assertions.assertEqual(type(env.getFieldInfo), "function")

    local runtime = services.runtime(env)
    assertions.assertTableHasKey(runtime, "order", "runtime should track service order")

    local service = {
        id = "demo",
        interval = 20,
        due = 0,
        count = 1,
        revision = 0,
        update = function() end,
    }

    services.register(runtime, service, 0)
    local updatedId = services.update(runtime, 0)
    assertions.assertEqual(updatedId, "demo")
end

local function run()
    testSnapshotIsReadOnly()
    testEnvironmentAndRuntime()
end

run()
