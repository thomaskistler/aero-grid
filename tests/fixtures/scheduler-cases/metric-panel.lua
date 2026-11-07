-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local metric = load("panels/metric.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local theme = {}
    for key, value in pairs(api.theme) do
        theme[key] = value
    end
    theme.alertColor = { warning = 0x705020, critical = 0x702020 }
    local function setup(target, rect, span, count, visual, variant)
        return function(seed)
            local entries, states, views = {}, {}, {}
            for index = 1, count do
                entries[index] = {
                    source = "Q" .. index,
                    label = variant == 4 and string.rep("W", seed * 820) or "READING",
                    rangeMin = variant == 4 and -9876543 or 0,
                    rangeMax = variant == 4 and 9876543 or 100,
                    warning = 20,
                    critical = 40,
                }
                states[index] = { available = true, value = index * 10, precision = 0, unitText = "V" }
                views["Q" .. index] = support.snapshot(states[index])
            end
            local config = assert(host.resolveSettings(metric, { metrics = entries, visual = visual }))
            local context = api.withApi(metric.create, api.node(), rect, config, {
                theme = theme,
                themeBuilder = builder,
                primitives = primitives,
                fonts = builder.typography(span.colSpan, span.rowSpan),
                span = span,
                telemetry = {
                    subscribe = function(_, name)
                        return views[name]
                    end,
                },
                state = function(state, accent)
                    return builder.state(theme, state, accent)
                end,
            })
            api.withApi(metric.refresh, context)
            if variant == 2 or variant == 4 or variant == 7 then
                for index, state in ipairs(states) do
                    state.value, state.precision = -seed * index * 98765.4321, seed % 3 + 1
                    state.unitText = variant == 4 and string.rep("mAh", seed * 820) or "mAh"
                end
            elseif variant == 3 then
                for _, state in ipairs(states) do
                    state.available, state.stale = false, true
                end
            elseif variant == 5 then
                context.feed = nil
            elseif variant == 6 then
                for index, state in ipairs(states) do
                    state.value = seed + index
                end
            end
            if variant == 7 then
                api.withApi(metric.step, context, 1, "prepare")
                api.withApi(metric.step, context, 1, "geometry")
                assert(metric.stageOf(context) == "layout")
                metric.cancelRefresh(context)
                assert(context.refreshGeometry)
            end
            if target == "layout" and variant == 3 then
                assert(count == 3)
            end
            for _ = 1, 5 do
                local stage = metric.stageOf(context)
                if stage == target then
                    break
                end
                local _, unfinished = api.withApi(metric.step, context, 1, stage)
                assert(unfinished, "metric fixture finished before " .. target)
            end
            assert(metric.stageOf(context) == target)
            local task = host.task({ module = metric, instance = context, interval = 20 })
            local step = task.step
            function task:step(grant, stage, now)
                return api.withApi(step, self, grant, stage, now)
            end
            return task, 1000000
        end
    end
    local cases = {}
    for _, shape in ipairs({
        { 4, 4, 800, 480 },
        { 4, 1, 800, 90 },
        { 1, 4, 160, 480 },
        { 2, 2, 238, 134 },
        { 1, 1, 90, 50 },
        { 1, 1, 117, 65 },
        { 4, 1, 480, 65 },
        { 4, 4, 480, 272 },
    }) do
        local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
        local span = { colSpan = shape[1], rowSpan = shape[2] }
        for _, count in ipairs({ 1, 3 }) do
            for _, visual in ipairs({ "none", "bar", "radial" }) do
                for variant = 1, 7 do
                    for stage in pairs(metric.decl.stages) do
                        local eligible = stage == "prepare"
                            or variant ~= 5 and stage == "render"
                            or variant ~= 1 and variant ~= 5 and stage == "apply"
                            or (stage == "layout" or stage == "geometry")
                                and (variant == 2 or variant == 4 or variant == 7 or (variant == 3 or variant == 6) and count == 3)
                        if eligible then
                            cases[#cases + 1] = {
                                stage = stage,
                                grant = 1,
                                setup = setup(stage, rect, span, count, visual, variant),
                            }
                        end
                    end
                end
            end
        end
    end
    return { id = "panel:metric", decl = metric.decl, cases = cases }
end
