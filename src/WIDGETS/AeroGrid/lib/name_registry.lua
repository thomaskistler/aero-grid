-- SPDX-License-Identifier: GPL-2.0-only

--- Append-only names for EdgeTX CHOICE options.
local registry = {}

local function readText(ops, filename)
    local info = ops.stat(filename)
    local size = type(info) == "table" and info.size or nil
    if not size or size == 0 then
        return nil
    end
    local handle = ops.open(filename, "r")
    if not handle then
        return nil
    end
    local content = ops.read(handle, size)
    ops.close(handle)
    return content
end

local function scan(ops, folder, pattern, names, seen)
    local ok, iterator = pcall(ops.dir, folder)
    if not ok or type(iterator) ~= "function" then
        return false
    end
    local added = false
    for filename in iterator do
        local name = string.match(filename, pattern)
        if name and not seen[string.lower(name)] then
            seen[string.lower(name)] = true
            names[#names + 1] = name
            added = true
        end
    end
    return added
end

--- Keep persisted CHOICE names stable while appending names discovered on disk.
---@param shippedDirectory string
---@param userDirectory string
---@param registryFile string
---@param extension string
---@param seedNames string[]
---@param ops? table
---@param canonicalize? fun(name: string): string
---@return string[]
function registry.load(shippedDirectory, userDirectory, registryFile, extension, seedNames, ops, canonicalize)
    ops = ops
        or {
            dir = dir,
            stat = fstat,
            open = io.open,
            read = io.read,
            write = io.write,
            close = io.close,
            mkdir = mkdir,
        }
    local names = {}
    local seen = {}
    local function append(name)
        if canonicalize then
            name = canonicalize(name)
        end
        local key = string.lower(name)
        if not seen[key] then
            seen[key] = true
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(seedNames or {}) do
        append(name)
    end
    if type(ops.dir) ~= "function" or type(ops.stat) ~= "function" then
        return names
    end

    local changed = false
    local stored = readText(ops, registryFile)
    if stored then
        for storedName in string.gmatch(stored, "[^\r\n]+") do
            local name = canonicalize and canonicalize(storedName) or storedName
            changed = changed or name ~= storedName
            if not seen[string.lower(name)] then
                append(name)
                changed = true
            end
        end
    else
        changed = true
    end

    local escapedExtension = string.gsub(extension, "([%.%+%-%[%]%(%)])", "%%%1")
    local pattern = "^([%w_-]+)" .. escapedExtension .. "$"
    changed = scan(ops, shippedDirectory, pattern, names, seen) or changed
    changed = scan(ops, userDirectory, pattern, names, seen) or changed
    if changed and type(ops.write) == "function" then
        local directory = string.match(registryFile, "^(.*)/[^/]+$")
        if directory and type(ops.mkdir) == "function" and not ops.stat(directory) then
            ops.mkdir(directory)
        end
        local handle = ops.open(registryFile, "w")
        if handle then
            ops.write(handle, table.concat(names, "\n") .. "\n")
            ops.close(handle)
        end
    end
    return names
end

return registry
