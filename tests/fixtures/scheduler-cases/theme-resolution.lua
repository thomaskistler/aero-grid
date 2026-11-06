-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local theme = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local catalog, requests, copy = load("@support/theme_resolution_fixture.lua")()
    assert(theme.setCatalog(catalog))
    local cases = {}
    local stages = {}
    for stage, bound in pairs({
        begin = 220,
        legibility = 2200,
        chart = 1650,
        alert = 500,
        display = 100,
        finalize = 130,
        done = 80,
    }) do
        stages[stage] = { fixed = 0, perUnit = bound, maxUnits = 1 }
    end
    for _, request in ipairs(requests) do
        cases[#cases + 1] = {
            stage = "begin",
            grant = 1,
            setup = function()
                return {
                    step = function()
                        assert(theme.beginBuild(request.mode))
                        return 1
                    end,
                },
                    0
            end,
        }
        local work = theme.beginBuild(request.mode)
        repeat
            local snapshot = copy(work)
            cases[#cases + 1] = {
                stage = work.stage,
                grant = 1,
                setup = function()
                    local pending = copy(snapshot)
                    return {
                        step = function()
                            theme.advanceBuild(pending)
                            return 1
                        end,
                    },
                        0
                end,
            }
        until theme.advanceBuild(work)
        cases[#cases + 1] = {
            stage = "done",
            grant = 1,
            setup = function()
                return {
                    step = function()
                        assert(theme.advanceBuild(work) == work.result)
                        return 1
                    end,
                },
                    0
            end,
        }
    end
    return {
        id = "load:theme-resolution",
        decl = { class = "normal", first = "begin", stages = stages },
        cases = cases,
    }
end
