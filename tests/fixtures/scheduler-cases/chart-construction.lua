-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local chart = load("panels/chart.lua")
    local api = load("@support/scheduler_panel_api.lua")
    local create = load("@support/scheduler_chart_fixture.lua")(load, chart)
    local decl = {
        class = "normal",
        exclusive = true,
        first = "begin",
        kinds = { steady = true },
        stages = {
            begin = { fixed = 0, perUnit = 920, maxUnits = 1 },
            series = { fixed = 0, perUnit = 970, maxUnits = 1 },
            controls = { fixed = 0, perUnit = 510, maxUnits = 1 },
            layout = { fixed = 0, perUnit = 930, maxUnits = 1 },
            font = { fixed = 0, perUnit = 1120, maxUnits = 1 },
            position = { fixed = 0, perUnit = 2950, maxUnits = 1 },
        },
    }
    local function setup(target, count, rect, cursor, warm, resize)
        return function(seed)
            local context, services = create(seed, {
                staged = true,
                warm = warm,
                count = count,
                rect = rect,
                longText = true,
            })
            api.withApi(function()
                if target ~= "begin" then
                    local ready = false
                    for _ = 1, 50 do
                        if context.createStage == target then
                            if target == "series" or target == "position" then
                                ready = context.createIndex == cursor
                            elseif target == "layout" then
                                ready = cursor == 1 or context.createGeometry ~= nil
                            else
                                ready = true
                            end
                            if ready then
                                break
                            end
                        end
                        assert(not chart.construct(context), "construction finished before " .. target)
                    end
                    assert(ready, "construction setup did not reach " .. target)
                    if target == "font" then
                        context.createGeometry.index = cursor
                    end
                end
            end)
            local task = { stage = target, want = 1 }
            function task:step(_, stage)
                assert(stage == target)
                if stage == "begin" then
                    context.settings.armSwitch = "SBv"
                    api.withApi(chart.create, api.node(), rect, context.settings, services)
                else
                    api.withApi(chart.construct, context, resize and { x = 0, y = 0, w = 320, h = 200 } or rect)
                end
                return 1
            end
            return task, 1000000
        end
    end
    local cases = {}
    for _, rect in ipairs({
        { x = 0, y = 0, w = 800, h = 480 },
        { x = 0, y = 0, w = 800, h = 180 },
        { x = 0, y = 0, w = 160, h = 90 },
    }) do
        for _, count in ipairs({ 0, 1, 3 }) do
            for _, warm in ipairs({ false, true }) do
                for stage in pairs(decl.stages) do
                    if stage ~= "series" or count > 0 then
                        local last = (stage == "series" or stage == "position") and math.max(1, count)
                            or stage == "font" and 3
                            or stage == "layout" and 2
                            or 1
                        for cursor = 1, last do
                            cases[#cases + 1] = {
                                stage = stage,
                                grant = 1,
                                setup = setup(stage, count, rect, cursor, warm),
                            }
                            if stage ~= "begin" then
                                cases[#cases + 1] = {
                                    stage = stage,
                                    grant = 1,
                                    setup = setup(stage, count, rect, cursor, warm, true),
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    return { id = "load:chart", decl = decl, cases = cases }
end
