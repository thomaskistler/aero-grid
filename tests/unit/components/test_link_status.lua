-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local linkStatus = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/link-status.lua"))()

local function testSourceClassification()
    assertions.assertEqual(linkStatus.classify(nil), "none")
    assertions.assertEqual(linkStatus.classify({ name = "" }), "none")
    assertions.assertEqual(linkStatus.classify({ name = "RSSI", known = false }), "absent")
    assertions.assertEqual(linkStatus.classify({ name = "RSSI", known = true }), "waiting")
    assertions.assertEqual(
        linkStatus.classify({ name = "RSSI", known = true, available = true, stale = true }),
        "stale"
    )
    assertions.assertEqual(linkStatus.classify({ name = "RSSI", known = true, available = true }), "live")

    assertions.assertEqual(linkStatus.primaryFor({ reading = "auto" }, "live", "live"), "quality")
    assertions.assertEqual(linkStatus.primaryFor({ reading = "auto" }, "live", "absent"), "rssi")
    assertions.assertEqual(linkStatus.primaryFor({ reading = "rssi" }, "absent", "live"), "rssi")
    assertions.assertEqual(linkStatus.primaryFor({ reading = "quality" }, "live", "absent"), "quality")
end

local function testLinkStates()
    local settings = { warning = 50, critical = 30 }
    local function state(reading)
        return linkStatus.resolveState(settings, reading)
    end

    assertions.assertEqual(state({ sourceState = "absent", linkDown = false }), "unavailable")
    assertions.assertEqual(state({ sourceState = "waiting", linkDown = true, available = false }), "unavailable")
    assertions.assertEqual(state({ sourceState = "live", linkDown = true, available = true, value = 96 }), "critical")
    assertions.assertEqual(state({ sourceState = "live", value = 96 }), "normal")
    assertions.assertEqual(state({ sourceState = "live", value = 44 }), "warning")
    assertions.assertEqual(state({ sourceState = "live", value = 0 }), "critical")
    assertions.assertEqual(state({ sourceState = "stale", value = 96 }), "stale")

    assertions.assertEqual(linkStatus.sourceText(nil, "none"), "--")
    assertions.assertEqual(linkStatus.sourceText({}, "absent"), "N/A")
    assertions.assertEqual(linkStatus.sourceText({ value = 78, precision = 0, unitText = "dB" }, "live"), "78dB")
    assertions.assertEqual(
        linkStatus.sourceText({ value = -72.4, precision = 1, unitText = "dBm" }, "live"),
        "-72.4dBm"
    )
end

local function testBarFraction()
    local settings = { barMin = -110, barMax = -30 }
    assertions.assertEqual(linkStatus.fraction(settings, -110), 0)
    assertions.assertEqual(linkStatus.fraction(settings, -30), 1)
    assert(math.abs(linkStatus.fraction(settings, -70) - 0.5) < 0.001)
    assertions.assertEqual(linkStatus.fraction(settings, -200), 0)
    assertions.assertEqual(linkStatus.fraction({ barMin = 0, barMax = 0 }, 5), 0)
end

local function run()
    testSourceClassification()
    testLinkStates()
    testBarFraction()
end

run()
