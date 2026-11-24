-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local panel = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)("panels/flight-counter.lua")
local detector = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/flight_service.lua"))()
local support = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
local flightConfig = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/flight_config.lua"))()

local function new()
    local settings = flightConfig.defaults()
    local context = {
        settings = settings,
        phase = "ground",
        feed = { available = true, raw = 39, precision = 0 },
        arm = { fresh = true, value = false, updatedAt = 0 },
        motor = { fresh = true, value = -1024, updatedAt = 0 },
        link = { live = true, updatedAt = 0 },
        logs = {},
        sounds = {},
    }
    context.control = {
        incrementFlightCount = function()
            context.feed.raw = context.feed.raw + 1
            return context.feed.raw
        end,
    }
    context.model = {
        flightDate = function()
            return "2026-10-06 16:00"
        end,
        logFlight = function(_, date, duration, count)
            context.logs[#context.logs + 1] = { date, duration, count }
        end,
        announceFlight = function(_, count, ended)
            context.sounds[#context.sounds + 1] = { count, ended }
        end,
    }
    local function step(now)
        context.arm.updatedAt, context.motor.updatedAt, context.link.updatedAt = now, now, now
        detector.advance(context, now, support.MAX_SAMPLE_AGE)
    end
    return context, step
end

local context, step = new()
equal(support.MAX_SAMPLE_AGE, 500, "cached sample limit is five seconds in 10 ms ticks")
for _, source in ipairs({ "arm", "motor", "link" }) do
    for _, age in ipairs({ -1, 100, 101, 499, 500, 501 }) do
        local candidate, start = new()
        candidate.settings.minFlightDuration = 1
        candidate.arm.value, candidate.motor.value = true, 0
        start(0)
        local now = 1000
        candidate.arm.updatedAt, candidate.motor.updatedAt, candidate.link.updatedAt = now, now, now
        candidate[source].updatedAt = now - age
        detector.advance(candidate, now, support.MAX_SAMPLE_AGE)
        equal(
            candidate.phase,
            age >= 0 and age <= 500 and "active" or "ground",
            source .. " must honor the inclusive five-second sample limit and reject future samples"
        )
    end
end
equal(#flightConfig.validate(context.settings), 0)
for _, age in ipairs({ -1, 0, 500, 501 }) do
    local candidate, advance = new()
    candidate.settings.disarmDuration = 1
    candidate.phase, candidate.arm.value, candidate.link.live = "active", false, false
    advance(0)
    local now = 1000
    candidate.arm.updatedAt = now
    candidate.link.updatedAt = now - age
    detector.advance(candidate, now, support.MAX_SAMPLE_AGE)
    equal(
        candidate.phase,
        age >= 0 and age <= 500 and "ground" or "ending",
        "completion requires a current receiver-disconnection observation, not stale or future data"
    )
end
step(0)
equal(context.phase, "ground")
context.arm.value, context.motor.value = true, 0
step(10)
equal(context.phase, "starting")
step(3009)
equal(context.feed.raw, 39, "must not count before 30 seconds")
step(3010)
equal(context.feed.raw, 40)
equal(context.phase, "active")
step(9000)
equal(context.feed.raw, 40, "an active flight must only count once")
context.link.live = false
step(10000)
equal(context.phase, "active", "telemetry loss must not end a flight")
context.arm.value = false
step(10100)
equal(context.phase, "ending")
step(11099)
equal(context.phase, "ending", "ten seconds of disarming are required")
equal(#context.logs, 0, "pending endings must not write history")
context.arm.value = true
step(11100)
equal(context.phase, "active", "rearming cancels the ending")
context.arm.value = false
step(12000)
step(12999)
equal(#context.logs, 0)
step(13000)
equal(context.phase, "ground")
equal(#context.logs, 0, "completed flights must not write CSV history")
equal(context.feed.raw, 40, "removing CSV history must preserve the counted flight")
step(15000)
equal(#context.logs, 0)
equal(context.feed.raw, 40, "completed flights must not count twice")

context, step = new()
context.arm.value, context.motor.value = true, 0
step(0)
context.link.live = false
step(1000)
equal(context.phase, "ground", "loss of any qualification input resets the attempt")
context.link.live = true
step(1500)
step(4499)
equal(context.feed.raw, 39)
step(4500)
equal(context.feed.raw, 40)
context.arm.value = false
step(5000)
context.arm.fresh = false
step(5999)
equal(context.phase, "active", "missing arm input must not mean disarmed")
context.arm.fresh = true
context.link.live = false
step(6000)
step(6999)
equal(context.phase, "ending")
step(7000)
equal(context.phase, "ground")

context, step = new()
context.settings.motorReversed = true
context.settings.announcements = true
context.settings.history = true
context.arm.value, context.motor.value = true, 1024
step(0)
equal(context.phase, "ground")
context.motor.value = 512 -- exactly 25% on a reversed channel
step(10)
equal(context.phase, "ground", "motor must be above the configured threshold")
context.motor.value = 0
step(20)
step(3020)
equal(context.feed.raw, 40)
equal(#context.sounds, 0, "legacy announcement settings must not play audio at qualification")
context.arm.value, context.link.live = false, false
step(4000)
step(5000)
equal(#context.logs, 0)
equal(context.phase, "ground", "legacy CSV settings must not affect completion")
equal(#context.sounds, 0, "legacy announcement settings must not play audio at completion")

context, step = new()
context.arm.value, context.motor.value = true, 0
step(0)
detector.advance(context, 3000, support.MAX_SAMPLE_AGE)
equal(context.phase, "ground", "old samples must not qualify a flight")
context.feed.raw = -1
assert(pcall(step, 4000), "flight detection does not validate or depend on external GVs")
for _, key in ipairs({ "minFlightDuration", "disarmDuration" }) do
    local settings = flightConfig.defaults()
    settings[key] = 0
    equal(#flightConfig.validate(settings), 1)
end
local threshold = flightConfig.defaults()
threshold.minMotorPercent = 100
equal(#flightConfig.validate(threshold), 1)
local settings, warnings = host.resolveSettings(panel, { label = "FLT" })
equal(#warnings, 0)
equal(settings.label, "FLT")
local _, rejected = host.resolveSettings(panel, { armSwitch = "SFv" })
assert(#rejected > 0, "Flight counter has no arm switch; the model Armed condition is used")
