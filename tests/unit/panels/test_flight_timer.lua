-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local moduleLoader = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local timer = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/flight-timer.lua"))()
local primitives = moduleLoader("lib/primitives.lua")

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

    assertions.assertEqual(timer.displayValue(countdown), 90)

    countdown.showElapsed = true
    assertions.assertEqual(timer.displayValue(countdown), 210)
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
    assertions.assertEqual(timer.displayValue(countUp), 200)
    assertions.assertEqual(timer.detailText(countUp, tostring), "COUNTING UP")
    assertions.assertEqual(timer.fraction(countUp, primitives), 0)
    assertions.assertEqual(timer.fraction(countdown, primitives), 0.7)
    assertions.assertEqual(timer.resolveState({}, nil), "unavailable")
    assertions.assertEqual(timer.detailText(nil, tostring), "NO TIMER")

    local host = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
    for _, reading in ipairs({ "model", "elapsed", "remaining" }) do
        local _, warnings = host.resolveSettings(timer, { reading = reading })
        assertions.assertEqual(#warnings, 1)
        assertions.assertEqual(warnings[1], "reading is not a setting of this panel")
    end
end

local function testTimerBounds()
    assertions.assertEqual(timer.clamp(120), 120)
    assertions.assertEqual(timer.clamp(timer.CLAMP + 1), timer.CLAMP)
    assertions.assertEqual(timer.clamp(-timer.CLAMP - 1), -timer.CLAMP)
    assertions.assertEqual(timer.formatClock(90), "1:30")
    assertions.assertEqual(timer.formatClock(-90), "-1:30")
    assertions.assertEqual(timer.formatClock(nil), "--:--")
end

local function testTimerLabels()
    for index = 0, 2 do
        local context = { settings = { timer = index, label = "" } }
        local expected = "TIMER " .. tostring(index + 1)
        assertions.assertEqual(timer.labelText(context), expected)

        context.feed = { name = "" }
        assertions.assertEqual(timer.labelText(context), expected)

        context.feed.name = "Flight"
        assertions.assertEqual(timer.labelText(context), "Flight")

        context.settings.label = "Custom"
        assertions.assertEqual(timer.labelText(context), "Custom")

        context.settings.label = nil
        assertions.assertEqual(timer.labelText(context), "Flight")

        context.feed.name = nil
        assertions.assertEqual(timer.labelText(context), expected)
    end
end

local function testThresholdRegistration()
    local settings = { timer = 1, warning = 60, critical = 30 }
    assertions.assertEqual(#timer.thresholds(settings, {}), 0, "direction is unknown until the timer is read")
    local list = timer.thresholds(settings, { feed = { available = true, countdown = true } })
    assertions.assertEqual(list[1].sensor, "timer2")
    assertions.assertEqual(list[1].falling, true, "a countdown alarms on time left")
    list = timer.thresholds(settings, { feed = { available = true, countdown = false } })
    assertions.assertEqual(list[1].falling, false, "a count-up timer alarms on time used")
    assertions.assertEqual(#timer.thresholds({ timer = 0 }, { feed = { available = true } }), 0)
end

local function run()
    testThresholdRegistration()
    testTimerSemantics()
    testTimerBounds()
    testTimerLabels()
end

run()
