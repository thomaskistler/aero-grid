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
panels:
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
    assertions.assertEqual(normalized.panels[1].futureKey, "keep-me-too")
end

local function testMalformedInput()
    local cases = {
        {
            name = "scalar panel entry",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  - bare-scalar\n",
        },
        {
            name = "numeric panel entry",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  - 42\n",
        },
        { name = "panels mapping", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  nope: 1\n" },
        { name = "missing grid", fatal = true, text = "version: 1\npanels: []\n" },
        {
            name = "future version",
            fatal = true,
            text = "version: 99\ngrid:\n  columns: 4\n  rows: 4\npanels: []\n",
        },
        {
            name = "wrong grid size",
            fatal = true,
            text = "version: 1\ngrid:\n  columns: 3\n  rows: 3\npanels: []\n",
        },
        {
            name = "unsafe type",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  - id: a\n    type: ../evil\n    col: 0\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n",
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

local function buildMapping(tokens, budget)
    local work, result, parseError
    local previousIndex, callbacks = 1, 0
    repeat
        work, result, parseError = yaml.buildMappingChunk(tokens, work, budget)
        if work then
            assert(work.index - previousIndex <= budget, "mapping advance exceeded its token allowance")
            previousIndex = work.index
        end
        callbacks = callbacks + 1
        assert(callbacks <= 2 * #tokens + 2, "mapping construction stopped progressing")
    until not work
    return result, parseError
end

local function testMappingChunks()
    local texts = {
        "",
        "name: example\ncolors:\n  red: 0xff0000\n  blue: 255\nspacing:\n  gap: 4\n",
        "a:\n  b:\n    c: true\n  d: false\ne: {}\nf: null\nf: 2\n",
        'name: "quoted # text"\nempty:\nvalue: "escaped\\nvalue"\n',
    }
    for _, name in ipairs({ "modern-dark", "modern-light" }) do
        local file = assert(io.open(root .. "/src/WIDGETS/AeroGrid/themes/" .. name .. ".yml", "r"))
        texts[#texts + 1] = file:read("*a")
        file:close()
    end
    for _, text in ipairs(texts) do
        local tokens = assert(yaml.tokenize(text))
        local expected = assert(yaml.serialize(assert(yaml.build(tokens))))
        for _, budget in ipairs({ 1, 4 }) do
            local result, parseError = buildMapping(tokens, budget)
            assert(result, parseError)
            assertions.assertEqual(assert(yaml.serialize(result)), expected)
        end
    end
    for _, text in ipairs({
        "a: 1\na: 2\n",
        "a:\n  b: 1\n  b: 2\n",
        "a:\n    b: 1\n",
        "  a: 1\n",
        "a: 1\n  b: 2\n",
    }) do
        local tokens = assert(yaml.tokenize(text))
        local _, expectedError = yaml.build(tokens)
        for _, budget in ipairs({ 1, 4 }) do
            local result, parseError = buildMapping(tokens, budget)
            assertions.assertEqual(result, nil)
            assertions.assertEqual(parseError, expectedError)
        end
    end
    local tokens = assert(yaml.tokenize("a:\n  - value\n"))
    local result, parseError = buildMapping(tokens, 1)
    assert(not result and parseError, "mapping-only construction must reject sequences")
    local _, _, budgetError = yaml.buildMappingChunk(tokens, nil, 0)
    assert(budgetError, "mapping construction must reject a non-progressing budget")
end

local function testCommentChunks()
    local source = 'label: "' .. string.rep("a", 130) .. ' # quoted \\" text" # comment\n'
        .. 'nested:\r\n  value: "x\\\\#y" # actual\r\n'
    local expected = assert(yaml.serialize(assert(yaml.tokenize(source))))
    for _, budget in ipairs({ 1, 2, 7, 64 }) do
        local position, line, work = 1, 1, nil
        local tokens, callbacks = {}, 0
        repeat
            local tokenError
            position, line, tokenError, work = yaml.tokenizeChunk(source, position, line, 4, tokens, budget, work)
            assert(not tokenError, tokenError)
            callbacks = callbacks + 1
            assert(callbacks <= #source, "bounded comment scanning must keep progressing")
        until not position
        assertions.assertEqual(assert(yaml.serialize(tokens)), expected)
    end
    local _, _, budgetError = yaml.tokenizeChunk(source, 1, 1, 4, {}, 0)
    assert(budgetError, "comment scanning must reject a non-progressing budget")
end

local function run()
    testUnknownKeysArePreserved()
    testMalformedInput()
    testMappingChunks()
    testCommentChunks()
end

run()
