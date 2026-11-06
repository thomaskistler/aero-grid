-- SPDX-License-Identifier: GPL-2.0-only

return function(load, builder, only)
    local host = load("lib/panel_host.lua")
    assert(builder, "construction cases need a configured theme builder")
    local primitives = load("lib/primitives.lua")
    local cases = {}
    local variants = {
        metric = { "none", "bar", "radial" },
        ["link-status"] = { "none", "bar" },
        ["rx-battery"] = { "none", "bar", "battery" },
        ["tx-battery"] = { "none", "bar", "battery" },
        ["flight-timer"] = { "none" },
    }
    for kind, visuals in pairs(variants) do
        if not only or kind == only then
            local panel = load("panels/" .. kind .. ".lua")
            for _, mode in ipairs({ "modern-dark", "modern-light" }) do
                local theme = builder.build(mode)
                for _, shape in ipairs({
                    { 1, 1, 90, 50 },
                    { 1, 1, 117, 65 },
                    { 1, 2, 117, 134 },
                    { 1, 3, 117, 203 },
                    { 2, 1, 238, 65 },
                    { 2, 3, 238, 203 },
                    { 2, 4, 238, 272 },
                    { 3, 1, 359, 65 },
                    { 3, 2, 359, 134 },
                    { 3, 3, 359, 203 },
                    { 3, 4, 359, 272 },
                    { 4, 1, 800, 90 },
                    { 4, 2, 480, 134 },
                    { 4, 3, 480, 203 },
                    { 1, 4, 160, 480 },
                    { 2, 2, 238, 134 },
                    { 4, 4, 800, 480 },
                }) do
                    for _, visual in ipairs(visuals) do
                        for variant = 1, 4 do
                            local config = {
                                visual = visual,
                                label = kind == "flight-timer" and variant == 4 and "" or "READING",
                                metrics = {
                                    { source = "Alt", unit = variant == 4 and "" or "mAh", precision = 3 },
                                    { source = "Alt", label = "LOW" },
                                    { source = "Alt", label = "HIGH" },
                                },
                                protocol = variant == 4 and "frsky" or "elrs4",
                                reading = kind == "link-status" and (variant == 4 and "rssi" or "quality")
                                    or variant == 4 and "pack"
                                    or "cell",
                                rssiSource = "1RSS",
                                qualitySource = "RQly",
                                modeSource = "RFMD",
                                snrSource = "RSNR",
                                powerSource = "TPWR",
                                extrema = variant == 4 and "source" or "none",
                                source = "Cels",
                                showCount = true,
                                showPack = true,
                                showDelta = true,
                                showPercent = variant ~= 4,
                                packEmpty = 6.4,
                                packFull = 8.4,
                            }
                            local resolution = host.beginSettings(panel, config)
                            while not host.advanceSettings(resolution) do
                            end
                            local settings, proof = resolution.settings, resolution.proof
                            cases[#cases + 1] = {
                                panel = panel,
                                settingsValidation = proof,
                                kind = kind,
                                variant = variant,
                                rect = { x = 0, y = 0, w = shape[3], h = shape[4] },
                                name = kind
                                    .. "/"
                                    .. mode
                                    .. "/"
                                    .. shape[1]
                                    .. "x"
                                    .. shape[2]
                                    .. "/"
                                    .. visual
                                    .. "/"
                                    .. variant,
                                dependencies = function()
                                    local feeds = {}
                                    local function subscribe(_, source)
                                        if not feeds[source] then
                                            local values = {
                                                Alt = 98765.432,
                                                Cels = variant == 4 and 64
                                                    or {
                                                        4.2,
                                                        4.1,
                                                        4.0,
                                                        3.9,
                                                        3.8,
                                                        3.7,
                                                        3.6,
                                                        3.5,
                                                        3.4,
                                                        3.3,
                                                        3.2,
                                                        3.1,
                                                        3.0,
                                                        2.9,
                                                        2.8,
                                                        2.7,
                                                    },
                                                RQly = 98,
                                                ["1RSS"] = -108,
                                                RFMD = 6,
                                                RSNR = 8,
                                                TPWR = 1000,
                                            }
                                            feeds[source] = {
                                                name = source,
                                                available = variant ~= 1,
                                                known = true,
                                                fresh = variant ~= 3,
                                                stale = variant == 3,
                                                updatedAt = 100,
                                                value = values[source] or -120,
                                                raw = values[source],
                                                unitText = source == "RQly" and "%"
                                                    or source == "1RSS" and "dBm"
                                                    or "mAh",
                                                precision = source == "Alt" and 3 or 0,
                                            }
                                        end
                                        return feeds[source]
                                    end
                                    return {
                                        settingsValidation = proof,
                                        theme = theme,
                                        themeBuilder = builder,
                                        primitives = primitives,
                                        fonts = builder.typography(shape[1], shape[2]),
                                        span = { colSpan = shape[1], rowSpan = shape[2] },
                                        telemetry = {
                                            subscribe = subscribe,
                                            link = function()
                                                return { live = variant ~= 3, indicator = variant ~= 3, rssi = 85 }
                                            end,
                                        },
                                        model = variant ~= 1
                                                and {
                                                    timer = function()
                                                        return {
                                                            available = true,
                                                            name = variant == 4 and string.rep("W", 80) or "FLIGHT",
                                                            value = variant == 3 and -99999 or 299,
                                                            start = variant == 4 and 18000 or 300,
                                                            countdown = true,
                                                            stale = variant == 3,
                                                        }
                                                    end,
                                                    txVoltage = function()
                                                        return {
                                                            available = true,
                                                            value = variant == 4 and 10.1 or 7.9,
                                                            stale = variant == 3,
                                                        }
                                                    end,
                                                    batteryRange = function()
                                                        return { available = true, min = 6.4, max = 8.4 }
                                                    end,
                                                }
                                            or nil,
                                        state = function(state, accent)
                                            return builder.state(theme, state, accent)
                                        end,
                                    }
                                end,
                                settings = settings,
                            }
                        end
                    end
                end
            end
        end
    end
    return cases
end
