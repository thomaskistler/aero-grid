-- SPDX-License-Identifier: GPL-2.0-only

--- Stable names and paths for built-in and user-installed themes.
local registry = { RUNTIME_API = 1 }

local function directory(path)
    return string.sub(path, -1) == "/" and path or path .. "/"
end

local function sdRoot(widgetPath)
    local base = directory(widgetPath)
    return string.match(base, "^(.*/)WIDGETS/[^/]+/$") or base
end

function registry.load(widgetPath, ops)
    local nameRegistry = ops and ops.nameRegistry
    if not nameRegistry then
        local chunk = assert(loadScript(directory(widgetPath) .. "lib/name_registry.lua"))
        nameRegistry = chunk()
    end
    local base = directory(widgetPath)
    return nameRegistry.load(
        base .. "themes",
        sdRoot(base) .. "AEROGRID/themes",
        sdRoot(base) .. "AEROGRID/theme-registry.txt",
        ".yml",
        { "modern-dark", "modern-light" },
        ops
    )
end

function registry.paths(widgetPath, name)
    local base = directory(widgetPath)
    local root = sdRoot(base)
    local filename = name .. ".yml"
    return root .. "AEROGRID/themes/" .. filename, base .. "themes/" .. filename
end

return registry
