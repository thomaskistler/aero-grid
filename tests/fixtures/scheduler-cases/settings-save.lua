-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local module = load("lib/model_settings_store.lua")
    local writer = load("lib/verified_file.lua")
    local config = load("lib/flight_config.lua")
    local armed = load("lib/armed_service.lua")
    local yaml = load("lib/yaml.lua")
    local memory = load("@support/memory_files.lua")
    local stages, cases = {}, {}
    for stage, bound in pairs(module.SAVE_BOUNDS) do
        stages[stage] = { fixed = 0, perUnit = bound, maxUnits = 1 }
    end
    for _, filename in ipairs({
        "a.yml", "model1.yml", string.rep("#", 27) .. ".yml",
        string.rep("\\", 27) .. ".yml", string.rep('"', 27) .. ".yml",
    }) do
        for _, mode in ipairs({ "missing", "primary", "recovered", "edited", "plain" }) do
            local function setup(seed)
                local files, operations = memory()
                local store = module.new("/WIDGETS/AeroGrid/", yaml, {
                    modelFilename = function() return filename end,
                    flightConfig = config, verifiedFile = writer, armedConfig = armed,
                }, operations)
                local values = config.defaults()
                values.motorSource = seed % 2 == 0 and "ch32" or "ch1"
                values.minFlightDuration, values.disarmDuration = 3600, 3600
                values.minMotorPercent, values.smartDetection = 99.75, true
                values.flightSwitch = "L64"
                local document = {
                    version = 1, revision = 1, modelFilename = filename,
                    armed = "!L64", sessionReset = "L03", flight = values,
                }
                local path = assert(module.path("/WIDGETS/AeroGrid/", filename))
                if mode == "edited" then
                    local deep = { leaf = true }
                    for _ = 1, 12 do deep = { child = deep } end
                    values.history = {
                        { name = string.rep('quoted \\" # ', 100), values = { 1, false, "entry" } },
                        { name = "second", nested = deep },
                    }
                    values.announcements = { "obsolete", "retained until validation" }
                end
                if mode ~= "missing" then files[path] = assert(yaml.serialize(document)) end
                if mode == "recovered" then
                    files[path .. ".bak"] = files[path]
                    document.version = 99
                    files[path] = assert(yaml.serialize(document))
                elseif mode == "edited" then
                    files[path] = string.rep("# retained comment\n", 32) .. files[path]
                elseif mode == "plain" then
                    files[path] = string.gsub(files[path], "flight:\n",
                        "flight:\n  history: " .. string.rep("a", 1024) .. " # obsolete value\n", 1)
                end
                return store, store:startSave(filename, mode == "missing" and 0 or 1, values, "!L64", "L03")
            end
            local store, job = setup(0)
            for index = 1, 1000 do
                local stage = job.stage
                cases[#cases + 1] = {
                    stage = stage, grant = 1,
                    setup = function(seed)
                        local measuredStore, measuredJob = setup(seed)
                        for _ = 1, index - 1 do assert(not measuredStore:advanceSave(measuredJob)) end
                        assert(measuredJob.stage == stage)
                        return { step = function()
                            local done, saved, result = measuredStore:advanceSave(measuredJob)
                            assert(not done or saved, result)
                            return 1
                        end }, 1000000
                    end,
                }
                local done, saved, result = store:advanceSave(job)
                if done then
                    assert(saved, result)
                    assert(result.flight.history == nil and result.flight.announcements == nil)
                    break
                end
                assert(index < 1000, "settings fixture did not finish")
            end
        end
    end
    return {
        id = "modal:settings-save",
        decl = { class = "normal", first = "read", kinds = { steady = true }, stages = stages },
        cases = cases,
    }
end
