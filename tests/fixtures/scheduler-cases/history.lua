-- SPDX-License-Identifier: GPL-2.0-only

-- One release advances every recording session, drains one flight boundary,
-- and maintains one rolling series entry across the largest dashboard.
return function(load)
    local services = load("lib/services.lua")
    local scheduler = load("lib/scheduler.lua")
    local historyService = load("lib/history_service.lua")
    local NOW, PANELS, SERIES = 1000000, 16, 4

    local function setup(grant)
        return function(seed)
            local runtime = services.runtime(services.environment({}))
            local arms, readings = {}, {}
            local boundaryReady = false
            runtime.byId.armed = {
                state = function(_, name)
                    if not arms[name] then
                        arms[name] = {
                            key = name,
                            configured = true,
                            available = true,
                            fresh = true,
                            value = true,
                            updatedAt = NOW,
                        }
                    end
                    return arms[name]
                end,
            }
            runtime.byId.telemetry = {
                subscribe = function(_, name)
                    readings[name] = readings[name] or {}
                    return readings[name]
                end,
                observe = function() end,
            }
            local flightState = {
                epoch = 1,
                armKey = "L01",
                active = true,
                startedAt = NOW - 2500,
                flightId = 1,
            }
            runtime.byId.flight = {
                state = function()
                    return flightState
                end,
                boundaries = function(_, after)
                    if boundaryReady and after < 1 then
                        return {
                            {
                                sequence = 1,
                                epoch = 1,
                                kind = "start",
                                at = NOW - 2500,
                                observedAt = NOW,
                                flightId = 1,
                                armKey = "L01",
                            },
                        }, 1, false
                    end
                    return {}, 1, false
                end,
            }
            local service = historyService.new(runtime.env, services, runtime)
            for panel = 1, PANELS do
                for series = 1, SERIES do
                    service:subscribe("V" .. tostring(panel) .. "-" .. tostring(series), {
                        armSwitch = string.format("L%02d", panel),
                        timeRange = "rolling",
                        windowSeconds = 30,
                        precision = 0,
                    })
                end
            end

            for offset, at in ipairs({ NOW - 5000, NOW - 4000, NOW - 3000, NOW - 2000 }) do
                for panel = 1, PANELS do
                    local arm = arms[string.format("L%02d", panel)]
                    arm.updatedAt = at
                end
                service:advance(at)
                for panel = 1, PANELS do
                    for series = 1, SERIES do
                        service:sample({
                            name = "V" .. tostring(panel) .. "-" .. tostring(series),
                            value = offset % 2 == 0 and 100 or -100,
                            kind = "number",
                            fresh = true,
                            updatedAt = at,
                            precision = 0,
                            unitText = "V",
                        }, at)
                    end
                end
            end
            for _, arm in pairs(arms) do
                arm.updatedAt = NOW
            end
            boundaryReady = true
            service.cursor = (grant - 1) % SERIES + 1
            service.sessionCursor = PANELS - grant + 1
            service.sessionTarget = PANELS
            service.tasks.run.want = grant
            service.tickElapsed = scheduler.elapsed
            service.due = NOW
            return service.tasks.run, NOW
        end
    end

    local cases = {}
    for grant = 1, PANELS do
        cases[#cases + 1] = { stage = "run", grant = grant, setup = setup(grant) }
    end
    return {
        id = "service:history",
        decl = historyService.decl,
        cases = cases,
    }
end
