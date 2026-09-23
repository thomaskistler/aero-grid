-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local yaml = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/yaml.lua"))()
local grid = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/grid.lua"))()
local layout = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/layout.lua"))()

local function testUnknownKeysArePreserved()
    local document = assert(yaml.parse([[
version: 1
vendorExtra: keep-me
grid:
  columns: 4
  rows: 4
components:
  - id: only
    type: placeholder
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    futureKey: keep-me-too
]]))

    local normalized, errors = layout.validate(document, grid)
    assertions.assertEqual(#errors, 0)
    assertions.assertEqual(normalized.vendorExtra, "keep-me")
    assertions.assertEqual(normalized.components[1].futureKey, "keep-me-too")
end

local function testMalformedInput()
    local cases = {
        {
            name = "scalar component entry",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - bare-scalar\n",
        },
        {
            name = "numeric component entry",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - 42\n",
        },
        { name = "components mapping", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  nope: 1\n" },
        { name = "missing grid", fatal = true, text = "version: 1\ncomponents: []\n" },
        {
            name = "future version",
            fatal = true,
            text = "version: 99\ngrid:\n  columns: 4\n  rows: 4\ncomponents: []\n",
        },
        {
            name = "wrong grid size",
            fatal = true,
            text = "version: 1\ngrid:\n  columns: 3\n  rows: 3\ncomponents: []\n",
        },
        {
            name = "unsafe type",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - id: a\n    type: ../evil\n    col: 0\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n",
        },
    }

    for _, case in ipairs(cases) do
        local document = yaml.parse(case.text)
        if document then
            local ok, normalized, errors = pcall(layout.validate, document, grid)
            assert(ok, case.name .. " raised: " .. tostring(normalized))
            if case.fatal then
                assertions.assertEqual(normalized, nil, case.name .. " should fail closed")
            else
                assert(normalized, case.name .. " returned no layout")
                assert(#errors > 0, case.name .. " reported no error")
            end
        end
    end
end

local function run()
    testUnknownKeysArePreserved()
    testMalformedInput()
end

run()
