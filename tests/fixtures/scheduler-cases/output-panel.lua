-- SPDX-License-Identifier: GPL-2.0-only

-- Real Output/reading/theme Lua work with constant-cost C API stand-ins, not
-- the instruction-charging widget mock. Each stand-in adds a few instructions
-- a native C setter does not. The matched output-max audit covers actual LVGL.
return function(load)
    local output = load("panels/output.lua")
    local panelHost = load("lib/panel_host.lua")
    local services = load("lib/services.lua")
    local controlService = load("lib/control_service.lua")
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
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
            green = 0x55D990,
        },
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
    local settings = assert(panelHost.resolveSettings(output, { channelCount = 32 }))
    local function setup(mode, available, position)
        return function(seed)
            local instance = withApi(function()
                local runtime = services.runtime(services.environment({}))
                local control = controlService.new(runtime.env, services, runtime)
                local context = output.create(node(), { w = 800, h = 1000 }, settings, {
                    theme = theme,
                    themeBuilder = builder,
                    primitives = primitives,
                    fonts = builder.typography(4, 4),
                    control = control,
                    state = function(state, accent)
                        return builder.state(theme, state, accent)
                    end,
                })
                if mode ~= "create" then
                    for index = 1, 32 do
                        control:output(index - 1)
                        local state = control.outputEntries[index].state
                        state.available, state.nameReady, state.name = available, true, "WWW"
                        state.fraction = (index % 2 == 0 and -1 or 1) * 1.5
                        state.trim = { available = true, fraction = seed / 5 }
                    end
                    for _ = 1, 70 do
                        output.refresh(context)
                    end
                    assert(context.showRows == 32)
                    if mode ~= "render-stable" then
                        context.rendered = nil
                    end
                    if mode == "mount" or mode == "mount-final" then
                        context.layoutNames = nil
                        context.nextRow = 1
                    elseif mode == "render" or mode == "render-stable" then
                        context.renderReady = true
                    elseif mode == "apply" or mode == "apply-empty" then
                        if mode == "apply-empty" then
                            context.showRows, context.area.count = 0, 0
                        end
                        context.pendingDrawn = {}
                        output.render(context, context.pendingDrawn)
                        context.applyRow = position
                        context.stateName = nil
                        context.panel.accentColor = nil
                        for _, row in ipairs(context.rows) do
                            row.text, row.fraction, row.trimFraction = nil, nil, nil
                        end
                    end
                    if mode == "mount-final" or mode == "ready-final" then
                        for _ = 1, 3 do
                            output.step(context, 1, "prepare")
                        end
                        assert(context.captionWork.next == 25)
                    end
                end
                return context
            end)
            local task = panelHost.task({ module = output, instance = instance, interval = 10 })
            local step = task.step
            task.step = function(self, grant, stage, now)
                return withApi(step, self, grant, stage, now)
            end
            return task, 1000000
        end
    end
    local cases = {}
    for _, available in ipairs({ true, false }) do
        for _, mode in ipairs({ "create", "mount", "mount-final", "ready", "ready-final" }) do
            cases[#cases + 1] = { stage = "prepare", grant = 1, setup = setup(mode, available) }
        end
        cases[#cases + 1] = { stage = "render", grant = 1, setup = setup("render", available) }
        cases[#cases + 1] = { stage = "render", grant = 1, setup = setup("render-stable", available) }
        cases[#cases + 1] = { stage = "apply", grant = 1, setup = setup("apply-empty", available, 1) }
        for grant = 1, 2 do
            for position = 1, 32 do
                cases[#cases + 1] = {
                    stage = "apply",
                    grant = grant,
                    setup = setup("apply", available, position),
                }
            end
        end
    end
    return { id = "panel:output", decl = output.decl, cases = cases }
end
