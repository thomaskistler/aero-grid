-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local metric = load("panels/metric.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local telemetryService = load("lib/telemetry_service.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local decl = { class = "normal", first = "begin", kinds = { steady = true }, stages = {} }
    for stage, bound in pairs({
        begin = 1540,
        frame = 620,
        geometry = 1710,
        header = 1400,
        controls = 1420,
        reflow = 320,
        place = 1730,
        publish = 900,
    }) do
        decl.stages[stage] = { fixed = 0, perUnit = bound, maxUnits = 1 }
    end
    local function setup(target, rect, span, count, visual, variant)
        return function(seed)
            local runtime = support.runtime(support.environment())
            local telemetry = telemetryService.new(runtime.env, support, runtime)
            local entries = {}
            for index = 1, count do
                entries[index] = {
                    source = "Q" .. index,
                    label = variant == 3 and string.rep("W", seed * 820) or "READING",
                    precision = seed % 4,
                    unit = variant == 2 and "" or "mAh",
                    rangeMin = -9876543,
                    rangeMax = 9876543,
                }
                if variant == 2 then
                    telemetry:subscribe(entries[index].source, nil, 20)
                end
            end
            local resolution = host.beginSettings(metric, { metrics = entries, visual = visual })
            while not host.advanceSettings(resolution) do
            end
            local config = resolution.settings
            local dependencies = {
                settingsValidation = resolution.proof,
                theme = api.theme,
                themeBuilder = builder,
                primitives = primitives,
                fonts = builder.typography(span.colSpan, span.rowSpan),
                span = span,
                telemetry = variant ~= 4 and telemetry or nil,
                state = function(state, accent)
                    return builder.state(api.theme, state, accent)
                end,
                staged = true,
            }
            local context = api.withApi(metric.create, api.node(), rect, config, dependencies)
            for _, key in ipairs({ "feed", "detailFeed", "secondaryFeed" }) do
                if context[key] then
                    context[key] = {
                        available = true,
                        value = seed * 98765.4321,
                        precision = seed % 4,
                        unitText = "mAh",
                    }
                end
            end
            local resized = { x = 1, y = 2, w = 320, h = 200 }
            if target ~= "begin" and target ~= "frame" then
                assert(not api.withApi(metric.construct, context, rect))
                assert(context.createStage == "geometry")
                if target ~= "geometry" then
                    assert(not api.withApi(metric.construct, context, rect))
                    assert(context.createStage == "header")
                    if target ~= "header" then
                        assert(not api.withApi(metric.construct, context, rect))
                        assert(context.createStage == "controls")
                        if target ~= "controls" then
                            assert(not api.withApi(metric.construct, context, resized))
                            assert(context.createStage == "reflow")
                            while context.createStage ~= target do
                                assert(not api.withApi(metric.construct, context, resized))
                            end
                        end
                    end
                end
            end
            local task = { stage = target, want = 1 }
            function task:step(_, stage)
                assert(stage == target)
                if target == "begin" then
                    if variant ~= 2 then
                        for _, entry in ipairs(config.metrics) do
                            entry.source = entry.source .. "-new"
                        end
                    end
                    api.withApi(metric.create, api.node(), rect, config, dependencies)
                else
                    api.withApi(
                        metric.construct,
                        context,
                        (target == "reflow" or target == "place" or target == "publish") and resized or rect
                    )
                end
                return 1
            end
            return task, 1000000
        end
    end
    local cases = {}
    for _, shape in ipairs({
        { 4, 4, 800, 480 },
        { 4, 1, 800, 90 },
        { 1, 4, 160, 480 },
        { 1, 1, 90, 50 },
    }) do
        local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
        local span = { colSpan = shape[1], rowSpan = shape[2] }
        for _, count in ipairs({ 0, 1, 3 }) do
            for _, visual in ipairs({ "none", "bar", "radial" }) do
                for variant = 1, 4 do
                    for stage in pairs(decl.stages) do
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
    return { id = "load:metric", decl = decl, cases = cases }
end
