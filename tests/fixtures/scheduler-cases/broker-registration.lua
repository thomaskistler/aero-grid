-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    return load("@support/scheduler_broker_registration.lua")(load)
end
