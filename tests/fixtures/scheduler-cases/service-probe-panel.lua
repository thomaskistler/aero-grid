-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local panel = load("panels/service-probe.lua")
    local host = load("lib/panel_host.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local serviceFor = load("@support/scheduler_probe_fixture.lua")(load)
    local function setup(target, grant, name, shape, variant)
        return function(seed)
            local service, change = serviceFor(name, variant)
            local settings = assert(host.resolveSettings(panel, { service = name, source = "SOURCE" }))
            local context = api.withApi(
                panel.create,
                api.node(),
                { x = 0, y = 0, w = shape[3], h = shape[4] },
                settings,
                {
                    theme = api.theme,
                    themeBuilder = builder,
                    primitives = primitives,
                    fonts = builder.typography(shape[1], shape[2]),
                    [name] = service,
                    state = function(state, accent)
                        return builder.state(api.theme, state, accent)
                    end,
                }
            )
            if variant == 3 then
                context.service = nil
            elseif variant == 4 then
                context.subscribeError = true
            end
            change(seed)
            for _ = 1, 150 do
                local stage = panel.stageOf(context)
                if stage == target then
                    break
                end
                local _, unfinished = api.withApi(panel.step, context, 1, stage)
                assert(unfinished, "probe fixture finished before " .. target)
            end
            assert(panel.stageOf(context) == target)
            if target == "describe" and variant == 2 and seed % 2 == 0 then
                for _ = 1, 128 do
                    api.withApi(panel.step, context, 1, "describe")
                end
            end
            if target == "apply" and seed % 2 == 0 then
                context.refreshWork.applyRow = math.max(1, context.visibleRows - grant + 1)
            end
            local task = host.task({ module = panel, instance = context, interval = panel.refreshInterval })
            local step = task.step
            function task:step(units, stage, now)
                return api.withApi(step, self, units, stage, now)
            end
            return task, 1000000
        end
    end
    local cases = {}
    for _, shape in ipairs({ { 2, 2, 238, 134 }, { 4, 2, 480, 134 }, { 4, 4, 800, 480 } }) do
        for _, name in ipairs({ "telemetry", "model", "control", "navigation" }) do
            for variant = 1, 4 do
                for stage, decl in pairs(panel.decl.stages) do
                    if stage ~= "describe" or name == "control" and variant <= 2 then
                        for grant = 1, decl.maxUnits do
                            cases[#cases + 1] = {
                                stage = stage,
                                grant = grant,
                                setup = setup(stage, grant, name, shape, variant),
                            }
                        end
                    end
                end
            end
        end
    end
    return { id = "panel:service-probe", decl = panel.decl, cases = cases }
end
