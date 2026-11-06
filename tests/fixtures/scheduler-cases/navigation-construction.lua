-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local navigation = load("panels/navigation.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local navigationService = load("lib/navigation_service.lua")
    local telemetryService = load("lib/telemetry_service.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local function noop() end
    local function withApi(fn, ...)
        local oldIo = io
        -- File existence is a native operation; exercise the successful icon path.
        io = {
            open = function()
                return true
            end,
            close = noop,
        }
        local ok, result = pcall(api.withApi, fn, ...)
        io = oldIo
        assert(ok, result)
        return result
    end
    local decl = { class = "normal", first = "begin", kinds = { steady = true }, stages = {} }
    for stage, bound in pairs({ begin = 3410, controls = 590, tape = 3880, reflow = 2820, publish = 3540 }) do
        decl.stages[stage] = { fixed = 0, perUnit = bound, maxUnits = 1 }
    end
    local function setup(target, rect, span, flags, variant, resize)
        return function(seed)
            local runtime = support.runtime(support.environment())
            local telemetry = telemetryService.new(runtime.env, support, runtime)
            runtime.byId.telemetry = telemetry
            local service = navigationService.new(runtime.env, support, runtime)
            local settings = assert(host.resolveSettings(navigation, {
                label = string.rep("W", seed * 820),
                showTape = flags % 2 == 1,
                showCoordinates = math.floor(flags / 2) % 2 == 1,
                satelliteSource = flags >= 4 and "Sats" or "",
                bearingFormat = variant % 2 == 0 and "degrees" or "quadrant",
            }))
            if variant == 2 then
                service:subscribe(settings.source)
                telemetry:subscribe("Sats", nil, 25)
            end
            local dependencies = {
                theme = api.theme,
                themeBuilder = builder,
                primitives = primitives,
                fonts = builder.typography(span.colSpan, span.rowSpan),
                span = span,
                navigation = service,
                telemetry = telemetry,
                host = { path = "/WIDGETS/AeroGrid/" },
                state = function(state, accent)
                    return builder.state(api.theme, state, accent)
                end,
                staged = true,
            }
            local context = withApi(navigation.create, api.node(), rect, settings, dependencies)
            context.feed = {
                source = "GPS",
                known = true,
                fix = variant ~= 4,
                home = variant ~= 3,
                state = variant == 3 and "stale" or "normal",
                latitude = 47.3769,
                longitude = 8.5417,
                distance = variant ~= 4 and seed * 9876543.21 or nil,
                bearing = variant ~= 4 and seed * 119.5 or nil,
            }
            if context.satellites then
                context.satellites = { value = variant == 4 and 3 or 12, stale = variant == 3 }
            end
            if target ~= "begin" then
                for _ = 1, 5 do
                    if context.createStage == target then
                        break
                    end
                    assert(not withApi(navigation.construct, context, rect))
                end
                assert(context.createStage == target)
            end
            local task = { stage = target, want = 1 }
            function task:step(_, stage)
                assert(stage == target)
                if target == "begin" then
                    if variant ~= 2 then
                        settings.source, settings.satelliteSource = "GPS-new", flags >= 4 and "Sats-new" or ""
                    end
                    withApi(navigation.create, api.node(), rect, settings, dependencies)
                else
                    withApi(navigation.construct, context, resize and { x = 1, y = 2, w = 320, h = 200 } or rect)
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
        for flags = 0, 7 do
            for variant = 1, 4 do
                for stage in pairs(decl.stages) do
                    cases[#cases + 1] = { stage = stage, grant = 1, setup = setup(stage, rect, span, flags, variant) }
                    if stage == "reflow" or stage == "publish" then
                        cases[#cases + 1] = {
                            stage = stage,
                            grant = 1,
                            setup = setup(stage, rect, span, flags, variant, true),
                        }
                    end
                end
            end
        end
    end
    return { id = "load:navigation", decl = decl, cases = cases }
end
