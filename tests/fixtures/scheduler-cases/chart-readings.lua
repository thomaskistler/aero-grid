-- SPDX-License-Identifier: GPL-2.0-only

-- Real chart/theme/primitive work; API stand-ins add conservative Lua costs.
-- Plot projection and publication are deliberately not part of this subtask.
return function(load)
    local chart = load("panels/chart.lua")
    local panelHost = load("lib/panel_host.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local function noop() end
    local function node()
        return { set = noop }
    end
    local native = {
        box = node,
        rectangle = node,
        label = node,
        triangle = node,
        arc = node,
        hline = node,
        vline = node,
        show = noop,
        hide = noop,
    }
    local screen = {
        RGB = function(value)
            return value
        end,
        sizeText = function(text)
            return #text * 10, 17
        end,
    }
    local function withApi(fn, ...)
        local oldLvgl, oldLcd = lvgl, lcd
        lvgl, lcd = native, screen
        local ok, a, b = pcall(fn, ...)
        lvgl, lcd = oldLvgl, oldLcd
        assert(ok, a)
        return a, b
    end
    local theme = {
        accent = "cyan",
        rgb = { surface = 0x212830 },
        color = {
            surface = 0x212830,
            text = 0xF4F6F7,
            textMuted = 0xDCE2E6,
            textFaint = 0xC4CDD3,
            border = 0x3A434B,
            cyan = 0x70D6F3,
        },
        chartColor = { cyan = 0x70D6F3, orange = 0xEDAD79, green = 0x55D990, grid = 0x3A434B },
        spacing = {
            padding = 8,
            paddingTight = 8,
            paddingRight = 4,
            paddingCompact = 6,
            radius = 8,
            accentWidth = 4,
            barHeight = 4,
            borderFocus = 2,
        },
    }
    local module = {
        decl = chart.readingDecl,
        step = chart.readingStep,
        stageOf = chart.readingStageOf,
    }
    local function setup(rect, count, stage, position, grow, missing)
        return function(seed)
            local panel = withApi(function()
                local metrics, feeds = {}, {}
                for index = 1, count do
                    metrics[index] = {
                        source = "Q" .. index,
                        label = string.rep("W", seed * 820),
                        precision = seed % 4,
                    }
                    feeds[index] = {
                        revision = 1,
                        value = -123456789.321 * seed,
                        min = -987654321.123 * seed,
                        max = 987654321.123 * seed,
                        unitText = "mAh",
                        precision = 3,
                        stale = index % 2 == 0,
                    }
                end
                local settings = assert(panelHost.resolveSettings(chart, {
                    label = string.rep("W", seed * 820),
                    metrics = metrics,
                }))
                local cursor = 0
                local context = chart.create(node(), rect, settings, {
                    theme = theme,
                    themeBuilder = builder,
                    primitives = primitives,
                    state = function(state, accent)
                        return builder.state(theme, state, accent)
                    end,
                    history = {
                        session = function()
                            return { elapsed = 0, configured = true, available = true }
                        end,
                        subscribe = function()
                            cursor = cursor + 1
                            return not missing and feeds[cursor] or nil
                        end,
                    },
                })
                if not grow then
                    chart.render(context)
                else
                    context.legendWidth = 0
                end
                if position == 0 then
                    return context
                end
                context.readingGeometry = nil
                for _ = 1, 20 do
                    local current = chart.readingStageOf(context)
                    local index = context.readingWork and context.readingWork.index or 1
                    local ready = current == stage
                    if stage == "readings" or stage == "position" then
                        ready = ready and index == position
                    elseif stage == "layout" then
                        ready = ready and (position == 1 or context.readingWork.geometry ~= nil)
                    end
                    if ready then
                        if stage == "font" then
                            context.readingWork.geometry.index = position
                        end
                        return context
                    end
                    chart.readingStep(context, 1, current)
                end
                error("chart setup did not reach " .. stage .. ":" .. position)
            end)
            local task = panelHost.task({ module = module, instance = panel, interval = 10 })
            local step = task.step
            task.step = function(self, grant, planned, now)
                return withApi(step, self, grant, planned, now)
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
            for _, grow in ipairs({ true, false }) do
                for _, missing in ipairs({ true, false }) do
                    for _, stage in ipairs({ "readings", "measure", "layout", "font", "position" }) do
                        if (stage ~= "layout" and stage ~= "font") or grow then
                            local last = (stage == "readings" or stage == "position") and math.max(1, count)
                                or stage == "layout" and 2
                                or stage == "font" and 3
                                or 1
                            for index = 1, last do
                                cases[#cases + 1] = {
                                    stage = stage,
                                    grant = 1,
                                    setup = setup(rect, count, stage, index, grow, missing),
                                }
                            end
                        end
                    end
                    cases[#cases + 1] = {
                        stage = "readings",
                        grant = 1,
                        setup = setup(rect, count, "readings", 0, grow, missing),
                    }
                end
            end
        end
    end
    return { id = "panel:chart:readings", decl = chart.readingDecl, cases = cases }
end
