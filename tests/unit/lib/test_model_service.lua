-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local modelService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/model_service.lua"))()

local function testFormatTime()
    assertions.assertEqual(modelService.formatTime(3661), "1:01:01")
    assertions.assertEqual(modelService.formatTime(-45), "-0:45")
end

local function testIdentityViewExists()
    local env = services.environment({
        getInfo = function()
            return { name = "My Model", filename = "my-model.yml", labels = "Demo", bitmap = "demo.png" }
        end,
    })
    local service = modelService.new(env, services)
    local identity = service:identity()
    assertions.assertEqual(type(identity), "table")
    assertions.assertEqual(identity.name, "")
end

local function run()
    testFormatTime()
    testIdentityViewExists()
end

run()
