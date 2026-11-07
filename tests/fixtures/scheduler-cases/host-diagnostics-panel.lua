-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local panel = load("panels/host-diagnostics.lua")
    local host = load("lib/panel_host.lua")
    local builder = load("lib/theme.lua", load("lib/typography.lua"), load("lib/panel_layout.lua"))
    local primitives = load("lib/primitives.lua", load("lib/reading.lua"))
    local api = load("@support/scheduler_panel_api.lua")
    local hostFor = load("@support/scheduler_diagnostics_fixture.lua")(load)
    local function setup(target, grant, section, shape, variant)
        return function(seed)
            local reportHost, change = hostFor(section, variant)
            change(seed)
            local settings = assert(host.resolveSettings(panel, { section = section }))
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
                    host = reportHost,
                    state = function(state, accent)
                        return builder.state(api.theme, state, accent)
                    end,
                }
            )
            for _ = 1, 1000 do
                local stage = panel.stageOf(context)
                if stage == target then
                    break
                end
                local _, unfinished = api.withApi(panel.step, context, 1, stage)
                assert(unfinished, "diagnostics fixture finished before " .. target)
            end
            assert(panel.stageOf(context) == target)
            if target == "collect" and section == "log" and seed % 2 == 0 then
                context.refreshWork.read = { stage = "trim", limit = seed == 2 and 1 or 256 }
            elseif target == "collect" and section == "log" and seed == 3 then
                context.refreshWork.logEntries = {}
                for index = 1, math.min(12, reportHost.diagnosticsLog.count) do
                    context.refreshWork.logEntries[index] = reportHost.diagnosticsLog.entries[index]
                end
            elseif target == "collect" and section == "panels" and seed % 2 == 0 then
                context.refreshWork.mode = "panels"
            end
            if target == "apply" and seed % 2 == 0 then
                context.refreshWork.position = math.max(1, context.visibleLines - grant + 1)
            end
            local task = host.task({ module = panel, instance = context, interval = 50 })
            local step = task.step
            function task:step(units, stage, now)
                local previous = fstat
                fstat = function()
                    if variant == 2 then
                        error("filesystem unavailable")
                    end
                    if variant == 3 then
                        return
                    end
                    return { size = 12345, time = { year = 2026, mon = 11, day = 6, hour = 7, min = 30 } }
                end
                local ok, result = pcall(api.withApi, step, self, units, stage, now)
                fstat = previous
                assert(ok, result)
                return result
            end
            return task, 1000000
        end
    end
    local cases = {}
    for _, shape in ipairs({ { 2, 2, 238, 134 }, { 4, 2, 480, 134 }, { 4, 4, 800, 480 } }) do
        for _, section in ipairs({ "identity", "theme", "panels", "sources", "log" }) do
            for variant = 1, 4 do
                for stage, decl in pairs(panel.decl.stages) do
                    local collects = section ~= "identity" and variant ~= 3 and variant ~= 4 or section == "log"
                    if stage ~= "collect" or collects and not (section == "log" and variant == 3) then
                        for grant = 1, decl.maxUnits do
                            cases[#cases + 1] = {
                                stage = stage,
                                grant = grant,
                                setup = setup(stage, grant, section, shape, variant),
                            }
                        end
                    end
                end
            end
        end
    end
    return { id = "panel:host-diagnostics", decl = panel.decl, cases = cases }
end
