-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local navigation = load("panels/navigation.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local navigationService = load("lib/navigation_service.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local function withApi(fn, ...)
        local oldIo = io
        io = {
            open = function()
                return true
            end,
            close = function() end,
        }
        local ok, a, b = pcall(api.withApi, fn, ...)
        io = oldIo
        assert(ok, a)
        return a, b
    end
    local function setup(target, rect, span, flags, variant, format)
        return function(seed)
            local theme = {}
            for key, value in pairs(api.theme) do
                theme[key] = value
            end
            theme.light = seed % 2 == 0
            theme.rgb = { surface = theme.light and 0xF5F5F5 or 0x212830 }
            theme.alertRgb = { warning = 0x705020, critical = 0x702020 }
            theme.alertColor = { warning = 0x705020, critical = 0x702020 }
            local runtime = support.runtime(support.environment())
            local service = navigationService.new(runtime.env, support, runtime)
            local state = {
                source = "GPS",
                known = true,
                fix = true,
                home = true,
                state = "normal",
                latitude = 47.3769,
                longitude = 8.5417,
                distance = seed * 987.65,
                bearing = seed * 71.9,
            }
            local satellites = { value = 12, available = true }
            local settings = assert(host.resolveSettings(navigation, {
                label = variant == 9 and string.rep("W", seed * 820) or "NAV",
                showTape = flags % 2 == 1,
                showCoordinates = math.floor(flags / 2) % 2 == 1,
                satelliteSource = flags >= 4 and "Sats" or "",
                bearingFormat = format,
            }))
            local context = withApi(navigation.create, api.node(), rect, settings, {
                theme = theme,
                themeBuilder = builder,
                primitives = primitives,
                fonts = builder.typography(span.colSpan, span.rowSpan),
                span = span,
                navigation = service,
                telemetry = {
                    subscribe = function()
                        return support.snapshot(satellites)
                    end,
                },
                host = { path = "/WIDGETS/AeroGrid/" },
                state = function(name, accent)
                    return builder.state(theme, name, accent)
                end,
            })
            context.feed = support.snapshot(state)
            context.satellites = support.snapshot(satellites)
            api.withApi(navigation.refresh, context)
            if variant == 1 then
                state.distance, state.bearing = seed * 9876543.21, seed * 119.5
                state.latitude = state.latitude + seed / 100
            elseif variant == 3 then
                state.known = false
            elseif variant == 4 then
                state.fix, state.distance, state.bearing = false, nil, nil
            elseif variant == 5 then
                state.home, state.homeStatus, state.distance, state.bearing = false, "switch-unavailable", nil, nil
            elseif variant == 6 then
                state.state = "stale"
            elseif variant == 7 then
                satellites.value = 6
                state.distance = state.distance + seed * 987.654
            elseif variant == 8 then
                satellites.value = 3
                state.distance = state.distance + seed * 987.654
            elseif variant == 9 then
                state.state = "stale"
                if context.tape then
                    context.tape.pending = true
                end
            elseif variant == 10 then
                context.feed = nil
            elseif variant == 11 then
                state.state = "stale"
                if context.tape then
                    context.tape.width, context.tape.height, context.tape.surface = nil, nil, nil
                    context.tape.pending = true
                end
            end
            for _ = 1, 3 do
                local stage = navigation.stageOf(context)
                if stage == target then
                    break
                end
                local _, unfinished = api.withApi(navigation.step, context, 1, stage)
                assert(
                    unfinished,
                    "navigation fixture finished before " .. target .. ": flags=" .. flags .. ", variant=" .. variant
                )
            end
            assert(navigation.stageOf(context) == target)
            local task = host.task({ module = navigation, instance = context, interval = 25 })
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
        { 1, 1, 90, 50 },
        { 1, 1, 117, 65 },
    }) do
        local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
        local span = { colSpan = shape[1], rowSpan = shape[2] }
        for flags = 0, 7 do
            local area = api.withApi(
                navigation.regionsFor,
                api.theme,
                builder,
                rect,
                {
                    showTape = flags % 2 == 1,
                    showCoordinates = math.floor(flags / 2) % 2 == 1,
                    wide = span.colSpan > span.rowSpan,
                    square = span.colSpan == span.rowSpan,
                },
                builder.typography(span.colSpan, span.rowSpan),
                {
                    digits = navigation.DIGITS,
                    unit = navigation.UNIT,
                }
            )
            for variant = 1, 11 do
                for _, format in ipairs({ "degrees", "quadrant" }) do
                    for stage in pairs(navigation.decl.stages) do
                        if
                            stage == "render"
                            or variant ~= 2
                                and variant ~= 10
                                and (stage == "reading" or flags % 2 == 1)
                                and (stage ~= "tape" or area.showTape)
                        then
                            cases[#cases + 1] = {
                                stage = stage,
                                grant = 1,
                                setup = setup(stage, rect, span, flags, variant, format),
                            }
                        end
                    end
                end
            end
        end
    end
    return { id = "panel:navigation", decl = navigation.decl, cases = cases }
end
