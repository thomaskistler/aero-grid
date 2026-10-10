-- SPDX-License-Identifier: GPL-2.0-only

--- Append-only list of layout names behind the native Layout setting.
local registry = { RUNTIME_API = 1, EMPTY = "Empty" }
local BUILTIN_NAMES = { empty = "Empty", default = "Default", diagnostics = "Diagnostics", palette = "Palette" }

--- Return layout names in their stable order, with Empty first.
---@param sdRoot string SD-card root holding `WIDGETS/` and `AEROGRID/`.
---@param widgetPath string Widget directory holding the shipped `layouts/`.
---@param ops? table File operations; defaults to EdgeTX globals.
---@return string[]
function registry.load(sdRoot, widgetPath, ops)
    local nameRegistry = ops and ops.nameRegistry
    if not nameRegistry then
        local chunk = assert(loadScript(widgetPath .. "lib/name_registry.lua"))
        nameRegistry = chunk()
    end
    return nameRegistry.load(
        widgetPath .. "layouts",
        sdRoot .. "AEROGRID/layouts",
        sdRoot .. "AEROGRID/registry.txt",
        ".yaml",
        { registry.EMPTY },
        ops,
        function(name)
            return BUILTIN_NAMES[string.lower(name)] or name
        end
    )
end

return registry
