-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local brokerCases = load("@support/scheduler_broker_registration.lua")(load)
    local support, telemetryModule = load("lib/services.lua"), load("lib/telemetry_service.lua")
    local hostModule = load("lib/scheduler_host.lua")
    local stages, cases = {}, {}
    local actions = {
        "begin",
        "canonical",
        "broker",
        "service",
        "retained",
        "panel",
        "panel-retained",
        "complete",
        "enroll-source",
        "enroll-maintenance",
        "replace",
        "remove",
        "remove-panel",
        "reset",
        "steady",
    }
    local function prepare(total)
        local _, _, state = brokerCases.cases[1].setup()
        local context, host = state.context, state.scheduling
        state.settle(context, host)
        assert(host.scheduler:reschedule("service:flight", 47))
        assert(host.scheduler:reschedule("service:smart", 83))
        local telemetry = telemetryModule.new(state.owner.env, support)
        for index = 1, total - 3 do
            telemetry:subscribe("Source" .. index, false)
        end
        context.serviceRuntime = { order = { telemetry }, byId = { telemetry = telemetry } }
        for index = 1, 16 do
            context.panels[index] = {
                placement = { id = "idle-" .. index },
                module = { id = "sample", idle = true },
                instance = {},
            }
        end
        context.panelTasksDirty = true
        state.telemetry, state.total = telemetry, total
        state.untilReady = function(predicate)
            for _ = 1, total * 8 + 128 do
                if predicate(host.reconciliation) then
                    return
                end
                state.ready(context, host)
            end
            error("bounded readiness did not reach its target")
        end
        state.reconciled = function()
            state.untilReady(function()
                return not host.reconciliation
                    and host.checked == context.panels
                    and host.registry == context.serviceRuntime
                    and not context.panelTasksDirty
            end)
        end
        return state
    end
    for _, total in ipairs({ 30, 128 }) do
        for _, action in ipairs(actions) do
            stages[action] = {
                fixed = 0,
                perUnit = string.sub(action, 1, 6) == "enroll" and hostModule.SERVICE_ENROLL_COST
                    or hostModule.RECONCILE_COST,
                maxUnits = 1,
            }
            cases[#cases + 1] = {
                stage = action,
                grant = 1,
                setup = function()
                    local state = prepare(total)
                    local context, host, telemetry = state.context, state.scheduling, state.telemetry
                    if action == "begin" then
                        -- The registry and 16 panel contracts have not been scanned.
                    elseif action == "reset" then
                        for index in ipairs(telemetry.schedulerTasks) do
                            host:resetServiceRelease(telemetry, 17, index)
                        end
                        context.serviceRuntime = nil
                        state.untilReady(function(job)
                            return job and job.phase == "retire-resets"
                        end)
                    elseif
                        action == "replace"
                        or action == "remove"
                        or action == "remove-panel"
                        or action == "steady"
                    then
                        state.reconciled()
                        state.settle(context, host)
                        assert(host.scheduler.count == total)
                        if action == "replace" then
                            local replacement = telemetryModule.new(state.owner.env, support)
                            for index = 1, total - 3 do
                                replacement:subscribe("Replacement" .. index, false)
                            end
                            context.serviceRuntime = { order = { replacement }, byId = { telemetry = replacement } }
                            state.untilReady(function(job)
                                return job and job.phase == "services" and job.index == 1
                            end)
                        elseif action == "remove" then
                            context.serviceRuntime = nil
                            state.untilReady(function(job)
                                return job and job.phase == "retire-services"
                            end)
                            local id = next(host.registeredTasks)
                            while host.registeredTasks[id] == state.stable do
                                id = next(host.registeredTasks, id)
                            end
                            assert(host.scheduler:reschedule(id, 100000))
                            state.untilReady(function(job)
                                return job
                                    and job.phase == "retire-services"
                                    and next(host.registeredTasks, job.cursor) == id
                            end)
                            state.removedId = id
                        elseif action == "remove-panel" then
                            context.panels = {}
                            state.untilReady(function(job)
                                return job and job.phase == "retire-panels"
                            end)
                        end
                    elseif action == "enroll-source" or action == "enroll-maintenance" then
                        state.reconciled()
                        if action == "enroll-maintenance" then
                            state.untilReady(function()
                                return #host.waiting == 1
                            end)
                        end
                    else
                        state.untilReady(function(job)
                            if not job then
                                return false
                            elseif action == "canonical" then
                                return job.phase == "services" and job.index == 0 and job.taskIndex == 2
                            elseif action == "broker" then
                                return job.phase == "broker-enroll"
                            elseif action == "service" then
                                return job.phase == "services" and job.index == 1 and job.taskIndex == 2
                            elseif action == "retained" then
                                return job.phase == "retire-services"
                            elseif action == "panel" then
                                return job.phase == "panels" and job.index == 16
                            elseif action == "panel-retained" then
                                return job.phase == "retire-panels"
                            elseif action == "complete" then
                                return job.phase == "retire-panels"
                                    and job.cursor
                                    and next(host.panelEntries, job.cursor) == nil
                            end
                        end)
                    end
                    state.action = action
                    return {
                        step = function()
                            state.ready(context, host)
                            return 1
                        end,
                    },
                        0,
                        state
                end,
            }
        end
    end
    return {
        id = "host:readiness",
        decl = { class = "normal", first = "begin", stages = stages },
        cases = cases,
        prepare = prepare,
    }
end
