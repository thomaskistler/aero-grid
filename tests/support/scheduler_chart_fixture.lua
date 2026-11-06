-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local chart = load("panels/chart.lua")
    local panelHost = load("lib/panel_host.lua")
    local services = load("lib/services.lua")
    local historyService = load("lib/history_service.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    return function(seed, options)
        options = options or {}
        return api.withApi(function()
            local now = 0
            local runtime = services.runtime(services.environment({
                getTime = function()
                    return now
                end,
            }))
            local arm = { key = "SAv", configured = true, available = true, fresh = true, value = true, updatedAt = 0 }
            runtime.byId.armed = {
                state = function()
                    return arm
                end,
            }
            runtime.byId.telemetry = {
                subscribe = function()
                    return {}
                end,
                observe = function() end,
            }
            local ready, boundaryAt = false, nil
            if options.boundaries then
                runtime.byId.flight = {
                    state = function()
                        return { epoch = 1, armKey = "SAv", active = false, flightId = 1 }
                    end,
                    boundaries = function(_, after)
                        if ready and after < 2 then
                            local boundaries = {}
                            for sequence = after + 1, 2 do
                                boundaries[#boundaries + 1] = {
                                    sequence = sequence,
                                    epoch = 1,
                                    kind = sequence == 1 and "start" or "end",
                                    at = boundaryAt - (sequence == 1 and 500 or 250),
                                    observedAt = boundaryAt,
                                    flightId = 1,
                                    armKey = "SAv",
                                }
                            end
                            return boundaries, 2, false
                        end
                        return {}, after, false
                    end,
                }
            end
            local history = historyService.new(runtime.env, services, runtime)
            local metrics = {}
            for index = 1, options.count or 3 do
                metrics[index] = {
                    source = "Q" .. index,
                    label = options.longText and string.rep("W", seed * 820) or nil,
                }
            end
            local settings = assert(panelHost.resolveSettings(chart, {
                armSwitch = "SAv",
                duration = "30s",
                timeRange = "rolling",
                metrics = metrics,
                label = options.longText and string.rep("W", seed * 820) or nil,
            }))
            local panel = chart.create(api.node(), options.rect or { x = 0, y = 0, w = 800, h = 480 }, settings, {
                theme = api.theme,
                themeBuilder = builder,
                primitives = primitives,
                history = history,
                clock = function()
                    return now
                end,
                state = function(state, accent)
                    return builder.state(api.theme, state, accent)
                end,
            })
            for index = 1, options.points or 256 do
                now, arm.updatedAt = index * 10, index * 10
                if options.boundaries then
                    arm.available, arm.value = index % 13 ~= 0, index % 37 ~= 0
                end
                history:advance(now)
                for series = 1, #metrics do
                    history:sample({
                        name = "Q" .. series,
                        value = (index % 2 == 0 and 1 or -1) * (options.largeValues and 987654321.123 or index) * seed,
                        kind = "number",
                        fresh = index % 13 ~= 0,
                        updatedAt = now,
                        precision = options.largeValues and 3 or 0,
                        unitText = options.largeValues and "mAh" or "V",
                    }, now)
                end
            end
            if options.boundaries then
                ready, boundaryAt = true, now
                for _ = 1, 2 do
                    now = now + 10
                    arm.updatedAt = now
                    history.tasks.run:step(1, "run", now)
                end
                assert(panel.session.flightLast > 0 and not panel.session.flightActive, "fixture needs a closed flight")
                assert(panel.session.resumeLast > 1 and panel.session.armLast > 1, "fixture needs lifecycle boundaries")
            end
            return panel
        end)
    end
end
