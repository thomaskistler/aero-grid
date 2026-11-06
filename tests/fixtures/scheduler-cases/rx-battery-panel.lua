-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local panel = load("panels/rx-battery.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local screen = lcd
    local function runWithScreen(fn, ...)
        if screen then
            lcd = screen
        end
        return fn(...)
    end
    local function withApi(fn, ...)
        local delta = CHAR_DELTA
        CHAR_DELTA = delta or "D"
        local ok, first, second = pcall(api.withApi, runWithScreen, fn, ...)
        CHAR_DELTA = delta
        assert(ok, first)
        return first, second
    end
    local function setup(target, shape, visual, reading, flags, variant, mask, corner)
        return function(seed)
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
                        corner and { w = 47, h = 45, side = shape[2] == 1 } or nil
                    )
                end,
            }, { __index = builder })
            local state = { available = true, raw = { 4.2, 4.1, 4.0, 4.1, 4.2, 4.1 }, fresh = true, updatedAt = 100 }
            local config = assert(host.resolveSettings(panel, {
                visual = visual,
                reading = reading,
                cells = variant == 11 and 16 or 0,
                showCount = flags > 0,
                showPack = flags > 0,
                showDelta = flags > 0,
            }))
            local context = withApi(panel.create, api.node(), { x = 0, y = 0, w = shape[3], h = shape[4] }, config, {
                theme = theme,
                themeBuilder = panelBuilder,
                primitives = primitives,
                fonts = builder.typography(shape[1], shape[2]),
                telemetry = {
                    subscribe = function()
                        return support.snapshot(state)
                    end,
                },
                state = function(name, accent)
                    return builder.state(theme, name, accent)
                end,
            })
            if variant == 2 or variant == 4 or variant == 12 then
                state.raw = {}
                for index = 1, 16 do
                    state.raw[index] = variant == 12 and 29.99 - index / 10 or 3 + seed / 10 + index / 100
                end
                state.stale = variant == 4
            elseif variant == 3 then
                state.available = false
            elseif variant == 5 or variant == 11 then
                state.raw = variant == 5 and 12.6 or 64
            elseif variant == 6 then
                state.raw = {}
            elseif variant == 7 then
                state.raw = { 0, 0 / 0, 31, "bad" }
            elseif variant == 8 then
                state.raw = { 3.8, 0, 4.1, "bad" }
            elseif variant == 9 then
                state.raw = nil
            elseif variant == 10 then
                context.feed = nil
            end
            for _ = 1, 16 do
                local stage = panel.stageOf(context)
                if stage == target then
                    break
                end
                local _, unfinished = withApi(panel.step, context, 1, stage)
                assert(
                    unfinished,
                    "RX fixture finished before "
                        .. target
                        .. ": "
                        .. visual
                        .. "/"
                        .. reading
                        .. "/"
                        .. flags
                        .. "/"
                        .. variant
                )
            end
            assert(panel.stageOf(context) == target)
            if mask then
                context.refreshWork.geometry.mask = mask
            end
            local task = host.task({ module = panel, instance = context, interval = 20 })
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
        { 2, 2, 238, 134 },
        { 4, 1, 480, 65 },
        { 1, 4, 160, 480 },
        { 4, 4, 800, 480 },
        { 4, 4, 480, 272 },
    }) do
        for _, corner in ipairs({ false, true }) do
            for _, visual in ipairs({ "battery", "bar", "none" }) do
                for _, reading in ipairs({ "cell", "pack" }) do
                    for _, flags in ipairs({ 0, 7 }) do
                        for variant = 1, 12 do
                            for stage in pairs(panel.decl.stages) do
                                local eligible = stage == "prepare"
                                    or stage == "render" and variant ~= 10
                                    or stage == "apply" and variant ~= 1 and variant ~= 10 and (variant ~= 11 or reading == "pack" or visual ~= "battery" and flags == 7)
                                    or stage == "layout" and visual ~= "battery" and flags == 7 and variant == 2
                                if eligible then
                                    cases[#cases + 1] = {
                                        stage = stage,
                                        grant = 1,
                                        setup = setup(stage, shape, visual, reading, flags, variant, nil, corner),
                                    }
                                end
                            end
                        end
                        if visual ~= "battery" and flags == 7 then
                            for mask = 0, 7 do
                                cases[#cases + 1] = {
                                    stage = "geometry",
                                    grant = 1,
                                    setup = setup("geometry", shape, visual, reading, flags, 2, mask, corner),
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    return { id = "panel:rx-battery", decl = panel.decl, cases = cases }
end
