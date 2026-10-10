-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local loadModule = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local services = loadModule("lib/services.lua")
local env = services.environment({
    getSwitchIndex = function()
        return 1
    end,
    getSwitchValue = function()
        return false
    end,
})
local runtime = services.runtime(env)
local telemetry = loadModule("lib/telemetry_service.lua").new(env, services)
services.register(runtime, telemetry, 0)
local reading = telemetry:subscribe("RxBt")
assert(telemetry:subscribe("RxBt") == reading and telemetry.count == 1)
assert(#telemetry.entries == 1 and telemetry.entries[1].view == reading)

local control = loadModule("lib/control_service.lua").new(env, services)
local trim = control:trim("trim-ail")
assert(control:trim("trim-ail") == trim and control.count == 1)
assert(#control.entries == 1 and control.entries[1].view == trim)

local modelService = loadModule("lib/model_service.lua").new(env, services)
local timer = modelService:timer(0)
assert(modelService:timer(0) == timer and modelService.count == 1)
assert(#modelService.facets == 1 and modelService.facets[1].view == timer)

local navigation = loadModule("lib/navigation_service.lua").new(env, services, runtime)
local position = navigation:subscribe("GPS")
assert(navigation:subscribe("GPS") == position and navigation.count == 1)
assert(#navigation.entries == 1 and navigation.entries[1].view == position)

local extrema = loadModule("lib/extrema_service.lua").new(env, services, runtime)
local track = extrema:sessionExtrema("Alt")
assert(extrema:sessionExtrema("Alt") == track and extrema.count == 1)
assert(#extrema.trackOrder == 1 and extrema.trackOrder[1].view == track)
