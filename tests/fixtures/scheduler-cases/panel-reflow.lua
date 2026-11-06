-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local host, support = load("lib/panel_host.lua"), load("lib/services.lua")
    local telemetryModule, navigationModule = load("lib/telemetry_service.lua"), load("lib/navigation_service.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local chartFixture = load("@support/scheduler_chart_fixture.lua")(load)
    local bounds = {
        metric = { begin = 3270, apply = 2080 },
        navigation = { begin = 3170, render = 620, reading = 1630, ["tape-frame"] = 910, tape = 2650 },
        chart = { begin = 800, font = 1130, layout = 950, position = 1770, finish = 1300 },
        ["theme-showcase"] = { begin = 2170, place = 450 },
    }
    local function withApi(fn, ...)
        local previous = io
        io = {
            open = function()
                return true
            end,
            close = function() end,
        }
        local ok, result = pcall(api.withApi, fn, ...)
        io = previous
        assert(ok, result)
        return result
    end
    local function create(kind, module, seed, rect, span, variant)
        if kind == "chart" then
            return chartFixture(
                seed,
                { count = variant == 1 and 0 or 3, points = 32, rect = rect, longText = true, largeValues = true }
            )
        end
        local runtime = support.runtime(support.environment())
        local telemetry = telemetryModule.new(runtime.env, support, runtime)
        runtime.byId.telemetry = telemetry
        local settings = kind == "theme-showcase" and {}
            or assert(host.resolveSettings(module, kind == "metric" and {
                metrics = {
                    {
                        source = "Q1",
                        label = string.rep("W", seed * 820),
                        unit = "mAh",
                        rangeMin = -9876543,
                        rangeMax = 9876543,
                    },
                    { source = "Q2", rangeMin = -9876543, rangeMax = 9876543 },
                    { source = "Q3", rangeMin = -9876543, rangeMax = 9876543 },
                },
                visual = variant == 1 and "bar" or "radial",
            } or {
                source = "GPS",
                label = string.rep("W", seed * 820),
                showTape = variant == 2,
                showCoordinates = true,
                satelliteSource = "Sats",
            }))
        local theme = api.theme
        if kind == "theme-showcase" then
            theme = {}
            for key, value in pairs(api.theme) do
                theme[key] = type(value) == "table" and {} or value
                if type(value) == "table" then
                    for field, item in pairs(value) do
                        theme[key][field] = item
                    end
                end
            end
            theme.label, theme.light, theme.spacing.gutter = "Reflow", variant == 1, 4
            for _, token in ipairs({ "canvas", "surfaceRaised", "track", "blue", "orange" }) do
                theme.color[token] = 0x223344
            end
            theme.alertColor = { active = 0x335577, warning = 0x554433, critical = 0x663333 }
        end
        local services = {
            theme = theme,
            themeBuilder = builder,
            primitives = primitives,
            fonts = builder.typography(span.colSpan, span.rowSpan),
            span = span,
            telemetry = telemetry,
            navigation = navigationModule.new(runtime.env, support, runtime),
            host = { path = "/WIDGETS/AeroGrid/" },
            state = function(state, accent)
                return builder.state(theme, state, accent)
            end,
        }
        local context = withApi(module.create, api.node(), rect, settings, services)
        if kind == "metric" then
            for _, key in ipairs({ "feed", "detailFeed", "secondaryFeed" }) do
                context[key] = { available = true, value = seed * 98765.4321, precision = seed % 4, unitText = "mAh" }
            end
        elseif kind == "navigation" then
            context.feed = {
                source = "GPS",
                known = true,
                fix = true,
                home = true,
                state = "normal",
                latitude = 47.3769,
                longitude = 8.5417,
                distance = seed * 9876543.21,
                bearing = seed * 119.5,
            }
            context.satellites = { value = variant == 1 and 3 or 12, stale = seed % 3 == 0 }
        end
        if module.refresh then
            withApi(module.refresh, context)
        end
        return context
    end
    local cases, stages = {}, {}
    for kind, kindBounds in pairs(bounds) do
        local module = load("panels/" .. kind .. ".lua")
        for stage, bound in pairs(kindBounds) do
            local label = kind .. ":" .. stage
            stages[label] = { fixed = 0, perUnit = bound, maxUnits = 1 }
            for _, shape in ipairs({
                { 4, 4, 800, 480 },
                { 4, 1, 800, 90 },
                { 1, 4, 160, 480 },
                { 1, 1, 90, 50 },
                { 1, 1, 200, 120 },
                { 2, 2, 320, 200 },
            }) do
                for variant = 1, 2 do
                    if
                        (stage ~= "tape-frame" or variant == 2)
                        and (stage ~= "tape" or variant == 2 and shape[1] == 4 and shape[2] == 4)
                    then
                        local positions = stage == "position" and (variant == 1 and 1 or 3)
                            or stage == "place" and 6
                            or 1
                        for position = 1, positions do
                            cases[#cases + 1] = {
                                stage = label,
                                grant = 1,
                                setup = function(seed)
                                    local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
                                    local span = { colSpan = shape[1], rowSpan = shape[2] }
                                    local context = create(kind, module, seed, rect, span, variant)
                                    local changed = { x = 1, y = 2, w = rect.w + 20, h = rect.h + 30 }
                                    local begin = stage == "begin"
                                    if not begin then
                                        assert(not withApi(module.reflow, context, changed, nil, nil, span, true))
                                        for _ = 1, 30 do
                                            local work = context.reflowWork
                                            if
                                                work
                                                and work.stage == stage
                                                and (stage ~= "position" and stage ~= "place" or work.index == position)
                                            then
                                                break
                                            end
                                            assert(
                                                not withApi(module.reflow, context, changed, nil, nil, span, false),
                                                label .. ": missing position " .. position
                                            )
                                        end
                                        assert(context.reflowWork and context.reflowWork.stage == stage)
                                    end
                                    return {
                                        step = function()
                                            local done = withApi(module.reflow, context, changed, nil, nil, span, begin)
                                            assert(type(done) == "boolean")
                                            return 1
                                        end,
                                    },
                                        0
                                end,
                            }
                        end
                    end
                end
            end
        end
    end
    return {
        id = "lifecycle:panel-reflow",
        decl = { class = "normal", first = "metric:begin", stages = stages },
        cases = cases,
    }
end
