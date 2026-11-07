-- SPDX-License-Identifier: GPL-2.0-only

-- Worst-case custom-home transitions with diagnostics enabled across the
-- largest dashboard, measured at every cursor and grant.
return function(load)
    local services = load("lib/services.lua")
    local scheduler = load("lib/scheduler.lua")
    local navigationService = load("lib/navigation_service.lua")
    local NOW, PANELS = 1000000, 16

    local function setup(start)
        return function(seed)
            local runtime = services.runtime(services.environment({}))
            local readings, switches = {}, {}
            runtime.host = {
                panels = {},
                diagnosticsLog = {
                    limit = function()
                        return 64
                    end,
                    append = function() end,
                },
            }
            runtime.byId.telemetry = {
                subscribe = function(_, name)
                    local reading = readings[name]
                    if not reading then
                        reading = {
                            known = true,
                            available = true,
                            fresh = true,
                            stale = false,
                            updatedAt = NOW,
                            age = 0,
                            raw = { lat = 47 + seed / 100000, lon = 8, delay = seed % 4 },
                        }
                        readings[name] = reading
                    end
                    return reading
                end,
            }
            runtime.byId.armed = {
                state = function(_, name)
                    if not switches[name] then
                        switches[name] = {
                            key = name,
                            available = true,
                            fresh = true,
                            value = false,
                            updatedAt = NOW,
                        }
                    end
                    return switches[name]
                end,
            }

            local service = navigationService.new(runtime.env, services, runtime)
            for index = 1, PANELS do
                local name = "GPS" .. tostring(index)
                local view = service:subscribe(name, "SF" .. tostring(index), "first-arm")
                local entry = service.entries[index]
                entry.wasArmed = false
                entry.arm.value = true
                runtime.host.panels[index] = {
                    placement = { id = "nav" .. tostring(index), type = "navigation" },
                    instance = { feed = view },
                }
            end
            service.cursor = start
            service.tickElapsed = scheduler.elapsed
            service.due = NOW
            return service.tasks.run, NOW
        end
    end

    local cases = {}
    for start = 1, PANELS do
        for grant = 1, navigationService.decl.stages.run.maxUnits do
            cases[#cases + 1] = { stage = "run", grant = grant, setup = setup(start) }
        end
    end
    return {
        id = "service:navigation",
        decl = navigationService.decl,
        cases = cases,
    }
end
