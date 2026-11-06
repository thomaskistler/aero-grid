-- SPDX-License-Identifier: GPL-2.0-only
-- Module costs only; the native matrix measures complete lifecycle advances.

return function(load)
    local api = load("@support/scheduler_panel_api.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local configured = setmetatable({
        build = function()
            return api.theme
        end,
    }, { __index = builder })
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local samples = load("@support/construction_cases.lua")(function(relative)
        return relative == "lib/primitives.lua" and primitives or load(relative)
    end, configured, "rx-battery")
    local screen = lcd
    local function withScreen(fn, ...)
        if screen then
            lcd = screen
        end
        return fn(...)
    end
    local function withApi(fn, ...)
        local delta = CHAR_DELTA
        CHAR_DELTA = delta or "D"
        local ok, result = pcall(api.withApi, withScreen, fn, ...)
        CHAR_DELTA = delta
        assert(ok, result)
        return result
    end
    local function create(sample)
        local context = withApi(sample.panel.create, api.node(), sample.rect, sample.settings, sample.dependencies())
        withApi(sample.panel.refresh, context)
        return context
    end
    local cases = {}
    local function add(sample, rect, target, stage, restart)
        cases[#cases + 1] = {
            stage = stage,
            grant = 1,
            setup = function()
                local context = create(sample)
                for _ = 1, target - 1 do
                    assert(not withApi(sample.panel.reflow, context, rect, nil, nil, nil, context.reflowWork == nil))
                end
                if restart then
                    assert(not withApi(sample.panel.reflow, context, rect, nil, nil, nil, true))
                    sample.panel.cancelRefresh(context)
                end
                assert(stage == "begin" or context.reflowWork.stage == stage)
                return {
                    step = function()
                        local done =
                            withApi(sample.panel.reflow, context, rect, nil, nil, nil, stage == "begin" and not restart)
                        assert(type(done) == "boolean")
                        return 1
                    end,
                },
                    1000000
            end,
        }
    end
    for _, sample in ipairs(samples) do
        if
            string.find(sample.name, "/modern-dark/", 1, true)
            and (sample.rect.w == 90 or sample.rect.w == 800 or sample.rect.w == 160)
        then
            for _, rect in ipairs({
                sample.rect,
                { x = 1, y = 2, w = 90, h = 50 },
                { x = 3, y = 4, w = 800, h = 480 },
            }) do
                local context = create(sample)
                add(sample, rect, 1, "begin", false)
                add(sample, rect, 1, "begin", true)
                assert(not withApi(sample.panel.reflow, context, rect, nil, nil, nil, true))
                for index = 2, 20 do
                    add(sample, rect, index, context.reflowWork.stage, false)
                    if withApi(sample.panel.reflow, context, rect, nil, nil, nil, false) then
                        break
                    end
                end
                assert(not context.reflowWork, sample.name)
            end
        end
    end
    return {
        id = "lifecycle:rx-reflow",
        decl = {
            class = "normal",
            first = "begin",
            kinds = { steady = true },
            stages = {
                begin = { fixed = 0, perUnit = 560, maxUnits = 1 },
                fit = { fixed = 0, perUnit = 1860, maxUnits = 1 },
                place = { fixed = 0, perUnit = 1960, maxUnits = 1 },
            },
        },
        cases = cases,
    }
end
