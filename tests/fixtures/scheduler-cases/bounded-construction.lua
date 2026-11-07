-- SPDX-License-Identifier: GPL-2.0-only
-- Module costs only. Admission uses the enclosing native construction-cost atoms.

return function(load)
    local api = load("@support/scheduler_panel_api.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local configured = setmetatable({
        build = function()
            return api.theme
        end,
    }, { __index = builder })
    local function module(relative)
        if relative == "lib/primitives.lua" then
            return primitives
        end
        return load(relative)
    end
    local samples = load("@support/construction_cases.lua")(module, configured)
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
    local decl = { class = "normal", first = "metric:begin", kinds = { steady = true }, stages = {} }
    local bounds = {
        ["flight-timer"] = { begin = 330, controls = 370, geometry = 1180, header = 1190, place = 1220, publish = 1090 },
        ["link-status"] = { begin = 800, controls = 580, geometry = 1510, header = 670, place = 1150, publish = 2370 },
        metric = {
            begin = 730,
            controls = 880,
            frame = 520,
            geometry = 1660,
            header = 660,
            place = 1130,
            publish = 150,
            reflow = 330,
        },
        ["rx-battery"] = {
            begin = 380,
            controls = 820,
            fit = 1850,
            geometry = 1170,
            header = 670,
            place = 1190,
            publish = 2060,
        },
        ["tx-battery"] = {
            begin = 320,
            controls = 720,
            geometry = 1570,
            header = 660,
            publish = 1590,
            reading = 650,
            visual = 640,
        },
    }
    local cases = {}
    local function create(sample)
        local dependencies = sample.dependencies()
        dependencies.staged = true
        return withApi(sample.panel.create, api.node(), sample.rect, sample.settings, dependencies)
    end
    local function add(sample, path, target, stage, rect)
        local key = sample.kind .. ":" .. stage
        decl.stages[key] = { fixed = 0, perUnit = assert(bounds[sample.kind][stage]), maxUnits = 1 }
        cases[#cases + 1] = {
            stage = key,
            grant = 1,
            setup = function()
                local context = create(sample)
                for index = 1, target - 1 do
                    assert(not withApi(sample.panel.construct, context, path[index]))
                end
                assert(stage == "begin" or context.createStage == stage)
                local task = { stage = key, want = 1 }
                function task:step()
                    if stage == "begin" then
                        create(sample)
                    else
                        withApi(sample.panel.construct, context, rect)
                    end
                    return 1
                end
                return task, 1000000
            end,
        }
    end
    for _, sample in ipairs(samples) do
        local rect = sample.rect
        if string.find(sample.name, "/modern-dark/", 1, true) and (rect.w == 90 or rect.w == 800 or rect.w == 160) then
            add(sample, {}, 1, "begin", rect)
            for _, resize in ipairs({ false, true }) do
                local context, path, latest = create(sample), {}, rect
                local changed = false
                for index = 1, 40 do
                    local stage = context.createStage
                    if resize and stage == "controls" and not changed then
                        latest, changed = { x = 1, y = 2, w = rect.w + 30, h = rect.h + 40 }, true
                    end
                    path[index] = latest
                    add(sample, path, index, stage, latest)
                    if withApi(sample.panel.construct, context, latest) then
                        break
                    end
                end
                assert(not context.createStage, sample.name)
            end
        end
    end
    return { id = "load:bounded-construction", decl = decl, cases = cases }
end
