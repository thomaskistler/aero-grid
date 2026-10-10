-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local source = root .. "/src/WIDGETS/AeroGrid/"
local files, folders =
    {}, {
        ["/WIDGETS/AeroGrid/themes"] = { "modern-dark.yml", "modern-light.yml", "modern-test.yml" },
        ["/AEROGRID/themes"] = {},
        ["/WIDGETS/AeroGrid/layouts"] = { "Default.yaml", "Empty.yaml", "Diagnostics.yaml", "Palette.yaml" },
        ["/AEROGRID/layouts"] = {},
    }
for _, name in ipairs({ "modern-dark", "modern-light" }) do
    local handle = assert(io.open(source .. "themes/" .. name .. ".yml", "r"))
    files["/WIDGETS/AeroGrid/themes/" .. name .. ".yml"] = handle:read("*a")
    handle:close()
end
files["/WIDGETS/AeroGrid/themes/modern-test.yml"] = string.gsub(
    string.gsub(files["/WIDGETS/AeroGrid/themes/modern-dark.yml"], "name: modern%-dark", "name: modern-test"),
    "label: Modern Dark",
    'label: "Test #3: Dark"'
)
loadScript = function(path)
    return loadfile(source .. string.gsub(path, "^/WIDGETS/AeroGrid/", ""))
end
dir = function(path)
    local names, index = assert(folders[path], "unexpected directory " .. path), 0
    return function()
        index = index + 1
        return names[index]
    end
end
fstat = function(path)
    return files[path] and { size = #files[path] } or nil
end
mkdir = function() end
io = {
    open = function(path, mode)
        return (mode == "w" or files[path]) and { path = path } or nil
    end,
    read = function(handle)
        return files[handle.path]
    end,
    write = function(handle, content)
        files[handle.path] = content
    end,
    close = function() end,
}

local chunk = assert(loadfile(source .. "main.lua"))
local instructions = 0
debug.sethook(function()
    instructions = instructions + 200
end, "", 200)
local ok, definition = pcall(chunk)
debug.sethook()
assert(ok, definition)
assert(
    instructions < fixture.firmware.INSTRUCTION_BUDGET,
    "widget registration exceeds the firmware instruction budget: " .. instructions
)
assert(definition.name == "AeroGrid")
local themeOptions = definition.options[2][4]
assert(#themeOptions == 3, "registration discovers additional themes")
assert(themeOptions[3] == "Test #3: Dark", "picker labels retain YAML quoting and embedded punctuation")
