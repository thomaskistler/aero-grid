-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local editor = load("lib/editor.lua")
    local decl = {
        class = "normal",
        first = "copy",
        kinds = { steady = true },
        stages = { copy = { fixed = 0, perUnit = 1000, maxUnits = 1 } },
    }
    local function document(shape)
        local input = { panels = {} }
        for index = 1, 16 do
            input.panels[index] = {
                id = "metric-" .. index,
                type = "metric",
                col = (index - 1) % 4,
                row = math.floor((index - 1) / 4),
                colSpan = 1,
                rowSpan = 1,
                config = { label = "LONG METRIC HEADING", source = "Alt", scale = 1, unit = "m" },
            }
        end
        if shape == "deep" then
            local node = input
            for _ = 1, 128 do
                node.child = {}
                node = node.child
            end
        elseif shape == "keys" then
            for _ = 1, 64 do
                input[{}] = {}
            end
        elseif shape == "cycles" then
            input.self = input
            input[input] = input
            for _, placement in ipairs(input.panels) do
                placement.config.shared = input
            end
        end
        return input
    end
    local cases = {}
    for _, shape in ipairs({ "plain", "deep", "keys", "cycles" }) do
        local probe = assert(editor.new(document(shape), {}, {}, {}, nil, true))
        local cursor = 0
        while probe.initializing do
            local position = cursor
            cases[#cases + 1] = {
                stage = "copy",
                grant = 1,
                setup = function()
                    local session = assert(editor.new(document(shape), {}, {}, {}, nil, true))
                    for _ = 1, position do
                        assert(not editor.advanceInitialization(session))
                    end
                    local task = { stage = "copy", want = 1 }
                    function task:step()
                        editor.advanceInitialization(session)
                        return 1
                    end
                    return task, 1000000
                end,
            }
            editor.advanceInitialization(probe)
            cursor = cursor + 1
        end
    end
    return { id = "editor:initialize", decl = decl, cases = cases }
end
