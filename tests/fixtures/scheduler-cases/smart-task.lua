-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local fixture = load("@support/scheduler_flight_fixture.lua")(load)
    local cases = {}
    for _, variant in ipairs({ "run", "discover", "dense", "stale", "changed", "error", "empty" }) do
        cases[#cases + 1] = {
            stage = "run",
            grant = 1,
            setup = function(seed)
                local owner, radio = fixture(variant, seed)
                return owner.tasks.smart, radio.now
            end,
        }
    end
    return { id = "service:smart", decl = load("lib/flight_service.lua").SMART_DECL, cases = cases }
end
