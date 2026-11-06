-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local editor = load("lib/editor.lua")
    local function setup(shape)
        local config, shared = {}, { enabled = false }
        for index = 1, 128 do config[index] = { label = "row", nested = { index } } end
        if shape == "deep" then
            local node = config
            for _ = 1, 128 do node.child = {}; node = node.child end
        elseif shape == "keys" then
            for _ = 1, 64 do config[{}] = {} end
        elseif shape == "cycles" then
            config.self, config[config], shared.self = config, config, shared
        end
        local module = { settings = {
            { key = "a", default = shared }, { key = "b", default = shared }, { key = "enabled", default = false },
        } }
        if shape == "settings" then
            for index = 1, 128 do
                module.settings[#module.settings + 1] = { key = "setting" .. index, default = false }
            end
        end
        if shape == "groups" then
            config.source, config.cells, module.drawerGroups = "Cels", 0, {}
            for index = 1, 128 do module.drawerGroups[index] = { key = "group" .. index, sourceType = "pack" } end
        end
        return {
            selected = 1, draft = { panels = { { type = "test", config = config } } },
            loadPanel = function() return module end,
            panelHost = { validateModule = function() return true end },
        }
    end
    local cases = {}
    for _, shape in ipairs({ "plain", "deep", "keys", "cycles", "groups", "settings" }) do
        cases[#cases + 1] = {
            stage = "start", grant = 1,
            setup = function()
                local session = setup(shape)
                local task = { stage = "start", want = 1 }
                function task:step() assert(editor.startSettings(session)); return 1 end
                return task, 1000000
            end,
        }
        local probe, position = assert(editor.startSettings(setup(shape))), 0
        while not probe.done do
            local cursor = position
            cases[#cases + 1] = {
                stage = "advance", grant = 1,
                setup = function()
                    local job = assert(editor.startSettings(setup(shape)))
                    for _ = 1, cursor do assert(not editor.advanceSettings(job)) end
                    local task = { stage = "advance", want = 1 }
                    function task:step() editor.advanceSettings(job); return 1 end
                    return task, 1000000
                end,
            }
            editor.advanceSettings(probe)
            position = position + 1
        end
        cases[#cases + 1] = {
            stage = "summary", grant = 1,
            setup = function()
                local session = setup("groups")
                local job = assert(editor.startSettings(session))
                while not editor.advanceSettings(job) do end
                local task = { stage = "summary", want = 1 }
                function task:step()
                    assert(editor.drawerSummary(session, "group128", job.config, job.module, job.groups) == "Cels  Auto")
                    return 1
                end
                return task, 1000000
            end,
        }
    end
    return {
        id = "editor:settings-snapshot",
        decl = { class = "normal", first = "start", kinds = { steady = true }, stages = {
            start = { fixed = 0, perUnit = 150, maxUnits = 1 },
            advance = { fixed = 0, perUnit = 620, maxUnits = 1 },
            summary = { fixed = 0, perUnit = 110, maxUnits = 1 },
        } },
        cases = cases,
    }
end
