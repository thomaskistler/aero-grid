-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local panelHost = load("lib/panel_host.lua")
    local flight, support = load("lib/flight_service.lua"), load("lib/services.lua")
    local fixture = load("@support/scheduler_flight_fixture.lua")(load)
    local declaration = {
        class = "normal",
        stages = {
            run = { fixed = 0, perUnit = 2300, maxUnits = 1 },
            prospective = { fixed = 0, perUnit = 2300, maxUnits = 1 },
        },
    }
    local cases = {}
    for _, size in ipairs({ 0, 16 }) do
        for _, action in ipairs({
            "enroll",
            "enroll-next",
            "extra-kinds",
            "extra-kinds-final",
            "registry-gap",
            "partial",
            "facade",
            "model-reset",
            "session-reset",
            "handoff",
            "disable",
        }) do
            cases[#cases + 1] = {
                stage = string.sub(action, 1, 11) == "extra-kinds" and "prospective" or "run",
                grant = 1,
                setup = function()
                    local host = load("lib/scheduler_host.lua")
                    local extra = action == "extra-kinds" or action == "extra-kinds-final"
                    if extra then
                        for index = 1, 8 do
                            host.SERVICE_KINDS["audit-loader-" .. index] = true
                            host.OVERHEAD["audit-loader-" .. index] = 2400
                        end
                    end
                    local owner, radio, _, context = fixture("run")
                    radio.now = 0
                    local factory = { broker = owner, members = owner.members, revision = 1 }
                    owner.factory = factory
                    local function registry(target)
                        target.flightFactory = factory
                        local runtime = support.runtime(owner.env)
                        runtime.host, runtime.modules = target, owner.modules
                        local facade = flight.new(owner.env, support, runtime)
                        support.register(runtime, facade, radio.now)
                        target.serviceRuntime = runtime
                        return facade
                    end
                    local facade = registry(context)
                    local function attach(target)
                        target.panels, target.panelHost = {}, panelHost
                        for index = 1, size do
                            target.panels[index] = {
                                placement = { id = "p" .. index },
                                module = { id = "sample", idle = true },
                                instance = {},
                            }
                        end
                        local previous = getTime
                        getTime = function() return radio.now end
                        local scheduling = host.attach(target, {
                            load = load,
                            api = {
                                log = function(_, message)
                                    error(message)
                                end,
                            },
                        })
                        getTime = previous
                        return scheduling
                    end
                    local scheduling = attach(context)
                    local function ready(target, scheduler)
                        local previous = getTime
                        getTime = function()
                            return radio.now
                        end
                        local ok, result = pcall(scheduler.ready, scheduler, target)
                        getTime = previous
                        assert(ok, result)
                        return assert(result)
                    end
                    local stable = owner:schedulerService(context)
                    local function settle(target, scheduler)
                        for _ = 1, 256 do
                            ready(target, scheduler)
                            if
                                not scheduler.reconciliation
                                and not scheduler.pendingPanels
                                and #scheduler.waiting == 0
                            then
                                return
                            end
                        end
                        error("actual broker enrollment did not finish")
                    end
                    local state = {
                        owner = owner,
                        context = context,
                        scheduling = scheduling,
                        stable = stable,
                        facade = facade,
                        action = action,
                        size = size,
                        ready = ready,
                        settle = settle,
                    }
                    if action == "enroll" or action == "enroll-next" or extra then
                        while not scheduling.reconciliation or scheduling.reconciliation.phase ~= "broker-enroll" do
                            ready(context, scheduling)
                        end
                        if action == "enroll-next" or action == "extra-kinds-final" then
                            ready(context, scheduling)
                        end
                    else
                        settle(context, scheduling)
                    end
                    if action ~= "enroll" and action ~= "enroll-next" and not extra then
                        assert(scheduling.scheduler:reschedule("service:flight", 47))
                        assert(scheduling.scheduler:reschedule("service:smart", 83))
                        if action == "registry-gap" then
                            context.serviceRuntime = nil
                        elseif action == "partial" then
                            context.serviceRuntime = { order = {}, byId = {} }
                        elseif action == "facade" then
                            state.replaced = registry(context)
                        elseif action == "model-reset" then
                            owner.taskService.failed, owner.failed = true, true
                            owner:reset("other.yml")
                            context.serviceRuntime = nil
                        elseif action == "session-reset" then
                            owner:resetSession(1)
                            context.serviceRuntime = nil
                        elseif action == "disable" or action == "handoff" then
                            owner:disableScheduler(context)
                            context.serviceRuntime = nil
                            if action == "handoff" then
                                settle(context, scheduling)
                                local replacement = {}
                                state.replaced = registry(replacement)
                                local nextScheduling = attach(replacement)
                                owner:enableScheduler(replacement)
                                state.previous = context
                                state.previousScheduling = scheduling
                                state.context, state.scheduling = replacement, nextScheduling
                                context, scheduling = replacement, nextScheduling
                            end
                        end
                    end
                    return {
                        step = function()
                            ready(context, scheduling)
                            return 1
                        end,
                    },
                        radio.now,
                        state
                end,
            }
        end
    end
    return { id = "host:broker-registration", decl = declaration, cases = cases }
end
