-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local layoutStore = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/layout_store.lua"))()

local function testLayoutPath()
    local path = layoutStore.path("/WIDGETS/AeroGrid", "My Model.yml", "nav 1")
    assert(string.match(path, "^/WIDGETS/AeroGrid/layouts/My%-Model%-%x%x%x%x%-%-nav%-1%-%x%x%x%x%.yaml$"), path)
    assertions.assertEqual(
        layoutStore.path("/WIDGETS/AeroGrid", "model.yml", "main"),
        "/WIDGETS/AeroGrid/layouts/model--main.yaml"
    )
end

local function testModelFilenameResolution()
    local names = {
        "model1.yml",
        "MODEL01.yml",
        "Kavan Sonic.yml",
        "FPV-7in.yml",
        "Heli_450.yml",
        "..%2fescape.yml",
        "model1.yml.bak",
        "",
    }
    local seen = {}

    for _, name in ipairs(names) do
        local path = layoutStore.path("/WIDGETS/AeroGrid", name, "main")
        local segment = string.match(path, "^/WIDGETS/AeroGrid/layouts/([^/]+)%.yaml$")
        assert(segment, "unsafe layout path for " .. name .. ": " .. path)
        assert(not string.find(segment, "%.%."), "traversal survived for " .. name)
        assert(not seen[path], "filename collision for " .. name .. ": " .. path)
        seen[path] = true
    end

    assertions.assertEqual(
        layoutStore.path("/WIDGETS/AeroGrid", "model1.yml", "main")
            ~= layoutStore.path("/WIDGETS/AeroGrid", "model1.yml", "nav"),
        true
    )
end

local function run()
    testLayoutPath()
    testModelFilenameResolution()
end

run()
