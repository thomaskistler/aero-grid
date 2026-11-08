-- SPDX-License-Identifier: GPL-2.0-only

-- One atomic source poll at each supported History observer multiplicity.
return function(load)
    local services = load("lib/services.lua")
    local scheduler = load("lib/scheduler.lua")
    local telemetryService = load("lib/telemetry_service.lua")
    local historyService = load("lib/history_service.lua")
    local NOW, SENSOR_COUNT = 1000000, 8

    local function setup(recorders)
        return function(seed)
            local arm = {
                key = "L01",
                configured = true,
                available = true,
                fresh = true,
                value = true,
                updatedAt = NOW - 10,
            }
            local env = services.environment({
                getFieldInfo = function(name)
                    return name == "S01" and { id = 1, name = name, unit = 1 }
                end,
                getValue = function()
                    return seed + 20
                end,
                getRSSI = function()
                    return 42
                end,
                model = {
                    getSensor = function(index)
                        if index < SENSOR_COUNT then
                            return { name = string.format("S%02d", index + 1), prec = 1 }
                        end
                    end,
                },
            })
            local runtime = services.runtime(env)
            runtime.host = {}
            runtime.byId.armed = {
                state = function()
                    return arm
                end,
            }
            local telemetry = telemetryService.new(env, services, runtime)
            runtime.byId.telemetry = telemetry
            local history = historyService.new(env, services, runtime)
            runtime.byId.history = history
            telemetry:subscribe("S01")
            for recorder = 0, recorders - 1 do
                history:subscribe("S01", {
                    armSwitch = "L01",
                    timeRange = "rolling",
                    windowSeconds = 30 + recorder % 6 * 30,
                    precision = recorder // 6,
                })
            end

            local task = history.tasks.run
            task:step(task.want, "run", NOW - 10)
            history:sample({
                name = "S01",
                value = seed,
                kind = "number",
                fresh = true,
                updatedAt = NOW - 10,
                precision = 1,
                precisionKnown = true,
                unitText = "V",
            }, NOW - 10)

            local task = telemetry.entries[1].task
            task.tickElapsed = scheduler.elapsed
            return task, NOW
        end
    end

    local cases = {}
    for recorders = 1, historyService.SOURCE_CAP do
        for grant = 1, recorders do
            cases[#cases + 1] = {
                stage = "run",
                grant = grant,
                setup = setup(recorders),
                recorders = recorders,
            }
        end
    end
    return {
        id = "service:telemetry:source:recorded",
        decl = telemetryService.decl,
        cases = cases,
    }
end
