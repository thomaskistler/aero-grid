-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local fixture = load("@support/scheduler_registration_fixture.lua")(load)
    local registration = load("lib/flight_registration.lua")
    local stages, cases = {}, {}
    for _, name in ipairs({ "load-begin", "load-start", "publish-start", "publish" }) do
        stages[name] = { fixed = 0, perUnit = registration.BOUNDS[name], maxUnits = 1 }
    end
    for name, bound in pairs(load("lib/model_settings_store.lua").LOAD_BOUNDS) do
        if name ~= "start" then
            stages[name] = { fixed = 0, perUnit = bound + 300, maxUnits = 1 }
        end
    end
    local function stage(job)
        return job.stage == "load" and job.load.stage or job.stage
    end
    for _, filename in ipairs({ "model1.yml", string.rep('"', 27) .. ".yml" }) do
        for _, scenario in ipairs({
            "missing",
            "valid",
            "recovered",
            "obsolete",
            "large",
            "schema0",
            "damaged",
            "edited",
            "plain",
            "read-error",
            "unreadable",
        }) do
            cases[#cases + 1] = {
                stage = "load-begin",
                grant = 1,
                setup = function()
                    local state = fixture("empty", 1, scenario, filename)
                    return {
                        stage = "load-begin",
                        step = function()
                            assert(registration.beginLoad(state.context, state.store))
                            return 1
                        end,
                    },
                        state.radio.now
                end,
            }
            local blueprint = fixture("empty", 1, scenario, filename)
            for index = 1, 2000 do
                local name = stage(blueprint.job)
                cases[#cases + 1] = {
                    stage = name,
                    grant = 1,
                    setup = function()
                        local state = fixture("empty", 1, scenario, filename)
                        for _ = 1, index - 1 do
                            assert(not registration.advance(state.job))
                        end
                        assert(stage(state.job) == name)
                        return {
                            stage = name,
                            step = function()
                                state.bound = registration.workBound(state.job)
                                state.done, state.ok, state.error = registration.advance(state.job)
                                return 1
                            end,
                        },
                            state.radio.now,
                            state
                    end,
                }
                if registration.advance(blueprint.job) then
                    break
                end
                assert(index < 2000, "configuration load fixture did not finish")
            end
        end
    end
    return {
        id = "flight:registration-load",
        decl = { class = "normal", first = "read", stages = stages },
        cases = cases,
    }
end
