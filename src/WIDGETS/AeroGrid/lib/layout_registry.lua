-- SPDX-License-Identifier: GPL-2.0-only

--- Append-only list of layout names behind the native Layout setting.
---
--- EdgeTX stores a CHOICE option as a position in its value list, so a name
--- must keep its position for as long as any widget may have selected it.
--- Names found in the shipped and user layout folders are appended to
--- `/AEROGRID/registry.txt` and never removed or reordered. The list is built
--- when EdgeTX loads the script, so a layout saved later appears after a
--- restart.

local registry = { RUNTIME_API = 1, EMPTY = "Empty" }

--- Read `filename` whole, or nil when it does not exist.
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

--- Append the layout names in `folder` that the list does not have yet.
local function scan(ops, folder, names, seen)
    local ok, iterator = pcall(ops.dir, folder)
    if not ok or type(iterator) ~= "function" then
        return false
    end
    local added = false
    for filename in iterator do
        local name = string.match(filename, "^([%w_-]+)%.yaml$")
        if name and not seen[string.lower(name)] then
            seen[string.lower(name)] = true
            names[#names + 1] = name
            added = true
        end
    end
    return added
end

--- Return the layout names in their stable order, Empty first.
---@param sdRoot string SD-card root holding `WIDGETS/` and `AEROGRID/`.
---@param widgetPath string Widget directory holding the shipped `layouts/`.
---@param ops? table File operations; defaults to the EdgeTX globals.
---@return string[]
function registry.load(sdRoot, widgetPath, ops)
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
    local names = { registry.EMPTY }
    if type(ops.dir) ~= "function" or type(ops.stat) ~= "function" then
        return names
    end
    local seen = { [string.lower(registry.EMPTY)] = true }
    local filename = sdRoot .. "AEROGRID/registry.txt"
    local changed = false
    local stored = readText(ops, filename)
    if stored then
        for name in string.gmatch(stored, "[^\r\n]+") do
            if not seen[string.lower(name)] then
                seen[string.lower(name)] = true
                names[#names + 1] = name
            end
        end
    else
        changed = true
    end
    changed = scan(ops, widgetPath .. "layouts", names, seen) or changed
    changed = scan(ops, sdRoot .. "AEROGRID/layouts", names, seen) or changed
    if changed and type(ops.write) == "function" then
        if type(ops.mkdir) == "function" and not ops.stat(sdRoot .. "AEROGRID") then
            ops.mkdir(sdRoot .. "AEROGRID")
        end
        local handle = ops.open(filename, "w")
        if handle then
            ops.write(handle, table.concat(names, "\n") .. "\n")
            ops.close(handle)
        end
    end
    return names
end

return registry
