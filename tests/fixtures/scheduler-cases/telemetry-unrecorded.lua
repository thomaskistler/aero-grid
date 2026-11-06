-- SPDX-License-Identifier: GPL-2.0-only

-- A source with no History observers has its own one-unit declaration.
return function(load)
    local services = load("lib/services.lua")
    local telemetryService = load("lib/telemetry_service.lua")
    return {
        id = "service:telemetry:source:plain",
        decl = telemetryService.plainDecl,
        cases = {
            {
                stage = "run",
                grant = 1,
                setup = function()
                    local env = services.environment({
                        getFieldInfo = function(name)
                            return { id = 1, name = name, unit = 1 }
                        end,
                        getValue = function()
                            return 10
                        end,
                        getRSSI = function()
                            return 42
                        end,
                        model = {},
                    })
                    local telemetry = telemetryService.new(env, services)
                    telemetry:subscribe("S01")
                    return telemetry.entries[1].task, 100
                end,
            },
        },
    }
end
