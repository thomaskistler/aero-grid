-- SPDX-License-Identifier: GPL-2.0-only

-- RSSI publication, source inspection, and one bounded precision scan.
return function(load)
    local services = load("lib/services.lua")
    local telemetryService = load("lib/telemetry_service.lua")
    local cases = {}
    for total = 1, telemetryService.maintenanceDecl.stages.run.maxUnits do
        for _, scanning in ipairs({ false, true }) do
            cases[#cases + 1] = {
                stage = "run",
                grant = total,
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
                        model = {
                            getSensor = function(index)
                                return { name = "OTHER" .. tostring(index), prec = 1 }
                            end,
                        },
                    })
                    local telemetry = telemetryService.new(env, services)
                    telemetry:link()
                    for index = 1, total do
                        telemetry:subscribe("S" .. tostring(index))
                    end
                    if scanning then
                        assert(telemetry:resolve(telemetry.entries[total], 100))
                    end
                    return telemetry.tasks.maintenance, 101
                end,
            }
        end
    end
    return {
        id = "service:telemetry:maintenance",
        decl = telemetryService.maintenanceDecl,
        cases = cases,
    }
end
