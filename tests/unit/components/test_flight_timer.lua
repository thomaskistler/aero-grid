-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local timer = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/flight-timer.lua"))()

local function testTimerSemantics()
    local countdown = {
        available = true,
        countdown = true,
        value = 90,
        start = 300,
        elapsed = 210,
        remaining = 90,
        expired = false,
        showElapsed = false,
    }

    assertions.assertEqual(timer.displayValue({ reading = "model" }, countdown), 90)
    assertions.assertEqual(timer.displayValue({ reading = "elapsed" }, countdown), 210)
    assertions.assertEqual(timer.displayValue({ reading = "remaining" }, countdown), 90)

    countdown.showElapsed = true
    assertions.assertEqual(timer.displayValue({ reading = "model" }, countdown), 210)
    assertions.assertEqual(timer.resolveState({}, countdown), "normal")
    assertions.assertEqual(timer.resolveState({ warning = 120 }, countdown), "warning")
    assertions.assertEqual(timer.resolveState({ critical = 120 }, countdown), "critical")

    local expired = {
        available = true,
        countdown = true,
        value = -12,
        start = 300,
        elapsed = 312,
        remaining = -12,
        expired = true,
    }
    assertions.assertEqual(timer.resolveState({}, expired), "critical")
    assertions.assertEqual(timer.detailText(expired, tostring), "EXPIRED")

    local countUp = {
        available = true,
        countdown = false,
        value = 200,
        start = 0,
        elapsed = 200,
        remaining = 0,
        expired = false,
    }
    assertions.assertEqual(timer.resolveState({ warning = 180 }, countUp), "warning")
    assertions.assertEqual(timer.fraction(countUp), 0)
    assertions.assertEqual(timer.fraction(countdown), 0.7)
    assertions.assertEqual(timer.resolveState({}, nil), "unavailable")
    assertions.assertEqual(timer.detailText(nil, tostring), "NO TIMER")
end

local function testTimerBounds()
    assertions.assertEqual(timer.clamp(120), 120)
    assertions.assertEqual(timer.clamp(timer.CLAMP + 1), timer.CLAMP)
    assertions.assertEqual(timer.clamp(-timer.CLAMP - 1), -timer.CLAMP)
    assertions.assertEqual(timer.formatClock(90), "1:30")
    assertions.assertEqual(timer.formatClock(-90), "-1:30")
    assertions.assertEqual(timer.formatClock(nil), "--:--")
end

local function run()
    testTimerSemantics()
    testTimerBounds()
end

run()
