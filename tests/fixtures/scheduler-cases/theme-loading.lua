-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local yaml = load("lib/yaml.lua")
    local sources = {
        "",
        'name: "Quoted # name"\ncolors:\n  red: 0xff0000\n  blue: 255\nspacing:\n  gap: 4\n',
        "root:\n  first:\n    value: true\n  second:\n    value: false\nlast: {}\n",
        'name: "' .. string.rep("a", 1024) .. ' # quoted"\n',
    }
    local lines = { "# Theme definition", "name: example", "colors:" }
    for index = 1, 128 do
        lines[#lines + 1] = "  color" .. index .. ": 0xff0000 # color"
    end
    sources[#sources + 1] = table.concat(lines, "\n")
    local cases = {}
    for _, source in ipairs(sources) do
        local tokens = assert(yaml.tokenize(source))
        local work, advances = nil, 0
        repeat
            work = yaml.buildMappingChunk(tokens, work, 4)
            advances = advances + 1
        until not work
        for index = 1, advances do
            cases[#cases + 1] = {
                stage = "mapping", grant = 1,
                setup = function()
                    local pending
                    for _ = 1, index - 1 do
                        pending = yaml.buildMappingChunk(tokens, pending, 4)
                        assert(pending)
                    end
                    return { step = function()
                        local _, _, parseError = yaml.buildMappingChunk(tokens, pending, 4)
                        assert(not parseError, parseError)
                        return 1
                    end }, 0
                end,
            }
        end
        local position, line, commentWork = 1, 1, nil
        repeat
            local start, startLine, startComment = position, line, commentWork
            cases[#cases + 1] = {
                stage = "tokenize", grant = 1,
                setup = function()
                    return { step = function()
                        local _, _, tokenError = yaml.tokenizeChunk(source, start, startLine, 4, {}, 64, startComment)
                        assert(not tokenError, tokenError)
                        return 1
                    end }, 0
                end,
            }
            local tokenError
            position, line, tokenError, commentWork = yaml.tokenizeChunk(source, position, line, 4, {}, 64, commentWork)
            assert(not tokenError, tokenError)
        until not position
    end
    return {
        id = "load:theme",
        decl = { class = "normal", first = "tokenize", stages = {
            tokenize = { fixed = 0, perUnit = 1700, maxUnits = 1 },
            mapping = { fixed = 0, perUnit = 500, maxUnits = 1 },
        } },
        cases = cases,
    }
end
