-- SPDX-License-Identifier: GPL-2.0-only

return function(root, yaml)
    local catalog = { version = 1, themes = {} }
    for _, name in ipairs({ "modern-dark", "modern-light" }) do
        local filename = root .. "/src/WIDGETS/AeroGrid/themes/" .. name .. ".yml"
        local file = assert(io.open(filename, "r"))
        catalog.themes[#catalog.themes + 1] = assert(yaml.parse(file:read("*a")))
        file:close()
    end
    return catalog
end
