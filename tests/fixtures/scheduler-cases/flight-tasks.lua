-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local fixture = load("@support/scheduler_flight_fixture.lua")(load)
    local cases = {}
    for _, variant in ipairs({
        "run",
        "configure",
        "start",
        "end",
        "output",
        "empty",
        "telemetry",
        "count-error",
        "output-full",
    }) do
        cases[#cases + 1] = {
            stage = variant == "configure" and "configure" or "run",
            grant = 1,
            setup = function(seed)
                local owner, radio = fixture(variant, seed)
                return owner.tasks.run, radio.now
            end,
        }
    end
    for _, variant in ipairs({ "proposal", "conflict" }) do
        for _, phase in ipairs({ 1, 2, 3, 4, 50, 52, 60, 100, 150, 200, 225 }) do
            cases[#cases + 1] = {
                stage = "run",
                grant = 1,
                setup = function(seed)
                    local owner, radio = fixture(variant, seed, phase)
                    return owner.tasks.run, radio.now
                end,
            }
        end
    end
    return { id = "service:flight", decl = load("lib/flight_service.lua").TICK_DECL, cases = cases }
end
