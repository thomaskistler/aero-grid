-- SPDX-License-Identifier: GPL-2.0-only

return function(load, host, only)
    local panelHost, builder = load("lib/panel_host.lua"), host.themeBuilder
    local cases = {}
    local function settle(case, context)
        if case.panel.refresh then
            for _ = 1, case.kind == "chart" and 400 or case.kind == "output" and 100 or 1 do
                case.panel.refresh(context)
            end
        end
        assert(not context.framePhase, case.name .. ": chart frame must finish without service progress")
    end
    for _, kind in ipairs({ "metric", "link-status", "tx-battery", "flight-timer" }) do
        if not only or only == kind then
            for _, case in ipairs(load("@support/construction_cases.lua")(load, builder, kind)) do
                case.settle = settle
                cases[#cases + 1] = case
            end
        end
    end
    local function config(kind, variant)
        local label = variant == 4 and string.rep("W", 80) or "READING"
        if kind == "output" then
            return {
                label = label,
                firstChannel = variant == 4 and 32 or 1,
                channelCount = 32,
                showNames = variant ~= 2,
                showTrim = variant ~= 3,
            }
        elseif kind == "navigation" then
            return {
                label = label,
                source = "GPS",
                satelliteSource = "Sats",
                showTape = variant >= 3,
                showCoordinates = variant ~= 2,
            }
        elseif kind == "chart" then
            local metrics = {}
            for index = 1, variant == 1 and 0 or variant == 2 and 1 or 3 do
                metrics[index] = { source = "Q" .. index, label = label }
            end
            return { label = label, armSwitch = "SAv", duration = "30s", metrics = metrics }
        elseif kind == "state" then
            local entries = {}
            for index = 1, variant == 1 and 1 or 3 do
                entries[index] = {
                    label = "STATE" .. index,
                    states = {
                        { switch = "SA^", text = label, background = variant == 4 and "critical" or "normal" },
                        { switch = "SA-", text = "MID" },
                        { switch = "SAv", text = "DOWN" },
                    },
                }
            end
            return { entries = entries }
        elseif kind == "trim-panel" then
            return { label = label, readout = ({ "none", "raw", "percent", "percent" })[variant] }
        elseif kind == "host-diagnostics" then
            return { section = ({ "identity", "theme", "panels", "sources" })[variant] }
        elseif kind == "service-probe" then
            return { service = ({ "telemetry", "model", "control", "navigation" })[variant], source = "Q1" }
        elseif kind == "theme-showcase" then
            return {}
        end
        return { label = label, showLabels = variant ~= 2, showIndex = variant ~= 2 }
    end
    for _, kind in ipairs({
        "navigation",
        "chart",
        "output",
        "theme-showcase",
        "flight-counter",
        "flight-mode",
        "model-identity",
        "state",
        "trim-panel",
        "host-diagnostics",
        "service-probe",
    }) do
        if not only or only == kind then
            local panel = load("panels/" .. kind .. ".lua")
            for _, mode in ipairs({ "modern-dark", "modern-light" }) do
                local theme = builder.build(mode)
                for columns = 1, 4 do
                    for rows = 1, 4 do
                        if panelHost.supportsSpan(panel, columns, rows) then
                            for variant = 1, 4 do
                                local settings = assert(panelHost.resolveSettings(panel, config(kind, variant)))
                                local case = {
                                    kind = kind,
                                    panel = panel,
                                    settings = settings,
                                    rect = { x = 0, y = 0, w = columns * 121 - 4, h = rows * 69 - 4 },
                                    name = kind .. "/" .. mode .. "/" .. columns .. "x" .. rows .. "/" .. variant,
                                    settle = settle,
                                }
                                function case.dependencies()
                                    local span = { colSpan = columns, rowSpan = rows }
                                    local services = host.dashboardLoader.buildServices(host, span)
                                    services.theme, services.fonts = theme, builder.typography(columns, rows)
                                    services.themeBuilder = builder
                                    services.state = function(state, accent)
                                        return builder.state(theme, state, accent)
                                    end
                                    local available, now = variant ~= 1, 320
                                    services.clock = function()
                                        return now
                                    end
                                    local feed = {
                                        available = available,
                                        known = true,
                                        fresh = variant ~= 3,
                                        stale = variant == 3,
                                        updatedAt = now,
                                        value = 98765.432,
                                        raw = 999,
                                        precision = 3,
                                        unitText = "mAh",
                                    }
                                    local function describe(_, rows)
                                        rows[1] = { label = "Source", text = "Q1" }
                                        rows[2] = { label = "Reading", text = "98765.432mAh" }
                                        return 2
                                    end
                                    services.telemetry = {
                                        subscribe = function()
                                            return feed
                                        end,
                                        describe = describe,
                                    }
                                    local identity = {
                                        available = available,
                                        name = variant == 4 and string.rep("W", 80) or "MODEL",
                                        labels = "GLIDER, ELECTRIC, AEROBATIC",
                                        bitmapPath = variant == 4
                                                and services.host.path .. "assets/aerogrid-mark-45.png"
                                            or nil,
                                    }
                                    services.model = {
                                        identity = function()
                                            return identity
                                        end,
                                        flightMode = function()
                                            return { available = available, name = "LANDING", index = 8 }
                                        end,
                                        widestFlightModeName = function()
                                            return "WWWWWWWWWW"
                                        end,
                                        txVoltage = function()
                                            return { available = available, value = 7.9 }
                                        end,
                                        timer = function()
                                            return { available = available, name = "FLIGHT", value = -99999 }
                                        end,
                                        describe = describe,
                                    }
                                    services.control = {
                                        output = function(_, channel)
                                            return {
                                                available = available,
                                                nameReady = variant ~= 2,
                                                name = "WWWW long channel",
                                                fraction = channel % 2 == 0 and -1.5 or 1.5,
                                                trim = { available = variant ~= 3, fraction = 0.75 },
                                            }
                                        end,
                                        trim = function()
                                            return {
                                                available = available,
                                                fraction = -0.75,
                                                value = -384,
                                                raw = -384,
                                                centered = false,
                                                threePosition = variant == 4,
                                            }
                                        end,
                                        globalVariable = function()
                                            return feed
                                        end,
                                        displaySwitch = function()
                                            return {
                                                known = true,
                                                available = available,
                                                fresh = true,
                                                value = variant ~= 2,
                                            }
                                        end,
                                        describe = describe,
                                    }
                                    local arm = {
                                        key = "SAv",
                                        configured = true,
                                        available = true,
                                        fresh = true,
                                        value = true,
                                        updatedAt = 0,
                                    }
                                    services.armed = {
                                        state = function()
                                            return arm
                                        end,
                                    }
                                    services.flight = {
                                        state = function()
                                            return { active = variant == 4 }
                                        end,
                                    }
                                    services.navigation = {
                                        describeDistanceParts = load("lib/navigation_service.lua").describeDistanceParts,
                                        subscribe = function()
                                            return {
                                                source = "GPS",
                                                known = true,
                                                fix = available,
                                                home = available,
                                                state = variant == 3 and "stale" or "normal",
                                                latitude = 47.3769,
                                                longitude = 8.5417,
                                                distance = 9876543.21,
                                                bearing = variant * 119.5,
                                            }
                                        end,
                                        describe = describe,
                                    }
                                    if kind == "chart" then
                                        local support = load("lib/services.lua")
                                        local runtime = support.runtime(support.environment({
                                            getTime = function()
                                                return now
                                            end,
                                        }))
                                        runtime.byId.armed = services.armed
                                        runtime.byId.telemetry = {
                                            subscribe = function()
                                                return {}
                                            end,
                                            observe = function() end,
                                        }
                                        services.history =
                                            load("lib/history_service.lua").new(runtime.env, support, runtime)
                                        services.seedHistory = function()
                                            for point = 1, 32 do
                                                now, arm.updatedAt = point * 10, point * 10
                                                services.history:advance(now)
                                                for _, metric in ipairs(settings.metrics) do
                                                    services.history:sample({
                                                        name = metric.source,
                                                        value = (point % 2 == 0 and 1 or -1) * point * 98765.432,
                                                        kind = "number",
                                                        fresh = true,
                                                        updatedAt = now,
                                                        precision = 3,
                                                        unitText = "mAh",
                                                    }, now)
                                                end
                                            end
                                        end
                                    end
                                    return services
                                end
                                cases[#cases + 1] = case
                            end
                        end
                    end
                end
            end
        end
    end
    assert(#cases > 0, "missing reflow cases: " .. tostring(only))
    return cases
end
