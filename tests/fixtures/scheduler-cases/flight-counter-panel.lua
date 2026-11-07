-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    return load("@support/scheduler_flight_readout.lua")(load, "flight-counter")
end
