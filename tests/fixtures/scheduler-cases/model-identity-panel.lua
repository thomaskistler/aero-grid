-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local panel = load("panels/model-identity.lua")
    local host = load("lib/panel_host.lua")
    local support = load("lib/services.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local nativeScreen = lcd
    local function withApi(fn, ...)
        local function run(...)
            if nativeScreen then
                lcd = nativeScreen
            end
            return fn(...)
        end
        return api.withApi(run, ...)
    end
    local function setup(shape, presentation, labels, variant)
        return function(seed)
            local feed = { available = true, name = "MODEL", labels = "GLIDER" }
            local settings = assert(host.resolveSettings(panel, { presentation = presentation, showLabels = labels }))
            local context = withApi(panel.create, api.node(), { x = 0, y = 0, w = shape[3], h = shape[4] }, settings, {
                theme = api.theme,
                themeBuilder = builder,
                primitives = primitives,
                fonts = builder.typography(shape[1], shape[2]),
                span = { colSpan = shape[1], rowSpan = shape[2] },
                model = {
                    identity = function()
                        return support.snapshot(feed)
                    end,
                },
                state = function(name, accent)
                    return builder.state(api.theme, name, accent)
                end,
            })
            feed.name = seed % 2 == 0 and "MMMMMMMMMMMMMMM" or "ggggy AEROPLANE"
            feed.labels = string.rep("GLIDER ", seed * 100)
            if variant >= 2 and variant <= 6 then
                feed.bitmapPath = "/IMAGES/fixture.png"
            elseif variant == 7 then
                feed.available = false
            elseif variant == 8 then
                context.feed = nil
            elseif variant == 9 then
                context.readingAnchor, context.labelsAnchor, context.rendered = nil, nil, nil
            elseif variant == 10 then
                feed.name, feed.labels = "MODEL", "GLIDER"
            end
            local task = host.task({ module = panel, instance = context, interval = panel.refreshInterval })
            local step = task.step
            function task:step(grant, stage, now)
                local previous = fstat
                if variant == 2 or variant == 6 then
                    fstat = function()
                        return { size = 1024 }
                    end
                elseif variant == 3 then
                    fstat = nil
                elseif variant == 4 then
                    fstat = function()
                        return nil
                    end
                elseif variant == 5 then
                    fstat = function()
                        error("fixture filesystem failure")
                    end
                end
                local ok, result = pcall(withApi, step, self, grant, stage, now)
                fstat = previous
                assert(ok, result)
                return result
            end
            if variant == 6 then
                task:step(1, "run", 0)
                feed.name = "NEW HEADING " .. seed
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
        for _, presentation in ipairs({ "auto", "name", "image", "both" }) do
            for _, labels in ipairs({ false, true }) do
                for variant = 1, 10 do
                    cases[#cases + 1] = {
                        stage = "run",
                        grant = 1,
                        setup = setup(shape, presentation, labels, variant),
                    }
                end
            end
        end
    end
    return { id = "panel:model-identity", decl = panel.decl, cases = cases }
end
