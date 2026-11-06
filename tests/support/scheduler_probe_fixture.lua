-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local support = load("lib/services.lua")
    local modules = {
        control = load("lib/control_service.lua"),
        model = load("lib/model_service.lua"),
        telemetry = load("lib/telemetry_service.lua"),
        navigation = load("lib/navigation_service.lua"),
    }
    return function(name, variant)
        local state = {
            available = true,
            known = true,
            name = "SOURCE",
            source = "GPS",
            state = "normal",
            value = 12.5,
            unitText = "V",
            precision = 1,
            age = 0,
            bitmap = "plane.png",
            text = "00:12",
            fix = true,
            home = true,
            latitude = 47.3769,
            longitude = 8.5417,
            distance = 1234.5,
            bearing = 99,
        }
        local view = support.snapshot(state)
        local service = setmetatable({
            support = support,
            entries = {},
            linkLive = true,
            identityView = view,
            flightModeView = view,
            txVoltageView = view,
            timers = { [0] = view, [1] = view, [2] = view },
            subscribe = function()
                return view
            end,
            identity = function()
                return view
            end,
            flightMode = function()
                return view
            end,
            txVoltage = function()
                return view
            end,
            timer = function()
                return view
            end,
            trim = function()
                return view
            end,
            globalVariable = function()
                return view
            end,
        }, { __index = assert(modules[name]) })
        if name == "control" then
            for index = 1, variant == 2 and 128 or 0 do
                service.entries[#service.entries + 1] = { state = { name = "S" .. index, available = true } }
            end
            for index = 1, 12 do
                local entry = {
                    state = {
                        name = "trim" .. index,
                        available = true,
                        value = index * 10,
                        fraction = index / 12,
                        threePosition = index % 2 == 0,
                    },
                }
                if index % 3 == 0 then
                    entry.read = modules.control.readOutput
                    entry.state.index = index
                elseif index % 3 == 1 then
                    entry.state.fraction, entry.state.index, entry.state.unitText = nil, index, "V"
                end
                service.entries[#service.entries + 1] = entry
            end
        end
        local function change(cycle)
            state.available, state.stale = cycle ~= 3, cycle == 4
            state.value, state.precision, state.age = cycle * 12.5, cycle % 4, cycle / 10
            state.state, state.name = cycle == 4 and "stale" or "normal", "SOURCE " .. cycle
            state.text, state.bitmap = "00:" .. cycle, "plane" .. cycle .. ".png"
            state.fix, state.home = cycle ~= 5, cycle ~= 6
            state.latitude, state.longitude, state.distance, state.bearing =
                47 + cycle / 100, 8 - cycle / 100, cycle * 2345.6, cycle * 40.1
            service.linkLive = cycle ~= 3
            for index, entry in ipairs(service.entries) do
                local reading = entry.state
                reading.available, reading.value = cycle ~= 3, cycle * index
                if reading.fraction ~= nil then
                    reading.fraction = cycle / 10
                end
            end
        end
        return service, change
    end
end
