-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local fixture = load("@support/scheduler_registration_fixture.lua")(load)
    local bounds = load("lib/flight_registration.lua").BOUNDS
    local stages, cases = {}, {}
    for _, stage in ipairs({ "begin", "retained", "sources", "arms", "claim", "declaration", "commit", "reject" }) do
        stages[stage] = { fixed = 0, perUnit = bounds[stage], maxUnits = 1 }
    end
    for _, variant in ipairs({ "empty", "legacy", "model", "normal", "critical", "cached" }) do
        for _, size in ipairs({ 1, 16, 128 }) do
            for _, stage in ipairs({
                "begin",
                "retained",
                "sources",
                "arms",
                "claim",
                "declaration",
                "commit",
                "reject",
            }) do
                if stage ~= "claim" or variant ~= "empty" and variant ~= "cached" then
                    for phase = 1, (stage == "claim" and 3 or 1) do
                        cases[#cases + 1] = {
                            stage = stage,
                            grant = 1,
                            setup = function()
                                local state = fixture(variant, size)
                                local registration, job = state.registration, state.job
                                if stage ~= "begin" and stage ~= "reject" then
                                    for _ = 1, size * 15 + 50 do
                                        if job.stage == stage then
                                            break
                                        end
                                        local done, ok, message = registration.advance(job)
                                        assert(not done or ok, message)
                                    end
                                    assert(job.stage == stage, "registration did not reach " .. stage)
                                    if stage == "claim" then
                                        for _ = 2, phase do
                                            registration.advance(job)
                                        end
                                    end
                                elseif stage == "reject" then
                                    state.context.document = {}
                                end
                                return {
                                    stage = stage,
                                    step = function()
                                        if stage == "begin" then
                                            assert(registration.begin(state.context))
                                        else
                                            state.done, state.ok, state.error = registration.advance(job)
                                        end
                                        return 1
                                    end,
                                },
                                    state.radio.now,
                                    state
                            end,
                        }
                    end
                end
            end
        end
    end
    return {
        id = "flight:registration",
        decl = { class = "normal", first = "begin", stages = stages },
        cases = cases,
    }
end
