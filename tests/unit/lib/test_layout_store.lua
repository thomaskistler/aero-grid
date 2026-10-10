-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local layoutStore = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/layout_store.lua"))()
local registry = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/layout_registry.lua"))()
local nameRegistry = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/name_registry.lua"))()
local themeRegistry = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/theme_registry.lua"))()

--- User layouts live beside WIDGETS/, so a widget update leaves them alone.
local function testUserLayoutPath()
    assertions.assertEqual(layoutStore.sdRoot("/WIDGETS/AeroGrid/"), "/")
    assertions.assertEqual(layoutStore.sdRoot("/WIDGETS/AeroGrid"), "/")
    assertions.assertEqual(layoutStore.path("/WIDGETS/AeroGrid", "Sonic1"), "/AEROGRID/layouts/Sonic1.yaml")
    -- A package outside WIDGETS/ (a test copy) keeps everything inside itself.
    assertions.assertEqual(layoutStore.userDirectory("/tmp/pkg/"), "/tmp/pkg/AEROGRID/layouts/")

    -- A registry name is a filename stem already, so it maps to itself, and
    -- anything unsafe cannot leave the user folder.
    local path = layoutStore.path("/WIDGETS/AeroGrid", "../escape")
    local segment = string.match(path, "^/AEROGRID/layouts/([^/]+)%.yaml$")
    assert(segment and not string.find(segment, "%.%."), path)
end

local function testValidName()
    assert(layoutStore.validName("Sonic_1"))
    assert(layoutStore.validName("fpv-7in"))
    for _, name in ipairs({
        "",
        "a b",
        "x.yaml",
        "../up",
        string.rep("a", layoutStore.NAME_LIMIT + 1),
        "Empty",
        "empty",
    }) do
        local ok, message = layoutStore.validName(name)
        assert(not ok, name .. " was accepted")
        assert(type(message) == "string" and message ~= "", "no reason given for " .. name)
    end
    assert(layoutStore.validName(string.rep("a", layoutStore.NAME_LIMIT)))
end

--- Recovery order: the saved layout, its backup, the shipped one, then default.
local function testCandidates()
    local origins = {}
    for _, candidate in ipairs(layoutStore.candidates("/WIDGETS/AeroGrid/", "sim")) do
        origins[#origins + 1] = candidate.origin .. "=" .. candidate.filename
    end
    assertions.assertEqual(
        table.concat(origins, ","),
        "user=/AEROGRID/layouts/sim.yaml,user-backup=/AEROGRID/layouts/sim.yaml.bak,"
            .. "shipped=/WIDGETS/AeroGrid/layouts/sim.yaml,default=/WIDGETS/AeroGrid/layouts/Default.yaml,"
            .. "default-backup=/WIDGETS/AeroGrid/layouts/Default.yaml.bak"
    )

    -- Empty is never written, so nothing saved can shadow it.
    local empty = layoutStore.candidates("/WIDGETS/AeroGrid/", "Empty")
    assertions.assertEqual(empty[1].origin, "shipped")
    assertions.assertEqual(empty[1].filename, "/WIDGETS/AeroGrid/layouts/Empty.yaml")
end

--- Save As offers the model name with the first number no layout uses.
local function testSuggestName()
    local taken = {
        ["/AEROGRID/layouts/My-Model1.yaml"] = true,
        ["/WIDGETS/AeroGrid/layouts/My-Model2.yaml"] = true,
    }
    _G.fstat = function(filename)
        return taken[filename] and { size = 1 } or nil
    end
    assertions.assertEqual(layoutStore.suggestName("/WIDGETS/AeroGrid/", "My Model"), "My-Model3")
    assertions.assertEqual(layoutStore.suggestName("/WIDGETS/AeroGrid/", "  "), "Layout1")
    local long = layoutStore.suggestName("/WIDGETS/AeroGrid/", string.rep("x", 40))
    assert(#long <= layoutStore.NAME_LIMIT and layoutStore.validName(long), long)
    assert(layoutStore.exists("/WIDGETS/AeroGrid/", "My-Model2"), "a shipped name was not reported as taken")
    _G.fstat = nil
end

--- A fake card: `files` maps paths to content, `folders` lists dir() results.
local function fakeCard(files, folders)
    local ops = { nameRegistry = nameRegistry }
    ops.stat = function(filename)
        if files[filename] then
            return { size = #files[filename] }
        end
        return folders[filename] and {} or nil
    end
    ops.dir = function(folder)
        local entries = folders[folder]
        if not entries then
            error("no such folder " .. folder)
        end
        local index = 0
        return function()
            index = index + 1
            return entries[index]
        end
    end
    ops.open = function(filename, mode)
        return { filename = filename, mode = mode, buffer = {} }
    end
    ops.read = function(handle)
        return files[handle.filename]
    end
    ops.write = function(handle, text)
        handle.buffer[#handle.buffer + 1] = text
    end
    ops.close = function(handle)
        if handle.mode == "w" then
            files[handle.filename] = table.concat(handle.buffer)
        end
    end
    ops.mkdir = function(folder)
        folders[folder] = folders[folder] or {}
    end
    return ops
end

--- CHOICE stores a position, so names are only ever appended.
local function testRegistryIsAppendOnly()
    local files = {}
    local folders = {
        ["/WIDGETS/AeroGrid/layouts"] = { "Empty.yaml", "Default.yaml", "sim.yaml", "notes.txt", "x.yaml.bak" },
    }
    local ops = fakeCard(files, folders)

    local names = registry.load("/", "/WIDGETS/AeroGrid/", ops)
    assertions.assertEqual(table.concat(names, ","), "Empty,Default,sim")
    assertions.assertEqual(files["/AEROGRID/registry.txt"], "Empty\nDefault\nsim\n")

    -- A user layout saved later, and a shipped one whose listing order changed,
    -- keep every earlier position.
    folders["/WIDGETS/AeroGrid/layouts"] = { "zeta.yaml", "sim.yaml", "Default.yaml", "Empty.yaml" }
    folders["/AEROGRID/layouts"] = { "Sonic1.yaml", "SIM.yaml" }
    names = registry.load("/", "/WIDGETS/AeroGrid/", ops)
    assertions.assertEqual(table.concat(names, ","), "Empty,Default,sim,zeta,Sonic1")

    -- A deleted file keeps its slot, so no widget silently changes layout.
    folders["/WIDGETS/AeroGrid/layouts"] = { "Empty.yaml", "Default.yaml" }
    folders["/AEROGRID/layouts"] = {}
    names = registry.load("/", "/WIDGETS/AeroGrid/", ops)
    assertions.assertEqual(table.concat(names, ","), "Empty,Default,sim,zeta,Sonic1")
end

local function testRegistryWithoutFileApi()
    local names = registry.load("/", "/WIDGETS/AeroGrid/", { nameRegistry = nameRegistry })
    assertions.assertEqual(table.concat(names, ","), "Empty")
end

local function testBuiltinNamesKeepPositions()
    local files = { ["/AEROGRID/registry.txt"] = "Empty\nSonic1\ndefault\nhost\n" }
    local folders = {
        ["/WIDGETS/AeroGrid/layouts"] = { "Empty.yaml", "Default.yaml", "Host.yaml" },
        ["/AEROGRID/layouts"] = {},
    }
    local names = registry.load("/", "/WIDGETS/AeroGrid/", fakeCard(files, folders))
    assertions.assertEqual(table.concat(names, ","), "Empty,Sonic1,Default,Host")
    assertions.assertEqual(files["/AEROGRID/registry.txt"], "Empty\nSonic1\nDefault\nHost\n")
end

local function testThemeRegistryKeepsPositionsAndAddsNames()
    local files = {}
    local folders = {
        ["/WIDGETS/AeroGrid/themes"] = { "modern-light.yml", "modern-dark.yml" },
        ["/AEROGRID/themes"] = { "modern-dark.yml", "custom-night.yml", "ignored.yaml" },
    }
    local ops = fakeCard(files, folders)
    local names = themeRegistry.load("/WIDGETS/AeroGrid/", ops)
    assertions.assertEqual(table.concat(names, ","), "modern-dark,modern-light,custom-night")
    assertions.assertEqual(
        files["/AEROGRID/theme-registry.txt"],
        "modern-dark\nmodern-light\ncustom-night\n"
    )
    local userPath, shippedPath = themeRegistry.paths("/WIDGETS/AeroGrid/", "modern-dark")
    assertions.assertEqual(userPath, "/AEROGRID/themes/modern-dark.yml")
    assertions.assertEqual(shippedPath, "/WIDGETS/AeroGrid/themes/modern-dark.yml")

    folders["/WIDGETS/AeroGrid/themes"] = { "modern-dark.yml", "modern-light.yml", "sunrise.yml" }
    names = themeRegistry.load("/WIDGETS/AeroGrid/", ops)
    assertions.assertEqual(table.concat(names, ","), "modern-dark,modern-light,custom-night,sunrise")
end

local function run()
    testUserLayoutPath()
    testValidName()
    testCandidates()
    testSuggestName()
    testRegistryIsAppendOnly()
    testRegistryWithoutFileApi()
    testBuiltinNamesKeepPositions()
    testThemeRegistryKeepsPositionsAndAddsNames()
end

run()
