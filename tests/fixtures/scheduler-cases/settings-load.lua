-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local module = load("lib/model_settings_store.lua")
    local writer = load("lib/verified_file.lua")
    local config = load("lib/flight_config.lua")
    local armed = load("lib/armed_service.lua")
    local yaml = load("lib/yaml.lua")
    local memory = load("@support/memory_files.lua")
    local stages, cases = {}, {}
    for stage, bound in pairs(module.LOAD_BOUNDS) do
        stages[stage] = { fixed = 0, perUnit = bound, maxUnits = 1 }
    end
    for _, filename in ipairs({
        "a.yml", "model1.yml", string.rep("#", 27) .. ".yml",
        string.rep("\\", 27) .. ".yml", string.rep('"', 27) .. ".yml",
    }) do
        for _, mode in ipairs({
            "missing", "primary", "recovered", "edited", "plain", "invalid", "backup-only", "read-error", "unreadable",
        }) do
            local function setup(seed)
                local files, operations = memory()
                local state = { filename = filename }
                local store = module.new("/WIDGETS/AeroGrid/", yaml, {
                    modelFilename = function()
                        if state.identityError then error("identity unavailable") end
                        return state.filename
                    end,
                    flightConfig = config, verifiedFile = writer, armedConfig = armed,
                }, operations)
                local values = config.defaults()
                values.motorSource = seed % 2 == 0 and "ch32" or "ch1"
                values.minFlightDuration, values.disarmDuration = 3600, 3600
                values.minMotorPercent, values.smartDetection, values.flightSwitch = 99.75, true, "L64"
                if mode == "edited" then
                    local deep = { leaf = true }
                    for _ = 1, 12 do deep = { child = deep } end
                    values.history = {
                        { name = string.rep('quoted \\" # ', 100), values = { 1, false, "entry" } },
                        { name = "second", nested = deep },
                    }
                    values.announcements = { "obsolete", "retained until validation" }
                end
                local document = {
                    version = 1, revision = 7, modelFilename = filename,
                    armed = "!L64", sessionReset = "L03", flight = values,
                }
                local path = assert(module.path("/WIDGETS/AeroGrid/", filename))
                if mode ~= "missing" then files[path] = assert(yaml.serialize(document)) end
                if mode == "recovered" or mode == "backup-only" then
                    files[path .. ".bak"] = files[path]
                    files[path] = mode == "recovered" and "version: 0\n" or nil
                elseif mode == "invalid" then
                    files[path], files[path .. ".bak"] = "version: 0\n", "invalid: [yaml"
                elseif mode == "edited" then
                    files[path] = string.rep("# retained comment\n", 32) .. files[path]
                elseif mode == "plain" then
                    files[path] = string.gsub(files[path], "flight:\n",
                        "flight:\n  history: " .. string.rep("a", 1024) .. " # obsolete value\n", 1)
                elseif mode == "read-error" then
                    operations.read = function() error("injected read exception") end
                elseif mode == "unreadable" then
                    operations.read = function() return nil end
                end
                return store, state, files, path
            end
            cases[#cases + 1] = {
                stage = "start", grant = 1,
                setup = function(seed)
                    local store = setup(seed)
                    return { step = function() assert(store:startLoad(filename)); return 1 end }, 1000000
                end,
            }
            local store = setup(0)
            local job = assert(store:startLoad(filename))
            for index = 1, 2000 do
                local stage = job.stage
                for _, failure in ipairs({ "none", "model", "identity" }) do
                    cases[#cases + 1] = {
                        stage = stage, grant = 1,
                        setup = function(seed)
                            local measured, state, files, path = setup(seed)
                            local pending = assert(measured:startLoad(filename))
                            for _ = 1, index - 1 do assert(not measured:advanceLoad(pending)) end
                            assert(pending.stage == stage)
                            if failure == "model" then state.filename = "other.yml" end
                            if failure == "identity" then state.identityError = true end
                            local primary, backup = files[path], files[path .. ".bak"]
                            return { step = function()
                                local done, document, info = measured:advanceLoad(pending)
                                if failure ~= "none" or mode == "invalid" or mode == "read-error" or mode == "unreadable" then
                                    assert(not document and (not done or type(info) == "string"))
                                elseif done then
                                    assert(document.revision == (mode == "missing" and 0 or 7))
                                    assert(info.filename == path .. ((mode == "recovered" or mode == "backup-only")
                                        and ".bak" or ""))
                                    assert(document.flight == nil or document.flight.history == nil)
                                end
                                assert(files[path] == primary and files[path .. ".bak"] == backup)
                                return 1
                            end }, 1000000
                        end,
                    }
                end
                local done, document, info = store:advanceLoad(job)
                if done then
                    assert(document or mode == "invalid" or mode == "read-error" or mode == "unreadable", info)
                    cases[#cases + 1] = {
                        stage = stage, grant = 1,
                        setup = function(seed)
                            local measured, state = setup(seed)
                            local finished = assert(measured:startLoad(filename))
                            while not measured:advanceLoad(finished) do end
                            state.identityError = true
                            return { step = function()
                                assert(measured:advanceLoad(finished))
                                return 1
                            end }, 1000000
                        end,
                    }
                    break
                end
                assert(index < 2000, "settings reader fixture did not finish")
            end
            for _, failure in ipairs({ "model", "identity" }) do
                cases[#cases + 1] = {
                    stage = "start", grant = 1,
                    setup = function(seed)
                        local measured, state = setup(seed)
                        if failure == "model" then state.filename = "other.yml" end
                        if failure == "identity" then state.identityError = true end
                        return { step = function()
                            local pending, message = measured:startLoad(filename)
                            assert(not pending and type(message) == "string")
                            return 1
                        end }, 1000000
                    end,
                }
            end
        end
    end
    return {
        id = "modal:settings-load",
        decl = { class = "normal", first = "read", kinds = { steady = true }, stages = stages },
        cases = cases,
    }
end
