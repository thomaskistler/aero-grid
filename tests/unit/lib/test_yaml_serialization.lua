-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local yaml = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/yaml.lua"))()

local function same(first, second, path)
    path = path or "document"
    assert(type(first) == type(second), path .. " type differs")
    if type(first) ~= "table" then
        assert(first == second, path .. " differs")
        return
    end
    for key, value in pairs(first) do
        same(value, second[key], path .. "." .. tostring(key))
    end
    for key in pairs(second) do
        assert(first[key] ~= nil, path .. " gained " .. tostring(key))
    end
end

local function testRoundTrip()
    local source = {
        version = 1,
        grid = { columns = 4, rows = 4 },
        panels = {
            {
                id = "first",
                type = "state",
                col = 0,
                row = 0,
                colSpan = 2,
                rowSpan = 1,
                config = {
                    label = "quoted: value",
                    enabled = true,
                    count = 2.5,
                    future = { "one", "two\nlines", 'quote: "ok"' },
                    empty = {},
                },
            },
        },
        extra = "line one\r\nline two",
    }
    local text, encodeError = yaml.serialize(source)
    assert(text, encodeError)
    local parsed, parseError = yaml.parse(text)
    assert(parsed, parseError)
    same(source, parsed)
    assert(text == assert(yaml.serialize(parsed)), "serializer output must be deterministic")
end

local function testUnsupportedValuesFail()
    local serialized, serializeError = yaml.serialize({ version = 1, value = 0 / 0 })
    assert(not serialized and string.find(serializeError, "finite", 1, true))
    serialized, serializeError = yaml.serialize({ version = 1, value = "\1" })
    assert(not serialized and string.find(serializeError, "control", 1, true))
    serialized, serializeError = yaml.serialize({ version = 1, ["bad key"] = "value" })
    assert(not serialized and string.find(serializeError, "mapping key", 1, true))
end

testRoundTrip()
testUnsupportedValuesFail()
