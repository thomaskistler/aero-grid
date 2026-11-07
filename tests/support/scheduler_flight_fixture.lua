-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local support = load("lib/services.lua")
    local flight = load("lib/flight_service.lua")
    local config = load("lib/flight_config.lua")
    local modules = {
        control = load("lib/control_service.lua"),
        telemetry = load("lib/telemetry_service.lua"),
        smart = load("lib/smart_flight.lua"),
    }
    return function(variant, seed, phase)
        local radio = { now = 1000, armed = false, altitude = 100, speed = 0, count = 39, sticky = false, fresh = true }
        local sensors = {
            { type = 0, id = 9, instance = 0, unit = 9, prec = 1 },
            { type = 0, id = 2, instance = 2, unit = 7, prec = 1 },
            { type = 0, id = 2, instance = 0, unit = 40, prec = 0 },
            { type = 0, id = 2, instance = 5, unit = 0, prec = 0 },
        }
        local env = {
            getInfo = function()
                return { filename = "model1.yml" }
            end,
            getTime = function()
                return radio.now
            end,
            getFieldInfo = function(name)
                local index = tonumber(string.match(name, "^telem(%d+)$"))
                return { id = index and 100 + index or 1, unit = index and sensors[index] and sensors[index].unit }
            end,
            getValue = function()
                return 0
            end,
            getRSSI = function()
                return 85
            end,
            getSwitchIndex = function(name)
                return tonumber(string.match(name, "^L(%d+)$"))
            end,
            getSwitchValue = function(index)
                if index == 20 then
                    return radio.sticky
                end
                return radio.armed
            end,
            getGlobalVariable = function()
                return radio.count
            end,
            getGlobalVariableDetails = function()
                return { min = 0, max = 999, prec = 0 }
            end,
            setGlobalVariable = function(_, _, value)
                radio.count = value
            end,
            getLogicalSwitch = function()
                return { func = 17 }
            end,
            setStickySwitch = function(_, value)
                radio.sticky = value
                return false
            end,
            getModule = function(index)
                return { Type = index == 0 and 5 or 0 }
            end,
            getSensor = function(index)
                return sensors[index + 1]
            end,
            getSourceValue = function(id)
                local values = { radio.altitude, radio.speed, { lat = 47, lon = 8, delay = 0 }, 12 }
                return values[id - 100], radio.fresh, radio.fresh
            end,
        }
        local owner = flight.newBroker(env, support, modules, config)
        local host = {}
        owner.context, owner.facade = setmetatable({ host }, { __mode = "v" }), { broker = owner }
        host.serviceRuntime = { byId = { flight = owner.facade } }
        owner:reset("model1.yml")
        local settings = config.resolve({
            smartDetection = true,
            minFlightDuration = 30,
            disarmDuration = 1,
            flightSwitch = "L20",
        })
        owner:setDocument({ revision = 1, flight = settings })
        owner.members[host] = {
            modelFilename = "model1.yml",
            layoutName = "Test",
            declarations = { { armKey = "L01", source = "Armed" } },
        }
        local proposal, signature, status
        for _ = 1, 16 do
            proposal, signature, status = owner:proposals(radio.now)
            if status == "ready" then
                break
            end
        end
        assert(status == "ready", "flight proposal did not complete")
        owner:attach(proposal, signature, radio.now)
        owner:enableScheduler(host)
        local smart = owner.smartRuntime.byId.smart
        if variant == "dense" then
            for index = 1, 60 do
                sensors[index] = { type = 0, id = 9, instance = 0, unit = 9, prec = 1 }
            end
        end
        if variant ~= "discover" and variant ~= "dense" then
            for n = 1, 8 do
                smart:update(n * 100)
            end
        elseif seed then
            for n = 1, seed - 1 do
                smart:update(n * 100)
            end
        end
        owner:tick(radio.now)
        owner.pumpedAt, owner.lastTick = nil, nil
        radio.now = 1100
        if variant == "configure" then
            owner.signature = nil
            owner:tick(1080)
            owner.tasks.run.stage = "configure"
        elseif variant == "start" then
            radio.armed = true
            owner.session.startedAt, owner.session.phase = -3000, "starting"
        elseif variant == "end" then
            owner.session.phase, owner.session.disarmedAt = "ending", 900
        elseif variant == "output" then
            owner.output = { name = "L20", armKey = "L01", desired = true, flightId = 1 }
        elseif variant == "stale" then
            radio.fresh = false
        elseif variant == "changed" then
            sensors[1].prec = 2
        elseif variant == "error" then
            env.getSourceValue = function()
                error("sensor failed")
            end
        elseif variant == "empty" then
            owner.smartRuntime, owner.session, owner.signature = nil, nil, nil
        elseif variant == "proposal" or variant == "conflict" then
            owner.factory = { revision = 1 }
            owner.fixtureMembers = {}
            for n = 1, 16 do
                local member = {}
                owner.fixtureMembers[n] = member
                owner.members[member] = {
                    modelFilename = "model1.yml",
                    layoutName = "Widget" .. n,
                    declarations = { { armKey = variant == "conflict" and "L" .. n or "L01", source = "Armed" } },
                }
            end
            owner:proposals(1080)
            radio.armed, owner.session.phase = true, "active"
            for n = 1, (phase or 1) - 1 do
                radio.now = 1080 + n * 20
                owner.tasks.run:step(1, owner.tasks.run.stage or "run", radio.now)
            end
            radio.now = 1080 + (phase or 1) * 20
        elseif variant == "telemetry" then
            owner.runtime.cursor = 1
        elseif variant == "count-error" then
            radio.armed = true
            owner.session.startedAt, owner.session.phase = -3000, "starting"
            env.setGlobalVariable = function()
                error("count failed")
            end
        elseif variant == "output-full" then
            owner.output = { name = "L20", armKey = "L01", desired = true, flightId = 1 }
            env.setStickySwitch = function()
                return true
            end
        end
        return owner, radio, sensors, host
    end
end
