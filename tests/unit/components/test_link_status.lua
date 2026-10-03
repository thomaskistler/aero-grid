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

local function feed(name, value, unit)
    return { name = name, value = value, unitText = unit, known = true, available = true, precision = 0 }
end

local function elrsContext()
    return {
        settings = {
            protocol = "elrs4",
            reading = "auto",
            rssiSource = "1RSS",
            qualitySource = "RQly",
            modeSource = "RFMD",
            qualityWarning = 90,
            qualityCritical = 70,
            marginWarning = 10,
            marginCritical = 5,
        },
        readingCache = {},
        rssiFeed = feed("1RSS", -98, "dB"),
        qualityFeed = feed("RQly", 100, "%"),
        modeFeed = feed("RFMD", 27, ""),
        link = { live = true, indicator = true, rssi = 60 },
    }
end

local function testElrsModes()
    local expected = {
        [0] = -123,
        [1] = -120,
        [2] = -117,
        [3] = -112,
        [5] = -112,
        [6] = -111,
        [7] = -111,
        [10] = -112,
        [11] = -101,
        [21] = -115,
        [23] = -112,
        [24] = -112,
        [27] = -108,
        [28] = -105,
        [29] = -105,
        [30] = -104,
        [31] = -104,
        [32] = -104,
        [33] = -104,
        [34] = -103,
        [35] = -103,
        [36] = -103,
    }
    for index, sensitivity in pairs(expected) do
        assertions.assertEqual(linkStatus.modeFor(index)[2], sensitivity, "RFMD " .. index)
    end
    for _, index in ipairs({ -1, 4, 8, 9, 20, 22, 25, 26, 37, 255, 27.5 }) do
        assertions.assertEqual(linkStatus.modeFor(index), nil)
    end
    assertions.assertEqual(linkStatus.modeFor(nil), nil)
    assertions.assertEqual(linkStatus.modeFor(100)[2], nil)
    assertions.assertEqual(linkStatus.modeFor(101)[2], nil)

    local context = elrsContext()
    local reading = linkStatus.read(context)
    assertions.assertEqual(reading.margin, 10)
    assertions.assertEqual(reading.mode[1], "250Hz")
    context.modeFeed.value = 21
    assertions.assertEqual(linkStatus.read(context).margin, 17)
    context.modeFeed.value = 0
    assertions.assertEqual(linkStatus.read(context).margin, 25, "RFMD zero is valid 900MHz 25Hz")
    for _, index in ipairs({ 255, 27.5, 100, 101 }) do
        context.modeFeed.value = index
        assertions.assertEqual(linkStatus.read(context).margin, nil)
    end
    context.modeFeed.value = 27
    for _, property in ipairs({ "stale", "available", "known" }) do
        context.modeFeed[property] = property == "stale"
        assertions.assertEqual(linkStatus.read(context).margin, nil)
        context.modeFeed[property] = property ~= "stale"
    end
    context.rssiFeed.stale = true
    assertions.assertEqual(linkStatus.read(context).margin, nil)
    context.rssiFeed.stale = false
    context.rssiFeed.unitText = "%"
    assertions.assertEqual(linkStatus.read(context).margin, nil)
    context.rssiFeed.unitText = "dBm"
    context.link.live = false
    assertions.assertEqual(linkStatus.read(context).margin, nil)
    context.link.live = true
    context.settings.protocol = "generic"
    assertions.assertEqual(linkStatus.read(context).margin, nil)
end

local function testIndependentAlarms()
    local context = elrsContext()
    local function state()
        local reading = linkStatus.read(context)
        return linkStatus.resolveState(context.settings, reading), reading.cause
    end
    assertions.assertEqual(state(), "warning", "margin warning includes boundary")
    context.rssiFeed.value = -97
    assertions.assertEqual(state(), "normal")
    context.rssiFeed.value = -103
    local severity, cause = state()
    assertions.assertEqual(severity, "critical", "margin critical includes boundary")
    assertions.assertEqual(cause, "LOW MARGIN")
    context.qualityFeed.value = 90
    severity, cause = state()
    assertions.assertEqual(severity, "critical", "margin critical wins over LQ warning")
    assertions.assertEqual(cause, "LOW MARGIN")
    context.rssiFeed.value = -98
    context.qualityFeed.value = 70
    severity, cause = state()
    assertions.assertEqual(severity, "critical", "LQ critical wins over margin warning")
    assertions.assertEqual(cause, "LOW LQ")
    context.modeFeed.stale = true
    assertions.assertEqual(state(), "critical", "stale RFMD cannot suppress live low LQ")
    context.qualityFeed.value = 100
    assertions.assertEqual(state(), "normal", "stale RFMD cannot trigger a margin alarm")
    context.modeFeed.stale = false
    context.qualityFeed.stale = true
    context.rssiFeed.value = -103
    assertions.assertEqual(state(), "critical", "live margin alarm wins over stale primary")
    context.rssiFeed.stale = true
    assertions.assertEqual(state(), "stale")
    context.link.live = false
    assertions.assertEqual(state(), "critical")
end

local function testValidation()
    local settings = elrsContext().settings
    assertions.assertEqual(#linkStatus.validateSettings(settings), 0)
    settings.marginCritical = 11
    assert(#linkStatus.validateSettings(settings) > 0)
    settings.marginCritical = 5
    settings.protocol = "generic"
    assert(#linkStatus.validateSettings(settings) > 0)
    settings.marginWarning, settings.marginCritical = nil, nil
    settings.qualityWarning = 101
    assert(#linkStatus.validateSettings(settings) > 0)
    settings.qualityWarning = 90
    settings.qualitySource = ""
    assert(#linkStatus.validateSettings(settings) > 0)
end

local function run()
    testSourceClassification()
    testLinkStates()
    testBarFraction()
    testElrsModes()
    testIndependentAlarms()
    testValidation()
end

run()
