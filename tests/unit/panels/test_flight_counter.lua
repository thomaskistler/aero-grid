-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local panel = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/flight-counter.lua"))()
local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()

local function new()
    local settings = host.resolveSettings(panel, {})
    local context = {
        settings = settings,
        phase = "ground",
        feed = { available = true, raw = 39, precision = 0 },
        arm = { fresh = true, value = 0, updatedAt = 0 },
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
        panel.advance(context, now)
    end
    return context, step
end

local context, step = new()
equal(#panel.validateSettings(context.settings), 0)
step(0)
equal(context.phase, "ground")
context.arm.value, context.motor.value = 1, 0
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
context.arm.value = 0
step(10100)
equal(context.phase, "ending")
step(11099)
equal(context.phase, "ending", "ten seconds of disarming are required")
equal(#context.logs, 0, "pending endings must not write history")
context.arm.value = 1
step(11100)
equal(context.phase, "active", "rearming cancels the ending")
context.arm.value = 0
step(12000)
step(12999)
equal(#context.logs, 0)
step(13000)
equal(context.phase, "ground")
equal(#context.logs, 1)
equal(context.logs[1][1], "2026-10-06 16:00")
equal(context.logs[1][2], 119.9, "duration excludes final disarm grace")
equal(context.logs[1][3], 40)
step(15000)
equal(#context.logs, 1, "completed flights must not log twice")

context, step = new()
context.arm.value, context.motor.value = 1, 0
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
context.arm.value = 0
step(5000)
context.arm.fresh = false
step(5999)
equal(context.phase, "active", "missing arm input must not mean disarmed")
context.arm.fresh = true
step(6000)
step(6999)
equal(context.phase, "ending")
step(7000)
equal(context.phase, "ground")

context, step = new()
context.settings.motorReversed = true
context.settings.announcements = true
context.settings.history = false
context.arm.value, context.motor.value = 1, 1024
step(0)
equal(context.phase, "ground")
context.motor.value = 512 -- exactly 25% on a reversed channel
step(10)
equal(context.phase, "ground", "motor must be above the configured threshold")
context.motor.value = 0
step(20)
step(3020)
equal(context.feed.raw, 40)
equal(#context.sounds, 1)
equal(context.sounds[1][2], false)
context.arm.value = 0
step(4000)
step(5000)
equal(#context.logs, 0)
equal(#context.sounds, 2)
equal(context.sounds[2][2], true)

context, step = new()
context.arm.value, context.motor.value = 1, 0
step(0)
panel.advance(context, 3000)
equal(context.phase, "ground", "old samples must not qualify a flight")
context.feed.raw = -1
local ok, err = pcall(step, 4000)
assert(not ok and string.find(err, "GV9 FM0", 1, true))
for _, key in ipairs({ "minFlightDuration", "disarmDuration" }) do
    local settings = host.resolveSettings(panel, { [key] = 0 })
    equal(#panel.validateSettings(settings), 1)
end
equal(#panel.validateSettings(host.resolveSettings(panel, { minMotorPercent = 100 })), 1)
for _, name in ipairs({ "SF^", "SA-", "SFv", "L01" }) do
    equal(#panel.validateSettings(host.resolveSettings(panel, { armSwitch = name })), 0)
end
for _, name in ipairs({ "sf", "SF", "SFx", "", "L1" }) do
    equal(#panel.validateSettings(host.resolveSettings(panel, { armSwitch = name })), 1)
end
