-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local support = load("lib/services.lua")
    local registration = load("lib/flight_registration.lua")
    local modules = {
        control = load("lib/control_service.lua"),
        armed = load("lib/armed_service.lua"),
    }
    local flight = load("@support/scheduler_flight_fixture.lua")(load)
    return function(variant, size, loadCase, modelFilename)
        local owner, radio, _, context = flight("run")
        local factory = { broker = owner, members = owner.members, revision = 1 }
        owner.factory, context.flightFactory = factory, factory
        context.modelFilename, context.layoutName = owner.filename, "Registration"
        context.document, context.flightSources, context.flightConfig = {}, {}, owner.config
        local runtime = support.runtime(owner.env)
        runtime.host, runtime.modules = context, modules
        if variant == "model" then
            runtime.modelArmed = "L02"
        end
        local control = modules.control.new(owner.env, support, runtime)
        support.register(runtime, control, radio.now)
        local armed = modules.armed.new(owner.env, support, runtime)
        support.register(runtime, armed, radio.now)
        context.serviceRuntime = runtime
        local original = { { source = "Previous", armKey = "L01" } }
        local member = factory.members[context]
        member.declarations, member.pending = original, true
        if variant ~= "empty" then
            context.document.legacyFlightArms = {}
            for index = 1, size do
                context.document.legacyFlightArms["old-" .. index] = "L01"
                context.flightSources[index] = {
                    id = "source-" .. index,
                    config = {
                        _legacyFlight = true,
                        armSwitch = index % 2 == 0 and "L02" or "L01",
                        minMotorPercent = index % 75,
                    },
                }
            end
        end
        if variant == "normal" or variant == "critical" then
            if variant == "normal" then
                control:displaySwitch("L01")
            else
                control:switch("L01")
            end
            for index = 1, size do
                if variant == "normal" then
                    control:displaySwitch("pending" .. index)
                else
                    control:switch("pending" .. index)
                end
            end
            control.criticalRemaining, control.normalRemaining = 3, 4
            control.criticalCursor, control.normalCursor = #control.criticalEntries, #control.normalEntries
            if control.criticalCursor == 0 then
                control.criticalCursor = 1
            end
            if control.normalCursor == 0 then
                control.normalCursor = 1
            end
        elseif variant == "cached" then
            armed:state("L01")
            armed:state("L02")
        end
        local state = {
            owner = owner,
            radio = radio,
            context = context,
            runtime = runtime,
            member = member,
            registration = registration,
            original = original,
            size = size,
            variant = variant,
        }
        if loadCase then
            if modelFilename then
                owner:reset(modelFilename)
                context.modelFilename, member.modelFilename = modelFilename, modelFilename
            end
            state.filename = owner.filename
            owner.env.getInfo = function()
                return { filename = state.filename }
            end
            local memory = load("@support/memory_files.lua")
            local storeModule, yaml = load("lib/model_settings_store.lua"), load("lib/yaml.lua")
            local files, operations = memory()
            local store = storeModule.new("/WIDGETS/AeroGrid/", yaml, {
                modelFilename = function()
                    return owner:identity()
                end,
                flightConfig = owner.config,
                armedConfig = modules.armed,
                verifiedFile = load("lib/verified_file.lua"),
            }, operations)
            local path = assert(storeModule.path("/WIDGETS/AeroGrid/", owner.filename))
            local document = {
                version = 1,
                modelFilename = owner.filename,
                revision = 4,
                armed = "L02",
                sessionReset = "L03",
                flight = owner.config.defaults(),
            }
            if loadCase == "obsolete" then
                document.flight.announcements, document.flight.history = true, true
                document.flight.smartDetection = nil
            elseif loadCase == "edited" then
                local nested = { leaf = true }
                for _ = 1, 12 do
                    nested = { child = nested }
                end
                document.flight.history = {
                    { name = string.rep('quoted \\" # ', 20), nested = nested },
                    { "a", false, 1 },
                }
                document.flight.announcements = { "obsolete" }
            end
            if loadCase ~= "missing" then
                files[path] = assert(yaml.serialize(document))
                if loadCase == "recovered" then
                    files[path .. ".bak"], files[path] = files[path], "version: 0\n"
                elseif loadCase == "schema0" then
                    files[path] = "version: 0\n"
                elseif loadCase == "large" then
                    files[path] = "# " .. string.rep("edited comment ", 200) .. "\n" .. files[path]
                elseif loadCase == "damaged" then
                    files[path], files[path .. ".bak"] = "version: [broken", "version: 0\n"
                elseif loadCase == "plain" then
                    files[path] = string.gsub(
                        files[path],
                        "flight:\n",
                        "flight:\n  history: " .. string.rep("a", 256) .. " # obsolete value\n",
                        1
                    )
                elseif loadCase == "read-error" then
                    operations.read = function()
                        error("injected read exception")
                    end
                elseif loadCase == "unreadable" then
                    operations.read = function()
                        return nil
                    end
                end
            end
            owner.document, owner.documentLoaded = nil, false
            state.store, state.files, state.path, state.loadCase = store, files, path, loadCase
            state.expected, state.expectedInfo = store:load(owner.filename)
            state.job = assert(registration.beginLoad(context, store))
        else
            state.job = assert(registration.begin(context))
        end
        return state
    end
end
