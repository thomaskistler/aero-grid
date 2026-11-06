-- SPDX-License-Identifier: GPL-2.0-only

local function equal(first, second, path)
    if type(first) == "function" and string.sub(path, -5) == ".font" then
        first, second = first(), second()
    end
    if type(first) ~= "table" then
        assert(first == second, path .. ": " .. tostring(first) .. " ~= " .. tostring(second))
        return
    end
    assert(type(second) == "table", path)
    for key, value in pairs(first) do
        equal(value, second[key], path .. "." .. tostring(key))
    end
    for key in pairs(second) do
        assert(first[key] ~= nil, path .. ": unexpected property " .. tostring(key))
    end
end

local function sameTree(first, second, path)
    path = path or "root"
    assert(first.kind == second.kind and first.hidden == second.hidden, path .. ": kind/visibility")
    if first.hidden then
        return -- Hidden pools are positioned lazily when revealed.
    end
    equal(first.properties, second.properties, path)
    assert(#first.children == #second.children, path .. ": children")
    for index, child in ipairs(first.children) do
        sameTree(child, second.children[index], path .. ".children[" .. index .. "]")
    end
end

return sameTree
