-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local logger = load("lib/diagnostics_log.lua")
    return function(section, variant)
        local host = {
            path = "/WIDGETS/AeroGrid/",
            packageInfo = { version = "1.2.3" },
            theme = { mode = "modern-dark", requested = "unknown" },
            themeSource = "option",
            panels = {},
            rejected = {},
            notices = {},
            serviceRuntime = { byId = { telemetry = { entries = {} } } },
            layoutName = "Flight",
            layoutOrigin = "model",
            layoutPath = "/layouts/Flight.yaml",
            modelFilename = "model.yml",
            peers = {},
        }
        local count = variant == 2 and 128 or variant == 4 and 0 or 16
        local sources = host.serviceRuntime.byId.telemetry.entries
        for index = 1, count do
            local placement = { id = "p" .. index, type = "metric", colSpan = 2, rowSpan = 2 }
            host.panels[index] = {
                placement = placement,
                failed = false,
                settings = {},
                instance = {},
            }
            host.rejected[index] = { placement = placement, reason = "invalid setting " .. index }
            host.notices[index] = { severity = "warning", text = "notice " .. index }
            host.serviceRuntime.byId.telemetry.entries[index] = {
                state = { name = "SOURCE " .. index, id = index, known = true, state = "normal" },
            }
        end
        local log = logger.new()
        host.diagnosticsLog = log
        log:register(host)
        if section == "log" then
            host.panels[#host.panels + 1] = {
                placement = { type = "host-diagnostics" },
                settings = { section = "log", maxEntries = 256 },
                instance = {},
            }
            for index = 1, variant == 2 and 8 or 1 do
                local peer = { panels = {} }
                for position = 1, 16 do
                    peer.panels[position] = {
                        placement = { type = "host-diagnostics" },
                        settings = { section = "identity" },
                        instance = {},
                    }
                end
                host.peers[index] = peer
                log:register(peer)
            end
            log.count = variant == 4 and 0 or variant == 2 and 256 or 64
        end
        local function change(cycle)
            host.layoutName, host.modelFilename = "Flight " .. cycle, "model" .. cycle .. ".yml"
            for index, entry in ipairs(host.panels) do
                entry.failed = entry.placement.type ~= "host-diagnostics" and (index + cycle) % 3 == 0
                entry.error = "failure " .. cycle
            end
            for index, entry in ipairs(host.rejected) do
                entry.reason = "rejected " .. cycle .. ":" .. index
            end
            for index, entry in ipairs(host.notices) do
                entry.text = "notice " .. cycle .. ":" .. index
            end
            for index, entry in ipairs(sources) do
                entry.state.known = (index + cycle) % 3 ~= 0
                entry.state.state = cycle % 2 == 0 and "stale" or "normal"
            end
            for index = 1, log.count do
                log.entries[index] = {
                    time = cycle * 100 + index,
                    host = "Flight#1",
                    panel = "nav",
                    text = "message " .. cycle .. ":" .. index,
                }
            end
        end
        change(1)
        if variant == 3 then
            host.theme, host.serviceRuntime, host.diagnosticsLog = nil, nil, nil
        end
        return host, change
    end
end
