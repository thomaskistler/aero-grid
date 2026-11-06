-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local panel = load("panels/link-status.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local screen = lcd
    local function withApi(fn, ...)
        local function run(...)
            if screen then
                lcd = screen
            end
            return fn(...)
        end
        return api.withApi(run, ...)
    end
    local function setup(target, shape, protocol, primary, visual, extrema, variant)
        return function(seed)
            local states, views = {}, {}
            for name, value in pairs({ RSSI = -72, LQ = 96, MODE = 6, SNR = 8, POWER = 250, MIN = -100 }) do
                states[name] = {
                    name = name,
                    known = true,
                    available = true,
                    value = value,
                    precision = 0,
                    unitText = name == "LQ" and "%" or name == "RSSI" and "dBm" or "",
                }
                views[name] = support.snapshot(states[name])
            end
            local link = { live = variant ~= 4, indicator = true, rssi = 72 }
            local settings = assert(host.resolveSettings(panel, {
                protocol = protocol,
                reading = primary,
                visual = visual,
                extrema = extrema,
                rssiSource = "RSSI",
                qualitySource = "LQ",
                modeSource = "MODE",
                snrSource = "SNR",
                powerSource = "POWER",
                extremaSource = "MIN",
                qualityWarning = 80,
                qualityCritical = 70,
                rssiWarning = -90,
                rssiCritical = -100,
                marginWarning = protocol == "elrs4" and 15 or nil,
                marginCritical = protocol == "elrs4" and 8 or nil,
            }))
            local theme = {}
            for key, value in pairs(api.theme) do
                theme[key] = value
            end
            theme.alertRgb = { warning = 0x705020, critical = 0x702020 }
            theme.alertColor = { warning = 0x705020, critical = 0x702020 }
            local panelBuilder = setmetatable({
                frame = function(resolved, rect, fonts)
                    return builder.frame(
                        resolved,
                        rect,
                        fonts,
                        seed % 2 == 0 and { w = 47, h = 45, side = shape[2] == 1 } or nil
                    )
                end,
            }, { __index = builder })
            local context = withApi(panel.create, api.node(), { x = 0, y = 0, w = shape[3], h = shape[4] }, settings, {
                theme = theme,
                themeBuilder = panelBuilder,
                primitives = primitives,
                fonts = builder.typography(shape[1], shape[2]),
                span = { colSpan = shape[1], rowSpan = shape[2] },
                telemetry = {
                    subscribe = function(_, name)
                        return views[name]
                    end,
                    link = function()
                        return support.snapshot(link)
                    end,
                },
                state = function(name, accent)
                    return builder.state(theme, name, accent)
                end,
            })
            withApi(panel.refresh, context)
            states.RSSI.value, states.LQ.value = -72 - seed * 5, 96 - seed * 10
            states.MODE.value, states.SNR.value, states.POWER.value = seed + 1, -seed, seed * 100
            if variant == 3 then
                link.live = false
            elseif variant == 4 then
                link.live = true
            elseif variant == 5 then
                for _, feed in pairs(states) do
                    feed.available = false
                end
            elseif variant == 6 then
                for _, feed in pairs(states) do
                    feed.known = false
                end
            elseif variant == 7 then
                for _, feed in pairs(states) do
                    feed.stale = true
                end
            elseif variant == 8 then
                states.MODE.value = 255
            elseif variant == 9 then
                context.rssiFeed, context.qualityFeed = nil, nil
            elseif variant == 10 then
                context.rendered, context.unitAnchor, context.readingAnchor = nil, nil, nil
            elseif variant == 11 then
                states.RSSI.value, states.LQ.value = 0 / 0, math.huge
            elseif variant == 12 then
                states.RSSI.unitText, states.LQ.unitText = string.rep("dBm", seed * 100), string.rep("%", seed * 100)
                states.LQ.precision, states.RSSI.precision = 3, 3
            end
            for _ = 1, 5 do
                local stage = panel.stageOf(context)
                if stage == target then
                    break
                end
                local _, unfinished = withApi(panel.step, context, 1, stage)
                assert(unfinished, "link fixture finished before " .. target)
            end
            assert(panel.stageOf(context) == target)
            local task = host.task({ module = panel, instance = context, interval = panel.refreshInterval })
            local step = task.step
            function task:step(grant, stage, now)
                return withApi(step, self, grant, stage, now)
            end
            return task, 1000000
        end
    end
    local cases = {}
    for _, shape in ipairs({
        { 1, 1, 90, 50 },
        { 1, 1, 117, 65 },
        { 2, 1, 238, 65 },
        { 2, 2, 238, 134 },
        { 4, 1, 800, 90 },
        { 1, 4, 160, 480 },
        { 4, 4, 800, 480 },
    }) do
        for _, protocol in ipairs({ "generic", "elrs4" }) do
            for _, primary in ipairs({ "auto", "quality", "rssi" }) do
                for _, visual in ipairs({ "none", "bar" }) do
                    for _, extrema in ipairs({ "none", "source" }) do
                        for variant = 1, 12 do
                            for stage in pairs(panel.decl.stages) do
                                if
                                    stage == "prepare"
                                    or variant ~= 9 and (stage == "render" or stage == "apply")
                                    or (variant == 3 or variant == 4) and (stage == "geometry" or stage == "layout")
                                then
                                    cases[#cases + 1] = {
                                        stage = stage,
                                        grant = 1,
                                        setup = setup(stage, shape, protocol, primary, visual, extrema, variant),
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return { id = "panel:link-status", decl = panel.decl, cases = cases }
end
