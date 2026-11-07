-- SPDX-License-Identifier: GPL-2.0-only

-- A single History observer uses the one-unit recorded-source declaration.
return function(load)
    local services = load("lib/services.lua")
    local telemetryService = load("lib/telemetry_service.lua")
    local historyService = load("lib/history_service.lua")
    return {
        id = "service:telemetry:source:recorded-one",
        decl = telemetryService.recordedOneDecl,
        cases = {
            {
                stage = "run",
                grant = 1,
                setup = function(seed)
                    local env = services.environment({
                        getFieldInfo = function(name)
                            return name == "S01" and { id = 1, name = name, unit = 1 }
                        end,
                        getValue = function()
                            return seed
                        end,
                        getRSSI = function()
                            return 42
                        end,
                        model = {},
                    })
                    local runtime = services.runtime(env)
                    runtime.byId.armed = {
                        state = function()
                            return {
                                key = "L01",
                                configured = true,
                                available = true,
                                fresh = true,
                                value = true,
                                updatedAt = 90,
                            }
                        end,
                    }
                    local telemetry = telemetryService.new(env, services, runtime)
                    runtime.byId.telemetry = telemetry
                    local history = historyService.new(env, services, runtime)
                    runtime.byId.history = history
                    history:subscribe("S01", {
                        armSwitch = "L01",
                        timeRange = "rolling",
                        windowSeconds = 30,
                        precision = 0,
                    })
                    history:advance(90)
                    history:sample({
                        name = "S01",
                        value = 5,
                        kind = "number",
                        fresh = true,
                        updatedAt = 90,
                        precision = 0,
                        precisionKnown = true,
                        unitText = "V",
                    }, 90)
                    return telemetry.entries[1].task, 100
                end,
            },
        },
    }
end
